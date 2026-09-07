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
}
