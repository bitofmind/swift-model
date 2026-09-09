import Foundation

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
            // The park scope is per UPSTREAM element (it is inside the `while`
            // condition), so a duplicate that gets swallowed re-parks — the
            // property `_ParkSource` has to arrange explicitly for the filtered
            // sources below.
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
// ## Two things the first cut got wrong, and why the source now owns both ends
//
// The first cut wrapped the *consumer-facing* sequence
// (`someChain._eraseToParkedWaitStream()`) and unparked lazily, from the
// resumed task's `defer`. Measuring it (design §5 property 2) found both halves
// of that wrong:
//
//  1. **Lazy is late.** Between the continuation being resumed and the resumed
//     task's `defer` running, the unit still reads parked while model-writing
//     work is already inbound. 62 % of the surviving "new says quiescent, old
//     says busy" checks were an `AsyncStream.next()` cancellation resume
//     (`_Storage.finish()` called from the cancel handler) and 20 % a
//     `Continuation.yield`. The cancellation half has no activity signal behind
//     it at all, so §5's containment argument does not cover it, and the body
//     it resumes goes on to run model-writing `defer`s.
//     `ModelWorkUnit.noteResumeInFlight()` is the fix: the *resumer* unparks,
//     before it resumes.
//
//  2. **The outer position is the wrong position for an eager unpark.**
//     `node.event(ofType:)` is `context.events().compactMap { … }`: an event
//     that fails the filter still resumes the consumer, which filters it and
//     loops back into the *same* open park scope. An eager unpark at the outer
//     position would therefore leave the unit reading *running* until the next
//     event that happens to pass the filter — potentially never. So the park
//     moved inwards, to the one scope that is entered and left exactly once per
//     upstream element: the iterator over the raw `AsyncStream` that the
//     framework's own continuation feeds. Filtering downstream of it re-parks
//     by construction.
//
// `_ParkSource` is the rendezvous between the two ends, and it also closes a
// third window the outer position hid: a value yielded while the consumer was
// *running* sits in the stream's buffer, so the consumer's next `park()` would
// mark parked for a delivery that is already queued (and whose resume, being a
// buffered fast-path, is an executor hop away rather than a suspension away).
// `_ParkSource` counts undelivered yields and refuses to park while any are
// outstanding.
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
// **from an actor** hops off it once per element to run `produce`. Model task
// bodies are non-isolated, so the common path is unaffected — and every
// `node.event(…)` stream already paid exactly this, because `eraseToStream()`
// is itself an unfolding wrapper.

/// The producer↔consumer rendezvous for one SwiftModel-owned `AsyncStream`.
///
/// Held by both ends of a stream built with `_makeParkedStream`: the
/// `_ParkedYield` the framework yields through, and the `_ParkedWaitBox` the
/// consumer drives. Everything it does happens under one `NSLock`, which is
/// what makes "park" and "resume in flight" mutually exclusive rather than
/// racing — a producer can only force a unit it can still see parked, and a
/// consumer can only park when no delivery is outstanding. Without that, an
/// eager unpark could land just after the consumer re-parked and strand the
/// unit reading *running*.
///
/// Lock order is `_ParkSource` → `ModelWorkUnit`; nothing takes them the other
/// way round, and `AsyncStream.Continuation.yield` — which can resume a
/// continuation — is always called *outside* this lock.
final class _ParkSource: @unchecked Sendable {
    private let lock = NSLock()
    /// Yields handed to the stream's buffer that the consumer has not taken out
    /// yet. While this is non-zero the consumer refuses to park: the value is
    /// already queued, so no wait may read the unit as quiescent.
    private var undelivered = 0
    /// The unit currently suspended in this stream's `next()`, if any.
    private var waitingUnit: ModelWorkUnit?
    private var isTerminated = false

    // MARK: Producer side

    /// Call IMMEDIATELY BEFORE `AsyncStream.Continuation.yield(_:)`.
    func willYield() {
        lock.withLock {
            undelivered += 1
            resumeWaiterLocked()
        }
    }

    /// Call before anything that resumes a suspended `next()` with `nil`:
    /// `finish()`, and the stream's `onTermination` handler — which the stdlib
    /// invokes *before* resuming on cancellation (`AsyncStream._Storage.cancel`:
    /// "handler must be invoked before yielding nil for termination"). That is
    /// the cancellation half of the window, and the half with no activity
    /// signal behind it.
    func willTerminate() {
        lock.withLock {
            isTerminated = true
            resumeWaiterLocked()
        }
    }

    private func resumeWaiterLocked() {
        guard let unit = waitingUnit else { return }
        waitingUnit = nil
        unit.noteResumeInFlight()
    }

    // MARK: Consumer side

