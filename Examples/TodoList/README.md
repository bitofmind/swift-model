# TodoList

A to-do list with add, edit, delete, and reorder — plus full undo/redo and a live completion count. Demonstrates two features: selective undo tracking and bottom-up preference aggregation.

## What it demonstrates

### Selective undo/redo with `node.trackUndo`

Only the `items` array participates in undo history. The ephemeral `newItemTitle` field is intentionally excluded so typing in the add field doesn't pollute the undo stack:

```swift
@Model struct TodoListModel {
    var items: [TodoItem] = []
    var newItemTitle = ""  // ephemeral — not tracked

    func onActivate() {
        node.trackUndo(\.items)  // only items participate in undo/redo
    }
}
```

Each `TodoItem` also tracks its own `title` and `isDone` for undo, so renaming and toggling are individually undoable.

### Preferences — bottom-up aggregation

Each `TodoItem` reports its completion status upward as a preference contribution. `TodoListModel` reads the aggregate to show "X of Y completed" in the title bar — without iterating the array or holding a reference to each item:

```swift
extension PreferenceKeys {
    var completedCount: PreferenceStorage<Int> {
        .init(defaultValue: 0) { $0 += $1 }  // reduce: sum contributions
    }
}

// TodoItem — reports upward whenever isDone changes
func onActivate() {
    node.forEach(Observed { isDone }) { done in
        node.preference.completedCount = done ? 1 : 0
    }
}

// TodoListModel — reads the aggregate
var completedCount: Int { node.preference.completedCount }
```

This pattern scales naturally: adding more items, removing items, or toggling them all update the count automatically. The root model never needs to know how many items exist or iterate over them.

## App structure

| Type | Responsibility |
|------|---------------|
| `TodoListModel` | Items array, add/delete/move, undo wiring, reads `completedCount` preference |
| `TodoItem` | Individual task: title, completion flag, reports completion via preference |
| `ModelUndoStack` | Undo/redo backend, injected at anchor time |
