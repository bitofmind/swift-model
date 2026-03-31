import SwiftUI
import SwiftModel

@main
struct CounterFactApp: App {
    let model = AppModel().withDebug().withAnchor()

    var body: some Scene {
        WindowGroup {
            NavigationView {
#if os(macOS)
                EmptyView()
#endif
                AppView(model: model)
            }
#if !os(macOS)
            .navigationViewStyle(.stack)
#endif
        }
    }
}
