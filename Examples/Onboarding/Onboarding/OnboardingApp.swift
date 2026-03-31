import SwiftUI
import SwiftModel

@main
struct OnboardingApp: App {
    // `.triggers()` prints which property changed without an expensive full-tree diff.
    // See Search/SearchApp.swift for a detailed comment on why `.changes()` (the default)
    // is avoided on models that own large child collections.
    let model = SignUpModel().withDebug([.triggers()]).withAnchor()

    var body: some Scene {
        WindowGroup {
            // SignUpView owns its own NavigationStack(path:) — no wrapper needed here.
            SignUpView(model: model)
        }
    }
}
