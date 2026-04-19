[← Back to README](../README.md)

## Undo and Redo

SwiftModel has built-in support for undo/redo via `node.trackUndo()`. Call it from `onActivate()` to register which properties participate in the undo stack. Each modification to a tracked property automatically pushes an entry onto a ``ModelUndoStack`` (or any custom ``UndoBackend``), and undoing restores the model to its previous state as a single atomic transaction.

### Basic setup

Inject a `ModelUndoStack` as the `undoSystem` dependency when anchoring, then call `trackUndo()` from `onActivate()`:

```swift
@Model struct EditorModel {
    var title = ""
    var body = ""

    func onActivate() {
        node.trackUndo()  // all tracked properties participate in undo
    }
}

// At the call site:
let stack = ModelUndoStack()
let model = EditorModel().withAnchor {
    $0.undoSystem.backend = stack
}

stack.undo()
stack.redo()
```

### Selective tracking

There are two ways to track only a subset of properties:

**Track specific paths** — pass the key paths you want to track:

```swift
@Model struct TodoListModel {
    var items: [TodoItem] = []
    var newItemTitle = ""   // ephemeral — not part of undo history

    func onActivate() {
        node.trackUndo(\.items)  // only item changes are undoable
    }
}
```

**Exclude specific paths** — track everything except the listed key paths:

```swift
@Model struct EditorModel {
    var title = ""
    var body = ""
    var searchQuery = ""   // ephemeral search field

    func onActivate() {
        node.trackUndo(excluding: \.searchQuery)  // all except searchQuery
    }
}
```

**Child model tracking** — each model is responsible for its own properties. Child models that should participate in undo must call `trackUndo` in their own `onActivate`:

```swift
@Model struct TodoItem {
    var title: String
    var isDone: Bool = false

    func onActivate() {
        node.trackUndo(\.title, \.isDone)  // tracked by the child itself
    }
}
```

### Observable canUndo / canRedo

`ModelUndoSystem` exposes `canUndo` and `canRedo` as observable model properties that update reactively as the stack changes. Wire them directly in your view:

```swift
Button { model.node.undoSystem.undo() } label: {
    Label("Undo", systemImage: "arrow.uturn.backward")
}
.disabled(!model.node.undoSystem.canUndo)
.keyboardShortcut("z", modifiers: .command)

Button { model.node.undoSystem.redo() } label: {
    Label("Redo", systemImage: "arrow.uturn.forward")
}
.disabled(!model.node.undoSystem.canRedo)
.keyboardShortcut("z", modifiers: [.command, .shift])
```

### System UndoManager integration

For macOS and iOS apps that want Cmd+Z / Cmd+Shift+Z wired to the system Edit menu automatically, use `UndoManagerBackend` instead of `ModelUndoStack`:

```swift
struct TodoListView: View {
    @ObservedModel var model: TodoListModel
    @Environment(\.undoManager) var undoManager

    var body: some View {
        TodoListContent(model: model)
            .task(id: undoManager.map(ObjectIdentifier.init)) {
                model.node.undoSystem.backend = undoManager.map(UndoManagerBackend.init)
            }
    }
}
```

### Shared Models and Unique Ownership

`node.uniquelyReferenced()` returns a stream that emits `true` when a model has exactly one owner in the hierarchy and `false` when it is shared across multiple parents. This enables "exclusive editing" UX patterns — for example, disabling an edit button while a model is referenced from multiple places:

```swift
func onActivate() {
    node.forEach(node.uniquelyReferenced()) { isExclusive in
        isEditable = isExclusive
    }
}
```

The stream emits the current value immediately and deduplicates consecutive equal values.
