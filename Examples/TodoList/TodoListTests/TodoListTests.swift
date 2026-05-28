import SwiftModel
import Testing
@testable import TodoList

/// Demonstrates the TodoList app's undo/redo behaviour from a user perspective.
///
/// Tests drive undo/redo via `model.node.undoSystem` — the same API the app's
/// views use — and assert state through `expect` so that reactive
/// propagation is fully awaited before each expectation.
@Suite(.modelTesting(.removing([.local, .environment, .preference])) { $0.undoSystem.backend = ModelUndoStack() })
struct TodoListTests {

    // MARK: - Initial state

    @Test func initialState() async {
        let model = TodoListModel().withAnchor()

        await expect {
            model.items.isEmpty
            model.newItemTitle == ""
            model.node.undoSystem.canUndo == false
            model.node.undoSystem.canRedo == false
        }
    }

    // MARK: - Adding items

    @Test func addingItemAppearsInList() async {
        let model = TodoListModel().withAnchor()

        model.items.append(TodoItem(title: "Buy milk"))
        await expect { model.items.count == 1 && model.items[0].title == "Buy milk" }
    }

    @Test func addingItemCreatesUndoEntry() async {
        let model = TodoListModel().withAnchor()

        model.items.append(TodoItem(title: "Buy milk"))
        await expect {
            model.items.count == 1
            model.node.undoSystem.canUndo == true
            model.node.undoSystem.canRedo == false
        }
    }

    // MARK: - Undo / Redo

