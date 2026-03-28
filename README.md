# SwiftModel

[![Swift 6.1+](https://img.shields.io/badge/Swift-6.1%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2011%20%7C%20iOS%2014%20%7C%20tvOS%2014%20%7C%20watchOS%206%20%7C%20Linux-blue.svg)](https://swift.org)
[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager)

Composable models for SwiftUI — structured async lifetime, exhaustive testing, and fine-grained observation from iOS 14.

```swift
@Model struct CounterModel {
    var count = 0
    func incrementTapped() { count += 1 }
    func factButtonTapped() {
        node.task {
            let fact = try await node.factClient.fetch(count)
            onFact(count, fact)
        } catch: { error in
            alert = Alert(message: error.localizedDescription)
        }
    }
}
```

- No retain cycles — ever. Structs + weak context. The **compiler** enforces this, not a convention.
- Exhaustive tests that check **final state**, not action sequences — refactor freely without rewriting tests.
- `node.task { }` starts work tied to the model lifetime — auto-cancelled on removal, no `Task` storage needed.
- Works from any thread. No `@MainActor` required in model logic.
- Built-in undo/redo, hierarchy traversal, and preference propagation.

## Install

```swift
.package(url: "https://github.com/bitofmind/swift-model", from: "0.13.0")
```

## The core loop

### Define a model

```swift
import SwiftModel

@Model struct CounterModel {
    var count = 0
    func decrementTapped() { count -= 1 }
    func incrementTapped() { count += 1 }
}
```

`@Model` gives the struct observable storage, a `node` interface for async work and dependencies, and everything needed to participate in the model hierarchy.

### Connect it to a view

```swift
import SwiftUI

struct CounterView: View {
    @ObservedModel var model: CounterModel
    var body: some View {
        HStack {
            Button("-") { model.decrementTapped() }
            Text("\(model.count)")
            Button("+") { model.incrementTapped() }
        }
    }
}

@main struct MyApp: App {
    let model = CounterModel().withAnchor()
    var body: some Scene {
        WindowGroup { CounterView(model: model) }
    }
}
```

`withAnchor()` activates the model hierarchy — starting `onActivate` tasks, wiring up dependencies, and registering it for observation. It returns the same model, so it composes naturally.

### Test exhaustively

No test harness setup required. Call the method, assert the state, and any side effect you didn't assert is a test failure:

```swift
import Testing
import SwiftModel

@Test(.modelTesting) func testIncrement() async {
    let model = CounterModel().withAnchor()
    model.incrementTapped()
    await expect(model.count == 1)
}
```

For async effects and dependencies, override them at the anchor site:

```swift
@Test(.modelTesting) func testFactFetch() async {
    let model = CounterModel().withAnchor {
        $0.factClient.fetch = { n in "\(n) is a perfect number." }
    }
    model.factButtonTapped()
    await expect { model.fact != nil }
}
```

`expect { }` waits for all predicates to become true, settles async work, and fails if the model changed anything you didn't assert.

## Why @Model and not just @Observable?

`@Observable` handles reactive state well. It leaves the rest to you:

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
| Context propagation | `@Environment` | None | **Model-layer environment + preferences** |
| Shared state | Manual | `@Shared` (value sync) | **Model dependency (live instance)** |
| Thread safety | `@MainActor` discipline | `@MainActor` discipline | **Lock-based, any thread** |
| Learning curve | Minimal | Very steep | **Moderate** |

¹ TCA tests encode action sequences — renaming a case or splitting an effect breaks tests even when visible behaviour is unchanged. SwiftModel tests assert final state only.

## What's in the box

**[Models and composition](Docs/Models.md)** — `@Model` macro, child models, optional and collection composition, `@ModelContainer` for navigation enums and reusable wrappers.

**[Async lifetime](Docs/Lifecycle.md)** — `node.task`, `node.forEach`, reactive streams with `Observed`, `onActivate`, `withActivation` for composable behaviour injection, `observeAnyModification`, transactions, and cancellation groups.

**[Undo and redo](Docs/Lifecycle.md#undo-and-redo)** — `node.trackUndo()` with selective key-path tracking, `UndoManager` integration, and observable `canUndo` / `canRedo`.

**[Dependency injection](Docs/Dependencies.md)** — `@ModelDependency`, per-model and per-hierarchy overrides, preview values, and test overrides at the anchor site.

**[Navigation](Docs/Navigation.md)** — modal sheets, navigation stacks, and deep links driven by model state. No extra libraries required.

**[Events](Docs/Events.md)** — typed events that travel up or down the model hierarchy. Composable with model-scoped `Event` types.

**[Hierarchy and preferences](Docs/HierarchyAndPreferences.md)** — `mapHierarchy` for tree queries, bottom-up preference aggregation, top-down environment propagation, and local node storage.

**[Testing](Docs/Testing.md)** — `expect { }`, `settle()`, `require()`, `TestProbe`, exhaustivity control per category, time-control with `TestClock`, and `withModelTesting` for non-trait contexts.

## Examples

| Example | What it shows |
|---|---|
| [CounterFact](Examples/CounterFact) | Nested models, async effects with error handling, dependency injection |
| [Standups](Examples/Standups) | Complete app: navigation, timers, speech recognition, persistence, exhaustive tests |
| [TodoList](Examples/TodoList) | Undo/redo with selective tracking, preference aggregation |
| [SharedState](Examples/SharedState) | Shared model identity across tabs — one instance, multiple views |
| [SignUpFlow](Examples/SignUpFlow) | Enum-based stack navigation, environment propagation, shared model state |
| [SignUpFlow (dependency)](Examples/SignUpFlowUsingDependency) | Same flow using `@ModelDependency` — compare the two approaches side by side |

Clone the repo and open any example in Xcode to run it immediately.

## What SwiftModel Is Not

**Not a UI framework.** SwiftModel sits entirely in the model layer. Views are plain SwiftUI.

**Not an opinion on file structure.** One model per file or many — organise however suits your team.

**Not a Combine replacement.** SwiftModel uses `async`/`await` throughout. Combine is supported via `node.onReceive(_:)` for projects that need it, but is not required.

**Not magic.** The `@Model` macro is a code generator. Expand it in Xcode (`Editor → Expand Macro`) to see exactly what it produces. No runtime swizzling, no reflection.
