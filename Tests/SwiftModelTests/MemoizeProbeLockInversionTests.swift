import Testing
import Foundation
@testable import SwiftModel
import SwiftModel

// WASI is single-threaded, so the two-thread race this reproduces cannot occur there.
#if !os(WASI)

/// Reproduction for the AB-BA deadlock between `TestAccess.lock` (A) and a context's
/// hierarchy lock (B) when a *probe* access is installed as `ModelAccess.active`.
///
/// Every write path takes A before B, resolving the holder from
/// `ModelAccess.active ?? … ?? ModelAccess.current`. Several `ModelAccess` subclasses are
/// not writers at all but short-lived probes installed with `usingActiveAccess` to observe
/// reads — `RegistrarDetector` (run by *every* `Observed` with `coalesceUpdates: true`, the
/// default), `AccessCollector`, `ForceObserver`. Their `acquireWriteLock()` is the base
/// no-op, so a `memoize` first-access evaluated under one resolved the holder to the probe,
/// took **no** A, and then took B. `memoize`'s `observe` clears `active` around `produce()`
/// (so nested memoizes don't inherit the probe), so a *nested* memoize inside `produce()`
/// resolved the holder to `ModelAccess.current` — the real `TestAccess` — and asked for A
/// while B was held. B→A against any concurrent writer's A→B is the deadlock.
///
/// Sampled live from a wedged `ParallelEditorTests` xctest on 2026-09-22 (swift-model
/// 1.0.20): one thread inside `Observed.init`'s detector probe → `memoize` → `context.lock`
/// → nested `memoize` → `TestAccess.acquireWriteLock` (blocked), against another thread in
/// `Context.beginDirectWrite` holding A and blocked on B.
@Model private struct Leaf: Sendable {
    var seed = 0

    /// First access sets up tracking — this is the memoize that ends up nested inside the
    /// outer one's `produce()`.
    var derived: Int {
        node.memoize { seed &* 2 }
    }
}

@Model private struct Root: Sendable {
    var leaf = Leaf()
    /// Plain property for the racing writer's `beginDirectWrite` (A→B).
    var bump = 0

    /// Outer memoize whose `produce()` reaches a *second*, not-yet-established memoize.
    var combined: Int {
        node.memoize { leaf.derived &+ 1 }
    }
}

private final class Flag: @unchecked Sendable {
    private let l = NSLock(); private var v = false
    var value: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
}

private final class Counter: @unchecked Sendable {
    private let l = NSLock(); private var v = 0
    var value: Int { l.lock(); defer { l.unlock() }; return v }
    func increment() { l.lock(); v += 1; l.unlock() }
}

struct MemoizeProbeLockInversionTests {
    /// Thread 1 builds an `Observed` over the outer memoize — its `RegistrarDetector` probe
    /// evaluates the access closure, establishing both memoizes. Thread 2 writes a plain
    /// property on the same context (A→B). Before the fix the two orders cross and both
    /// park forever; after it, thread 1 resolves the holder past the probe to the same
    /// `TestAccess` and takes A→B like everyone else.
    ///
    /// Verdict is a *stall* detector, not a wall-clock budget — see
    /// `DependencyLockInversionTests` for the rationale.
    @Test func memoizeUnderProbeAccessDoesNotInvertWriteLockOrder() async {
        let iterations = 200
        let done = Flag()
        let stop = Flag()
        let progress = Counter()

        let worker = Thread {
            for _ in 0..<iterations {
                if stop.value { break }

                let tester = ModelTester(Root())
                let model = tester.model
                // The access the model's own tasks would carry (`TaskCancellable`'s prelude
                // sets `ModelAccess.current`); the racing writer reaches the same instance
                // through the reference stamp, so only this side needs the task-local.
                let access = model.modelContext.access

                let ready = DispatchSemaphore(value: 0)
                let go = DispatchSemaphore(value: 0)
                let finished = DispatchSemaphore(value: 0)

                Thread {
                    ready.signal(); go.wait()
                    usingAccess(access) {
                        _ = Observed { model.combined }
                    }
                    finished.signal()
                }.start()

                Thread {
                    ready.signal(); go.wait()
                    model.bump &+= 1
                    finished.signal()
                }.start()

                ready.wait(); ready.wait()
                go.signal(); go.signal()
                finished.wait(); finished.wait()
                progress.increment()
                withExtendedLifetime(tester) {}
            }
            done.value = true
        }
        worker.start()

        let scale = ProcessInfo.processInfo.environment["SWIFT_MODEL_TIMEOUT_SCALE"].flatMap(Double.init) ?? 1
        let stallBudget = 10.0 * scale
        let ceiling = Date().addingTimeInterval(120 * scale)

        var lastProgress = progress.value
        var lastProgressAt = Date()
        var stalled = false
        while !done.value && Date() < ceiling {
            try? await Task.sleep(nanoseconds: 20_000_000)
            let current = progress.value
            if current != lastProgress {
                lastProgress = current
                lastProgressAt = Date()
            } else if Date().timeIntervalSince(lastProgressAt) > stallBudget {
                stalled = true
                break
            }
        }
        stop.value = true

        #expect(
            !stalled,
            """
            memoize-under-probe made no progress for \(stallBudget)s after \
            \(lastProgress)/\(iterations) iterations — the write lock and the hierarchy \
            lock are being taken in opposite orders again
            """
        )
        while !done.value && !stalled && Date() < ceiling.addingTimeInterval(5 * scale) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

#endif
