[← Back to README](../README.md)

## Undo and Redo

SwiftModel has built-in undo/redo via `node.trackUndo()`. Call it from `onActivate()` to register which properties participate; each change to a tracked property pushes an entry, and undoing restores the previous state as one atomic transaction.

### Setup and scope

Inject a backend (`ModelUndoStack`, or any `UndoBackend`) as the `undoSystem` dependency, then track:

```swift
@Model struct EditorModel {
    var title = ""
    var body = ""

    func onActivate() {
        node.trackUndo()   // all tracked properties participate
    }
}

let stack = ModelUndoStack()
let model = EditorModel().withAnchor { $0.undoSystem.backend = stack }
stack.undo()
stack.redo()
```

Track a subset by listing paths (`node.trackUndo(\.items)`) or excluding them (`node.trackUndo(excluding: \.searchQuery)`) — useful for keeping ephemeral fields like a search box out of the history. Each model owns its own properties: a child that should be undoable calls `trackUndo` in its *own* `onActivate()`.

### Wiring to the UI

`node.undoSystem` exposes `canUndo` / `canRedo` as observable properties, so buttons enable and disable reactively:

```swift
Button { model.node.undoSystem.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
    .disabled(!model.node.undoSystem.canUndo)
    .keyboardShortcut("z", modifiers: .command)
```

To hook into the system Edit menu (Cmd-Z / Cmd-Shift-Z) on macOS and iOS, use `UndoManagerBackend` driven by SwiftUI's environment `UndoManager` instead of a standalone `ModelUndoStack`:

```swift
.task(id: undoManager.map(ObjectIdentifier.init)) {
    model.node.undoSystem.backend = undoManager.map(UndoManagerBackend.init)
}
```
