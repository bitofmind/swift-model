// MARK: - Internal replacement for swift-async-algorithms
//
// eraseToStream() is NOT defined here — ConcurrencyExtras (re-exported by Dependencies) already
// provides AsyncSequence.eraseToStream(). Defining our own would create an ambiguous overload.
//
// removeDuplicates() is defined here because ConcurrencyExtras does not provide it.
//
// The concrete iterator type is hidden inside _DedupBox via a type-erased () async -> Element?
// closure stored at init time. This keeps Self.AsyncIterator.Type out of the @Sendable unfolding
// closure (its metatype may not be Sendable in generic contexts).
//
// The extension is constrained to Element: Equatable & Sendable so the @Sendable closure only
// captures metatypes guaranteed to be Sendable (Sendable implies SendableMetatype in Swift 6.1).
//
// @unchecked Sendable is safe: AsyncStream(unfolding:) drives the closure sequentially — only
// one call to box.next() is ever in-flight at a time.

private final class _DedupBox<Element: Equatable>: @unchecked Sendable {
    private let _next: () async -> Element?
    init<I: AsyncIteratorProtocol>(_ iterator: I) where I.Element == Element {
        var iter = iterator
        var previous: Element? = nil
        _next = {
            while let value = try? await iter.next() {
                if value != previous { previous = value; return value }
            }
            return nil
        }
    }
    func next() async -> Element? { await _next() }
}

extension AsyncSequence where Element: Equatable & Sendable {
    /// Returns a stream that omits consecutive duplicate values.
    /// Internal replacement for `AsyncAlgorithms.removeDuplicates()`.
    func removeDuplicates() -> AsyncStream<Element> {
        let box = _DedupBox(makeAsyncIterator())
        return AsyncStream { await box.next() }
    }
}
