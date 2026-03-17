# SwiftModel

[![Swift 5.9.2+](https://img.shields.io/badge/Swift-5.9.2%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2011%20%7C%20iOS%2014%20%7C%20tvOS%2014%20%7C%20watchOS%206%20%7C%20Linux-blue.svg)](https://swift.org)
[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager)

Composable value-type models for SwiftUI. The structured architecture of TCA without reducers, action enums, or effect indirection.

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
- Exhaustive tests that check **final state**, not action sequences. Refactor freely without rewriting tests.
- Built-in async lifecycle: `node.task { }` starts work tied to the model lifetime — auto-cancelled on deactivation.
- Built-in undo/redo, hierarchy traversal, context and preference propagation.
- Works from any thread. No `@MainActor` hops required in model logic.

## Quick Start

Add to `Package.swift`:

```swift
.package(url: "https://github.com/bitofmind/swift-model", from: "0.10.0")
```

Then build a model, a view, and an entry point — no boilerplate:

```swift
import SwiftModel
import SwiftUI

@Model struct CounterModel {
    var count = 0
    func decrementTapped() { count -= 1 }
    func incrementTapped() { count += 1 }
}

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

The same model is exhaustively testable with no extra setup:

```swift
import Testing

@Test func testIncrement() async {
    let (model, tester) = CounterModel().andTester()
    model.incrementTapped()
    await tester.assert {
        model.count == 1
    }
}
```

Clone the repo and open `Examples/CounterFact` to run a complete app immediately.

## How SwiftModel Compares

| | Plain MVVM | TCA | **SwiftModel** |
|---|---|---|---|
| Boilerplate | Low | Very high | **Low** |
| Retain cycles | Manual `[weak self]` | Low | **None — structural guarantee** |
| Exhaustive testing | No | Yes (action-ordered) | **Yes (state-focused)** |
| Refactor-resilient tests¹ | — | No | **Yes** |
| Async lifecycle | Manual `Task` | Effects/Actions | **`node.task` + auto-cancel** |
| Model events | Manual callbacks | Actions | **Typed streams, up/down hierarchy** |
| Undo/Redo | DIY | DIY | **Built-in** |
| Hierarchy queries | None | None | **Built-in** |
| Context propagation | `@Environment` | None | **Model-layer context + preferences** |
| Shared state | Manual | `@Shared` (value sync) | **Model dependency** |
| Navigation | Manual | Navigation library | **Patterns (no extra lib)** |
| Thread safety | `@MainActor` discipline | `@MainActor` discipline | **Lock-based, any thread** |
| Learning curve | Minimal | Very steep | **Moderate** |

¹ TCA tests encode action sequences — renaming an action case or splitting an effect breaks tests even if visible behaviour is unchanged. SwiftModel tests assert final state only.

---

- [What is SwiftModel](#what-is-swiftmodel)
- [Models and Composition](#models-and-composition)
- [SwiftUI Integration](#swiftui-integration)
- [Dependencies](#dependencies)
- [Lifetime and Asynchronous Work](#lifetime-and-asynchronous-work)
- [Undo and Redo](#undo-and-redo)
- [Events](#events)
- [Navigation](#navigation)
- [Testing](#testing)

## What is SwiftModel

Much like SwiftUI's composition of views, SwiftModel uses well-integrated modern Swift tools for composing your app's different features into a hierarchy of models. Under the hood, SwiftModel keeps track of model state changes, dependencies, and ongoing asynchronous work. This results in several advantages:

- Natural injection and propagation of dependencies down the model hierarchy.
- Support for sending events up or down the model hierarchy.
- Exhaustive testing of state changes, events and concurrent operations.
- Integrates fully with modern Swift concurrency with extended tools for powerful lifetime management.
- Fine-grained observation of model state changes.

 > SwiftModel takes inspiration from similar architectures such as [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture), but aims to be less esoteric by using a more familiar style.

### Why not just `@Observable`?

Swift's `@Observable` macro makes a class observable, but it doesn't give you a model architecture. You still need to wire up lifetime management, testing, and dependency injection yourself:

| | `@Observable` class | SwiftModel `@Model` |
|---|---|---|
| **Async work lifetime** | Manual `Task`; you cancel it yourself | `node.task` cancels automatically when the model deactivates |
| **Self references** | `[weak self]` in every async closure | Not needed — and not allowed; the compiler rejects it |
| **Testing** | No built-in harness; roll your own | `ModelTester` exhaustively asserts state, events, and concurrent tasks |
| **Dependency injection** | Global `@Environment` only | Per-model overrides with `withDependencies` at any hierarchy level |

If your app is a single screen with no async work and no tests, `@Observable` is fine. Once you add network calls, navigation, shared services, or the need to test async behaviour, you are rebuilding SwiftModel from scratch.

### Requirements

SwiftModel requires **Swift 5.9.2 / Xcode 15.1** or later (macOS 11+, iOS 14+, tvOS 14+, watchOS 6+, Linux).

### Documentation

Below we will build parts of a sample app that you can see as a whole in the Examples folder of this repository. 

The examples shown below are mostly from the example app [CounterFact](./Examples/CounterFact), but some more advanced examples comes from the [Standups](./Examples/Standups) app.

## Models and Composition

Models are the central building block in SwiftModel. A model declares state together with operations, that composes with other models to provide a model hierarchy for propagating dependencies and events. 

You use the SwiftModel's macro `@Model` to set your type up for model composition and observation tracking.

```swift
import SwiftModel

@Model struct CountModel {
  var count = 0
  
  func decrementTapped() {
    count -= 1
  }
  
  func incrementTapped() {
    count += 1
  }
}
``` 

> **`@Model` structs behave like SwiftUI's `@State`** — the struct is a lightweight handle into a reference-counted backing store. Writing `count += 1` doesn't mutate the struct; it writes through a context pointer to the shared store. This is why setters are non-mutating: you can write `model.count = 5` on a `let model`, and why `[weak self]` is both unnecessary and rejected by the compiler.

### No Retain Cycles — a structural guarantee

Models are structs, so the **compiler** makes retain cycles impossible: you cannot take a `weak` reference to a struct. `[weak self]` is a compile error, not a discipline. This is categorically stronger than class-based architectures (including TCA's `Store` and plain `@Observable` ViewModels) where avoiding retain cycles requires `[weak self]` discipline in every closure.

In practice you can freely store callbacks as `let` properties and capture `self` without risk:

```swift
@Model struct RecordMeetingModel {
    let onSave: @Sendable (String) -> Void
    let onDiscard: @Sendable () -> Void
}

@Model struct AppModel {
    var recording: RecordMeetingModel? = nil

    func startRecording() {
        recording = RecordMeetingModel(
            onSave: { transcript in
                self.saveTranscript(transcript)  // safe — no retain cycle
            },
            onDiscard: {
                self.recording = nil             // safe — no retain cycle
            }
        )
    }
}
```

The strong ownership lives in the model hierarchy (parent → child). Closures that capture `self` capture a context pointer — not a strong object reference — so cycles are structurally impossible.

### Composition

A model can be composed by other models where the most common composition is to have either an inline model, an optional model, or a collection of models.

```swift
@Model struct CounterRowModel {
  var counter = CountModel()
}
```

```swift
@Model struct AppModel {
  var counters: [CounterRowModel] = []
  var factPrompt: FactPromptModel? = nil
  
  var sum: Int {
    counters.reduce(0) { $0 + $1.counter.count }
  }
}
```

> A model has an identity and conforms to `Identifiable` using a default generated id unless overridden by your model. This is e.g. used to identify models in arrays.

> Often it is more convenient and safer to use an [`IdentifiedArray`](https://github.com/pointfreeco/swift-identified-collections) instead of a plain array.

For SwiftModel to be able to detect a composition of models, any container holding other models (directly or indirectly) needs to conform to the `ModelContainer` protocol. This is part of what the `@Model` macro provides a model, but if you nest models insides custom enum and struct types, SwiftModel provides the `@ModelContainer` macro:

```swift
@ModelContainer enum Path {
  case detail(StandupDetail)
  case meeting(Meeting, standup: Standup)
  case record(RecordMeeting)
}
```

`@ModelContainer` works equally well on structs, which makes it useful for reusable wrapper types. For example, a generic paginated list that holds a model alongside metadata:

```swift
@ModelContainer struct Paginated<Item: Model> {
    var items: [Item]
    var currentPage: Int
    var hasMore: Bool
}

@Model struct FeedModel {
    var posts: Paginated<PostModel> = Paginated(items: [], currentPage: 0, hasMore: true)
}
```

SwiftModel will correctly traverse into `Paginated.items` for activation, observation, and event propagation — the wrapper is transparent to the model hierarchy.

### Model Anchor

A model is backed by a behind the scenes context that holds a model's shared state, its relation to other models, overridden dependencies etc.

This context is weakly held by the model which helps avoiding memory cycles when e.g. using callback closures. A model will hold a strong reference to its children, but someone has to hold a strong reference to the root model. This is typically done by using an explicit `withAnchor()` modifier on the root model.

```swift
struct MyApp: App {
  let model = AppModel().withAnchor()
  
  var body: some Scene {
    WindowGroup {
      AppView(model: model)
    }
  }
}
```

If a view is not called more than once, you can create the model with an anchor inline:

```swift
#Preview {
  CounterView(model: CounterModel().withAnchor())
}
```

If you need to keep a reference to both the model and the anchor separately, use `andAnchor()`:

```swift
let (model, anchor) = AppModel().andAnchor()
```

### Model Life Stages

A SwiftModel model goes through different life stages. It starts out in the initial state. This is typically just for a really brief period between calling the initializer and being added to a model hierarchy of anchored models.

```swift
func addButtonTapped() {
  let row = CounterRowModel(...) // Initial state           
  counters.append(row) // row is anchored
}
```

Once an initial model is added to an anchored model, it is set up with a supporting context and becomes anchored.

If the model is later removed from the parent's anchored model, it will lose its supporting context and enter a destructed state.

> A model can also be copied into a frozen copy where the state will become immutable. This is used e.g. when printing state updates, and while running unit tests, to be able to compare previous states of a model with later ones.   

### Model Activation

The `Model` protocol provides an `onActivate()` extension point that is called by SwiftModel once the model becomes part of anchored model hierarchy. This is a perfect place to populate a model's state from its dependencies and to set up listeners on child events and state changes.

> Any parent will always be activated before its children to allow the parent to set up listeners on child events and value changes. Once a parent is deactivated it will cancel its own activities before deactivating its children.

```swift
func onActivate() {
  if standup.attendees.isEmpty {
    standup.attendees.append(Attendee(id: Attendee.ID(node.uuid())))
  }
}
```

You can also compose activation logic from the outside using the `withActivation(_:)` modifier. This is useful when you want to attach behavior to a model without modifying its source, or when building test setups and previews:

```swift
let model = StandupModel()
    .withActivation { $0.loadFromDisk() }
    .withAnchor()
```

Multiple `withActivation` calls are additive — each closure runs in order when the model activates.

### Sharing of Models

A model is typically instantiated and assigned to one place in the hierarchy, but the same *instance* can live at multiple points simultaneously. This is different from TCA's `@Shared`, which synchronises a *value type* across reducers — SwiftModel sharing is richer: the shared model has full lifecycle, sends and receives events, and runs `onActivate()` like any other model.

SwiftModel supports sharing with the following implications:

- A shared model will inherit the dependencies at its initial point of entry to the model hierarchy.
- The shared model is activated on initial anchoring and deactivated once the last reference of the model is removed.
- An event sent from a shared model will be coalesced and receivers will only see a single event (even though it was sent from all its locations in the model hierarchy).
- Similarly a shared model will only receive sent events at most once.

### Debugging State Changes

SwiftModel keeps track of all model state changes and can print diffs, trigger lists, and value snapshots to help you understand what's happening at runtime.

Enable debug output for the lifetime of a model by adding a modifier before anchoring:

```swift
AppModel().withDebug().withAnchor()
```

Or configure what gets printed using `DebugOptions`:

```swift
// Print a diff of the whole model tree whenever anything changes
AppModel().withDebug([.changes()]).withAnchor()

// Also show which properties triggered the update
AppModel().withDebug([.triggers(), .changes()]).withAnchor()

// Use a custom label and output stream
AppModel().withDebug([.changes(), .name("App"), .printer(myStream)]).withAnchor()
```

The trigger format can be `.name` (default), `.withValue` (old → new), or `.withDiff` (structured diff — useful when the trigger value is itself a model):

```swift
// "AppModel.filter: \"a\" → \"b\""
AppModel().withDebug([.triggers(.withValue), .changes()]).withAnchor()

// Full structured diff of the triggering property
AppModel().withDebug([.triggers(.withDiff), .changes()]).withAnchor()
```

Diffs default to `.compact` style (only the changed lines and their structural ancestors). Pass a `DiffStyle` to change this:

```swift
// Show every unchanged sibling as "… (N unchanged)"
model.debug([.changes(.diff(.collapsed))])

// Show the full before/after context
model.debug([.changes(.diff(.full))])
```

To debug a specific expression or enable debug output only temporarily on a live model, use `debug()` on the model directly — it returns a `Cancellable` you can cancel when done:

```swift
// Watch only a specific sub-expression
model.debug([.triggers(), .changes()]) { model.filter }

// Enable temporarily
let cancel = model.debug()
// ... do work ...
cancel.cancel()
```

The same `DebugOptions` are also accepted by `memoize` and `Observed`, so you can trace individual computed values or observation-driven side effects:

```swift
// Print triggers and the new value whenever a memoized result changes
node.memoize(for: "sorted", debug: [.triggers(), .changes(.value)]) { items.sorted() }

// Print which dependency triggered an Observed update
node.forEach(Observed(debug: [.triggers(.withValue)]) { model.count }) { value in ... }
```

> Debug output is only active in `DEBUG` builds.

> The leading underscore on `_printChanges` and `_withPrintChanges` is intentional — it mirrors the convention used by SwiftUI's own `_printChanges()` and TCA's `_printChanges()`. The underscore signals that this is a supported but debug-only tool that should not remain in production code. It is deliberately unsearchable to discourage leaving calls in shipping builds.

## SwiftUI Integration

SwiftModel has been designed to integrate well with SwiftUI. Where you typically conform your models to `ObservableObject` in plain vanilla SwiftUI projects, and get access and view updates by using `@ObservedObject` in your SwiftUI views. In SwiftModel you instead apply `@Model` to your models and use `@ObservedModel` to trigger your views to update on state changes.

```swift
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
```

Access to embedded models and derived properties are straight forward as well.

```swift 
struct AppView: View {
  @ObservedModel var model: AppModel

  var body: some View {
    ZStack(alignment: .bottom) {
      List {
        Text("Sum: \(model.sum)")

        ForEach(model.counters) { row in
          CounterRowView(model: row)
        }
      }

      if let factPrompt = model.factPrompt {
        FactPromptView(model: factPrompt)
      }
    }
  }
}
```

> `@ObservedModel` has been carefully crafted to only trigger view updates when properties you are accessing from your view is updated. In comparison, `@ObservedObject` will trigger a view update no matter what `@Published` property is updated in your `ObservableObject` model object.

### iOS 17+ Observation Compatibility

On iOS 17+, macOS 14+, tvOS 17+, and watchOS 10+, SwiftModel provides enhanced compatibility with Swift's native observation infrastructure. The `@Model` macro works seamlessly with types that conform to the `Observable` protocol (typically via the `@Observable` macro). Models automatically integrate with the platform's `ObservationRegistrar` when available, providing seamless observation support.

**When you need `@ObservedModel`:**
- **Always needed** if you require bindings to your model's properties (e.g., for forms, text fields, steppers)
- **Optional** on iOS 17+ for observation-only use cases (reading properties without creating bindings)

**Why Apple's `@Bindable` doesn't work with Models:**

Apple's `@Bindable` property wrapper (introduced in iOS 17+) is designed to work with reference types (classes) that conform to the `Observable` protocol. However, SwiftModel's `@Model` types are value types (structs) with reference semantics. While the `Observable` protocol itself doesn't require reference types, Apple chose to restrict `@Bindable`'s initializers to only accept classes. This design decision means you cannot use `@Bindable` with Models.

For bindings with Models, continue to use `@ObservedModel` on all iOS versions, which provides the same binding capabilities as `@Bindable` while also supporting SwiftModel's value-type architecture.

### Bindings

The `@ObservedModel` also expose bindings to a model's properties:

```swift 
Stepper(value: $model.count) {
  Text("\(model.count)")
}
```

## Dependencies

For improved control of a model's dependencies to outside systems, such as backend services, SwiftModel has a system where a model can access its dependencies without needing to know how they were configured or set up. This is very similar to how SwiftUI's environment is working.

> This has been popularized by the [swift-dependency](https://github.com/pointfreeco/swift-dependencies) package which SwiftModel integrates with.

You define a dependency type by conforming it to DependencyKey where you provide a default value: 

```swift
import Dependencies 

struct FactClient {
  var fetch: @Sendable (Int) async throws -> String
}

extension FactClient: DependencyKey {
  static let liveValue = FactClient(
    fetch: { number in
      let (data, _) = try await URLSession.shared.data(from: URL(string: "http://numbersapi.com/\(number)")!)
        return String(decoding: data, as: UTF8.self)
      }
   )
}
```

A model accesses its dependencies via its `node`.

```swift
let fact = try await node[FactClient.self].fetch(count)
``` 

> `node` is the model implementor's interface to the SwiftModel runtime. It provides access to dependencies, async tasks, events, cancellations, memoization, and hierarchy queries. It is intended to be used from within a model's own implementation — in `onActivate()`, in methods, and in extensions — not by external consumers of the model.

There is also a convenience macro for dependencies:

```swift
@Model struct CounterModel {
    @ModelDependency var factClient: FactClient
}
```

### DependencyValues

By also extending `DependencyValues` you will get more convenient access to commonly used dependencies:

```
extension DependencyValues {
  var factClient: FactClient {
    get { self[FactClient.self] }
    set { self[FactClient.self] = newValue }
  }
}
```

```swift
let fact = try await node.factClient.fetch(count)
``` 

### Overriding Dependencies

When anchoring your root model you can provide a trailing closure where you can override default dependencies. This is especially useful for testing and previews.

```swift
let model = AppModel().withAnchor {
  $0.factClient.fetch = { "\($0) is a great number!" }
}
```

Any descendant models will inherit its parent’s dependencies.

You can also override a child model's dependencies (and its descendants) using the `withDependencies()` modifier:

```swift
appModel.factPrompt = FactPromptModel(...).withDependencies {
  $0.factClient.fetch = { "\($0) is a great number!" }
}
```

### Model Dependency

A `@Model` type can also be used as a dependency by conforming to `DependencyKey`. When accessed via `@ModelDependency` (or `node[Dep.self]`), SwiftModel integrates it into the context hierarchy as a shared model — one instance, shared across all consumers.

```swift
@Model struct AnalyticsService {
    var isEnabled: Bool = true

    func track(_ event: String) { ... }
}

extension AnalyticsService: DependencyKey {
    static let liveValue = AnalyticsService()
    static let testValue = AnalyticsService()  // used automatically in tests
}

@Model struct FeatureModel {
    @ModelDependency var analytics: AnalyticsService
}
```

Alternatively — and in practice the most convenient approach — extend `DependencyValues` just like you would for a plain dependency:

```swift
extension DependencyValues {
    var analyticsService: AnalyticsService {
        get { self[AnalyticsService.self] }
        set { self[AnalyticsService.self] = newValue }
    }
}
```

This lets every model access the dependency directly via `node`, with no `@ModelDependency` property needed:

```swift
func onActivate() {
    node.analyticsService.track("app_launched")
    node.forEach(Observed { node.analyticsService.isEnabled }) { isEnabled in
        // react to changes
    }
}
```

Overriding works the same way, using either the key path or the subscript form:

```swift
let model = AppModel().withAnchor {
    $0.analyticsService = AnalyticsService(isEnabled: false)  // key path
    // or: $0[AnalyticsService.self] = AnalyticsService(isEnabled: false)
}
```

**Lifecycle.** The dependency model's `onActivate()` is called when it is first accessed by any model in the hierarchy. It is deactivated when the last host model is removed. Multiple models that access the same dependency type receive the same shared context — `onActivate()` runs once and `onCancel` fires once.

**Observation.** A host model can observe properties of the dependency model via `Observed`, exactly as it would observe any child model's properties:

```swift
func onActivate() {
    node.forEach(Observed { analytics.isEnabled }) { isEnabled in
        // fires whenever analytics.isEnabled changes
    }
}
```

**Events from the dependency.** Events sent by the dependency model with the default `to: [.self, .ancestors]` travel up to the host model's event listeners, because the dependency context has the host as a parent.

**Events to the dependency.** The default `node.send(event)` relation `[.self, .ancestors]` does **not** reach dependency models. To deliver an event to a dependency, you must include both `.children` and `.dependencies` in the relation:

```swift
node.send(MyEvent.refresh, to: [.self, .children, .dependencies])
```

**Hierarchy traversal.** `reduceHierarchy` and `mapHierarchy` do not visit dependency models by default. Include `.dependencies` alongside `.descendants` or `.children` to traverse them:

```swift
let services = node.mapHierarchy(for: [.self, .descendants, .dependencies]) {
    $0 as? AnalyticsService
}
```


## Lifetime and Asynchronous Work

A typical model will need to handle asynchronous work such as performing operations and listening on updates from its dependencies. It is also common to listen to model events and state changes that SwiftModel exposes as asynchronous streams.

> **Works from any thread — no `@MainActor` required.**
> Most Swift architectures push all model logic onto `@MainActor` to avoid data races. SwiftModel uses structural locking instead: every read and write is internally synchronised, so you can access your models freely from any `Task`, background queue, or test without actor hops. `@ObservedModel` handles the `@MainActor` hop that SwiftUI requires for view updates, so you never need to annotate your own model code with `@MainActor`. This also makes testing simpler — no `await MainActor.run { }` wrappers needed.

### Tasks

To start some asynchronous work that is tied to the life time of your model you call `node.task()`, similarly as you would do when adding a `task()` to your view. 


```swift
@Model struct CounterModel {
  let count: Int
  let onFact: (Int, String) -> Void
  var alert: Alert?

  func factButtonTapped() {
    node.task {
      let fact = try await node.factClient.fetch(count)
      onFact(count, fact)
    } catch: { error in
      alert = Alert(message: "Couldn't load fact.", title: "Error")
    }
  }
}
```

### Error Handling

`node.task` accepts an optional `catch:` closure for handling errors from the async body. The idiomatic pattern is to store the error as model state — typically an alert — so the view can present it:

```swift
node.task {
    let data = try await node.apiClient.load()
    result = data
} catch: { error in
    alert = Alert(message: error.localizedDescription, title: "Error")
}
```

The `catch:` closure is called on the same context as the task body, so writing to model state is safe. If you omit `catch:`, unhandled errors are silently discarded — add the closure whenever the task can throw.

For operations that should not show UI errors (fire-and-forget analytics, prefetch, etc.), omitting `catch:` is intentional.

### Observing State Changes

SwiftModel provides the `Observed` API for creating asynchronous streams that emit whenever observed model properties change. This is useful for reacting to state changes within your model logic.

```swift
func isPrime(_ value: Int) async throws -> Bool { ... }

node.forEach(Observed { count }) { count in
  state.isPrime = nil // Show spinner
  state.isPrime = try await isPrime(count)
}
```

The `Observed` stream automatically tracks which properties are accessed in its closure and will emit a new value whenever any of those properties change. For `Equatable` types, duplicate values are filtered out by default.

`forEach` will by default complete its asynchronous work before handling the next value, but sometimes it is useful to cancel any previous work that might become outdated.

```swift
node.forEach(Observed { count }, cancelPrevious: true) { count in
  state.isPrime = nil // Show spinner
  state.isPrime = try await isPrime(count)
}
```

> **`cancelPrevious` vs `cancelInFlight()`**: these solve similar but distinct problems.
> - `cancelPrevious: true` on `forEach` controls **per-element parallelism** — each new value from the sequence cancels the async work for the *previous* value. It's about keeping the handler up-to-date as values stream in.
> - `cancelInFlight()` on a `Cancellable` controls **call-site deduplication** — calling the same function again cancels the task started by the *previous call*. It's about ensuring only one instance of a task runs at a time, regardless of any input stream.

You can also use `Observed` directly as an `AsyncSequence`:

```swift
let countStream = Observed { model.count }
for await count in countStream {
  print("Count changed to: \(count)")
}
```

#### Silent writes for unchanged values

For `Equatable` properties, writing the same value that is already stored is a no-op: no observers are notified and the property value is unchanged. This is an intentional optimisation — it prevents cascading re-renders and avoids unnecessary work when a value is conditionally set to what it already holds.

```swift
model.count = 5  // count is already 5 — observers are not notified
model.count = 7  // count changed — observers are notified
```

#### Forcing observation with `node.touch(\.property)`

Sometimes external state that a property *depends on* changes in a way that is invisible to the equality check — for example, a reference-typed backing store that is mutated in-place. In those cases, call `node.touch(\.property)` to notify all registered observers of that property as if its value had changed, without actually modifying it:

```swift
// Mutate external backing store directly — equality check would suppress notification
externalDocument.unsafeReplace(newContent)
node.touch(\.document)   // Force dependents of `document` to re-read
```

`node.touch(\.property)` fires the observation callbacks for the given property and bypasses the `Equatable` deduplication check, so `Observed` streams and SwiftUI views that depend on that property will re-evaluate even if the observed value compares equal to its previous result.

### Memoized Computed Properties

SwiftModel provides `node.memoize()` for creating cached computed properties that automatically invalidate and recompute when their dependencies change. This is particularly useful for expensive computations.

```swift
@Model struct DataModel {
  var items: [Item] = []
  
  var processedData: [ProcessedItem] {
    node.memoize(for: "processedData") {
      // Expensive computation only runs when items changes
      items.map { processItem($0) }
    }
  }
}
```

Memoize automatically:
- **Caches the result** of the computation
- **Tracks dependencies** accessed during the computation
- **Invalidates the cache** when any dependency changes
- **Recomputes** only when the cached value is accessed after invalidation
- **Notifies observers** (like SwiftUI views) when the value changes

For `Equatable` types, you can enable deduplication to prevent unnecessary recomputations when the result would be the same:

```swift
var normalized: String {
  node.memoize(for: "normalized") {
    name.lowercased().trimmingCharacters(in: .whitespaces)
  }
}
```

The `Equatable` overload automatically compares the new result with the cached value and only triggers updates if they differ, even if dependencies changed.

> Memoize works seamlessly with SwiftUI's observation system on iOS 17+ and with the AccessCollector mechanism on earlier versions, ensuring views update correctly when memoized values change.

### Cancellation

All tasks started from a model are automatically cancelled once the model is deactivated (it is removed from an anchored model hierarchy). But `task()` and `forEach()` also return a `Cancellable` instance that allows you to cancel an operation earlier.

```swift
let task = task { ... }
    
...
    
task.cancel()
```

A cancellable can also be set up to cancel given a hashable id.

```swift
let operationID = "operationID"

func startOperation() {
  node.task { ... }.cancel(for: operationID)
}

func stopOperation() {
  node.cancelAll(for: operationID)
}
```

By using a cancellation context you can group several operations to allow cancellation of them all as a group:

```swift
node.cancellationContext(for: operationID) {
  node.task { }
  node.forEach(...) { }
}
```

This is particularly useful for multi-step operations where you want to cancel the entire flow as a unit. For example, a "save flow" that spawns a validation task and an upload task can be cancelled atomically:

```swift
let saveFlowID = "saveFlow"

func startSave() {
    node.cancellationContext(for: saveFlowID) {
        node.task { await validate() }
        node.task { await upload() }
    }
}

func cancelSave() {
    node.cancelAll(for: saveFlowID)  // cancels both tasks at once
}
```

When a task itself spawns nested work, use `.inheritCancellationContext()` so the nested work is also cancelled when the parent context is cancelled:

```swift
node.task {
    node.forEach(updates) { update in
        processUpdate(update)
    }.inheritCancellationContext()  // cancelled when the outer task's context is cancelled
}
```

You can also call `node.onCancel { ... }` to execute work upon cancellation.

### Cancel in Flight

If you perform an asynchronous operation it sometimes makes sense to cancel any already in flight operations.  

```swift
func startOperation() {
  node.task { ... }.cancel(for: operationID, cancelInFlight: true)
}
```

So if you call `startOperation()` while one is already ongoing, it will be cancelled and new operation is started to replace it.

If you don't need to cancel your operation from somewhere else you can let SwiftModel generate an id for you:

```swift
func startOperation() {
  node.task { ... }.cancelInFlight()
}
```

> The id is created by using the current source location of the `cancelInFlight()` call.

### Transactions

As SwiftModel fully embraces Swift concurrency tools, it means that your model is often accessed from several different threads at once. This is safe to do, but sometimes it is important that model state modifications are grouped together to not break invariants. For this SwiftModel provides the `node.transaction { ... }` helper.

```swift
node.transaction {
  counts.append(count)
  sum = counts.reduce(0, +)
}
```

All mutations inside the block appear atomically to other threads. Observation callbacks (and `observeAnyModification()` emissions) are deferred until the transaction completes, so observers see only the final consistent state.

The closure is non-throwing by design — transactions have no rollback, so a throwing closure provides no safety guarantee. If you need conditional application, compute the new values first, then apply them inside the transaction.

> `withAnimation { model.someProperty = newValue }` works as expected from any model method. SwiftModel's coalescing and observation are compatible with active `Transaction` objects, so animations driven by model mutations behave correctly without any special handling.

### Observing Any Modification

`observeAnyModification()` returns a stream that emits whenever *any* state in a model or its descendants changes, without needing to specify which property. This is useful for cross-cutting concerns:

```swift
func onActivate() {
    // Show unsaved-changes indicator whenever anything in the form changes
    node.forEach(observeAnyModification()) { [weak self] _ in
        hasUnsavedChanges = true
    }
}
```

Multiple mutations inside a `node.transaction { }` produce a single emission, so rapid batched changes don't cause redundant work. Combined with `AsyncAlgorithms` you can build debounced autosave:

```swift
func onActivate() {
    node.task {
        for await _ in observeAnyModification().debounce(for: .seconds(2)) {
            await autosave()
        }
    }
}
```

> `observeAnyModification()` is on `Model` directly (not `node`), so you call it as `observeAnyModification()` from within a model, or `childModel.observeAnyModification()` from a parent model.

### Combine Integration

If your project uses Combine, `node.onReceive(_:)` lets you subscribe to any `Publisher` for the lifetime of the model. The subscription is automatically cancelled when the model is deactivated.

```swift
func onActivate() {
    node.onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
        refresh()
    }
}
```

## Undo and Redo

SwiftModel has built-in support for undo/redo via `node.trackUndo()`. Call it from `onActivate()` to register which properties participate in the undo stack. Each modification to a tracked property automatically pushes an entry onto a ``ModelUndoStack`` (or any custom ``UndoBackend``), and undoing restores the model to its previous state as a single atomic transaction.

### Basic setup

Inject a `ModelUndoStack` as the `undoSystem` dependency when anchoring, then call `trackUndo()` from `onActivate()`:

```swift
@Model struct EditorModel {
    var title = ""
    var body = ""

