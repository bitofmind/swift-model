# SwiftModel

SwiftModel is a library for composing models that drives SwiftUI views. It comes with many powerful features and advanced tooling using a lightweight modern Swift style.

- [What is SwiftModel](#what-is-swiftmodel)
- [Models and Composition](#models-and-composition)
- [SwiftUI Integration](#swiftui-integration)
- [Dependencies](#dependencies)
- [Lifetime and Asynchronous Work](#lifetime-and-asynchronous-work)
- [Events](#events)
- [Testing](#testing)

## What is SwiftModel   

Much like SwiftUI's composition of views, SwiftModel uses well-integrated modern Swift tools for composing your app's different features into a hierarchy of models. Under the hood, SwiftModel will keep track of model state changes, dependencies and ongoing asynchronous work. This result in several advantages, such as:  

- Natural injection and propagation of dependencies down the model hierarchy.
- Support for sending events up or down the model hierarchy.
- Exhaustive testing of state changes, events and concurrent operations.
- Integrates fully with modern swift concurrency with extended tools for powerful lifetime management.
- Fine-grained observation of model state changes.

 > SwiftModel is an evolution of the [Swift One State](https://github.com/bitofmind/swift-one-state) library, where the introduction of Swift macros allows a more lightweight syntax. 

 > SwiftModel takes inspiration from similar architectures such as [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture), but aims to be less esoteric by using a more familiar style.

### Requirements

SwiftModel requires Swift 5.9.2 (Xcode 15.1) that fixes compiler bugs around the new [init accessor](https://github.com/apple/swift-evolution/blob/main/proposals/0400-init-accessors.md) 

> Even more [init accessor](https://github.com/apple/swift-evolution/blob/main/proposals/0400-init-accessors.md) compiler fixes did land in Swift 5.10, but there still some remaining fixes that did not make it to 5.10. Until then @Model custom initializers might require accessing the underscored private members directly instead of the regular ones.

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

> Note, that your model types is required to be a struct, even though its behavior is more like a reference type such as class. This is required to unlock some of the powerful state update tracking that is used in testing and debugging as well as to avoid issues with retain cycles that are common with reference types.

### No Retain Cycles

Because models are structs (value types), SwiftModel eliminates the retain-cycle problem that affects class-based architectures. You never need `[weak self]` capture lists — the compiler won't even accept them since you cannot take a weak reference to a struct. More practically, you can freely store callback closures directly as `let` properties and capture `self` in any closure without risk of a memory leak:

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

This works because each `@Model` struct holds only a weak reference to its underlying context. The strong ownership lives in the model hierarchy (parent → child), so closures that capture `self` cannot create cycles.

### @ModelIgnored and @ModelTracked

`@ModelIgnored` and `@ModelTracked` are implementation details used internally by the `@Model` macro. You should not use them directly in your own models.

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

### Model Life Stages

A SwiftModel model goes through different life stages. It starts out in the initial state. This is typically just for a really brief period between calling the initializer and being added to a model hierarchy of anchored models.

```swift
func addButtonTapped() {
  let row = CounterRowModel(...) // Initial state           
  counters.append(row) // row is anchored
}
```

Once an initial model is added to an anchored model, it is set up with a supporting context and becomes anchored.

If the model is later on removed from the parent’s anchored model, it will loose its supporting context and enter a destructed state.

> A model can also be copied into a frozen copy where the state will become immutable. This is used e.g. when printing state updates, and while running unit tests, to be able to compare previous states of a model with later ones.   

### Model Activation

The `Model` protocol provides an `onActivate()` extension point that is called by SwiftModel once the model becomes part of anchored model hierarchy. This is a perfect place to populate a model's state from its dependencies and to set up listeners on child events and state changes.

> Any parent will always be activated before its children to allow the parent to set up listener on child events and value changes. Once a parent is deactivated it will cancel it own activities before deactivating its children.

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

A model is typically instantiated and assigned to one place in a model hierarchy, but sometimes it can be useful to share a model in different parts of a model hierarchy. 

SwiftModel supports sharing with the following implications:

- A shared model will inherit the dependencies at its initial point of entry to the model hierarchy.
- The shared model is activated on initial anchoring and deactivated once the last reference of the model is removed. 
- An event sent from a shared model will be coalesced and receivers will only see a single event (even though it was sent from all its locations in the model hierarchy).
- Similarly a shared model will only receive sent events at most once.

### Debugging State Changes

As SwiftModels keeps track of all model state changes, it supports printing of differences between previous and updated state. You can enable this for the lifetime of a model by adding a modifier: 

```swift
AppModel()._withPrintChanges()
```

Or if you only want to print these updates for a period of time:

```swift
let printTask = model._printChanges()
await workToTrack()
printTask.cancel()
```

> Printing of changes are only active in `DEBUG` builds.

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

A model get access to its dependencies via its `node`.

```swift
let fact = try await node[FactClient.self].fetch(count)
``` 

> A model's `node` gives access to many of model's functionality. 

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

A typical model will need to handle asynchronous work such as performing operations and listening on updates from its dependencies. It is also common to listen on model events and state changes, that SwiftModel exposes as asynchronous streams.

>  SwiftModel is fully thread safe, and supports working with your models and their state from any task context. SwiftUI helpers such as `@ObservedModel` will make sure to only update views from the `@MainActor` that is required by SwiftUI.

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

All tasks started from a model are automatically cancelled once the model is deactivated (it is removed from an anchored model hierarchy). But `task()` and `forEach()` also returns a `Cancellable` instance that allows you to cancel an operation earlier.

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

As SwiftModel fully embraces swift concurrency tools, it means that your model is often accessed from several different threads at once. This is safe to do, but sometimes it is important that model state modifications are grouped together to not break invariants. For this SwiftModel provides the `node.transaction { ... }` helper.

```swift
node.transaction {
  counts.append(count)
  sum = counts.reduce(0, +)
}
```

All mutations inside the block appear atomically to other threads. Observation callbacks (and `observeAnyModification()` emissions) are deferred until the transaction completes, so observers see only the final consistent state.

> **No rollback on error**: if the closure throws, any mutations already applied inside the block are **not** rolled back. Wrap the transaction in a `do`/`catch` and handle partial-state recovery manually if needed.

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

## Events

It is common that models needs to communicate up or down the model hierarchy. Often it is most natural to set up a callback closure for children to communicate back to parents, or for parents to call method directly on children. But for more complicated setups, SwiftModel also support sending events up and down the model hierarchy. 

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

Now you can explicitly ask for events from composed models where your will conveniently also receive an instance of the sending model.

```swift
node.forEach(node.event(fromType: StandupDetail.self)) { event, standupDetail in
  switch event {
  case .deleteStandup: ...
  case .startMeeting: ...
  }
}
```

## Testing

Because SwiftModel manages your model's state and knows when events are being sent as well if any asynchronous works is ongoing, it can help tests to be more exhaustive.

For your tests you will set up your root model with a tester instead of an anchor, to get access to testing facilities. This is typically done by using the `andTester()` modifier, where you can conveniently override your dependencies as well.

```swift
class CounterFactTests: XCTestCase {
  func testExample() async throws {
    let (appModel, tester) = AppModel().andTester {
        $0.factClient.fetch = { "\($0) is a good number." }
    }

    appModel.addButtonTapped()
    await tester.assert(appModel.counters.count == 1)
```

> Assertions are required to await results, due to the asynchronous nature of state and event propagation.

You can further drill down to access child models once they become available:

```swift
    let counterRowModel = try await tester.unwrap(appModel.counters.first)
    let counterModel = counterRowModel.counter

    counterModel.incrementTapped()
    await tester.assert(counterModel.count == 1)
```

### Asserting Callbacks

To verify that a callback has been called you can set up a `TestProbe`:

```swift
func testFactButtonTapped() async throws {
  let onFact = TestProbe()
  let (model, tester) = CounterModel(count: 2, onFact: onFact.call).andTester {
    $0.factClient.fetch = { "\($0) is a good number." }
  }

  model.factButtonTapped()

  await tester.assert {
    onFact.wasCalled(with: 2, "2 is a good number.")
  }
}
```

> To make sure your probes are tested for exhaustivity (see below), make sure to install them on your tester `tester.install(onFact)`.

### Asserting Events

Events are asserted by checking that a model has sent them as expected:

```swift
  func testContinueWithoutRecording() async throws {
    let (standupDetail, tester) = StandupDetail(standup: .mock).andTester() {
      $0.speechClient.authorizationStatus = { .denied }
    }

    standupDetail.startMeetingButtonTapped()
    try await tester.unwrap(standupDetail.destination?.speechRecognitionDenied).continue()

    await tester.assert {
      standupDetail.destination?.speechRecognitionDenied != nil
      standupDetail.didSend(.startMeeting)
    }
  }
```

### Exhaustivity

Besides checking your explicit asserts, SwiftModel will verify that nothing else in your model's state was changed and that any probes or events was not asserted. It will also verify that there are no remaining asynchronous work still running.

To relax this exhaustive testing you can limit what areas to check (`state`, `probes`, `events` and `tasks`):

```swift
tester.exhaustivity = [.state, .events]
```

As well as optionally print out any skipped exhaustivity assertions without failing the tests.

```swift
tester.showSkippedAssertions = true
```

