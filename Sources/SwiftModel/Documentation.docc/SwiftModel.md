# ``SwiftModel``

Composable value-type models for SwiftUI. The structured architecture of TCA without reducers, action enums, or effect indirection.

## Overview

SwiftModel lets you build an app's logic as a hierarchy of plain Swift structs annotated with `@Model`. Each model declares its state and operations; SwiftModel handles observation, async lifetime, dependency injection, and exhaustive testing automatically.

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

Key properties:

- **No retain cycles — ever.** Models are structs. `[weak self]` is a compile error, not a convention.
- **Exhaustive testing.** `ModelTester` tracks every state change, event, task, and callback. Anything you don't assert fails the test.
- **Built-in async lifetime.** `node.task { }` starts work tied to the model — automatically cancelled when the model deactivates.
- **Any-thread safe.** Structural locking means no `@MainActor` discipline required in model code.

## Getting Started

Add SwiftModel to your `Package.swift`:

```swift
.package(url: "https://github.com/bitofmind/swift-model", from: "0.10.0")
```

Declare a model, a view, and an entry point:

```swift
import SwiftModel
import SwiftUI

@Model struct CounterModel {
    var count = 0
    func incrementTapped() { count += 1 }
}

struct CounterView: View {
    @ObservedModel var model: CounterModel
    var body: some View {
        HStack {
            Button("-") { model.count -= 1 }
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

Test it exhaustively with no extra setup:

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

## Topics

### Defining Models

- ``Model``
- ``Model()``
- ``ModelNode``
- ``ModelID``

### Containers and Composition

- ``ModelContainer``
- ``ModelContainer()``
- ``ContainerVisitor``

### Anchoring and Lifetime

- ``ModelAnchor``

### Dependencies

- ``ModelDependencies``
- ``ModelDependency()``

### Async Work

- ``Cancellable``

### Observation

- ``Observed``

### Events

- ``ModelRelation``

### Context and Preferences

- ``ModelContext``

### Testing

- ``ModelTester``
- ``TestProbe``
- ``Exhaustivity``

### Undo and Redo

- ``ModelUndoStack``
- ``ModelUndoSystem``
- ``UndoBackend``
- ``ModelUndoEntry``
- ``UndoAvailability``
