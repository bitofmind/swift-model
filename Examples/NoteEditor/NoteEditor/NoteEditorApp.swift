import SwiftUI
import SwiftModel

@main
struct NoteEditorApp: App {
    let model = NoteEditorModel()._withPrintChanges().withAnchor()

    var body: some Scene {
        WindowGroup {
            NoteEditorView(model: model)
        }
    }
}
