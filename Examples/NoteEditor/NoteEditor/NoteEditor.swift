import SwiftModel
import SwiftUI

// MARK: - Model

/// The root model for the NoteEditor app.
///
/// Demonstrates SwiftModel's undo/redo capability using `onChange` to
/// automatically capture snapshots after each change, and `restoreState`
/// to rewind the model to a previous state.
///
/// Key behaviours:
/// - `onChange` fires after every modification to `title` or `body`.
/// - `restoreState` is silently suppressed inside `onChange`, so undo/redo
///   never pushes onto the undo stack — preventing runaway recursion.
/// - Snapshots are lightweight value types (`ModelStateSnapshot<NoteEditorModel>`)
///   that capture all tracked properties at a point in time.
/// - The undo/redo stacks live inside a `let` constant `UndoHistory` object.
///   `canUndo`/`canRedo` are computed properties that read from `UndoHistory` —
///   they are not stored model state and therefore excluded from snapshots.
@Model
struct NoteEditorModel {
    var title: String = "Untitled"
    var body: String = ""

    /// Holds the undo/redo stacks.
    ///
    /// Declared as `let` so it is excluded from state snapshots — restoring
    /// a snapshot does not overwrite live undo/redo history.
    let history: UndoHistory<NoteEditorModel>

    /// Whether there is at least one undo step available.
    var canUndo: Bool { history.canUndo }
    /// Whether there is at least one redo step available.
    var canRedo: Bool { history.canRedo }

    init(title: String = "Untitled", body: String = "") {
        _title = title
        _body = body
        history = UndoHistory()
    }

    func onActivate() {
        // Capture the initial state so the first onChange can push a "before" snapshot.
        history.previousSnapshot = node.captureState()

        // `onChange` fires after each modification but NOT during restoreState.
        // We push `previousSnapshot` (the state *before* this change) onto the undo
        // stack, then advance previousSnapshot to the new current state.
        node.onChange { [history] proxy in
            history.undoStack.append(history.previousSnapshot)
            history.redoStack.removeAll()
            history.previousSnapshot = proxy.snapshot
        }
    }

    func undo() {
        guard let snapshot = history.undoStack.popLast() else { return }
        // Save current state for redo.
        history.redoStack.append(node.captureState())
        node.restoreState(snapshot)
    }

    func redo() {
        guard let snapshot = history.redoStack.popLast() else { return }
        // Save current state for undo.
        history.undoStack.append(node.captureState())
        node.restoreState(snapshot)
    }
}

/// Heap-allocated container for the undo/redo stacks.
///
/// Stored as a `let` constant on the model so it is excluded from state
/// snapshots and does not trigger model change notifications.
public final class UndoHistory<M: Model>: @unchecked Sendable {
    var undoStack: [ModelStateSnapshot<M>] = []
    var redoStack: [ModelStateSnapshot<M>] = []
    var previousSnapshot: ModelStateSnapshot<M>!

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
}

// MARK: - Views

struct NoteEditorView: View {
    @ObservedModel var model: NoteEditorModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Title field
                TextField("Title", text: $model.title)
                    .font(.title2.bold())
                    .padding(.horizontal)
                    .padding(.vertical, 12)

                Divider()

                // Body editor
                TextEditor(text: $model.body)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            .navigationTitle("Note Editor")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Undo") {
                        model.undo()
                    }
                    .disabled(!model.canUndo)

                    Button("Redo") {
                        model.redo()
                    }
                    .disabled(!model.canRedo)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let model = NoteEditorModel().withAnchor()
    model.title = "Meeting Notes"
    model.body = "Discussed the new SwiftModel undo/redo API.\n\nKey points:\n- onChange fires after each change\n- restoreState is suppressed in onChange\n- Snapshots are lightweight value types"
    return NoteEditorView(model: model)
}
