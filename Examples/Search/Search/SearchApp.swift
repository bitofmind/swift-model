import SwiftUI
import SwiftModel

@main
struct SearchApp: App {
    // `.triggers()` prints which property changed (e.g. "SearchModel.results") on every
    // modification — cheap enough for a large model tree. Avoid `.changes()` (the default)
    // here: it does a full customDump + LCS diff of the *entire* tree on every change,
    // which becomes expensive when there are many nested child models (SearchResultItems).
    // Use the targeted `Observed(debug:)` inside a model's onActivate() instead.
    let model = AppModel().withDebug([.triggers()]).withAnchor()

    var body: some Scene {
        WindowGroup {
            AppView(model: model)
        }
    }
}
