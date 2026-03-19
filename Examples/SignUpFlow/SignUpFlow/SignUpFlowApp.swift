import SwiftUI
import SwiftModel

@main
struct CounterFactApp: App {
    @ObservedModel var model = SignUpFeature(signUpData: SignUpData()).withDebug().withAnchor()

    var body: some Scene {
        WindowGroup {
            SignUpFlow(model: model)
        }
    }
}
