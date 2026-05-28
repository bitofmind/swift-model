import Testing

/// Tags for categorizing tests
extension Tag {
    /// Tests that measure performance/benchmarks
    ///
    /// These tests:
    /// - Run serially to avoid interference
    /// - May take longer to complete
    /// - Print performance metrics
    /// - Should be excluded from regular test runs
    @Tag static var benchmark: Self

    /// Tests that are flaky or timing-sensitive
    ///
    /// These tests may occasionally fail due to timing issues
    /// and should be monitored separately
    @Tag static var flaky: Self
}
