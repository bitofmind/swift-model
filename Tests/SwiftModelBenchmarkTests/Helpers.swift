@testable import SwiftModel

/// Local subset of `Tests/SwiftModelTests/Utilities.swift` — only the helpers the
/// benchmark suites actually reference. Duplicated rather than shared because
/// SwiftPM test targets can't import other test targets, and these targets are
/// otherwise self-contained.

/// Sets `ModelOption.$current` to `options` for the duration of `body`. Used by
/// the benchmark suites to anchor models under specific framework options
/// (`.lazyChildContexts`, `.disableObservationRegistrar`,
/// `.disableMemoizeCoalescing`) without affecting the framework-wide defaults.
func withModelOptions<T>(_ options: ModelOption, _ body: () throws -> T) rethrows -> T {
    try ModelOption.$current.withValue(options, operation: body)
}
