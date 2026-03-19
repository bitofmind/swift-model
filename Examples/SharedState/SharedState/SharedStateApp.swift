import SwiftUI
import SwiftModel

@main
struct CounterFactApp: App {
    let model = SharedState().withDebug().withAnchor()

    var body: some Scene {
        WindowGroup {
            SharedStateView(model: model)
        }
    }
}