    func onActivate() {
        node.trackUndo()  // all tracked properties participate in undo
    }
}

// At the call site:
let stack = ModelUndoStack()
let model = EditorModel().withAnchor {
    $0.undoSystem.backend = stack
}

stack.undo()
stack.redo()
```

### Selective tracking

There are two ways to track only a subset of properties:

**Track specific paths** — pass the key paths you want to track:

```swift
@Model struct TodoListModel {
    var items: [TodoItem] = []
    var newItemTitle = ""   // ephemeral — not part of undo history

    func onActivate() {
        node.trackUndo(\.items)  // only item changes are undoable
    }
}
```

**Exclude specific paths** — track everything except the listed key paths:

```swift
@Model struct EditorModel {
    var title = ""
    var body = ""
    var searchQuery = ""   // ephemeral search field

    func onActivate() {
        node.trackUndo(excluding: \.searchQuery)  // all except searchQuery
    }
}
```

**Child model tracking** — each model is responsible for its own properties. Child models that should participate in undo must call `trackUndo` in their own `onActivate`:

```swift
@Model struct TodoItem {
    var title: String
    var isDone: Bool = false

    func onActivate() {
        node.trackUndo(\.title, \.isDone)  // tracked by the child itself
    }
}
```

### Observable canUndo / canRedo

`ModelUndoSystem` exposes `canUndo` and `canRedo` as observable model properties that update reactively as the stack changes. Wire them directly in your view:

```swift
Button { model.node.undoSystem.undo() } label: {
    Label("Undo", systemImage: "arrow.uturn.backward")
}
.disabled(!model.node.undoSystem.canUndo)
.keyboardShortcut("z", modifiers: .command)

