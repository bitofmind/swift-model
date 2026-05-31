[← Back to README](../README.md)

## Lifetime and Asynchronous Work

A model typically performs asynchronous work — calling its dependencies, reacting to its own state changes, and listening to events. SwiftModel ties all of that to the model's lifetime: work started from a model is automatically cancelled when the model is removed from the hierarchy, with no stored `Task`, no `deinit`, and no manual cleanup.

> **Works from any thread — no `@MainActor` required.** SwiftModel synchronises every read and write through an internal lock instead of pushing model logic onto `@MainActor`, so you can touch your models from any task or queue. `@ObservedModel` handles the `@MainActor` hop SwiftUI needs for view updates, so your own model code never needs the annotation — and tests need no `await MainActor.run { }` wrappers.

### Tasks

Start lifetime-bound async work with `node.task`, much like adding `.task` to a view:

```swift
@Model struct CounterModel {
    var count = 0
    var fact: String?
    var alert: Alert?

    func factButtonTapped() {
        node.task {
            fact = try await node.factClient.fetch(count)
        } catch: { error in
            alert = Alert(message: "Couldn't load fact.", title: "Error")
        }
    }
}
```

The optional `catch:` closure handles errors from the body and runs on the same context, so writing model state from it (the idiomatic way to surface an error — store it as an alert) is safe. The non-throwing overload has no `catch:` at all. You can name a task (`node.task("fetchFact") { … }`); the name appears in Instruments and in test-exhaustion messages, and is otherwise synthesised from the call site.

### Reacting to state changes

`Observed { … }` wraps any Swift value expression in an async stream that emits whenever the result changes — not just simple property reads, but computed expressions and hierarchy queries too. It's the foundation the higher-level helpers build on:

```swift
node.forEach(Observed { count }) { count in
    isPrime = try await checkPrime(count)
}
```

`forEach` finishes handling one value before taking the next. Three common variations cover most needs:

- **`node.task(id:)`** — restart on change. Runs once on activation, then cancels and restarts each time the value changes, passing the emission-time value straight in:
  ```swift
  node.task(id: query) { query in
      results = try await node.search(query)
  } catch: { _ in }
  ```
- **`node.onChange(of:)`** — react to a *transition*. The closure receives both old and new value, for when "what it changed from" matters:
  ```swift
  node.onChange(of: isLoggedIn) { wasLoggedIn, isLoggedIn in
      if !wasLoggedIn && isLoggedIn { await fetchProfile() }
  }
  ```
- **`forEach` directly** — for chaining async operators (`.debounce`, etc.) or iterating any `AsyncSequence`:
  ```swift
  node.forEach(Observed { count }.debounce(for: .milliseconds(300)), cancelPrevious: true) { count in
      isPrime = try await checkPrime(count)
  }
  ```

All three share the same options (`initial`, `removeDuplicates`, `coalesceUpdates`, `cancelPrevious`, `name`, `priority`); pass `cancelPrevious: true` for "latest wins". `Observed` is also usable directly as an `AsyncSequence` (`for await x in Observed { model.x }`).

> Writing an `Equatable` property the value it already holds is a silent no-op — observers aren't notified. When a property *depends on* external state that changed invisibly (e.g. a mutated reference-typed backing store), call `node.touch(\.property)` to force its observers to re-evaluate.

### Memoized computed properties

`node.memoize { … }` caches an expensive computation, tracks the dependencies it reads, and recomputes only when one of them changes — then notifies observers (including SwiftUI):

```swift
var processedData: [ProcessedItem] {
    node.memoize { items.map(processItem) }
}
```

The cache key is synthesised from the call site (pass `for:` to override). For `Equatable` results, memoize also suppresses updates when a recompute produces the same value.

### Cancellation

Every task is cancelled automatically when the model deactivates. For earlier or grouped cancellation, `task` and `forEach` return a `Cancellable`:

```swift
let task = node.task { … }
task.cancel()
```

Cancel by id, or group several operations so they cancel as a unit:

```swift
node.task { … }.cancel(for: operationID)          // tag it
node.cancelAll(for: operationID)                  // cancel the tag

node.cancellationContext(for: saveFlowID) {       // group
    node.task { await validate() }
    node.task { await upload() }
}
node.cancelAll(for: saveFlowID)                   // cancels both
```

To **cancel-in-flight** — replace an ongoing operation each time a function is called — use `.cancelInFlight()` (id synthesised from the call site) or `.cancel(for: id, cancelInFlight: true)`. Nested work can join its parent's context with `.inheritCancellationContext()`, and `node.onCancel { … }` runs cleanup on cancellation.

### Transactions

Because models can be touched from multiple threads, group related mutations so observers never see a half-applied state:

```swift
node.transaction {
    counts.append(count)
    sum = counts.reduce(0, +)
}
```

Mutations inside the block apply atomically; observation callbacks (and `observeModifications()` emissions) are deferred until it completes. The closure is non-throwing by design — there's no rollback. `withAnimation { model.x = y }` works as expected from a SwiftUI/`@MainActor` context.

### Observing modifications

`observeModifications()` emits whenever *anything* in a model or its subtree changes, without naming a property — ideal for cross-cutting concerns like dirty tracking or debounced autosave:

```swift
func onActivate() {
    node.task {
        for await _ in observeModifications(kinds: .properties).debounce(for: .seconds(2)) {
            await autosave()
        }
    }
}
```

The stream can be narrowed by **scope** (`.self`, `.children`, `.descendants`), by **kind** (`.properties`, `.environment`, `.preferences`, `.parentRelationship`), or by a `where:` model-type predicate; `node.excludeFromModifications(\.cache, …)` keeps volatile properties from triggering it. A single `node.transaction` produces a single emission.

### Combine integration

If your project uses Combine, `node.onReceive(_:)` subscribes to any publisher for the model's lifetime (cancelled on deactivation):

```swift
node.onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
    refresh()
}
```

### Configuring activation from the outside

Two modifiers let a *caller* attach behaviour to a model without editing its source — useful for previews, tests, and cross-cutting concerns like logging:

- **`withSetup`** runs *before* `onActivate()`, so the model's own activation can see what you configure (e.g. an environment flag a child reads on activation):
  ```swift
  MyModel().withSetup { $0.node.environment.isEditorMode = true }.withAnchor()
  ```
- **`withActivation`** runs *after* `onActivate()`, on the live model — so you can start tasks and register observers tied to its lifetime:
  ```swift
  // Inject a logging observer at the call site without touching onActivate.
  model.withActivation { m in
      m.node.forEach(Observed { m.isSearching }) { logger.info("searching: \($0)") }
  }
  ```

Both are additive (multiple calls run in declaration order) and only fire when the model is anchored.

## Undo and Redo

`node.trackUndo()` and `UndoManager` integration are covered in the **[Undo and Redo](Undo.md)** guide.

## Debugging

`node.debug()` and `Observed(debug:)` for tracing state changes are covered in the **[Debugging](Debugging.md)** guide.
