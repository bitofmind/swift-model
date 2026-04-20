import Foundation

// Internal configuration options for model behavior. Not part of the public API.
// Set via `ModelOption.$current.withValue(...)` before calling `withAnchor()`.
// The value is captured into `AnyContext.options` at init time and inherited by child contexts.
struct ModelOption: OptionSet, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    @TaskLocal static var current: ModelOption = []

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

    /// Enable lazy child context creation for collection elements.
    ///
    /// When enabled, child models inside collections (e.g. `var posts: [Post]`) are not
    /// immediately given a `Context` during `withAnchor()`. Instead, each child's context
    /// is created on demand — triggered by the first write, `node` use, or any other
    /// operation that requires a live context.
    ///
    /// This benefits large arrays shown in lazy scroll views where only a small fraction
    /// of items are ever rendered. For a list of 2000 posts showing 20 visible items,
    /// only 20 child contexts are created instead of 2000 (~54% faster anchor time).
    ///
    /// Direct single-model children (e.g. `var child: Child`) are always created eagerly
    /// regardless of this option, so hierarchy APIs, dependency inheritance, and
    /// `onActivate()` are unaffected for non-collection children.
    internal static let lazyChildContexts = ModelOption(rawValue: 1 << 2)
}