Button { model.node.undoSystem.redo() } label: {
    Label("Redo", systemImage: "arrow.uturn.forward")
}
.disabled(!model.node.undoSystem.canRedo)
.keyboardShortcut("z", modifiers: [.command, .shift])
```

### System UndoManager integration

For macOS and iOS apps that want Cmd+Z / Cmd+Shift+Z wired to the system Edit menu automatically, use `UndoManagerBackend` instead of `ModelUndoStack`:

```swift
struct TodoListView: View {
    @ObservedModel var model: TodoListModel
    @Environment(\.undoManager) var undoManager

    var body: some View {
        TodoListContent(model: model)
            .task(id: undoManager.map(ObjectIdentifier.init)) {
                model.node.undoSystem.backend = undoManager.map(UndoManagerBackend.init)
            }
    }
}
```

### Shared Models and Unique Ownership

`node.uniquelyReferenced()` returns a stream that emits `true` when a model has exactly one owner in the hierarchy and `false` when it is shared across multiple parents. This enables "exclusive editing" UX patterns — for example, disabling an edit button while a model is referenced from multiple places:

```swift
func onActivate() {
    node.forEach(node.uniquelyReferenced()) { isExclusive in
        isEditable = isExclusive
    }
}
```

The stream emits the current value immediately and deduplicates consecutive equal values.

## Traversing the Hierarchy

SwiftModel maintains full knowledge of the parent-child relationships between all models in your application. The `node.reduceHierarchy` and `node.mapHierarchy` helpers expose this information so you can query or aggregate data across any portion of the hierarchy.

### ModelRelation

Both helpers accept a `ModelRelation` option set that controls which models are visited:

| Relation | Description |
|---|---|
| `.self` | Only the model itself |
| `.parent` | Direct parents (one hop up) |
| `.ancestors` | All ancestors recursively (parents, grandparents, …) |
| `.children` | Direct children (one hop down) |
| `.descendants` | All descendants recursively |
| `.dependencies` | Also include dependency models at each visited node |

Relations can be combined freely: `[.self, .descendants]` visits the model and its entire subtree.

### mapHierarchy

`mapHierarchy` applies a transform closure to each visited model and collects the non-nil results into an array:

```swift
// Find the nearest ancestor AppModel
let appModel = node.mapHierarchy(for: .ancestors) { $0 as? AppModel }.first

