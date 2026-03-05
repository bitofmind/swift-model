import SwiftModel
import SwiftUI

// MARK: - Model

/// A single to-do item.
@Model struct TodoItem: Sendable, Equatable {
    var title: String
    var isDone: Bool = false

    func onActivate() {
        // Track title and isDone for undo so renaming and toggling are undoable.
        node.trackUndo(\.title, \.isDone)
    }

    func toggleTapped() {
        isDone.toggle()
    }

    func renameSubmitted(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        title = trimmed
    }
}

/// Root model for the to-do list.
///
/// Demonstrates selective undo/redo: only the `items` array participates in the
/// undo stack. Typing into the "new item" field does not create undo entries.
/// A ``ModelUndoStack`` is injected as the ``ModelUndoSystem`` backend at anchor
/// time, making ``ModelUndoSystem/canUndo`` and ``ModelUndoSystem/canRedo``
/// observable model properties.
@Model struct TodoListModel: Sendable {
    var items: [TodoItem] = []
    var newItemTitle: String = ""

    func onActivate() {
        // Only track `items` for undo — typing in the new-item field is ephemeral
        // and does not pollute the undo stack.
        node.trackUndo(\.items)
    }

    func addItemTapped() {
        let trimmed = newItemTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        items.append(TodoItem(title: trimmed))
        newItemTitle = ""
    }

    func deleteItems(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    func moveItems(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }
}

// MARK: - Views

struct TodoListView: View {
    @ObservedModel var model: TodoListModel

    var body: some View {
        List {
            ForEach(model.items) { item in
                TodoItemRow(item: item) {
                    model.items.removeAll { $0.id == item.id }
                }
            }
            .onDelete { model.deleteItems(at: $0) }
            .onMove { model.moveItems(from: $0, to: $1) }
        }
        .navigationTitle("To-Do List")
        .toolbar {
#if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
            ToolbarItemGroup(placement: .bottomBar) {
                undoRedoButtons
            }
#else
            ToolbarItemGroup {
                undoRedoButtons
            }
#endif
        }
        .safeAreaInset(edge: .bottom) {
            AddItemBar(model: model)
        }
    }

    @ViewBuilder
    private var undoRedoButtons: some View {
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
    }
}

private struct TodoItemRow: View {
    @ObservedModel var item: TodoItem
    let onDelete: () -> Void
    @State private var isEditing = false
    @State private var editDraft = ""

    var body: some View {
        HStack {
            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isDone ? Color.accentColor : .secondary)
                .onTapGesture { item.toggleTapped() }

            if isEditing {
                TextField("Title", text: $editDraft)
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }   // Esc on macOS
            } else {
                Text(item.title)
                    .strikethrough(item.isDone)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEdit() }
            }

#if os(macOS)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
#endif
        }
    }

    private func beginEdit() {
        editDraft = item.title
        isEditing = true
    }

    private func commitEdit() {
        isEditing = false
        item.renameSubmitted(editDraft)
    }

    private func cancelEdit() {
        isEditing = false
    }
}

private struct AddItemBar: View {
    @ObservedModel var model: TodoListModel

    var body: some View {
        HStack(spacing: 12) {
            TextField("New item…", text: $model.newItemTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.addItemTapped() }

            Button(action: model.addItemTapped) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
            }
            .disabled(model.newItemTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

// MARK: - App entry point wrapper

#if os(iOS)
struct TodoListRootView: View {
    @ObservedModel var model: TodoListModel

    var body: some View {
        NavigationStack {
            TodoListView(model: model)
        }
    }
}
#else
typealias TodoListRootView = TodoListView
#endif

// MARK: - Preview

#Preview {
    let stack = ModelUndoStack()
    let model = TodoListModel().withAnchor(andDependencies: { $0.undoSystem.backend = stack })
    model.items = [
        TodoItem(title: "Buy groceries"),
        TodoItem(title: "Walk the dog", isDone: true),
        TodoItem(title: "Write unit tests"),
    ]
#if os(iOS)
    return NavigationStack {
        TodoListView(model: model)
    }
#else
    return TodoListView(model: model)
#endif
}
