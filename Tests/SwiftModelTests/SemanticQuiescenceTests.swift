import Testing
import Foundation
import Dependencies
import ConcurrencyExtras
@testable import SwiftModel

// Tests for the SEMANTIC quiescence accounting (`Docs/test-quiescence-redesign.md`
// §3–§6b): every `TaskCancellable` is a work unit that is either RUNNING (its
// body is executing, or suspended somewhere SwiftModel did not put it) or
// PARKED (suspended at a suspension point the framework owns, or inside
// `withModelParked`).
//
// Nothing here exercises a verdict: `AnyContext.semanticQuiescence` is computed
// alongside the existing executor/queue answer and compared, but the existing
// answer still decides every `expect`/`settle`/`waitUntil`. These tests assert
// the accounting directly, which is the point of §8 — a semantic invariant is
// deterministic and needs no loaded machine to validate.

// MARK: - Test fixtures

/// A clock SwiftModel knows nothing about: it conforms to no protocol the
/// framework can see (not `_Concurrency.Clock`, not anything of ours), suspends
/// on a raw continuation, and only resumes when the test calls `advance()`.
/// This is the shape design §6c calls "waiting for the test to act".
final class ForeignClock: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isCancelled = false

    /// Number of sleepers currently suspended.
    var sleeperCount: Int { lock.withLock { continuations.count } }

    func sleep() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeImmediately: Bool = lock.withLock {
                    if isCancelled { return true }
                    continuations.append(continuation)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        } onCancel: {
            // Keep test teardown honest: a cancelled task must be able to finish.
            self.lock.withLock { self.isCancelled = true }
            self.advance()
        }
    }

    /// Releases every current sleeper.
    func advance() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            defer { continuations = [] }
            return continuations
        }
        for continuation in pending { continuation.resume() }
    }
}

/// Shared out-of-band control surface for the models below: stop flags, an
/// externally-fed stream, and a gate the `forEach` body can be held inside.
final class QuiescenceControl: @unchecked Sendable {
    let stop = LockIsolated(false)
    let bodyEntered = LockIsolated(false)

    private let lock = NSLock()
    private var streamContinuation: AsyncStream<Int>.Continuation?
    private var gateContinuations: [CheckedContinuation<Void, Never>] = []
    private var gateIsOpen = false

    let stream: AsyncStream<Int>

    init() {
        var continuation: AsyncStream<Int>.Continuation!
        stream = AsyncStream { continuation = $0 }
        streamContinuation = continuation
    }

    func yieldValue(_ value: Int) {
        lock.withLock { streamContinuation }?.yield(value)
    }

    /// Suspends until `openGate()` — used to hold a `forEach` body inside the
    /// body (i.e. RUNNING), deterministically.
    func waitAtGate() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeImmediately: Bool = lock.withLock {
                    if gateIsOpen { return true }
                    gateContinuations.append(continuation)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        } onCancel: {
            self.openGate()
        }
    }

    func openGate() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            gateIsOpen = true
            defer { gateContinuations = [] }
            return gateContinuations
        }
        for continuation in pending { continuation.resume() }
    }
}

extension DependencyValues {
    var foreignClock: ForeignClock {
        get { self[ForeignClockKey.self] }
        set { self[ForeignClockKey.self] = newValue }
    }

    var quiescenceControl: QuiescenceControl {
        get { self[QuiescenceControlKey.self] }
        set { self[QuiescenceControlKey.self] = newValue }
    }

    enum ForeignClockKey: DependencyKey {
        static let liveValue = ForeignClock()
    }

    enum QuiescenceControlKey: DependencyKey {
        static let liveValue = QuiescenceControl()
    }
}

// MARK: - Models

/// Sleeps on the foreign clock inside `withModelParked` — design §6b hook 3.
@Model private struct ParkedClockSleeper {
    var didFinish = false

    func onActivate() {
        node.task {
            await withModelParked {
                await node.foreignClock.sleep()
            }
            didFinish = true
        }
    }
}

/// The same sleep with no wrap — the unmarked (tier 3) case.
@Model private struct UnmarkedClockSleeper {
    var didFinish = false

    func onActivate() {
        node.task {
            await node.foreignClock.sleep()
            didFinish = true
        }
    }
}

/// The PR #70 blind spot: a task that only ever `Task.yield()`s. The framework
/// did not park it, so it must count as RUNNING throughout.
@Model private struct YieldingLooper {
    func onActivate() {
        node.task {
            let control = node.quiescenceControl
            control.bodyEntered.setValue(true)
            while !Task.isCancelled && !control.stop.value {
                await Task.yield()
            }
        }
    }
}