// Collect all descendant models of a specific type
let counters = node.mapHierarchy(for: [.self, .descendants]) { $0 as? CounterModel }
```

### reduceHierarchy

`reduceHierarchy` is the general form. It lets you fold results into an accumulator, which is useful when building up non-array results:

```swift
// Sum all counts across the descendant subtree
let total = node.reduceHierarchy(
    for: [.self, .descendants],
    transform: { ($0 as? CounterModel)?.count },
    into: 0
) { $0 += $1 }
```

### Observation with Hierarchy Traversal

Combining `Observed` with `mapHierarchy` or `reduceHierarchy` creates a stream that automatically tracks *both* property changes and structural changes across an entire subtree. This is a uniquely powerful pattern that most architectures cannot express without manual subscriptions.

```swift
func onActivate() {
    // Re-evaluates when count changes on any CounterModel in the hierarchy,
    // AND when counters are added or removed.
    node.forEach(Observed { node.mapHierarchy(for: [.self, .descendants]) { ($0 as? CounterModel)?.count } }) { counts in
        total = counts.reduce(0, +)
    }
}
```

The stream re-evaluates in two situations:
- **Property change**: any `count` on any visited `CounterModel` changes
- **Structural change**: a child model is added or removed from the hierarchy

A practical real-world example — a document model that tracks whether any sub-editor has unsaved changes:

```swift
@Model struct DocumentModel {
    var editors: [EditorModel] = []
    var hasUnsavedChanges = false

