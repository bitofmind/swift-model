# SwiftModel

[![Swift 6.1+](https://img.shields.io/badge/Swift-6.1%2B-orange.svg)](https://swift.org)
[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager)
[![macOS](https://img.shields.io/github/actions/workflow/status/bitofmind/swift-model/ci.yml?branch=main&label=macOS)](https://github.com/bitofmind/swift-model/actions/workflows/ci.yml)
[![Linux](https://img.shields.io/github/actions/workflow/status/bitofmind/swift-model/ci.yml?branch=main&label=Linux)](https://github.com/bitofmind/swift-model/actions/workflows/ci.yml)
[![Android build](https://img.shields.io/github/actions/workflow/status/bitofmind/swift-model/ci.yml?branch=main&label=Android%20build)](https://github.com/bitofmind/swift-model/actions/workflows/ci.yml)
[![WASM build](https://img.shields.io/github/actions/workflow/status/bitofmind/swift-model/ci.yml?branch=main&label=WASM%20build)](https://github.com/bitofmind/swift-model/actions/workflows/ci.yml)

Composable models for SwiftUI — struct-based, automatic async lifetime, exhaustive testing, and dependency injection from iOS 14.

```swift
@Model struct SearchModel {
    var query   = ""
    var results: [Repo] = []

    func onActivate() {
        // Cancel-in-flight: each new query cancels the previous search.
        // No stored Task. No [weak self]. Cancelled automatically when removed.
        node.task(id: query) { query in
            results = (try? await node.gitHubClient.search(query)) ?? []
        }
    }
}
```

- **No retain cycles, ever.** Structs can't capture `self` — the compiler makes retain cycles impossible, not just unlikely.
- **Lifetime-tied tasks.** `node.task` and `node.forEach` are cancelled when the model is removed. No stored `Task`, no `deinit`, no manual cleanup.
- **Exhaustive tests.** Any state change you didn't assert is a test failure. Refactor freely — tests check *what changed*, not *how you got there*.
- **Dependency injection anywhere.** Override per model, per hierarchy level, or per test — with a trailing closure at the call site.

## Install

```swift
.package(url: "https://github.com/bitofmind/swift-model", from: "1.0.0")
```

**Xcode app targets:** SwiftModel references `Testing.framework` symbols at compile time (Xcode 16+). Without a weak link the app crashes at launch outside a test context with `Library not loaded: @rpath/Testing.framework/Testing`. Add this to your **app target's** build settings, regardless of whether you use SPM or xcodeproj to structure your project:

```
OTHER_LDFLAGS = $(inherited) -weak_framework Testing
```

**`swift build` / `swift test`** (command-line, no Xcode): no extra configuration required.

If you also use app-hosted tests with `BUNDLE_LOADER`, one additional setting is required — see [Xcodeproj setup](Docs/Testing.md#xcodeproj-setup) in Testing.md.

## The core loop

### Define a model

```swift
import SwiftModel

@Model struct SearchModel {
    var query   = ""
    var results: [Repo] = []

    func onActivate() {
        // Cancel-in-flight. With a plain @Observable class you'd need a stored
        // Task, [weak self] in every closure, and a deinit for cleanup. Here it's one line.
        node.task(id: query) { query in
            results = (try? await node.gitHubClient.search(query)) ?? []
        }
    }
}
```

`@Model` gives the struct observable storage, a `node` interface for async work and dependencies, and everything needed to participate in the model hierarchy. `node.task(id:)` watches any value expression and restarts the async task whenever it changes — cancelling the previous in-flight task first. Under the hood it uses `Observed { query }`, which tracks any Swift value expression and emits whenever its result changes — not just simple properties. (Apple added a similar `Observations` type in iOS 26; `Observed` works from iOS 14.)

`node.gitHubClient` accesses the `GitHubClient` dependency via a `DependencyValues` keypath — the same keypath used to override it in tests and previews, with no change to the model itself.

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

Compare to TCA, where tests encode the full action sequence:

```swift
// TCA
await store.send(.factButtonTapped) { $0.isLoading = true }
await store.receive(\.factResponse) { $0.fact = "42 is a great number" }

// SwiftModel
model.factButtonTapped()
await expect { model.fact == "42 is a great number" }
```

Rename a method or split an async effect — the test keeps passing as long as the outcome is the same. See [Testing](Docs/Testing.md) for the full comparison.

## Why @Model and not just @Observable?

`@Observable` handles reactive state well. It leaves the rest to you. Here's the same model written with `@Observable`:

```swift
@Observable class SearchModel {
    var query = "" { didSet { scheduleSearch() } }
    var results: [Repo] = []
    private var searchTask: Task<Void, Never>?

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in   // forget this → retain cycle
            guard !Task.isCancelled, let self else { return }
            self.results = (try? await GitHubClient.live.search(self.query)) ?? []
        }
    }
    deinit { searchTask?.cancel() }          // forget this → tasks outlive the view
}
```

`GitHubClient.live` is hardcoded — there is no clean path to inject a test double.

| | `@Observable` class | SwiftModel `@Model` |
|---|---|---|
| **Async task lifetime** | Manual `Task`; you manage cancellation | `node.task` cancels automatically when the model is removed |
| **Self references** | `[weak self]` required in every async closure | Not needed — and not allowed; the compiler rejects it on structs |
| **Testing** | No built-in harness; roll your own | `expect { }` exhaustively asserts state, events, and running tasks |
| **Dependency injection** | Global `@Environment` only | Per-model overrides at any hierarchy level |
| **Minimum iOS** | iOS 17 | iOS 14 |

## How it compares

| | `@Observable` / MVVM | TCA | **SwiftModel** |
|---|---|---|---|
| Boilerplate | Low | Very high | **Low** |
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
| Learning curve | Minimal | Very steep | **Moderate** |

¹ TCA tests encode action sequences — renaming a case or splitting an effect breaks tests even when visible behaviour is unchanged. SwiftModel tests assert final state only.

## What's in the box

**[Models and composition](Docs/Models.md)** — `@Model` macro, child models, optional and collection composition, `@ModelContainer` for navigation enums and reusable wrappers.

**[Async lifetime](Docs/Lifecycle.md)** — `node.task`, `node.task(id:)` for restart-on-change, `node.onChange(of:)` for old/new value transitions, `node.forEach`, reactive streams with `Observed`, `onActivate`, `withActivation` for composable behaviour injection, `observeAnyModification`, transactions, and cancellation groups.

**[Undo and redo](Docs/Undo.md)** — `node.trackUndo()` with selective key-path tracking, `UndoManager` integration, and observable `canUndo` / `canRedo`.

**[Dependency injection](Docs/Dependencies.md)** — `@ModelDependency`, per-model and per-hierarchy overrides, preview values, and test overrides at the anchor site.

**[Navigation](Docs/Navigation.md)** — modal sheets, navigation stacks, and deep links driven by model state. No extra libraries required.

**[Events](Docs/Events.md)** — typed events that travel up or down the model hierarchy. Composable with model-scoped `Event` types.

**[Hierarchy and preferences](Docs/HierarchyAndPreferences.md)** — `mapHierarchy` for tree queries, bottom-up preference aggregation, top-down environment propagation, and local node storage.

**[Testing](Docs/Testing.md)** — `expect { }`, `settle()`, `require()`, `TestProbe`, exhaustivity control per category, time-control with `TestClock`, and `withModelTesting` for non-trait contexts.

**[Debugging](Docs/Debugging.md)** — `withDebug()`, diff styles, trigger tracing, and `DebugOptions` for `memoize` and `Observed`.

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

**Not a UI framework.** SwiftModel sits entirely in the model layer. Views are plain SwiftUI.

**Not an opinion on file structure.** One model per file or many — organise however suits your team.

**Not a Combine replacement.** SwiftModel uses `async`/`await` throughout. Combine is supported via `node.onReceive(_:)` for projects that need it, but is not required.

**Not magic.** The `@Model` macro is a code generator. Expand it in Xcode (`Editor → Expand Macro`) to see exactly what it produces. No runtime swizzling, no reflection.

## Acknowledgements

SwiftModel uses [swift-dependencies](https://github.com/pointfreeco/swift-dependencies) by [Point-Free](https://www.pointfree.co) for its dependency injection system. The ideas around exhaustive testing and structured async effects were directly inspired by [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) — SwiftModel takes a different approach, but Point-Free's work on the problem space has been invaluable.

---

If SwiftModel is useful to you, a star helps others find it. Issues and pull requests are welcome — this is a spare-time project, so responses may take a day or two.
