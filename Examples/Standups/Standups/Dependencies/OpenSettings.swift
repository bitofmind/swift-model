import Dependencies
#if canImport(UIKit)
import UIKit
#endif

extension DependencyValues {
    var openSettings: @Sendable () async -> Void {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }

    private enum OpenSettingsKey: DependencyKey {
        typealias Value = @Sendable () async -> Void

        static let liveValue: @Sendable () async -> Void = {
            #if canImport(UIKit)
            await MainActor.run {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            }
            #endif
        }
    }
}
