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

    /// Disable withObservationTracking path and use AccessCollector instead.
    ///
    /// By default, the update() function uses Swift's withObservationTracking on supported platforms
    /// (macOS 14+, iOS 17+). When this option is enabled, it falls back to the AccessCollector-based
    /// implementation instead.
    ///
    /// This option is primarily for testing backward compatibility with older OS versions
    /// that don't support @Observable.
    internal static let disableObservationTracking = ModelOption(rawValue: 1 << 1)
    
    /// Disable update coalescing for memoized properties.
    ///
    /// By default, memoize batches multiple rapid dependency changes into a single
    /// recomputation for better performance. When this option is enabled, memoize will
    /// instead recompute synchronously on every dependency change.
    ///
    /// This is useful for testing when you need predictable, synchronous behavior,
    /// or for debugging to see every intermediate state.
    internal static let disableMemoizeCoalescing = ModelOption(rawValue: 1 << 2)
    
    /// Disable dirty tracking for memoized properties.
    ///
    /// By default, memoize uses dirty flags to avoid redundant recomputations
    /// during transactions. When this option is enabled, memoize will recompute
    /// on every dependency change (previous behavior).
    ///
    /// This is useful for testing and performance comparison.
    internal static let disableMemoizeDirtyTracking = ModelOption(rawValue: 1 << 3)
}
