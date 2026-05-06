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

### Async effects with `node.task`

Fetching a fact is an async operation that can fail. SwiftModel's `node.task` runs work in the background and handles errors cleanly:

```swift
func factButtonTapped() {
    node.task {
        let fact = try await factClient.fetch(count)
        // back on the model's executor — safe to mutate state
        onFactFetched(fact)
    } catch: { error in
        alert = AlertState { TextState(error.localizedDescription) }
    }
}
```

The `catch:` closure runs if the async work throws, keeping error handling co-located with the effect.

### Callback-based parent-child communication

`CounterRowModel` doesn't hold a reference to `AppModel`. Instead, `AppModel` passes a closure when creating the row:

```swift
CounterRowModel(
    counter: ...,
    onFact: { fact in factPrompt = FactPromptModel(fact: fact) },
    onRemove: { counters.removeAll { $0.id == id } }
)
```

Because `@Model` types are value types (structs), the closures capture a copy of `self` — there are no class instances and no retain cycles, so `[weak self]` is never needed. This keeps models decoupled — the child describes *what happened*, the parent decides *what to do*.

### Dependency injection

`FactClient` is injected via the [Dependencies](https://github.com/pointfreeco/swift-dependencies) library. In production it calls a real API; in tests and previews it can be replaced with a controlled implementation:

```swift
@Dependency(\.factClient) var factClient

// In tests:
withDependencies {
    $0.factClient.fetch = { count in "\(count) is a great number." }
} operation: { ... }
```

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
