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
            // Park around the upstream wait (semantic quiescence, hook 1). This
            // closure runs on the CONSUMER's task — a `node.forEach` body — so
            // when it is driven through `forEach` the park is nested inside
            // `forEach`'s own park and the counter (not a Bool) keeps the unit
            // parked until both scopes exit. Marking it here too means a
            // hand-written `for await` over one of these streams parks as well.
            while let value = await _withCurrentWorkUnitParked({ try? await iter.next() }) {
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

// MARK: - Tier 1: source-side parking
//
// `Docs/test-quiescence-redesign.md` §5: **the park mark belongs to the input
// source, not to the consuming loop.** `node.forEach` parks around its own
// `next()` (hook 1), but a user can write the loop by hand —
//
//     node.task { for await value in Observed { … } }         // no forEach
//
// — and if `forEach` were the only marking site that task would read as
// *running* forever, blocking quiescence for as long as it lives. SwiftModel
// owns every one of these sources (it produces the `AsyncStream` and holds the
// continuation), so the mark goes where the framework can guarantee it: the
// iterator's wait for the next yield.
//
// The mechanism is `AsyncStream(unfolding:)`, whose produce closure runs **on
// the consuming task** — so `ModelWorkUnit.current` resolves to the consumer's
// unit and the park is attributed correctly, wherever the stream was
// constructed. (`UpdateStreamTests`' "captured" case builds the `Observed` in
// `onActivate`'s scope and iterates it from a separate `node.task` body; the
// park still lands on the iterating body.) This is the same shape
// `removeDuplicates()` above and ConcurrencyExtras' `eraseToStream()` already
// use, which is why events cost nothing extra: `_eraseToParkedWaitStream()`
// REPLACES an `eraseToStream()` that was building an unfolding stream anyway.
//
// Only the wait is parked — never the consumer's body. Running the user's
// closure is real model work.
//
// ## Why `AsyncStream(unfolding:)` and not a custom iterator
//
// The obvious alternative is to give `Observed` its own `AsyncIterator` that
// parks around the upstream `next()`. Two reasons not to:
//
//   * **Public API.** `Observed.makeAsyncIterator()` returns
//     `AsyncStream<Element>.Iterator`, and `node.event(…)` /
//     `observeModifications()` return `AsyncStream<T>` outright. Unfolding keeps
//     every one of those types exactly as it was; a custom iterator would change
//     the `AsyncIterator` associated type.
//   * **SE-0431 (`next(isolation:)`).** Because the consumer still iterates a
//     plain `AsyncStream`, it gets the *stdlib's* `next(isolation:)`, so `for
//     await`'s desugaring is untouched and we never have to decide whether to
//     witness an availability-gated requirement (`next(isolation:)` is
//     SwiftStdlib 6.0; this library deploys to macOS 11). A hand-written
//     iterator implementing only `next()` would silently downgrade every
//     `for await` over these streams to the non-isolated path.
//
// The residual cost is real and worth knowing: the produce closure is
// `@Sendable` and non-isolated, so a consumer that iterates one of these streams
// **from an actor** now hops off it once per element to run `produce`. Model
// task bodies are non-isolated, so the common path is unaffected — and every
// `node.event(…)` stream already paid exactly this, because
// `eraseToStream()` is itself an unfolding wrapper.
//
// `_ParkedWaitBox` is generic over the *iterator* rather than over `Element`
// for the same reason `_DedupBox` is: it keeps `Self.AsyncIterator.Type` out of
// the `@Sendable` unfolding closure, whose metatype is not guaranteed `Sendable`
// in a generic context.

/// Drives an upstream iterator, parking the calling work unit around the wait.
///
/// `@unchecked Sendable` on the same terms as `_DedupBox`: `AsyncStream`'s
/// unfolding iterator serialises calls to `next()`, so only one call is ever
/// in flight and the captured iterator is never accessed concurrently.
private final class _ParkedWaitBox<Element>: @unchecked Sendable {
    private let _next: () async -> Element?

    init<I: AsyncIteratorProtocol>(_ iterator: I) where I.Element == Element {
        var iter = iterator
        _next = {
            // `try?` matches `eraseToStream()`'s own erasure semantics (a
            // throwing upstream terminates the stream); none of SwiftModel's
            // own sources throw.
            await _withCurrentWorkUnitParked { try? await iter.next() }
        }
    }

    func next() async -> Element? { await _next() }
}

extension AsyncSequence where Self: Sendable, Element: Sendable {
    /// `eraseToStream()`, plus the tier-1 park mark on the consumer's wait.
    ///
    /// Use this for every stream SwiftModel itself produces and hands to model
    /// code. Consumers that go through `node.forEach` park twice (once here,
    /// once in `forEach`'s own `next()`); `ModelWorkUnit`'s activity **counter**
    /// — rather than a `Bool` — is what makes that nesting compose.
    func _eraseToParkedWaitStream() -> AsyncStream<Element> {
        let box = _ParkedWaitBox<Element>(makeAsyncIterator())
        return AsyncStream { await box.next() }
    }
}