    @Test func undoRevertsAddedItem() async {
        let model = TodoListModel().withAnchor()

        model.items.append(TodoItem(title: "Buy milk"))
        await expect { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        model.node.undoSystem.undo()
        await expect {
            model.items.isEmpty
            model.node.undoSystem.canUndo == false
            model.node.undoSystem.canRedo == true
        }
    }

    @Test func redoReAppliesUndoneChange() async {
        let model = TodoListModel().withAnchor()

        model.items.append(TodoItem(title: "Walk dog"))
        await expect { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        model.node.undoSystem.undo()
        await expect { model.items.isEmpty && model.node.undoSystem.canRedo == true }

        model.node.undoSystem.redo()
        await expect {
            model.items.count == 1
            model.items.first?.title == "Walk dog"
            model.node.undoSystem.canUndo == true
            model.node.undoSystem.canRedo == false
        }
    }

    @Test func newChangeAfterUndoClearsRedo() async {
        let model = TodoListModel().withAnchor()

        model.items.append(TodoItem(title: "A"))
        await expect { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        model.node.undoSystem.undo()
        await expect { model.items.isEmpty && model.node.undoSystem.canRedo == true }

        model.items.append(TodoItem(title: "B"))
        await expect {
            model.items.count == 1
            model.node.undoSystem.canUndo == true
            model.node.undoSystem.canRedo == false
        }
    }

    @Test func multipleUndoSteps() async {
        let model = TodoListModel().withAnchor()

        model.items.append(TodoItem(title: "First"))
        await expect { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        model.items.append(TodoItem(title: "Second"))
        await expect { model.items.count == 2 }

        model.node.undoSystem.undo()
        await expect { model.items.count == 1 && model.items.first?.title == "First" }

        model.node.undoSystem.undo()
        await expect { model.items.isEmpty && model.node.undoSystem.canUndo == false }
    }

    @Test func deletingItemIsUndoable() async {
        let model = TodoListModel().withAnchor()

        model.items.append(TodoItem(title: "Task"))
        await expect { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        model.items.removeAll()
        await expect { model.items.isEmpty }

        model.node.undoSystem.undo()
        await expect { model.items.count == 1 && model.items.first?.title == "Task" }
    }

    // MARK: - Typing in the new-item field is ephemeral (not undoable)

    @Test func typingDoesNotCreateUndoEntry() async {
        let model = TodoListModel().withAnchor()

        model.newItemTitle = "typing…"
        await expect { model.newItemTitle == "typing…" && model.node.undoSystem.canUndo == false }
    }

    // MARK: - Completion count preference

    @Test func completedCountReflectsItemsDoneState() async {
        let model = TodoListModel().withAnchor()
        model.items = [
            TodoItem(title: "A"),
            TodoItem(title: "B"),
            TodoItem(title: "C"),
        ]
        await expect {
            model.items.count == 3
            model.completedCount == 0
        }

        model.items[0].toggleTapped()
        await expect {
            model.items[0].isDone == true
            model.completedCount == 1
        }

        model.items[2].toggleTapped()
        await expect {
            model.items[2].isDone == true
            model.completedCount == 2
        }

        model.items[0].toggleTapped()
        await expect {
            model.items[0].isDone == false
            model.completedCount == 1
        }
    }

    @Test func completedCountUpdatesWhenItemsRemoved() async {
        let model = TodoListModel().withAnchor()
        model.items = [
            TodoItem(title: "A", isDone: true),
            TodoItem(title: "B", isDone: true),
        ]
        await expect {
            model.items.count == 2
            model.completedCount == 2
        }

        model.items.removeFirst()
        await expect {
            model.items.count == 1
            model.completedCount == 1
        }
    }

    // MARK: - Show/hide completed (environment propagation)

    @Test func showingCompletedIncludesAllItems() async {
        let model = TodoListModel().withAnchor()
        model.items = [TodoItem(title: "Active"), TodoItem(title: "Done", isDone: true)]
        model.showCompleted = false  // start hidden so this test verifies the toggle to shown
        await settle()

        model.showCompleted = true
        await expect {
            model.showCompleted == true
            model.visibleItems.count == 2
        }
    }

    @Test func hidingCompletedFiltersItems() async {
        let model = TodoListModel().withAnchor()
        model.items = [TodoItem(title: "Active"), TodoItem(title: "Done", isDone: true)]
        await settle()

        model.showCompleted = false
        await expect {
            model.showCompleted == false
            model.visibleItems.count == 1
            model.visibleItems[0].title == "Active"
        }
    }

    /// Verifies that each item reads its visibility from the environment propagated
    /// by the parent list — the core demonstration of top-down environment propagation.
    @Test func itemVisibilityReflectsEnvironment() async {
        let model = TodoListModel().withAnchor()
        model.items = [TodoItem(title: "Done", isDone: true)]
        await settle()

        await expect { model.items[0].isVisible == true }  // showCompleted defaults to true

        model.showCompleted = false
        await expect {
            model.showCompleted == false
            model.items[0].isVisible == false  // environment propagated to item
        }

        model.showCompleted = true
        await expect {
            model.showCompleted == true
            model.items[0].isVisible == true
        }
    }

    // MARK: - Item property changes (title, isDone)

    @Test func renamingItemIsUndoable() async {
        let model = TodoListModel().withAnchor()

        model.items.append(TodoItem(title: "Original"))
        await expect { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        model.items[0].renameSubmitted("Renamed")
        await expect { model.items.first?.title == "Renamed" && model.node.undoSystem.canUndo == true }

        model.node.undoSystem.undo()
        await expect { model.items.first?.title == "Original" }
    }

    @Test func togglingIsDoneIsUndoable() async {
        let model = TodoListModel().withAnchor()

        model.items.append(TodoItem(title: "Task"))
        await expect { model.items.count == 1 }

        model.items[0].toggleTapped()
        await expect { model.items.first?.isDone == true && model.node.undoSystem.canUndo == true }

        model.node.undoSystem.undo()
        await expect { model.items.first?.isDone == false }
    }

    @Test func typingDoesNotInterfereWithItemUndo() async {
        let model = TodoListModel().withAnchor()

        model.items.append(TodoItem(title: "Task"))
        await expect { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        // User starts typing a new title — this must not add an undo entry
        model.newItemTitle = "draft"
        await expect { model.newItemTitle == "draft" && model.node.undoSystem.canUndo == true }

        // Undo removes the added item. Since only \.items is tracked, newItemTitle
        // is not restored — it stays at its current live value "draft".
        model.node.undoSystem.undo()
        await expect {
            model.items.isEmpty
            model.newItemTitle == "draft"
            model.node.undoSystem.canUndo == false
        }
    }
}
