import SwiftModel
import Testing
@testable import NoteEditor

struct NoteEditorTests {

    // MARK: - Initial state

    @Test func initialState() async {
        let (model, tester) = NoteEditorModel().andTester()

        await tester.assert {
            model.title == "Untitled"
            model.body == ""
            model.canUndo == false
            model.canRedo == false
        }
    }

    // MARK: - Undo stack grows on each edit

    @Test func undoStackGrowsOnEdit() async {
        let (model, tester) = NoteEditorModel().andTester()

        model.title = "Hello"

        await tester.assert {
            model.title == "Hello"
            model.canUndo == true
            model.canRedo == false
        }

        model.title = "Hello World"

        await tester.assert {
            model.title == "Hello World"
            model.canUndo == true
            model.canRedo == false
        }
    }

    // MARK: - Undo reverts the last change

    @Test func undoRevertsLastChange() async {
        let (model, tester) = NoteEditorModel().andTester()

        model.title = "First"
        model.title = "Second"

        await tester.assert {
            model.title == "Second"
            model.canUndo == true
        }

        model.undo()

        await tester.assert {
            model.title == "First"
            model.canUndo == true   // "Untitled" → "First" still on stack
            model.canRedo == true
        }

        model.undo()

        await tester.assert {
            model.title == "Untitled"
            model.canUndo == false
            model.canRedo == true
        }
    }

    // MARK: - Redo restores undone change

    @Test func redoRestoresUndoneChange() async {
        let (model, tester) = NoteEditorModel().andTester()

        model.title = "Draft"

        model.undo()

        await tester.assert {
            model.title == "Untitled"
            model.canRedo == true
        }

        model.redo()

        await tester.assert {
            model.title == "Draft"
            model.canUndo == true
            model.canRedo == false
        }
    }

    // MARK: - New edit clears the redo stack

    @Test func newEditClearsRedoStack() async {
        let (model, tester) = NoteEditorModel().andTester()

        model.title = "A"
        model.undo()

        await tester.assert {
            model.title == "Untitled"
            model.canRedo == true
        }

        model.title = "B"

        await tester.assert {
            model.title == "B"
            model.canRedo == false
        }
    }

    // MARK: - Body edits also participate in undo/redo

    @Test func bodyEditsUndoRedo() async {
        let (model, tester) = NoteEditorModel().andTester()

        model.body = "Line one"

        await tester.assert {
            model.body == "Line one"
            model.canUndo == true
            model.canRedo == false
        }

        model.undo()

        await tester.assert {
            model.body == ""
            model.canUndo == false
            model.canRedo == true
        }

        model.redo()

        await tester.assert {
            model.body == "Line one"
            model.canRedo == false
        }
    }

    // MARK: - Undo/redo on empty stacks is a no-op

    @Test func undoOnEmptyStackIsNoop() async {
        let (model, tester) = NoteEditorModel().andTester()

        model.undo() // should not crash or mutate state

        await tester.assert {
            model.title == "Untitled"
            model.canUndo == false
            model.canRedo == false
        }
    }

    @Test func redoOnEmptyStackIsNoop() async {
        let (model, tester) = NoteEditorModel().andTester()

        model.title = "Something"
        model.redo() // nothing to redo yet — should be a no-op

        await tester.assert {
            model.title == "Something"
            model.canRedo == false
        }
    }

    // MARK: - Undo/redo does not itself push onto the undo stack

    @Test func undoDoesNotGrowUndoStack() async {
        let (model, tester) = NoteEditorModel().andTester()

        model.title = "X"

        await tester.assert {
            model.title == "X"
            model.canUndo == true
        }

        model.undo()

        await tester.assert {
            model.title == "Untitled"
            model.canUndo == false   // back to initial — stack should be empty
            model.canRedo == true
        }
    }
}
