import Foundation

// Internal configuration options for model behavior. Not part of the public API.
struct ModelOption: OptionSet, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Disable ObservationRegistrar and use AccessCollector for dependency tracking.
    ///
    /// When enabled, uses the custom AccessCollector implementation for tracking
    /// property accesses instead of Swift's built-in ObservationRegistrar (macOS 14+).
    ///
    /// This allows testing both observation mechanisms side-by-side.
    internal static let disableObservationRegistrar = ModelOption(rawValue: 1 << 0)
    
    /// Disable update coalescing for memoized properties.
    ///
    /// By default, memoize batches multiple rapid dependency changes into a single
    /// recomputation for better performance. When this option is enabled, memoize will
    /// instead recompute synchronously on every dependency change.
    ///
    /// This is useful for testing when you need predictable, synchronous behavior,
    /// or for debugging to see every intermediate state.
    internal static let disableMemoizeCoalescing = ModelOption(rawValue: 1 << 1)
}
