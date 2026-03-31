import SwiftModel
import SwiftUI

@main
struct StandupsApp: App {
    @State private var model = AppFeature(path: []).withDebug().withAnchor()

    var body: some Scene {
        WindowGroup {
            AppView(model: model)
        }
    }
}

