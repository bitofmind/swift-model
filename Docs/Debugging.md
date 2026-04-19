[← Back to README](../README.md)

## Debugging State Changes

SwiftModel keeps track of all model state changes and can print diffs, trigger lists, and value snapshots to help you understand what's happening at runtime.

Enable debug output for the lifetime of a model by adding a modifier before anchoring:

```swift
AppModel().withDebug().withAnchor()   // triggers (name format) + changes (diff) — the default
```

Pass a `DebugOptions` value to configure exactly what gets printed. Use the static factory methods for common cases:

```swift
// Print only a diff of the whole model tree (no trigger lines)
AppModel().withDebug(.changes()).withAnchor()

// Print only which properties triggered updates (no diff)
AppModel().withDebug(.triggers()).withAnchor()

// Use a custom label and output stream (triggers + changes still on by default)
AppModel().withDebug(.init(name: "App", printer: myStream)).withAnchor()
```

The trigger format can be `.name` (default), `.withValue` (old → new), or `.withDiff` (structured diff — useful when the trigger value is itself a model):

```swift
// Triggers show "AppModel.filter: \"a\" → \"b\""; changes diff also printed
AppModel().withDebug(.init(triggers: .withValue)).withAnchor()

// Triggers-only with full structured diff of each changed dependency
AppModel().withDebug(.triggers(.withDiff)).withAnchor()
```

Diffs default to `.compact` style (only the changed lines and their structural ancestors). Pass a `DiffStyle` to change this:

```swift
// Show every unchanged sibling as "… (N unchanged)"
model.debug(.changes(.diff(.collapsed)))

// Show the full before/after context
model.debug(.changes(.diff(.full)))
```

To debug a specific expression or enable debug output only temporarily on a live model, use `debug()` on the model directly — it returns a `Cancellable` you can cancel when done:

```swift
// Watch only a specific sub-expression (triggers + changes)
model.debug() { model.filter }

// Enable temporarily
let cancel = model.debug()
// ... do work ...
cancel.cancel()
```

For `memoize` and `Observed`, the `debug:` parameter is `DebugOptions?` — omit it (or pass `nil`) to disable debug output, or pass a `DebugOptions` value to enable it:

```swift
// Print the new value (no diff) whenever a memoized result changes
node.memoize(for: "sorted", debug: .init(changes: .value)) { items.sorted() }

// Print which dependency triggered an Observed update (old → new value)
node.forEach(Observed(debug: .triggers(.withValue)) { model.count }) { value in ... }
```

> Debug output is only active in `DEBUG` builds.

**Targeted debug in practice** — the [TodoList](../Examples/TodoList) example uses `Observed(debug:)` inside `onActivate()` to trace only `items.count` and `completedCount`, avoiding noise from unrelated property changes (e.g., `newItemTitle` keystrokes). The [Search](../Examples/Search) example demonstrates `withDebug()` at the app level alongside `cancelPrevious: true` on `forEach` to show cancel-in-flight behaviour.