    func onActivate() {
        node.forEach(Observed { node.mapHierarchy(for: [.self, .descendants]) { ($0 as? EditorModel)?.isDirty } }) { dirtyFlags in
            hasUnsavedChanges = dirtyFlags.contains(true)
        }
    }
}
```

When a new `EditorModel` is added to `editors`, the stream immediately includes its `isDirty` property in the tracking set — no manual subscription needed.

## Context and Preferences

Context and preferences let models share data across the model hierarchy without explicit parent-to-child passing. **Context** flows downward (like SwiftUI's `@Environment`); **preferences** flow upward (like SwiftUI's `PreferenceKey`).

Both systems are declared by extending a namespace type with computed properties, and accessed via `node.context` and `node.preference`.

### Context — top-down propagation

Declare a context key by extending `ContextKeys` with a computed property that returns a `ContextStorage` descriptor:

```swift
extension ContextKeys {
    var isFeatureEnabled: ContextStorage<Bool> {
        .init(defaultValue: false)
    }
}
```

Read and write via `node.context`:

```swift
node.context.isFeatureEnabled = true      // write
let enabled = node.context.isFeatureEnabled  // read
```

#### Environment propagation

For values that should automatically flow to all descendants — like a colour scheme, a selection state, or an editing mode — use `.environment` propagation:

```swift
extension ContextKeys {
    var colorScheme: ContextStorage<ColorScheme> {
        .init(defaultValue: .light, propagation: .environment)
    }
}
```

A write on any ancestor is visible to all descendants. Reading walks up the hierarchy to the nearest ancestor that has set the value, returning `defaultValue` if none has:

```swift
// Parent sets the theme for its entire subtree:
parentModel.node.context.colorScheme = .dark

