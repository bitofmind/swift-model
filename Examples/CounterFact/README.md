# CounterFact

A multi-counter app where each counter can fetch a fun fact about its current number from a remote API. Demonstrates nested models, async effects, and dependency injection.


## What it demonstrates

### Nested models and composition

The app builds behaviour by composing small, focused models into a tree:

```
AppModel
  ├── [CounterRowModel]    ← one per row in the list
  │     └── CounterModel  ← the actual counter logic
  └── FactPromptModel?    ← shown when a fact has been fetched
```

Each model is responsible for a single concern. `AppModel` wires them together but doesn't duplicate their logic.

> If you've seen The Composable Architecture, this is its headline counter-with-a-number-fact example — the same feature, written in SwiftModel. A useful side-by-side for what the model layer looks like without reducers, action enums, or effect indirection.

### Async effects with `node.task`

Fetching a fact is an async operation that can fail. `node.task` runs the work tied to the model's lifetime and handles errors cleanly:

```swift
func factButtonTapped() {
    node.task {
        onFact(count, try await node.factClient.fetch(count))
    } catch: { error in
        alert = Alert(message: "Couldn't load fact.", title: "Error")
    }
}
```

The `catch:` closure runs on the model's context if the work throws, so error handling stays co-located with the effect — and the task is cancelled automatically if the model goes away before it finishes.

### Callback-based parent-child communication

`CounterRowModel` doesn't hold a reference to `AppModel`. Instead, `AppModel` passes closures when creating the row, and the row calls them to report what happened:

```swift
CounterRowModel(
    counter: ...,
    onFact: { count, fact in factPrompt = FactPromptModel(count: count, fact: fact) },
    onRemove: { counters.removeAll { $0.id == id } }
)
```

The child describes *what happened*; the parent decides *what to do*. (And because models are structs, these closures can capture `self` freely — no `[weak self]`, no retain cycle to worry about.)

### Dependency injection

`FactClient` is resolved through `node`, at the model's position in the hierarchy. In production it calls a real API; in tests and previews you override it at the anchor site — no change to the model:

```swift
// In the model:
try await node.factClient.fetch(count)

// At the anchor site (tests, previews):
AppModel().withAnchor {
    $0.factClient.fetch = { count in "\(count) is a good number." }
}
```

### Exhaustive testing

Because SwiftModel tracks every state change, the test drives the model and asserts the final state — anything it didn't assert fails the test. There's no harness setup and no action sequence to script:

```swift
@Test(.modelTesting) func testFact() async throws {
    let appModel = AppModel().withAnchor {
        $0.factClient.fetch = { "\($0) is a good number." }
    }

    appModel.addButtonTapped()
    let counter = try await require(appModel.counters.first).counter

    counter.incrementTapped()
    counter.factButtonTapped()

    await expect {
        appModel.factPrompt?.count == 1
        appModel.factPrompt?.fact == "1 is a good number."
    }
}
```

Rename `factButtonTapped()`, split the fetch into helpers, change how the prompt is presented — the test keeps passing as long as the outcome is the same.

### Swift concurrency isolation

This target is built with `defaultIsolation: MainActor` (`OTHER_SWIFT_FLAGS = -default-isolation MainActor`), which matches what Xcode 26 sets on new projects. The dependency type `FactClient` is therefore declared `nonisolated struct` so its stored property accessors remain accessible from any context — see [`Docs/Dependencies.md`](../../Docs/Dependencies.md) for the full pattern.

## App structure

| Model | Responsibility |
|-------|---------------|
| `AppModel` | List of rows, fact prompt overlay, add/remove |
| `CounterRowModel` | Row-level glue, remove callback |
| `CounterModel` | Increment/decrement, trigger fact fetch |
| `FactPromptModel` | Display fact, refetch, dismiss |
| `FactClient` | Dependency for fetching number facts |
