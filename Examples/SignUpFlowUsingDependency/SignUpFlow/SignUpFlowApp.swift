import SwiftUI
import SwiftModel

@main
struct CounterFactApp: App {
    @ObservedModel var model = SignUpFeature().withDebug().withAnchor()

    var body: some Scene {
        WindowGroup {
            SignUpFlow(model: model)
        }
    }
}
