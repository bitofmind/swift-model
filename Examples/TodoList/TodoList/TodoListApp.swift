import SwiftUI
import SwiftModel

@main
struct TodoListApp: App {
    let model: TodoListModel

    init() {
        let stack = ModelUndoStack()
        self.model = TodoListModel()._withPrintChanges().withAnchor(andDependencies: {
            $0.undoSystem.backend = stack
        })
    }

    var body: some Scene {
        WindowGroup {
            TodoListRootView(model: model)
        }
    }
}
