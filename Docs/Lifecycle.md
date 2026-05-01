[← Back to README](../README.md)

## Lifetime and Asynchronous Work

A typical model will need to handle asynchronous work such as performing operations and listening on updates from its dependencies. It is also common to listen to model events and state changes that SwiftModel exposes as asynchronous streams.

> **Works from any thread — no `@MainActor` required.**
> Most Swift architectures push all model logic onto `@MainActor` to avoid data races. SwiftModel uses structural locking instead: every read and write is internally synchronised, so you can access your models freely from any `Task`, background queue, or test without actor hops. `@ObservedModel` handles the `@MainActor` hop that SwiftUI requires for view updates, so you never need to annotate your own model code with `@MainActor`. This also makes testing simpler — no `await MainActor.run { }` wrappers needed.

### Tasks

To start some asynchronous work that is tied to the life time of your model you call `node.task()`, similarly as you would do when adding a `task()` to your view. You can optionally give a task a name — it appears in test exhaustion failure messages and in Instruments, making it easier to identify which task was still running:

```swift
node.task("fetchFact") {
    // ...
}
```

When no name is provided, one is synthesised automatically from the call site: `"factButtonTapped() @ CounterModel.swift:42"`.


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

The `catch:` closure is called on the same context as the task body, so writing to model state is safe.

For `node.task`, `catch:` is only required when the operation can throw — the non-throwing overload has no `catch:` parameter at all. If the task's body is non-throwing and you want to silently ignore errors from a specific branch, catch them inside the closure.

For `node.forEach`, omitting `catch:` is safe for non-throwing sequences. If the sequence or operation can throw and you omit `catch:`, SwiftModel calls `reportIssue` at the `forEach` call site — this fails the test in test mode and triggers an `assertionFailure` in debug builds. Per-element errors with `abortIfOperationThrows: false` (the default) are always silently swallowed; only sequence-level throws and `abortIfOperationThrows: true` errors trigger the report.

For fire-and-forget work where errors are genuinely ignorable (analytics pings, prefetch), pass an explicit empty `catch:` to document the intent:

```swift
node.forEach(prefetchStream) { item in
    try await prefetch(item)
} catch: { _ in }  // errors are intentionally ignored
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

`forEach` will by default complete its asynchronous work before handling the next value. For the common case of wanting to restart async work whenever a value changes — cancelling any in-flight work first — use `node.task(id:)`.

#### Restart on Change: `node.task(id:)`

`node.task(id:)` starts the task once immediately on activation, then cancels and restarts it each time the observed value changes. The emission-time value is passed directly to the operation, avoiding any race between when the task starts and when it reads the model.

```swift
node.task(id: count) { count in
    state.isPrime = nil // Show spinner
    state.isPrime = try await isPrime(count)
} catch: { _ in }
```

This is a convenience over `node.forEach(Observed { count }, cancelPrevious: true) { count in ... }`, making the "restart on change" intent explicit at the call site.

`node.task(id:)` accepts the same optional parameters as `node.forEach`: `initial`, `removeDuplicates`, `coalesceUpdates`, `name`, `isDetached`, and `priority`. Pass `initial: false` to skip the initial run and only react to subsequent changes.

#### React to Value Transitions: `node.onChange(of:)`

`node.onChange(of:)` calls its closure on each change, passing both the old and new value. This is the right tool when you need to react to a specific *transition* rather than just the latest value.

```swift
node.onChange(of: isLoggedIn) { wasLoggedIn, isNowLoggedIn in
    if !wasLoggedIn && isNowLoggedIn {
        await fetchUserProfile()
    }
}
```

When `initial: true` (the default), the closure is called once immediately on activation with `oldValue == newValue`. Pass `initial: false` to skip the initial call — the first real change will then report `(activationValue, firstChangedValue)` as `(old, new)`.

Pass `cancelPrevious: true` for "latest wins" semantics — any still-running closure from a prior change is cancelled before the new one starts:

```swift
node.onChange(of: searchQuery, cancelPrevious: true) { _, query in
    try await performSearch(query)
} catch: { _ in }
```

`node.onChange(of:)` accepts the same optional parameters as `node.task(id:)`: `initial`, `removeDuplicates`, `coalesceUpdates`, `cancelPrevious`, `name`, `isDetached`, and `priority`.

For more control — to chain `Observed` with async operators like `.debounce()`, or to iterate arbitrary `AsyncSequence` values — use `forEach` directly:

```swift
// Use forEach for debouncing or arbitrary AsyncSequences
node.forEach(Observed { count }.debounce(for: .milliseconds(300)), cancelPrevious: true) { count in
    state.isPrime = nil // Show spinner
    state.isPrime = try await isPrime(count)
}
```

> **`cancelPrevious` vs `cancelInFlight()`**: these solve similar but distinct problems.
> - `cancelPrevious: true` on `forEach` (and the underlying mechanism of `task(id:)`) controls **per-element parallelism** — each new value from the sequence cancels the async work for the *previous* value. It's about keeping the handler up-to-date as values stream in.
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

All mutations inside the block appear atomically to other threads. Observation callbacks (and `observeModifications()` emissions) are deferred until the transaction completes, so observers see only the final consistent state.

The closure is non-throwing by design — transactions have no rollback, so a throwing closure provides no safety guarantee. If you need conditional application, compute the new values first, then apply them inside the transaction.

> `withAnimation { model.someProperty = newValue }` works as expected when called from a SwiftUI view or any `@MainActor` context. SwiftModel's observation is compatible with active `Transaction` objects, so animations driven by model mutations behave correctly without any special handling. Note that `withAnimation` itself is a `@MainActor` function — it cannot be called directly from a non-main-actor model method.

### Observing Modifications

`observeModifications()` returns a stream that emits whenever state in a model or its descendants changes, without needing to specify which property. This is useful for cross-cutting concerns like dirty tracking and debounced autosave:

```swift
func onActivate() {
    // Show unsaved-changes indicator whenever anything in the form changes
    node.forEach(observeModifications()) { _ in
        hasUnsavedChanges = true
    }
}
```

Multiple mutations inside a `node.transaction { }` produce a single emission. Combined with `AsyncAlgorithms` you can build debounced autosave:

```swift
func onActivate() {
    node.task {
        // kinds: .properties skips environment/preference noise — only real data changes trigger a save
        for await _ in observeModifications(kinds: .properties).debounce(for: .seconds(2)) {
            await autosave()
        }
    }
}
```

#### Scope

By default, `observeModifications()` covers the full subtree (`scope: [.self, .descendants]`). You can narrow or widen this:

```swift
// Only react to changes on this model itself (not children)
observeModifications(scope: .self)

