// MARK: - Internal replacements for swift-async-algorithms
//
// These replace AsyncAlgorithms.eraseToStream() and AsyncAlgorithms.removeDuplicates().
// An @unchecked Sendable box bridges potentially non-Sendable iterators into AsyncStream's
// `sending` closure requirement. This is safe because AsyncStream's unfolding closure is
// called sequentially — never concurrently.

private final class _IteratorBox<I: AsyncIteratorProtocol, E>: @unchecked Sendable {
    var iterator: I
    var previous: E?
    init(_ iterator: I) { self.iterator = iterator }
}

extension AsyncSequence {
    /// Converts this async sequence into an `AsyncStream` by driving it element by element.
    /// Internal replacement for `AsyncAlgorithms.eraseToStream()`.
    func eraseToStream() -> AsyncStream<Element> {
        let box = _IteratorBox<AsyncIterator, Element>(makeAsyncIterator())
        return AsyncStream(unfolding: { try? await box.iterator.next() })
    }
}

extension AsyncSequence where Element: Equatable {
    /// Returns a stream that omits consecutive duplicate values.
    /// Internal replacement for `AsyncAlgorithms.removeDuplicates()`.
    func removeDuplicates() -> AsyncStream<Element> {
        let box = _IteratorBox<AsyncIterator, Element>(makeAsyncIterator())
        return AsyncStream(unfolding: {
            while let next = try? await box.iterator.next() {
                if next != box.previous {
                    box.previous = next
                    return next
                }
            }
            return nil
        })
    }
}
