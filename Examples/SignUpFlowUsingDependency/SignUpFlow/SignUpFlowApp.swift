import SwiftUI
import SwiftModel

@main
struct CounterFactApp: App {
    @ObservedModel var model = SignUpFeature()._withPrintChanges().withAnchor()

    var body: some Scene {
        WindowGroup {
            SignUpFlow(model: model)
        }
    }
}