// This model and its direct children, but not grandchildren
observeModifications(scope: [.self, .children])

// Only descendants (not self)
observeModifications(scope: .descendants)
```

#### Kind filtering

Changes are categorised into four kinds. Use the `kinds:` parameter to ignore irrelevant categories:

| Kind | What it covers |
|---|---|
| `.properties` | `@Tracked` model properties |
| `.environment` | Context-local environment values (`node.environment`, `node.local`) |
| `.preferences` | Bottom-up preference contributions (`node.preference`) |
| `.parentRelationship` | Model added to or removed from the hierarchy |
| `.all` | All of the above (default) |

```swift
// Autosave: only care about real data changes, not UI-state environment changes
observeModifications(kinds: .properties)
```

#### Model-type predicate

Pass a `where:` closure to filter by the model that changed. Return `true` to include the emission, `false` to skip it:

```swift
// Only fire when a Persistable model in the subtree changes
observeModifications(where: { $0 is Persistable })
```

#### Excluding specific properties

To exclude volatile or cache-like properties from triggering `observeModifications()`, call `node.excludeFromModifications(_:)` in `onActivate()`:

```swift
func onActivate() {
    // cachedResults and scrollOffset changes won't trigger the parent's observeModifications()
    node.excludeFromModifications(\.cachedResults, \.scrollOffset)
}
```

Exclusions only affect `observeModifications()`. Other observation mechanisms (`Observed`, `memoize`, `trackUndo`, SwiftUI) are unaffected.

#### Debug

Pass `debug: .triggers()` to print a line for each emission. Useful for diagnosing unexpected trigger sources:

```swift
observeModifications(debug: .triggers())
```

> `observeModifications()` is on `Model` directly, so you call it as `observeModifications()` from within a model, or `childModel.observeModifications()` from a parent model.

### Combine Integration

If your project uses Combine, `node.onReceive(_:)` lets you subscribe to any `Publisher` for the lifetime of the model. The subscription is automatically cancelled when the model is deactivated.

```swift
func onActivate() {
    node.onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
        refresh()
    }
}
```

### Customising Activation with `withActivation`

`withActivation` lets you attach extra setup that runs after `onActivate()`, without modifying the model itself. Unlike setting properties in the initialiser, `withActivation` runs after the model is live — so you can start tasks, register observers, and call `node.forEach`, all tied to the model's lifetime.

The primary use case is injecting async or cancellable work from the call site:

```swift
// Preview — inject a task that shows the loading state and then populates results,
// all without touching SearchModel itself. The task is cancelled when the preview closes.
#Preview("Loading → Results") {
    SearchModel()
        .withActivation { model in
            model.node.task {
                model.isSearching = true
                try await Task.sleep(for: .milliseconds(500))
                model.results = Repo.mocks.map { SearchResultItem(repo: $0) }
                model.isSearching = false
            }
        }
        .withAnchor()
}
```

`withActivation` is also the right tool for cross-cutting concerns that the model itself shouldn't know about — analytics, logging, or bridging to external systems:

```swift
// Attach a logging observer at the call site without touching onActivate.
// The observer is cancelled automatically when the model is deactivated.
model.withActivation { m in
    m.node.forEach(Observed { m.isSearching }) { isSearching in
        logger.info("Search in progress: \(isSearching)")
    }
}
```

In tests, this lets you verify side effects by injecting observers rather than by adding test-only code to the model:

```swift
// Verify that isSearching toggles correctly during a search,
// by observing it from outside the model.
@Test func searchTogglesLoadingState() async {
    var loadingStates: [Bool] = []
    let model = SearchModel()
        .withActivation { m in
            m.node.forEach(Observed { m.isSearching }) { loadingStates.append($0) }
        }
        .withAnchor {
            $0.continuousClock = ImmediateClock()
            $0.gitHubClient.search = { _ in Repo.mocks }
        }
    model.query = "swift"
    await expect(!model.results.isEmpty)
    #expect(loadingStates.contains(true))
}
```

The closure receives the live model instance and runs synchronously as part of activation, after `onActivate()` returns. Multiple `withActivation` calls can be chained — each closure runs in order.

This pattern keeps the model's own `onActivate()` free of call-site concerns, while still allowing callers to inject behaviour without subclassing or wrapping.

## Undo and Redo

Undo/redo support is covered in the **[Undo and Redo](Undo.md)** guide.

## Debugging

`debug()` and `Observed(debug:)` for tracing state changes and side effects are covered in the **[Debugging](Debugging.md)** guide.