// Any descendant reads it (returns .dark — inherited from parent):
let scheme = childModel.node.context.colorScheme

// A child can locally override it; only that child and its descendants see the override:
childModel.node.context.colorScheme = .light
```

To remove a local override and go back to inheriting from the nearest ancestor:

```swift
node.removeContext(\.colorScheme)
```

### Preferences — bottom-up aggregation

Declare a preference key by extending `PreferenceKeys` with a computed property that returns a `PreferenceStorage` descriptor. The descriptor includes a `reduce` closure that folds contributions together:

```swift
extension PreferenceKeys {
    var totalCount: PreferenceStorage<Int> {
        .init(defaultValue: 0) { $0 += $1 }
    }
    var hasUnsavedChanges: PreferenceStorage<Bool> {
        .init(defaultValue: false) { $0 = $0 || $1 }
    }
}
```

Each node writes its own contribution:

```swift
node.preference.totalCount = 3
```

Any ancestor reads the aggregate of the whole subtree (self + all descendants):

```swift
let total = parentNode.preference.totalCount  // sum of all contributions in subtree
```

To remove a node's contribution:

```swift
node.removePreference(\.totalCount)
```

Both reads and writes participate in SwiftModel's observation system: wrapping a read in `Observed { ... }` creates a stream that re-fires whenever any contributing node changes, or when nodes are added or removed from the subtree.

### Common patterns

**Propagating a colour scheme / theme:**

```swift
extension ContextKeys {
    var theme: ContextStorage<AppTheme> {
        .init(defaultValue: .default, propagation: .environment)
    }
}

