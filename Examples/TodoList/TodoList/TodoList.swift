import SwiftModel
import SwiftUI

// MARK: - Preference Keys

extension PreferenceKeys {
    /// Each TodoItem contributes 1 when done, 0 when not.
    /// The root reads the aggregate to show "X of Y completed" without
    /// iterating the items array or holding a reference to each item.
    var completedCount: PreferenceStorage<Int> {
        .init(defaultValue: 0) { $0 += $1 }
    }
}

// MARK: - Environment Keys

extension EnvironmentKeys {
    /// Whether completed items are shown in the list.
    /// Written by TodoListModel and read by each TodoItem to determine its own visibility.
    /// Demonstrates top-down environment propagation: parent sets it once,
    /// all descendants read it without a direct reference.
    var showCompleted: EnvironmentStorage<Bool> { .init(defaultValue: true) }
}

// MARK: - Model

/// A single to-do item.
@Model struct TodoItem: Sendable, Equatable {
    var title: String
    var isDone: Bool = false

    /// Whether this item is currently visible given the parent list's filter.
    /// Reads the `showCompleted` environment value propagated from TodoListModel.
    var isVisible: Bool { !isDone || node.environment.showCompleted }

    func onActivate() {
        // Track title and isDone for undo so renaming and toggling are undoable.
        node.trackUndo(\.title, \.isDone)
        // Report completion status upward as a preference contribution.
        // The root aggregates these without iterating the array directly.
        node.forEach(Observed { isDone }) { done in
            node.preference.completedCount = done ? 1 : 0
        }
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
/// Demonstrates three SwiftModel hierarchy communication patterns in one example:
///
/// - **Preferences (bottom-up):** Each ``TodoItem`` reports its `isDone` state
///   upward via ``PreferenceKeys/completedCount``; the root aggregates without
///   iterating `items` directly.
///
/// - **Environment (top-down):** ``showCompleted`` is set on this model and
///   propagated into the environment; each ``TodoItem`` reads
///   `node.environment.showCompleted` to determine its own visibility without a
///   direct reference to the parent list.
///
/// - **Undo / redo:** Only the `items` array participates in the undo stack.
///   Typing into the "new item" field does not create undo entries.
@Model struct TodoListModel: Sendable {
    var items: [TodoItem] = []
    var newItemTitle: String = ""
    /// Controls whether completed items are shown. Propagated to items via environment.
    var showCompleted: Bool = true

    /// Aggregate completion count reported upward by each TodoItem via preference.
    var completedCount: Int { node.preference.completedCount }

    /// Items currently visible given the `showCompleted` filter.
    var visibleItems: [TodoItem] { showCompleted ? items : items.filter { !$0.isDone } }

    func onActivate() {
        // Only track `items` for undo — typing in the new-item field is ephemeral
        // and does not pollute the undo stack.
        node.trackUndo(\.items)

        // Propagate showCompleted into the environment so TodoItem.isVisible
        // can read it without a direct reference to the parent list.
        node.forEach(Observed { showCompleted }) {
            node.environment.showCompleted = $0
        }

        // Targeted debug: print only when items.count or completedCount changes.
        // Contrast with .withDebug() which would also fire on every newItemTitle keystroke.
        node.forEach(Observed(debug: .all) { (items.count, completedCount) }) { _ in }
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

    func toggleShowCompleted() {
        showCompleted.toggle()
    }
}

// MARK: - Views

struct TodoListView: View {
    @ObservedModel var model: TodoListModel

    var body: some View {
        let visibleItems = model.visibleItems
        List {
            ForEach(visibleItems) { item in
                TodoItemRow(item: item) {
                    model.items.removeAll { $0.id == item.id }
                }
            }
            .onDelete { offsets in
                // Map filtered-array offsets back to IDs so deletion is correct
                // regardless of whether a filter is active.
                let ids = Set(offsets.map { visibleItems[$0].id })
                model.items.removeAll { ids.contains($0.id) }
            }
            // Disable reordering while the filter is active — the filtered array
            // indices don't correspond to the full items array.
            .onMove(perform: model.showCompleted ? { model.moveItems(from: $0, to: $1) } : nil)
        }
        .navigationTitle("To-Do List")
#if os(macOS)
        .navigationSubtitle(model.items.isEmpty ? "" : "\(model.completedCount) of \(model.items.count) completed")
#endif
        .toolbar {
#if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                filterButton
            }
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
            ToolbarItemGroup(placement: .bottomBar) {
                undoRedoButtons
            }
#else
            ToolbarItemGroup {
                filterButton
                undoRedoButtons
            }
#endif
        }
        .safeAreaInset(edge: .bottom) {
            AddItemBar(model: model)
        }
    }

    @ViewBuilder
    private var filterButton: some View {
        Button {
            model.toggleShowCompleted()
        } label: {
            Image(systemName: model.showCompleted
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .help(model.showCompleted ? "Hide completed" : "Show completed")
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
#if os(macOS)
                    .onExitCommand { cancelEdit() }   // Esc on macOS
#endif
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
    let model = TodoListModel().withAnchor { $0.undoSystem.backend = stack }
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