    /// About to `await` the next element. Parks the calling work unit unless a
    /// delivery is already outstanding (or the stream is over), and returns the
    /// ticket the caller must release when the await returns.
    ///
    /// Refusing to park is not enough on its own: `node.forEach` wraps its own
    /// `park()` around this whole call (hook 1, for foreign sequences), so a
    /// unit that declines to park here would still read parked from that OUTER
    /// scope while the buffered value it is about to take out is delivered.
    /// `noteResumeInFlight()` is what breaks out of an enclosing scope — it
    /// invalidates every open ticket on the unit, including `forEach`'s, and the
    /// unit stays running until `forEach`'s *next* loop parks it again.
    func beginWait() -> _ParkTicket? {
        guard let unit = ModelWorkUnit.current else { return nil }
        return lock.withLock { () -> _ParkTicket? in
            guard undelivered == 0, !isTerminated else {
                unit.noteResumeInFlight()
                return nil
            }
            let ticket = unit.park()
            waitingUnit = unit
            return ticket
        }
    }

    /// The await returned. `delivered` is `false` for the terminal `nil`.
    func endWait(delivered: Bool) {
        lock.withLock {
            waitingUnit = nil
            if delivered, undelivered > 0 { undelivered -= 1 }
        }
    }
}

/// The continuation SwiftModel's own stream sources yield through: an
/// `AsyncStream.Continuation` that tells its `_ParkSource` about every resume
/// *before* performing it.
///
/// Deliberately mirrors `AsyncStream.Continuation`'s member names, so adopting
/// it at a source site is a change to the stream's construction only — the body
/// that yields, finishes and installs `onTermination` needs no edit.
struct _ParkedYield<Element: Sendable>: Sendable {
    fileprivate let base: AsyncStream<Element>.Continuation
    fileprivate let source: _ParkSource

    func yield(_ value: Element) {
        source.willYield()
        base.yield(value)
    }

    func finish() {
        source.willTerminate()
        base.finish()
    }

    /// Composed rather than assigned: `_makeParkedStream` installs the park
    /// hook first, and a source site setting its own handler must not drop it.
    /// (That hook is what makes a *cancelled* consumer unpark eagerly, which no
    /// source site knows to do.)
    var onTermination: (@Sendable (AsyncStream<Element>.Continuation.Termination) -> Void)? {
        get { base.onTermination }
        nonmutating set {
            let source = self.source
            base.onTermination = { termination in
                source.willTerminate()
                newValue?(termination)
            }
        }
    }
}

/// Drives the raw stream's iterator, parking the calling work unit around the
/// wait.
///
/// `@unchecked Sendable` on the same terms as `_DedupBox`: `AsyncStream`'s
/// unfolding iterator serialises calls to `next()`, so only one call is ever in
/// flight and the captured iterator is never accessed concurrently.
private final class _ParkedWaitBox<Element>: @unchecked Sendable {
    private let _next: () async -> Element?

    init(_ iterator: AsyncStream<Element>.Iterator, source: _ParkSource) {
        var iter = iterator
        _next = {
            let ticket = source.beginWait()
            var delivered = false
            defer {
                source.endWait(delivered: delivered)
                // A no-op whenever the producer already unparked eagerly; see
                // `ModelWorkUnit`'s epoch discussion.
                ticket?.release()
            }
            let value = await iter.next()
            delivered = value != nil
            return value
        }
    }

    func next() async -> Element? { await _next() }
}

/// Builds a SwiftModel-owned `AsyncStream` whose consumer's wait is marked
/// parked and whose every resume is marked eagerly. The drop-in replacement for
/// `AsyncStream { cont in … }` at any site where the framework hands async
/// input to model code.
func _makeParkedStream<Element: Sendable>(
    of elementType: Element.Type = Element.self,
    _ build: (_ParkedYield<Element>) -> Void
) -> AsyncStream<Element> {
    let source = _ParkSource()
    let raw = AsyncStream<Element> { cont in
        // Installed before `build` so a site that never sets `onTermination`
        // still unparks eagerly on cancellation; `_ParkedYield`'s setter
        // composes rather than replaces.
        cont.onTermination = { _ in source.willTerminate() }
        build(_ParkedYield(base: cont, source: source))
    }
    let box = _ParkedWaitBox<Element>(raw.makeAsyncIterator(), source: source)
    return AsyncStream { await box.next() }
}

/// `AsyncStream.makeStream()` for a park-marked stream — for sources that store
/// the continuation rather than closing over it (`AnyContext.events()`).
func _makeParkedStream<Element: Sendable>(
    of elementType: Element.Type
) -> (stream: AsyncStream<Element>, continuation: _ParkedYield<Element>) {
    let source = _ParkSource()
    let (raw, cont) = AsyncStream<Element>.makeStream()
    cont.onTermination = { _ in source.willTerminate() }
    let box = _ParkedWaitBox<Element>(raw.makeAsyncIterator(), source: source)
    return (AsyncStream { await box.next() }, _ParkedYield(base: cont, source: source))
}