// Root model sets the theme once:
func onActivate() {
    node.context.theme = userPreferences.theme
}

// Any descendant reads it:
let colors = node.context.theme.colors
```

**Aggregating unsaved-changes across a subtree:**

```swift
extension PreferenceKeys {
    var hasUnsavedChanges: PreferenceStorage<Bool> {
        .init(defaultValue: false) { $0 = $0 || $1 }
    }
}

// Each editor signals its own dirty state:
func onActivate() {
    node.forEach(Observed { isDirty }) { dirty in
        node.preference.hasUnsavedChanges = dirty
    }
}

// The document root reads the aggregate:
var showsUnsavedIndicator: Bool {
    node.preference.hasUnsavedChanges
}
```

## Events

It is common that models need to communicate up or down the model hierarchy. Often it is most natural to set up a callback closure for children to communicate back to parents, or for parents to call methods directly on children. But for more complicated setups, SwiftModel also supports sending events up and down the model hierarchy.

```swift
enum AppEvent { 
  case logout
}

func onLogoutTapped() { // ChildModel
  node.send(AppEvent.logout)
}

func onActivate() { // AppModel
  node.forEach(node.event(of: AppEvent.logout)) {
    user = nil
  }
}
```

By default an event is sent to the sending model itself and any of its ancestors, but you can override that behavior by providing a custom receivers list.

```swift
node.send(AppEvent.userWasLoggedOut, to: .descendants)
```

Often events are specific to one type of model, and SwiftModel adds special support for `Model`'s using their `Event` extension point.

```swift
@Model struct StandupDetail {
  enum Event {
    case deleteStandup
    case startMeeting
  }

  func deleteButtonTapped() {
    node.send(.deleteStandup)
  }
}
```

Now you can explicitly ask for events from composed models, and you will also receive an instance of the sending model.

```swift
node.forEach(node.event(fromType: StandupDetail.self)) { event, standupDetail in
  switch event {
  case .deleteStandup: ...
  case .startMeeting: ...
  }
}
```

## Navigation

Navigation state is just model state. A modal sheet, a pushed screen, or a multi-destination flow is expressed as an optional or an enum child model — no wrappers, no navigation libraries required.

### Modal / sheet navigation

Declare a `Destination` enum annotated with `@ModelContainer` and `@CasePathable`, then hold an optional instance as model state:

```swift
@Model struct StandupDetail {
    var standup: Standup
    var destination: Destination?

    @ModelContainer @CasePathable
    @dynamicMemberLookup
    enum Destination: Sendable {
        case edit(StandupForm)
        case deleteConfirmation
    }

    func editButtonTapped() {
        destination = .edit(StandupForm(standup: standup))
    }

    func onActivate() {
        node.forEach(node.event(fromType: StandupForm.self)) { event, form in
            switch event {
            case .save:
                standup = form.standup
                destination = nil
            case .discard:
                destination = nil
            }
        }
    }
}
```

In the view, use `.sheet(item:)` with a case key-path binding (requires [`swift-case-paths`](https://github.com/pointfreeco/swift-case-paths)):

```swift
struct StandupDetailView: View {
    @ObservedModel var model: StandupDetail

    var body: some View {
        List { ... }
            .sheet(item: $model.destination.edit) { form in
                StandupFormView(model: form)
            }
    }
}
```

Setting `destination = nil` dismisses any active sheet automatically.

### Stack navigation

Represent a navigation stack as an array of `@ModelContainer` enum cases. Each case carries the model for that screen:

```swift
@Model struct AppFeature {
    var standupsList = StandupsList()
    var path: [Path] = []

    // Declare Hashable — @ModelContainer synthesises == and hash(into:).
    // For @Model associated values, identity (.id) is used; for Equatable/Hashable
    // value types, full value equality is used automatically.
    @ModelContainer @CasePathable
    @dynamicMemberLookup
    enum Path: Hashable {
        case detail(StandupDetail)
        case record(RecordMeeting)
    }

    func standupTapped(_ standup: Standup) {
        path.append(.detail(StandupDetail(standup: standup)))
    }
}
```

In the view, bind `$model.path` directly to `NavigationStack`:

```swift
struct AppView: View {
    @ObservedModel var model: AppFeature

