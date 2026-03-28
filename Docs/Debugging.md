[← Back to README](../README.md)

## Debugging State Changes

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