/// A compute loop with no suspension point at all — running forever, by design
/// (§6a: user error, to be reported rather than accommodated).
@Model private struct SpinningLooper {
    func onActivate() {
        node.task {
            let control = node.quiescenceControl
            control.bodyEntered.setValue(true)
            var sink = 0
            while !Task.isCancelled && !control.stop.value {
                sink &+= 1
            }
            _ = sink
        }
    }
}

/// `node.forEach` over an externally-fed `AsyncStream` — design §6b hook 1.
@Model private struct StreamConsumer {
    var received = 0

    func onActivate() {
        node.forEach(node.quiescenceControl.stream) { value in
            node.quiescenceControl.bodyEntered.setValue(true)
            // Hold the body open so "running while the body executes" is
            // observable without a race.
            await node.quiescenceControl.waitAtGate()
            received = value
        }
    }
}

// MARK: - Tests

@Suite(.modelTesting(exhaustivity: .off))
struct SemanticQuiescenceTests {
    /// A task parked on a FOREIGN clock inside `withModelParked` does not block
    /// quiescence: the semantic answer is quiescent while it sleeps.
    @Test func foreignClockSleepInsideWithModelParkedIsParked() async throws {
        let clock = ForeignClock()
        let model = ParkedClockSleeper().withAnchor {
            $0.foreignClock = clock
        }
        let context = model.anyContext!

        try await waitUntil(clock.sleeperCount == 1)
        // The registered unit exists (the task has not returned) …
        #expect(context.activeTasks.flatMap(\.tasks).count == 1)
        // … but it is parked, so the model is semantically quiescent.
        #expect(context.hasRunningWorkUnit == false)
        #expect(context.runningWorkUnits.isEmpty)
        #expect(context.semanticQuiescence == true)

        // Unparks and completes when the test acts.
        clock.advance()
        await expect(model.didFinish)
    }

    /// The same sleep WITHOUT the wrap is running work — SwiftModel cannot see
    /// the suspension, so the honest answer is "not quiescent" (§6 tier 3).
    @Test func foreignClockSleepWithoutWithModelParkedIsRunning() async throws {
        let clock = ForeignClock()
        let model = UnmarkedClockSleeper().withAnchor {
            $0.foreignClock = clock
        }
        let context = model.anyContext!

        try await waitUntil(clock.sleeperCount == 1)
        #expect(context.hasRunningWorkUnit == true)
        #expect(context.semanticQuiescence == false)
        // The backstop message material: the unit names itself.
        let running = context.runningWorkUnits
        #expect(running.count == 1)
        #expect(running.first?.modelName == "UnmarkedClockSleeper")

        clock.advance()
        await expect(model.didFinish)
        // Once the body returns the unit is finished and unregistered.
        try await waitUntil(model.anyContext?.hasRunningWorkUnit == false)
    }

