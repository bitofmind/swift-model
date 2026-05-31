[← Back to README](../README.md)

## Debugging

SwiftModel tracks every model state change and every view access, so it can answer the two questions that come up most when something misbehaves:

- **"What just changed in my model?"** — log a diff of the model tree (and which property triggered it) as state mutates.
- **"Why did this view re-render?"** — log the exact property whose change invalidated a SwiftUI view's body.

Every hook below is gated on `#if DEBUG`, so the calls compile to nothing in release builds — safe to leave in place while you ship.

### Watching model state changes

Attach `withDebug()` before anchoring to log changes for a model's whole lifetime:

```swift
AppModel().withDebug().withAnchor()   // logs which property triggered + a diff of the change
```

To enable it temporarily on a live model, call `node.debug()` — it returns a `Cancellable` you turn off when done. A trailing-closure form scopes logging to a single sub-expression:

```swift
let cancel = model.node.debug()        // ... do work ...
cancel.cancel()

model.node.debug { model.filter }      // watch just this expression
```

The same `debug:` parameter exists on the observation primitives, so you can trace one mechanism in isolation instead of the whole tree:

```swift
node.memoize(debug: .init(changes: .value)) { items.sorted() }
node.forEach(Observed(debug: .triggers(.withValue)) { count }) { value in … }
node.forEach(observeModifications(debug: .triggers())) { _ in autosave() }
```

### Tracing view re-renders

When a view redraws and you don't know why, call `$model.debug()` from inside `body`. Each time SwiftUI invalidates the view, it names the model and key path that fired:

```swift
struct EditorBar: View {
    @ObservedModel var editor: EditorModel

    var body: some View {
        $editor.debug()
        return HStack { /* … */ }
    }
}
```

```
EditorModel at EditorBar.swift:42 ← EditorModel.layerMode
EditorModel at EditorBar.swift:42 ← EditorModel.selectedTrackID
```

Trigger lines follow reads into child models, so reading `editor.canvas.scale` names `CanvasModel.scale`. To narrow the hunt within a noisy view, wrap a region in `ModelScope(debug:)` — only reads inside the scope are attributed to it:

```swift
ModelScope(debug: .init(name: "toolbar")) {
    EditorMidBar(editor: editor)
}
```

### Going further

*What* gets printed is controlled by a single `DebugOptions` value, shared by every hook above. The individual knobs are documented on `DebugOptions` itself — at a glance, you can:

- **Pick the trigger format** — just the property name, the `old → new` value, or a structured diff (handy when the property is itself a model).
- **Pick the diff style** — compact (changed lines only), collapsed, or the full before/after.
- **Capture the reader's call stack** (`captureAccessStack:`) — appends the `body` call stack that registered a dependency, but only for paths that actually fire, so you see *where* a re-rendering read came from.
- **Observe every access** (`accessObserver:`) — for custom telemetry, or to drop into LLDB at the moment of read.
- **Redirect output** (`printer:`) — route debug lines to Instruments signposts, `OSLog`, or a file via any `TextOutputStream & Sendable`, instead of stdout.

> **Seeing it in context:** the [TodoList](../Examples/TodoList) example uses `Observed(debug:)` to trace only `items.count` and `completedCount`, and the [Search](../Examples/Search) example pairs `withDebug()` with `cancelPrevious: true` to surface cancel-in-flight behaviour.
