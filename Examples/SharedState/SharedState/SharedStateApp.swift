import SwiftUI
import SwiftModel

@main
struct CounterFactApp: App {
    let model = SharedState()._withPrintChanges().withAnchor()

    var body: some Scene {
        WindowGroup {
            NavigationView {
                SharedStateView(model: model)
            }
        }
    }
}
