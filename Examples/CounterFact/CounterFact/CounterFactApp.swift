import SwiftUI
import SwiftModel
import XCTestDynamicOverlay

@main
struct CounterFactApp: App {
    let model = AppModel()._withPrintChanges().withAnchor()

    var body: some Scene {
        WindowGroup {
            NavigationView {
#if os(macOS)
                EmptyView()
#endif
                if !_XCTIsTesting {
                    AppView(model: model)
                }
            }
#if !os(macOS)
            .navigationViewStyle(.stack)
#endif
        }
    }
}
