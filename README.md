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


 > SwiftModel is an evolution of the [Swift One State](https://github.com/bitofmind/swift-one-state) library, where the introduction of Swift macros allows a more lightweight syntax. 

 > SwiftModel takes inspiration from similar architectures such as [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture), but aims to be less strict and esoteric by using a more familiar style.

### Requirements

SwiftModel requires Swift 5.9.2 (Xcode 15.1) that fixes compiler bugs around the new [init accessor](https://github.com/apple/swift-evolution/blob/main/proposals/0400-init-accessors.md) 

> Even more [init accessor](https://github.com/apple/swift-evolution/blob/main/proposals/0400-init-accessors.md) compiler fixes will land in Swift 5.10, until then @Model custom initializers might require accessing the underscore private members directly instead of the regular ones.

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

> Note, that your model types is required to be a struct, even though its behavior is more like a reference type such as class. This is required to unlock some of the powerful state update tracking that is used in testing and debugging as well as to avoid issues with retain cycles that are so common with reference types. 

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

A SwiftModel model goes through different life stages. It starts out in the initial state. This is typically just far a really brief period between calling the initializer and being added to a model hierarchy of anchored models.

```swift
func addButtonTapped() {
  let row = CounterRowModel(...) // Initial state           
  counters.append(row) // row is copied and anchored
}
```

Once an initial model is added to an anchored model, it is copied and set up with a supporting context. The initial copy should no longer be used after that point. Instead you should now access your model from the anchored parent.

If the model is later on removed from the parent anchored model, it will loose its supporting context and enter a destructed state.

> A model can also be copied into a frozen copy where the state will become immutable. This is used e.g. when printing state updates, and while running unit tests, to be able to compare a previous states of a model with later ones.   

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

### Debugging State Changes

As SwiftModel keeps track of all model state changes, it supports printing of differences between previous and updated state. You can enable this for the lifetime of a model by adding a modifier: 

```swift
AppModel()._withPrintChanges()
```

Or if you only want to print these updates for a period of time:

```swift
let printTask = model._printChanges()
await workToTrack()
printTask.cancel()
```

> `_printChanges()` is only active in `DEBUG` builds.

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

> In iOS 17, tvOS 17, macOS 14 and watchOS 10.0, `@ObservedModel` is no longer required, instead your models will automatically conform to the new `Observable` protocol.

### Bindings

The `@ObservedModel` also expose bindings to a model's properties:

```swift 
Stepper(value: $model.count) {
  Text("\(model.count)")
}
```

> In iOS 17, tvOS 17, macOS 14 and watchOS 10.0, `@ObservedModel` has to be used instead SwiftUI's new `@Bindable` annotation, as the latter does not yet accept non class types.

## Dependencies

For improved control of a model's dependencies to outside systems, such as backend services, SwiftModel has a system where a model can access its dependencies without needing to know how they were configured or set up. This is very similar to how SwiftUI's environment is working.

> This has been popularized by the [swift-dependency](https://github.com/pointfreeco/swift-dependencies) package which SwiftModel integrates with.

You define your dependencies similar to as you would set up a custom SwiftUI environment: 

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

extension DependencyValues {
  var factClient: FactClient {
    get { self[FactClientKey.self] }
    set { self[FactClientKey.self] = newValue }
  }
}
```

A model get access to its dependencies via its `node`, such as `node.factClient`.

> A model's `node` gives private access to many of model's functionality. 

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

### Asynchronous Sequences

For convenience, models also provide a `forEach` helper for consuming asynchronous stream such as `change(of:)` that will emit when the state changes. 

```swift
func isPrime(_ value: Int) async throws -> Bool { ... }

node.forEach(change(of: \.count)) { count in
  state.isPrime = nil // Show spinner
  state.isPrime = try await isPrime(count)
}
```

`forEach` will by default complete its asynchronous work before handling the next value, but sometimes it is useful to cancel any previous work that might become outdated.

```swift
node.forEach(change(of: \.count), cancelPrevious: true) { count in
  state.isPrime = nil // Show spinner
  state.isPrime = try await isPrime(count)
}
```

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

As SwiftModel fully embraces swift concurrency tools, it means that your model is often accessed from several different threads at once. This is safe to do, but sometimes it is important that model state modifications are group together to not break invariants. For this SwiftModel provides the `node.transaction { ... }` helper.

```
node.transaction {
  counts.append(count)
  sum = counts.reduce(0, +)
}
```

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

As SwiftModel manages your model's state and knows when events are being sent as well if any asynchronous works is ongoing, it can help tests to be more exhaustive.

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

