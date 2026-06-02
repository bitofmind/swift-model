# SwiftModel

[![Swift 6.1+](https://img.shields.io/badge/Swift-6.1%2B-orange.svg)](https://swift.org)
[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager)
[![macOS](https://img.shields.io/github/actions/workflow/status/bitofmind/swift-model/ci.yml?branch=main&label=macOS)](https://github.com/bitofmind/swift-model/actions/workflows/ci.yml)
[![Linux](https://img.shields.io/github/actions/workflow/status/bitofmind/swift-model/ci.yml?branch=main&label=Linux)](https://github.com/bitofmind/swift-model/actions/workflows/ci.yml)
[![Android build](https://img.shields.io/github/actions/workflow/status/bitofmind/swift-model/ci.yml?branch=main&label=Android%20build)](https://github.com/bitofmind/swift-model/actions/workflows/ci.yml)
[![WASM build](https://img.shields.io/github/actions/workflow/status/bitofmind/swift-model/ci.yml?branch=main&label=WASM%20build)](https://github.com/bitofmind/swift-model/actions/workflows/ci.yml)

Composable models for SwiftUI — plain structs with automatic async lifetime, a live model hierarchy that carries dependencies and events, and exhaustive testing, with fine-grained observation from iOS 14.

```swift
@Model struct SearchModel {
    var query   = ""
    var results: [Repo] = []

    func onActivate() {
        // Runs when the model goes live; restarts on each new query,
        // cancelling the previous search — and stops when the model is removed.
        node.task(id: query) { query in
            results = (try? await node.gitHubClient.search(query)) ?? []
        }
    }
}
```

- **Async work that cleans up after itself.** `node.task` and `node.forEach` start when the model goes live and are cancelled when it's removed — no stored `Task`, no `deinit`, no manual teardown to forget.
- **A live model hierarchy.** Every model knows its place in the tree, and that's how it reaches `node`'s tools: dependencies resolved by position, typed events up and down, top-down environment, bottom-up preferences.
- **Exhaustive tests, no setup.** Drive the model, assert the outcome — any state change you didn't assert fails the test. Tests check *what changed*, not *how you got there*, so refactors don't break them.
- **Structurally safe.** Models are structs, so retain cycles can't form and `[weak self]` is never needed — one less thing to think about, guaranteed by the compiler.

## Install

```swift
.package(url: "https://github.com/bitofmind/swift-model", from: "1.0.0")
```

**Xcode app targets** need one extra build setting on the **app target** (not the test target):

```
OTHER_LDFLAGS = $(inherited) -weak_framework Testing
```

Without it the app crashes at launch outside a test context (`Library not loaded: @rpath/Testing.framework/Testing`), because SwiftModel references `Testing.framework` symbols at compile time. Command-line `swift build` / `swift test` need no extra setup; app-hosted tests using `BUNDLE_LOADER` need one more setting — see [Xcode setup](Docs/Testing.md#xcodeproj-setup).

## The core loop

The `SearchModel` above is a complete feature. `@Model` gives the struct observable storage and a `node` interface for async work, dependencies, and its place in the model hierarchy. `node.task(id:)` watches a value expression and restarts the async task whenever it changes, cancelling any in-flight one first; `node.gitHubClient` resolves a dependency through a keypath — the same one you override in tests and previews. (`task(id:)` builds on `Observed`, which tracks any Swift value expression, not just simple properties, and works from iOS 14 — Apple's similar `Observations` arrived in iOS 26.)

Here's the rest of the loop — a view and a test.

### Connect it to a view

```swift
import SwiftUI

struct SearchView: View {
    @ObservedModel var model: SearchModel

    var body: some View {
        List(model.results) { repo in Text(repo.name) }
            .searchable(text: $model.query)
    }
}

@main struct SearchApp: App {
    let model = SearchModel().withAnchor()
    var body: some Scene {
        WindowGroup { SearchView(model: model) }
    }
}
```

`withAnchor()` activates the model hierarchy — starting `onActivate` tasks, wiring up dependencies, and registering it for observation. It returns the same model, so it composes naturally.

### Test exhaustively

No test harness setup required. Override dependencies at the call site, drive the model, assert the final state — any unasserted change is a failure:

```swift
import Testing
import SwiftModel

@Test(.modelTesting) func testSearch() async {
    let model = SearchModel().withAnchor {
        $0.gitHubClient.search = { _ in Repo.mocks }
    }
    model.query = "swift"
    await expect(!model.results.isEmpty)
}
```

`expect { }` waits for all predicates to become true, settles async work, and fails if the model changed anything you didn't assert.

Because tests assert the *outcome* — not the sequence of steps that produced it — you can rename a method, split an async effect, or move work to a helper and the test keeps passing, as long as the final state is the same. See [Testing](Docs/Testing.md).

## Why @Model and not just @Observable?

`@Observable` gives you reactive state. Everything *around* it you still build and maintain by hand: starting and cancelling async work as the model comes and goes, resolving dependencies, routing events and shared values through the hierarchy, and keeping all of it testable. `@Model` folds those into the model itself — `onActivate` and `node.task` tie async work to the model's lifetime, `node` resolves dependencies and routes events by position in the tree, and the test harness is built in. And `@ObservedModel` gives plain SwiftUI views fine-grained, per-property observation back to **iOS 14** — where `@Observable` needs 17. The table below has the point-by-point comparison.

## How it compares

| | `@Observable` / MVVM | TCA | **SwiftModel** |
|---|---|---|---|
| Boilerplate | Low | High | **Low** |
| Retain cycles | Manual `[weak self]` | Low | **None — structural guarantee** |
| Exhaustive testing | No | Yes (action-ordered) | **Yes (state-focused)** |
| Refactor-resilient tests¹ | — | No | **Yes** |
| Async lifetime | Manual `Task` | Effects / Actions | **`node.task` + auto-cancel** |
| Model events | Manual callbacks | Actions | **Typed streams, any direction** |
| Undo / Redo | DIY | DIY | **Built-in** |
| Hierarchy queries | None | None | **Built-in** |
| Context propagation | View `@Environment` only | None | **Model-layer environment + preferences** |
| Shared state | Manual | `@Shared` (value sync) | **Model dependency (live instance)** |
| Thread safety | `@MainActor` discipline | `@MainActor` discipline | **Lock-based, any thread** |
| Fine-grained observation | iOS 17+ | iOS 16 needs view wrappers² | **iOS 14+, in plain views** |
| Learning curve | Minimal | Steep | **Moderate** |

¹ SwiftModel tests assert final state, so restructuring internals — renaming a method, splitting an effect — leaves them passing. Action-sequence tests (as in TCA) deliberately encode those steps instead: a different trade-off, not a flaw.

² On iOS 16 and earlier, TCA observes state via the [swift-perception](https://github.com/pointfreeco/swift-perception) back-port, which requires wrapping view bodies in `WithPerceptionTracking`. SwiftModel needs no body wrapper; the one exception is model reads inside lazy `@ViewBuilder` closures (`.sheet`, `NavigationStack` destinations) on iOS 16, which use a `ModelScope`.

## What's in the box

**[Models and composition](Docs/Models.md)** — `@Model` macro, child models, optional and collection composition, `@ModelContainer` for navigation enums and reusable wrappers.

**[Async lifetime](Docs/Lifecycle.md)** — `node.task` and restart-on-change `task(id:)`, value transitions with `onChange(of:)`, reactive streams with `Observed`, `observeModifications`, transactions, cancellation groups, and `withActivation` for injecting behaviour from the outside.

**[Dependency injection](Docs/Dependencies.md)** — `@ModelDependency`, per-model and per-hierarchy overrides, preview values, and test overrides at the anchor site.

**[Navigation](Docs/Navigation.md)** — modal sheets, navigation stacks, and deep links driven by model state. No extra libraries required.

**[The model hierarchy](Docs/Hierarchy.md)** — typed events up and down the tree, top-down environment and bottom-up preferences, and `mapHierarchy` / `reduceHierarchy` for querying state across any region.

**[Testing](Docs/Testing.md)** — `expect { }`, `settle()`, `require()`, `TestProbe`, exhaustivity control per category, time-control with `TestClock`, and `withModelTesting` for non-trait contexts.

**[Debugging](Docs/Debugging.md)** — `withDebug()`, diff styles, trigger tracing, and `DebugOptions` for `memoize`, `Observed`, and `observeModifications`.

**[Undo and redo](Docs/Undo.md)** — `node.trackUndo()` with selective key-path tracking, `UndoManager` integration, and observable `canUndo` / `canRedo`.

## Examples

| Example | What it shows |
|---|---|
| [CounterFact](Examples/CounterFact) | Nested models, async effects with error handling, dependency injection |
| [Search](Examples/Search) | Cancel-in-flight search, per-item async loading, `TestProbe`, `withActivation` in previews and tests |
| [Onboarding](Examples/Onboarding) | 3-step sign-up wizard: `@ModelContainer` enum navigation, `node.task(id:)` for async username availability check, `node.local`, `node.task` with `catch:` |
| [TodoList](Examples/TodoList) | Undo/redo with selective tracking, preference aggregation (bottom-up), environment propagation (top-down), targeted debug with `Observed(debug:)` |
| [Standups](Examples/Standups) | Complete app: navigation, timers, speech recognition, persistence, exhaustive tests |

Clone the repo and open any example in Xcode to run it immediately.

## What SwiftModel Is Not

**Not a UI framework.** SwiftModel lives in the model layer — views are plain SwiftUI. No custom containers, no prescribed navigation wrappers. Existing SwiftUI knowledge applies directly.

**Not a whole-app commitment.** Add `@Model` to one struct and wire up one view. The rest of your codebase is unchanged. Adopt incrementally; there is no forced rewrite.

**Not a Combine replacement.** SwiftModel uses `async`/`await` throughout. If your project uses Combine, `node.onReceive(_:)` lets you subscribe to any publisher for the model's lifetime — but Combine is never required.

**Not magic.** `@Model` is a code generator. In Xcode, `Editor → Expand Macro` shows exactly what it produces. No runtime swizzling, no reflection, no hidden dispatch.

## Acknowledgements

SwiftModel builds on several open-source libraries from [Point-Free](https://www.pointfree.co). [swift-dependencies](https://github.com/pointfreeco/swift-dependencies) powers the dependency injection system which means you can use community-built dependency wrappers directly. [swift-custom-dump](https://github.com/pointfreeco/swift-custom-dump) provides the structured diffs in test failure messages and debug output. And `reportIssue` (from [xctest-dynamic-overlay](https://github.com/pointfreeco/xctest-dynamic-overlay)) is how SwiftModel surfaces runtime warnings in tests and in Xcode's issue navigator.

The ideas around exhaustive testing and structured async effects were directly inspired by [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) — SwiftModel takes a different approach, but Point-Free's work on the problem space has been invaluable.

---

If SwiftModel is useful to you, a star helps others find it. Issues and pull requests are welcome — this is a spare-time project, so responses may take a day or two.