    /// The blind spot that caused PR #70: a task looping on `Task.yield()` is
    /// suspended constantly, but SwiftModel did not park it, so it is RUNNING
    /// throughout — sampled repeatedly, never once quiescent.
    @Test func yieldLoopIsRunningThroughout() async throws {
        let control = QuiescenceControl()
        let model = YieldingLooper().withAnchor {
            $0.quiescenceControl = control
        }
        let context = model.anyContext!

        try await waitUntil(control.bodyEntered.value)
        var sawQuiescent = false
        for _ in 0..<50 {
            if !context.hasRunningWorkUnit { sawQuiescent = true; break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(sawQuiescent == false)

        control.stop.setValue(true)
        try await waitUntil(model.anyContext?.hasRunningWorkUnit == false)
    }

    /// A compute loop with no await never parks — running for as long as it
    /// runs. Bounded assertion: sample for a fixed number of iterations, then
    /// let the loop finish rather than hanging the suite.
    @Test func computeLoopWithNoAwaitIsRunningForever() async throws {
        let control = QuiescenceControl()
        let model = SpinningLooper().withAnchor {
            $0.quiescenceControl = control
        }
        let context = model.anyContext!

        try await waitUntil(control.bodyEntered.value)
        var sawQuiescent = false
        for _ in 0..<20 {
            if !context.hasRunningWorkUnit { sawQuiescent = true; break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(sawQuiescent == false)

        control.stop.setValue(true)
        try await waitUntil(model.anyContext?.hasRunningWorkUnit == false)
    }

    /// Hook 1: `node.forEach` parks around its own `next()`, so a consumer with
    /// nothing buffered is parked — and becomes running the moment a value is
    /// delivered and its body starts.
    @Test func forEachIsParkedWhileWaitingAndRunningWhileDelivering() async throws {
        let control = QuiescenceControl()
        let model = StreamConsumer().withAnchor {
            $0.quiescenceControl = control
        }
        let context = model.anyContext!

        // Nothing buffered: the consumer is parked inside `next()`.
        try await waitUntil(context.activeTasks.flatMap(\.tasks).count == 1)
        try await waitUntil(context.hasRunningWorkUnit == false)
        #expect(context.semanticQuiescence == true)

        // A yielded value wakes the consumer; its body is held at the gate, so
        // the unit is unambiguously running.
        control.yieldValue(7)
        try await waitUntil(control.bodyEntered.value)
        #expect(context.hasRunningWorkUnit == true)

        control.openGate()
        await expect(model.received == 7)
        // Back to parked once the body returns and the loop awaits `next()`.
        try await waitUntil(model.anyContext?.hasRunningWorkUnit == false)
    }

    /// Outside any model task there is no work unit; `withModelParked` is a
    /// plain passthrough — value and errors both propagate, no trap.
    @Test func withModelParkedOutsideAModelTaskIsAPassthrough() async {
        #expect(ModelWorkUnit.current == nil)

        let value = await withModelParked { 42 }
        #expect(value == 42)

        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withModelParked { throw Boom() }
        }
    }

    /// Nesting: the counter (not a `Bool`) keeps the unit parked until the
    /// OUTERMOST `withModelParked` exits.
    @Test func nestedWithModelParkedStaysParkedUntilOutermostExits() async {
        let unit = ModelWorkUnit()
        #expect(unit.isRunning == true)
        await ModelWorkUnit.$current.withValue(unit) {
            await withModelParked {
                #expect(unit.isRunning == false)
                await withModelParked {
                    #expect(unit.isRunning == false)
                }
                #expect(unit.isRunning == false)   // outer park still in scope
            }
        }
        #expect(unit.isRunning == true)
    }

    // MARK: - The combined rule's fallback classification
    //
    //     quiescent := oldSaysDone AND (newSaysDone OR runningWorkLooksUndeclared)
    //
    // These assert the third term directly. `looksUndeclared` is the ONLY shape
    // that may defer to the scheduler-observing answer, so the two failure modes
    // to guard are (a) it misses a genuinely undeclared sleep and a wait that
    // returns today starts hanging, and (b) it swallows a mid-flight unit and
    // the correctness fix this design exists for is silently undone.

    /// A brand-new unit has never parked and has just been created, so it is
    /// MID-FLIGHT against any non-zero quiet window (it may simply not have had
    /// its first CPU slot yet — design §7's `hasPendingStartTask` case) and
    /// LOOKS UNDECLARED only once it has been silent for the whole window.
    @Test func classifyNeverParkedUnitNeedsAFullQuietWindow() {
        let unit = ModelWorkUnit()
        let now = _drainMonotonicNs()
        #expect(unit.classify(nowNs: now, quietNs: 1_000_000_000) == .midFlight)
        #expect(unit.classify(nowNs: now, quietNs: 0) == .looksUndeclared)
    }

    /// A parked unit is never either: it does not block quiescence and it is
    /// not a fallback reason.
    @Test func classifyParkedUnitIsParked() {
        let unit = ModelWorkUnit()
        let ticket = unit.park()
        #expect(unit.classify(nowNs: _drainMonotonicNs(), quietNs: 0) == .parked)
        ticket.release()
    }

    /// THE ANTI-SWALLOW GUARANTEE. Once a unit has parked even once, SwiftModel
    /// knows where it suspends — so any later window in which it reads *running*
    /// is a resumption, a yield hop or a starved job, i.e. mid-flight. It can
    /// never look undeclared again, no matter how long it stays quiet.
    @Test func classifyUnitThatHasParkedIsNeverUndeclared() {
        let unit = ModelWorkUnit()
        let ticket = unit.park()
        ticket.release()
        #expect(unit.isRunning == true)
        // Quiet window of zero — the most permissive possible — still midFlight.
        #expect(unit.classify(nowNs: _drainMonotonicNs(), quietNs: 0) == .midFlight)
        // And a far-future "now", i.e. arbitrarily long silence.
        #expect(unit.classify(nowNs: _drainMonotonicNs() &+ 60_000_000_000, quietNs: 0) == .midFlight)
    }

    /// The eager unpark is a transition too, so a unit resumed by
    /// `noteResumeInFlight()` (a producer about to yield, a cancellation) is
    /// mid-flight even on the never-parked path — the resume itself is recent
    /// activity.
    @Test func classifyResumeInFlightCountsAsActivity() {
        let unit = ModelWorkUnit()
        unit.noteResumeInFlight()
        #expect(unit.classify(nowNs: _drainMonotonicNs(), quietNs: 1_000_000_000) == .midFlight)
    }

    /// End to end: an unmarked foreign sleep is what the fallback is FOR. The
    /// subtree verdict says work is running, and says every running unit looks
    /// undeclared — which is what lets the combined rule conclude.
    @Test func unmarkedForeignSleepIsTheFallbackShape() async throws {
        let clock = ForeignClock()
        let model = UnmarkedClockSleeper().withAnchor {
            $0.foreignClock = clock
        }
        let context = model.anyContext!

        try await waitUntil(clock.sleeperCount == 1)
        // `quietNs: 0` removes the wall clock from the assertion entirely: the
        // classification is structural (never parked), not a timing race.
        let verdict = context.semanticVerdict(nowNs: _drainMonotonicNs(), quietNs: 0)
        #expect(verdict.isQuiescent == false)
        #expect(verdict.running == 1)
        #expect(verdict.allRunningLookUndeclared == true)
        #expect(verdict.undeclared.first?.modelName == "UnmarkedClockSleeper")

        clock.advance()
        await expect(model.didFinish)
    }

    /// The same sleep with `withModelParked` disappears from the verdict
    /// altogether — the adoption path (design §6b hook 3): no running unit, so
    /// no fallback is needed and the new answer decides on its own.
    @Test func markedForeignSleepNeedsNoFallback() async throws {
        let clock = ForeignClock()
        let model = ParkedClockSleeper().withAnchor {
            $0.foreignClock = clock
        }
        let context = model.anyContext!

        try await waitUntil(clock.sleeperCount == 1)
        let verdict = context.semanticVerdict(nowNs: _drainMonotonicNs(), quietNs: 0)
        #expect(verdict.isQuiescent == true)
        #expect(verdict.allRunningLookUndeclared == false)

        clock.advance()
        await expect(model.didFinish)
    }

    /// A `forEach` body runs in the SAME unit as the loop that parked around
    /// `next()`, so the loop's park history must not be credited to it: the
    /// framework knows where its own `next()` suspends and nothing about where
    /// the user's closure does. Inside the body the quiet window is the whole
    /// discriminator — which means a body that has just started is mid-flight,
    /// and a body that has gone quiet (here, suspended at a gate SwiftModel
    /// cannot see) is honestly reported as undeclared. Without the region mark
    /// this hangs where it returns today; see `_withUserBodyRegion`.
    @Test func forEachBodyIsClassifiedByItsOwnQuietWindowNotTheLoopsPark() async throws {
        let control = QuiescenceControl()
        let model = StreamConsumer().withAnchor {
            $0.quiescenceControl = control
        }
        let context = model.anyContext!

        try await waitUntil(context.hasRunningWorkUnit == false)

        control.yieldValue(7)
        try await waitUntil(control.bodyEntered.value)

        // Just entered the body: recent activity, so still mid-flight.
        let fresh = context.semanticVerdict(nowNs: _drainMonotonicNs(), quietNs: 60_000_000_000)
        #expect(fresh.running == 1)
        #expect(fresh.allRunningLookUndeclared == false)

        // Quiet for a whole window while suspended at a gate we cannot see:
        // the honest answer is "undeclared", and the fallback may conclude.
        let quiet = context.semanticVerdict(nowNs: _drainMonotonicNs() &+ 60_000_000_000, quietNs: 0)
        #expect(quiet.running == 1)
        #expect(quiet.allRunningLookUndeclared == true)

        control.openGate()
        await expect(model.received == 7)
    }

    /// A mixed subtree: one undeclared sleeper beside one mid-flight consumer.
    /// `allRunningLookUndeclared` is an ALL-quantifier, so the mid-flight unit
    /// vetoes the fallback for the whole subtree — the wait keeps waiting.
    ///
    /// The mid-flight unit here is a HAND-WRITTEN `for await` loop: SwiftModel
    /// owns the stream (so the wait parks) but not the loop, so there is no
    /// user-body region and the unit's park history applies to its body too.
    /// That is the design's known residual, and it is what makes it a stable
    /// fixture for "running, has parked, arbitrarily quiet, still mid-flight".
    @Test func oneMidFlightUnitVetoesTheFallbackForTheWholeSubtree() async throws {
        let clock = ForeignClock()
        let control = QuiescenceControl()
        let parent = MixedFallbackParent().withAnchor {
            $0.foreignClock = clock
            $0.quiescenceControl = control
        }
        let context = parent.anyContext!

        try await waitUntil(clock.sleeperCount == 1)
        try await waitUntil(context.runningWorkUnits.count == 1)   // just the sleeper
        #expect(context.semanticVerdict(nowNs: _drainMonotonicNs(), quietNs: 0).allRunningLookUndeclared == true)

        // Wake the child consumer and hold its body: now two units are running,
        // and one of them has parked before.
        parent.consumer.trigger = 1
        try await waitUntil(control.bodyEntered.value)
        let verdict = context.semanticVerdict(nowNs: _drainMonotonicNs() &+ 60_000_000_000, quietNs: 0)
        #expect(verdict.running == 2)
        #expect(verdict.undeclared.count == 1)
        #expect(verdict.allRunningLookUndeclared == false)

        control.openGate()
        clock.advance()
        await expect {
            parent.didFinish
            parent.consumer.received == 1
        }
    }

    /// The region is what separates the two, asserted on a bare unit: the same
    /// already-parked unit is mid-flight in a framework stretch and classified
    /// by its quiet window inside a user-body stretch.
    @Test func theUserBodyRegionIsWhatDropsTheParkHistory() async {
        let unit = ModelWorkUnit()
        unit.park().release()
        #expect(unit.classify(nowNs: _drainMonotonicNs() &+ 60_000_000_000, quietNs: 0) == .midFlight)

        await ModelWorkUnit.$current.withValue(unit) {
            await _withUserBodyRegion {
                #expect(unit.classify(nowNs: _drainMonotonicNs() &+ 60_000_000_000, quietNs: 0) == .looksUndeclared)
                // …but still mid-flight while the region is fresh.
                #expect(unit.classify(nowNs: _drainMonotonicNs(), quietNs: 60_000_000_000) == .midFlight)
            }
        }
        // Back in framework code, the park history applies again.
        #expect(unit.classify(nowNs: _drainMonotonicNs() &+ 60_000_000_000, quietNs: 0) == .midFlight)
    }
}

/// Parent holding both fallback shapes at once — see
/// `oneMidFlightUnitVetoesTheFallbackForTheWholeSubtree`.
@Model private struct MixedFallbackParent {
    var didFinish = false
    var consumer = ObservedLoopConsumer()

    func onActivate() {
        node.task {
            await node.foreignClock.sleep()      // undeclared: never parks
            didFinish = true
        }
    }
}

// MARK: - Tier 1: source-side parking (design §5)
//
// The park mark belongs to the INPUT SOURCE, not to `node.forEach`'s loop,
// because a user can write the loop by hand. Every model below iterates a
// SwiftModel-produced stream with a raw `for await` inside a plain `node.task`
// — no `forEach` anywhere — and must behave exactly like the `forEach` case
// above: parked while waiting for the next element, running while the body
// runs.

private struct QuiescenceTestError: Error, Equatable {}

/// Hand-written `for await` over `Observed` — by far the most common shape in
/// the suite, and the one that produced 23 of the 33 decisive disagreements in
/// the first dual-run inventory.
@Model private struct ObservedLoopConsumer {
    var trigger = 0
    var received = 0

    func onActivate() {
        node.task {
            for await value in Observed(initial: false, removeDuplicates: false, { trigger }) {
                node.quiescenceControl.bodyEntered.setValue(true)
                await node.quiescenceControl.waitAtGate()
                received = value
            }
        }
    }
}

/// Hand-written `for await` over an event stream.
@Model private struct EventLoopConsumer {
    enum Event: Equatable, Sendable { case ping }

    var received = 0

    func onActivate() {
        node.task {
            for await _ in node.event(of: Event.ping) {
                node.quiescenceControl.bodyEntered.setValue(true)
                await node.quiescenceControl.waitAtGate()
                received += 1
            }
        }
    }

    func ping() { node.send(.ping) }
}

/// Hand-written `for await` over `observeModifications()`. The body writes only
/// out-of-band state — a model write here would re-trigger the stream and spin.
@Model private struct ModificationLoopConsumer {
    var trigger = 0

    func onActivate() {
        node.task {
            let control = node.quiescenceControl
            for await _ in observeModifications() {
                control.bodyEntered.setValue(true)
                await control.waitAtGate()
                control.stop.setValue(true)
            }
        }
    }
}

/// `node.task(catch:)` whose `catch` handler writes model state — the epilogue
/// window (a task still executing after its work unit was unregistered).
@Model private struct ThrowingCatcher {
    var caught = ""
    /// What the registry said about this very task *while its `catch` handler
    /// was running*. Must be `true`: the unit has to outlive the epilogue.
    var registryStillSawRunningWork: Bool? = nil

    func onActivate() {
        node.task {
            throw QuiescenceTestError()
        } catch: { _ in
            registryStillSawRunningWork = anyContext?.hasRunningWorkUnit
            caught = "caught"
        }
    }
}

@Suite(.modelTesting(exhaustivity: .off))
struct SemanticQuiescenceTier1Tests {
    /// A raw `for await` over `Observed` parks while waiting, exactly as
    /// `node.forEach` does — no adoption, no `forEach`.
    @Test func handWrittenObservedLoopParksWhileWaiting() async throws {
        let control = QuiescenceControl()
        let model = ObservedLoopConsumer().withAnchor {
            $0.quiescenceControl = control
        }
        let context = model.anyContext!

        // The task is registered and has not returned …
        try await waitUntil(context.activeTasks.flatMap(\.tasks).count == 1)
        // … but with nothing to deliver it is PARKED, so the model is
        // semantically quiescent.
        try await waitUntil(context.hasRunningWorkUnit == false)
        #expect(context.semanticQuiescence == true)

        // A write produces a value; the body is held at the gate, so the unit is
        // unambiguously running while it is being delivered.
        model.trigger = 7
        try await waitUntil(control.bodyEntered.value)
        #expect(context.hasRunningWorkUnit == true)

        control.openGate()
        await expect(model.received == 7)
        // Parked again once the body returns to the wait.
        try await waitUntil(model.anyContext?.hasRunningWorkUnit == false)
    }

    /// The same for a hand-written loop over `node.event(of:)`.
    @Test func handWrittenEventLoopParksWhileWaiting() async throws {
        let control = QuiescenceControl()
        let model = EventLoopConsumer().withAnchor {
            $0.quiescenceControl = control
        }
        let context = model.anyContext!

        try await waitUntil(context.activeTasks.flatMap(\.tasks).count == 1)
        try await waitUntil(context.hasRunningWorkUnit == false)
        #expect(context.semanticQuiescence == true)

        model.ping()
        try await waitUntil(control.bodyEntered.value)
        #expect(context.hasRunningWorkUnit == true)

        control.openGate()
        await expect(model.received == 1)
        try await waitUntil(model.anyContext?.hasRunningWorkUnit == false)
    }

    /// And for `observeModifications()`.
    @Test func handWrittenObserveModificationsLoopParksWhileWaiting() async throws {
        let control = QuiescenceControl()
        let model = ModificationLoopConsumer().withAnchor {
            $0.quiescenceControl = control
        }
        let context = model.anyContext!

        try await waitUntil(context.activeTasks.flatMap(\.tasks).count == 1)
        try await waitUntil(context.hasRunningWorkUnit == false)

        model.trigger = 1
        try await waitUntil(control.bodyEntered.value)
        #expect(context.hasRunningWorkUnit == true)

        control.openGate()
        try await waitUntil(control.stop.value)
        try await waitUntil(model.anyContext?.hasRunningWorkUnit == false)
    }

    /// The epilogue window: a `catch` handler is user code that writes model
    /// state, and it runs AFTER the body threw. The work unit must still be
    /// registered and running at that point — otherwise the registry reads
    /// "quiescent" with a model write still to come, and a wait could pass
    /// prematurely.
    @Test func catchHandlerRunsBeforeTheWorkUnitIsUnregistered() async throws {
        let model = ThrowingCatcher().withAnchor()

        await expect(model.caught == "caught")
        #expect(model.registryStillSawRunningWork == true)
        // …and the unit is gone once the epilogue is over.
        try await waitUntil(model.anyContext?.hasRunningWorkUnit == false)
    }
}


/// A cancelled task keeps running through its `defer` — and that `defer` writes
/// model state. This is the *other* epilogue window, and by far the common one:
/// `Cancellations` drops a task from its cancellation registry BEFORE the body
/// unwinds (`cancelAll()` empties the dictionary and only then calls
/// `onCancel()`), so an answer read off `registered` goes "quiescent" during
/// every teardown / `task(id:)` replacement / `cancelPrevious` swap.
@Model private struct CancelledDeferWriter {
    var marker = "live"

    func onActivate() {
        node.task {
            let control = node.quiescenceControl
            defer {
                // Observed from the unwind of a *cancelled* body, which is
                // exactly where the registry used to say "nothing running".
                control.stop.setValue(anyContext?.hasRunningWorkUnit == true)
                marker = "cleared"
            }
            control.bodyEntered.setValue(true)
            await control.waitAtGate()
        }
    }

}

@Suite(.modelTesting(exhaustivity: .off))
struct SemanticQuiescenceCancellationEpilogueTests {
    /// The work unit must still be visible — and running — while a cancelled
    /// body runs its `defer`, because that `defer` can write to the model.
    @Test func cancelledBodyStillOwnsItsWorkUnitWhileUnwinding() async throws {
        let control = QuiescenceControl()
        let model = CancelledDeferWriter().withAnchor {
            $0.quiescenceControl = control
        }
        let context = model.anyContext!

        // Wait for the body to be INSIDE its `defer`'s scope: a task cancelled
        // before its first slot returns at the pre-body `guard !Task.isCancelled`
        // without ever entering the user closure, and then there is no epilogue
        // to test.
        try await waitUntil(control.bodyEntered.value)
        // (The gate is a raw continuation — tier 3, unmarked — so the body reads
        // as running while it waits. That is not what this test is about.)

        // Tear the anchor's tasks down, then release the body so it unwinds
        // through its `defer`.
        context.cancellations.cancelAll()
        control.openGate()

        try await waitUntil(model.marker == "cleared")
        #expect(control.stop.value == true)
        // …and the unit retires once the body has genuinely finished.
        try await waitUntil(model.anyContext?.hasRunningWorkUnit == false)
    }
}

// MARK: - Eager unpark: the park→resume-in-flight window
//
// A lazy unpark — the resumed task's own `defer` — leaves the unit reading
// PARKED from the moment its continuation is resumed until the cooperative pool
// gives it a slot. Model-writing work is inbound throughout that window, so a
// wait that consulted the semantic answer there would pass early. It was the
// single largest surviving disagreement in the dual-run inventory, and design
// §5's containment argument does not cover the half of it that matters: an
// `AsyncStream` consumer resumed by CANCELLATION emits no activity signal, and
// the body it resumes goes on to run model-writing `defer`s.
//
// The fix is for the RESUMER to unpark, before it resumes
// (`ModelWorkUnit.noteResumeInFlight()`), with the resumed side's `defer`
// becoming a no-op via the park epoch. The tests below assert both halves
// synchronously — every `#expect` after a `send` / `cancelAll` runs on the
// producing thread, before the resumed task can possibly have had a slot.

/// Parks in a SwiftModel-owned event stream, and writes model state from the
/// `defer` that cancellation unwinds through: the exact shape the eager unpark
/// exists for.
@Model private struct ParkedEventWaiter {
    enum Event: Equatable, Sendable { case matching, other }

    var marker = "live"
    var received = 0

    func onActivate() {
        node.task {
            let control = node.quiescenceControl
            defer {
                // A cancelled body writes model state on its way out. If the
                // unit read parked while this was still to come, a wait could
                // conclude before it ran.
                marker = "cleared"
            }
            control.bodyEntered.setValue(true)
            for await _ in node.event(of: Event.matching) {
                received += 1
            }
        }
    }

    func sendMatching() { node.send(.matching) }
    func sendOther() { node.send(.other) }
}

@Suite(.modelTesting(exhaustivity: .off))
struct SemanticQuiescenceEagerUnparkTests {
    /// A yield unparks the consumer **at the yield**, not at the resumed task's
    /// next slot. `node.send` is synchronous, so the assertion below runs on the
    /// sending thread with the consumer's resume still in flight.
    @Test func yieldUnparksTheConsumerBeforeItIsResumed() async throws {
        let control = QuiescenceControl()
        let model = ParkedEventWaiter().withAnchor {
            $0.quiescenceControl = control
        }
        let context = model.anyContext!

        try await waitUntil(control.bodyEntered.value)
        try await waitUntil(context.hasRunningWorkUnit == false)

        model.sendMatching()
        #expect(context.hasRunningWorkUnit == true)

        await expect(model.received == 1)
        try await waitUntil(model.anyContext?.hasRunningWorkUnit == false)
    }

    /// The half with no activity signal behind it: cancelling a consumer parked
    /// in `next()` resumes it with `nil` through `AsyncStream`'s `onTermination`
    /// — which the stdlib invokes *before* the resume — and the body then runs a
    /// model-writing `defer`. The unit must read running from the instant
    /// `cancelAll()` returns.
    @Test func cancellationUnparksTheConsumerBeforeItIsResumed() async throws {
        let control = QuiescenceControl()
        let model = ParkedEventWaiter().withAnchor {
            $0.quiescenceControl = control
        }
        let context = model.anyContext!

        try await waitUntil(control.bodyEntered.value)
        try await waitUntil(context.hasRunningWorkUnit == false)

        context.cancellations.cancelAll()
        #expect(context.hasRunningWorkUnit == true)

        try await waitUntil(model.marker == "cleared")
        try await waitUntil(model.anyContext?.hasRunningWorkUnit == false)
    }

    /// The reason the park mark sits on the RAW source rather than on the
    /// filtered stream `node.event(of:)` hands back. A non-matching event
    /// resumes the consumer just the same — so it unparks eagerly — and the
    /// consumer then drops it and goes back to waiting. With the mark wrapped
    /// around the filter, that second wait would be inside the *same* open park
    /// scope, and the unit would read running until the next matching event.
    @Test func anEventThatFailsTheFilterUnparksAndThenReParks() async throws {
        let control = QuiescenceControl()
        let model = ParkedEventWaiter().withAnchor {
            $0.quiescenceControl = control
        }
        let context = model.anyContext!

        try await waitUntil(control.bodyEntered.value)
        try await waitUntil(context.hasRunningWorkUnit == false)

        model.sendOther()
        #expect(context.hasRunningWorkUnit == true)
        // …and back to parked, without ever running the body.
        try await waitUntil(context.hasRunningWorkUnit == false)
        #expect(model.received == 0)

        // Still live afterwards.
        model.sendMatching()
        await expect(model.received == 1)
    }

    /// The generic half, for a source SwiftModel does NOT own: `node.forEach`
    /// over a foreign `AsyncStream` parks through hook 1, and its *delivery* is
    /// not ours to mark — but its **cancellation** is, because SwiftModel is the
    /// one cancelling the task. `_withCurrentWorkUnitParked`'s cancellation
    /// handler runs synchronously inside `Task.cancel()`, before the parked task
    /// is resumed into its `defer`s.
    @Test func cancellingAForeignSequenceConsumerUnparksEagerly() async throws {
        let control = QuiescenceControl()
        let model = StreamConsumer().withAnchor {
            $0.quiescenceControl = control
        }
        let context = model.anyContext!

        try await waitUntil(context.activeTasks.flatMap(\.tasks).count == 1)
        try await waitUntil(context.hasRunningWorkUnit == false)

        context.cancellations.cancelAll()
        #expect(context.hasRunningWorkUnit == true)

        try await waitUntil(model.anyContext?.hasRunningWorkUnit == false)
    }

    /// A stale ticket releases nothing, so an eagerly-unparked unit is not
    /// re-parked by the `defer`s unwinding behind it — however many park scopes
    /// were open — and a fresh park still works afterwards.
    @Test func aTicketStaleAfterAnEagerUnparkReleasesNothing() {
        let unit = ModelWorkUnit()
        let outer = unit.park()
        let inner = unit.park()
        #expect(unit.isRunning == false)

        unit.noteResumeInFlight()
        #expect(unit.isRunning == true)

        inner.release()
        outer.release()
        #expect(unit.isRunning == true)

        let next = unit.park()
        #expect(unit.isRunning == false)
        next.release()
        #expect(unit.isRunning == true)
    }

    /// `_ParkSource`, directly: park, eager unpark on yield, no-op release,
    /// re-park once the delivery has been taken out.
    @Test func parkSourceUnparksOnYieldAndReParksAfterDelivery() {
        let source = _ParkSource()
        let unit = ModelWorkUnit()
        ModelWorkUnit.$current.withValue(unit) {
            let ticket = source.beginWait()
            #expect(ticket != nil)
            #expect(unit.isRunning == false)

            source.willYield()
            #expect(unit.isRunning == true)

            ticket?.release()
            #expect(unit.isRunning == true)
            source.endWait(delivered: true)

            let next = source.beginWait()
            #expect(next != nil)
            #expect(unit.isRunning == false)
            next?.release()
        }
    }

    /// A value yielded while the consumer was *running* sits in the stream's
    /// buffer, so the next wait must not park — and refusing to park is not
    /// enough on its own, because `node.forEach` wraps its own park around the
    /// whole call. `beginWait` therefore breaks out of the enclosing scope too.
    @Test func parkSourceRefusesToParkUnderAnEnclosingScopeWhenAValueIsBuffered() {
        let source = _ParkSource()
        let unit = ModelWorkUnit()
        ModelWorkUnit.$current.withValue(unit) {
            source.willYield()

            let outer = unit.park()          // `node.forEach`'s hook-1 park
            #expect(unit.isRunning == false)

            let inner = source.beginWait()
            #expect(inner == nil)
            #expect(unit.isRunning == true)

            outer.release()                  // stale
            #expect(unit.isRunning == true)
        }
    }

    /// Termination is a resume too: `finish()` and a cancelled consumer both
    /// wake `next()` with `nil`, and the body unwinds from there.
    @Test func parkSourceUnparksOnTermination() {
        let source = _ParkSource()
        let unit = ModelWorkUnit()
        ModelWorkUnit.$current.withValue(unit) {
            let ticket = source.beginWait()
            #expect(unit.isRunning == false)

            source.willTerminate()
            #expect(unit.isRunning == true)

            ticket?.release()
            #expect(unit.isRunning == true)
        }
    }
}