    var body: some View {
        NavigationStack(path: $model.path) {
            StandupsListView(model: model.standupsList)
                .navigationDestination(for: AppFeature.Path.self) { path in
                    switch path {
                    case let .detail(model): StandupDetailView(model: model)
                    case let .record(model): RecordMeetingView(model: model)
                    }
                }
        }
    }
}
```

> `NavigationStack` requires path elements to be `Hashable`. When you declare `Hashable` on a `@ModelContainer` enum, the conformance is synthesised automatically: `@Model` associated values compare and hash by identity, and `Equatable`/`Hashable` value types use their natural equality.

### Deep links and programmatic navigation

Because navigation state is plain model state, programmatic navigation is a direct array mutation:

```swift
func handleDeepLink(_ url: URL) {
    path = [.detail(StandupDetail(standup: loadStandup(from: url)))]
}
```

No special deep-link handling infrastructure is needed — change the state, SwiftUI reflects it.

## Testing

Because SwiftModel owns and tracks all of a model's state, events, and async tasks, it can make tests exhaustive by default: any side effect you didn't explicitly assert causes the test to fail. This catches regressions that are invisible to ordinary unit tests.

### Setup

Replace `withAnchor()` with `andTester()` to get a `ModelTester` alongside the live model. You can override dependencies in the same call:

```swift
@Test func testAddCounter() async {
    let (model, tester) = AppModel().andTester {
        $0.factClient.fetch = { "\($0) is a good number." }
    }

    model.addButtonTapped()

    await tester.assert {
        model.counters.count == 1
    }
}
```

> Assertions must `await` because state and event propagation is asynchronous.

The `assert` builder block accepts any number of predicates. Using `==` gives you a pretty-printed diff on failure; any other `Bool` expression also works:

```swift
await tester.assert {
    model.count == 42          // diff on failure
    model.isLoading == false   // diff on failure
    model.title.hasPrefix("A") // plain bool — no diff
}
```

Use `unwrap` to wait for an optional child model to appear before interacting with it:

```swift
let row = try await tester.unwrap(model.counters.first)
row.counter.incrementTapped()
await tester.assert {
    row.counter.count == 1
}
```

### Asserting Callbacks

Pass a `TestProbe` wherever the model expects a callback closure. Call `tester.install(probe)` to opt into exhaustion checking for it — omitting this call means probe invocations are not tracked and unexpected calls produce silent false-passes:

```swift
@Test func testFactButtonTapped() async {
    let onFact = TestProbe()
    let (model, tester) = CounterModel(count: 2, onFact: onFact.call).andTester {
        $0.factClient.fetch = { "\($0) is a good number." }
    }
    tester.install(onFact)

    model.factButtonTapped()

    await tester.assert {
        onFact.wasCalled(with: 2, "2 is a good number.")
    }
}
```

`TestProbe` also supports `callAsFunction`, so you can write `onFact: probe` directly instead of `onFact: probe.call`.

### Asserting Events

Assert that a model sent an event using `didSend(_:)` inside an `assert` block:

```swift
@Test func testContinueWithoutRecording() async throws {
    let (model, tester) = StandupDetail(standup: .mock).andTester {
        $0.speechClient.authorizationStatus = { .denied }
    }

    model.startMeetingButtonTapped()
    try await tester.unwrap(model.destination?.speechRecognitionDenied).continue()

    await tester.assert {
        model.destination?.speechRecognitionDenied != nil
        model.didSend(.startMeeting)
    }
}
```

### Exhaustivity

By default the tester enforces exhaustivity across six categories — any unasserted effect in any category fails the test when the tester is deallocated at the end of the test function:

- **`.state`** — every state change must be consumed by an `assert` block
- **`.events`** — every event sent via `node.send()` must be observed with `didSend(_:)`
- **`.tasks`** — all async tasks must complete or be cancelled before the tester deallocates
- **`.probes`** — every installed `TestProbe` invocation must be consumed by `wasCalled`
- **`.context`** — every `node.context` write must be consumed by an `assert` block
- **`.preference`** — every `node.preference` write must be consumed by an `assert` block

To focus a test on only some categories, pass `exhaustivity` to `andTester` or assign it afterwards:

```swift
// Set at creation time
let (model, tester) = MyModel().andTester(exhaustivity: .off)
let (model, tester) = MyModel().andTester(exhaustivity: [.state, .events])

// Or assign after creation
tester.exhaustivity = [.state, .events]  // ignore tasks and probes
tester.exhaustivity = .off               // skip all exhaustion checks
```

When debugging, you can print skipped assertions without failing the test:

```swift
tester.showSkippedAssertions = true
```

### Time Control

Models that use `node.continuousClock` for timers — such as polling loops or countdowns — are fully testable without real wall-clock delays. Inject a `TestClock` (from [swift-clocks](https://github.com/pointfreeco/swift-clocks)) via `andTester` and advance time explicitly in your test:

```swift
// Model under test
@Model struct TimerModel {
    var secondsElapsed = 0

    func onActivate() {
        node.forEach(node.continuousClock.timer(interval: .seconds(1))) { _ in
            secondsElapsed += 1
        }
    }
}

// Test
@Test func testTimer() async throws {
    let clock = TestClock()
    let (model, tester) = TimerModel().andTester {
        $0.continuousClock = clock
    }

    await clock.advance(by: .seconds(1))
    await tester.assert { model.secondsElapsed == 1 }

    await clock.advance(by: .seconds(2))
    await tester.assert { model.secondsElapsed == 3 }
}
```

For tests that only care about the end result and not intermediate timer ticks, use `ImmediateClock()` instead. It fires all timer intervals synchronously, letting the model reach its final state without manual advancement:

```swift
let (model, tester) = TimerModel().andTester {
    $0.continuousClock = ImmediateClock()
}
```

### Refactor-Resilient Tests

SwiftModel tests assert **final state**, not the sequence of actions or effects that produced it. This means you can freely restructure model internals — split a method, rename a case, change how async work is dispatched — and existing tests continue to pass as long as the observable outcome is unchanged.

TCA tests encode the full action sequence: renaming an action case or splitting an effect requires rewriting tests even when visible behaviour is identical. SwiftModel has no action enum, so there is nothing to encode and nothing to break.

## Examples

The `Examples/` directory contains several complete apps at different levels of complexity. Two of them illustrate the same feature — a sign-up flow — implemented in two different ways, which is a useful teaching tool:

- **`SignUpFlow`** — child models are passed directly from parent to child at construction time. Simple and explicit; ideal for shallow hierarchies where the model is only needed one or two levels deep.
- **`SignUpFlowUsingDependency`** — the shared model is registered as a `@ModelDependency`. Any descendant can access it directly via `node` without constructor parameter drilling. Preferable when many nested models all need access to the same service.

Use `SignUpFlow` as the default and reach for `SignUpFlowUsingDependency` when you find yourself threading the same model through three or more constructor parameters.

## What SwiftModel Is Not

- **Not a Redux store.** There is no global state atom, no dispatcher, and no reducer function. Each model owns its own state and communicates via direct method calls, typed events, or the dependency system.
- **Not a global singleton.** Models are values in a hierarchy. Two features can have independent instances of the same model type without sharing state.
- **Not a Combine wrapper.** SwiftModel uses `async`/`await` and `AsyncSequence` throughout. Combine integration exists via `node.onReceive(_:)` as a bridge for legacy publishers, not as the primary model.
- **Not a navigation library.** Navigation is expressed as plain model state (optionals, arrays, enums). No routing DSL or coordinator object is required.

---

If you find a bug or have a feature idea, please [open an issue](https://github.com/bitofmind/swift-model/issues). If SwiftModel is useful to you, consider starring the repo — it helps others find it.
