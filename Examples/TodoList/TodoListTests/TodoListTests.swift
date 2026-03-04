import SwiftModel
import Testing
@testable import TodoList

/// Demonstrates the TodoList app's undo/redo behaviour from a user perspective.
///
/// Tests drive undo/redo via `model.node.undoSystem` — the same API the app's
/// views use — and assert state through `tester.assert` so that reactive
/// propagation is fully awaited before each expectation.
struct TodoListTests {

    func makeModel() -> (TodoListModel, ModelTester<TodoListModel>) {
        TodoListModel().andTester(withDependencies: { $0.undoSystem.backend = ModelUndoStack() })
    }

    // MARK: - Initial state

    @Test func initialState() async {
        let (model, tester) = makeModel()

        await tester.assert {
            model.items.isEmpty
            model.newItemTitle == ""
            model.node.undoSystem.canUndo == false
            model.node.undoSystem.canRedo == false
        }
    }

    // MARK: - Adding items

    @Test func addingItemAppearsInList() async {
        let (model, tester) = makeModel()

        model.items.append(TodoItem(title: "Buy milk"))
        await tester.assert { model.items.count == 1 && model.items[0].title == "Buy milk" }
    }

    @Test func addingItemCreatesUndoEntry() async {
        let (model, tester) = makeModel()

        model.items.append(TodoItem(title: "Buy milk"))
        await tester.assert {
            model.items.count == 1
            model.node.undoSystem.canUndo == true
            model.node.undoSystem.canRedo == false
        }
    }

    // MARK: - Undo / Redo

    @Test func undoRevertsAddedItem() async {
        let (model, tester) = makeModel()

        model.items.append(TodoItem(title: "Buy milk"))
        await tester.assert { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        model.node.undoSystem.undo()
        await tester.assert {
            model.items.isEmpty
            model.node.undoSystem.canUndo == false
            model.node.undoSystem.canRedo == true
        }
    }

    @Test func redoReAppliesUndoneChange() async {
        let (model, tester) = makeModel()

        model.items.append(TodoItem(title: "Walk dog"))
        await tester.assert { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        model.node.undoSystem.undo()
        await tester.assert { model.items.isEmpty && model.node.undoSystem.canRedo == true }

        model.node.undoSystem.redo()
        await tester.assert {
            model.items.count == 1
            model.items.first?.title == "Walk dog"
            model.node.undoSystem.canUndo == true
            model.node.undoSystem.canRedo == false
        }
    }

    @Test func newChangeAfterUndoClearsRedo() async {
        let (model, tester) = makeModel()

        model.items.append(TodoItem(title: "A"))
        await tester.assert { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        model.node.undoSystem.undo()
        await tester.assert { model.items.isEmpty && model.node.undoSystem.canRedo == true }

        model.items.append(TodoItem(title: "B"))
        await tester.assert {
            model.items.count == 1
            model.node.undoSystem.canUndo == true
            model.node.undoSystem.canRedo == false
        }
    }

    @Test func multipleUndoSteps() async {
        let (model, tester) = makeModel()

        model.items.append(TodoItem(title: "First"))
        await tester.assert { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        model.items.append(TodoItem(title: "Second"))
        await tester.assert { model.items.count == 2 }

        model.node.undoSystem.undo()
        await tester.assert { model.items.count == 1 && model.items.first?.title == "First" }

        model.node.undoSystem.undo()
        await tester.assert { model.items.isEmpty && model.node.undoSystem.canUndo == false }
    }

    @Test func deletingItemIsUndoable() async {
        let (model, tester) = makeModel()

        model.items.append(TodoItem(title: "Task"))
        await tester.assert { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        model.items.removeAll()
        await tester.assert { model.items.isEmpty }

        model.node.undoSystem.undo()
        await tester.assert { model.items.count == 1 && model.items.first?.title == "Task" }
    }

    // MARK: - Typing in the new-item field is ephemeral (not undoable)

    @Test func typingDoesNotCreateUndoEntry() async {
        let (model, tester) = makeModel()

        model.newItemTitle = "typing…"
        await tester.assert { model.newItemTitle == "typing…" && model.node.undoSystem.canUndo == false }
    }

    // MARK: - Item property changes (title, isDone)

    @Test func renamingItemIsUndoable() async {
        let (model, tester) = makeModel()

        model.items.append(TodoItem(title: "Original"))
        await tester.assert { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        model.items[0].renameSubmitted("Renamed")
        await tester.assert { model.items.first?.title == "Renamed" && model.node.undoSystem.canUndo == true }

        model.node.undoSystem.undo()
        await tester.assert { model.items.first?.title == "Original" }
    }

    @Test func togglingIsDoneIsUndoable() async {
        let (model, tester) = makeModel()

        model.items.append(TodoItem(title: "Task"))
        await tester.assert { model.items.count == 1 }

        model.items[0].toggleTapped()
        await tester.assert { model.items.first?.isDone == true && model.node.undoSystem.canUndo == true }

        model.node.undoSystem.undo()
        await tester.assert { model.items.first?.isDone == false }
    }

    @Test func typingDoesNotInterfereWithItemUndo() async {
        let (model, tester) = makeModel()

        model.items.append(TodoItem(title: "Task"))
        await tester.assert { model.items.count == 1 && model.node.undoSystem.canUndo == true }

        // User starts typing a new title — this must not add an undo entry
        model.newItemTitle = "draft"
        await tester.assert { model.newItemTitle == "draft" && model.node.undoSystem.canUndo == true }

        // Undo removes the added item. Since only \.items is tracked, newItemTitle
        // is not restored — it stays at its current live value "draft".
        model.node.undoSystem.undo()
        await tester.assert {
            model.items.isEmpty
            model.newItemTitle == "draft"
            model.node.undoSystem.canUndo == false
        }
    }
}
