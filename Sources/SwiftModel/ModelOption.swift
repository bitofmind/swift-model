import Foundation

/// Configuration options for model behavior.
///
/// Model options allow switching between different internal implementations
/// and behaviors. Options are set when anchoring a model and propagate to
/// all child models in the hierarchy.
///
/// Example:
///
///     let model = MyModel().withAnchor(options: [.disableObservationRegistrar])
///
public struct ModelOption: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Disable ObservationRegistrar and use AccessCollector for dependency tracking.
    ///
    /// When enabled, uses the custom AccessCollector implementation for tracking
    /// property accesses instead of Swift's built-in ObservationRegistrar (macOS 14+).
    ///
    /// This allows testing both observation mechanisms side-by-side.
    internal static let disableObservationRegistrar = ModelOption(rawValue: 1 << 0)
}
