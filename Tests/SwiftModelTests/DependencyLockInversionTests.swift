import Testing
import Foundation
@testable import SwiftModel
import SwiftModel
import Dependencies

// WASI is single-threaded and has neither `Thread` nor `DispatchSemaphore`, so the race
// this reproduces cannot occur there and the test cannot be expressed.
#if !os(WASI)

/// Reproduction for the AB-BA deadlock between two contexts' hierarchy locks.
///
/// `AnyContext.dependency(for:)` holds ITS OWN hierarchy lock while resolving a model
/// dependency, and that resolution copies the dependency model — `initialDependencyCopy`
/// → `shallowCopy` → `Reference.lifetime` / `makeFrozen` → **another context's** hierarchy
/// lock. Two threads resolving dependencies that reach into each other's trees acquire the
/// two locks in opposite order and deadlock; a live `sample` of a wedged CI run on
/// 2026-09-07 showed exactly that, with the drive executor queued behind one of them, which
/// is what turns it into a whole-process hang.
///
/// Each iteration anchors two independent trees and resolves a model dependency on both
/// concurrently. The work runs on detached threads with a wall-clock bound so a regression
/// reports instead of hanging the suite.
@Model private struct DepA: Sendable {
    var value = 1
}
extension DepA: DependencyKey {
    static let liveValue = DepA(value: 1)
    static let testValue = DepA(value: 1)
}

@Model private struct DepB: Sendable {
    var value = 2
}
extension DepB: DependencyKey {
    static let liveValue = DepB(value: 2)
    static let testValue = DepB(value: 2)
}

@Model private struct LeafOne: Sendable {
    @ModelDependency var a: DepA
    @ModelDependency var b: DepB
    var touched = 0
    func touch() { touched = a.value &+ b.value }
}

@Model private struct LeafTwo: Sendable {
    @ModelDependency var b: DepB
    @ModelDependency var a: DepA
    var touched = 0
    func touch() { touched = b.value &+ a.value }
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

struct DependencyLockInversionTests {
    /// Regression test for the AB-BA fixed by giving `modeLifeTime` its own leaf lock and
    /// by resolving genesis state before `shallowCopy` in `MakeInitialDependencyCopyTransformer`
    /// — the two places where `dependency(for:)` reached a *foreign* hierarchy lock while
    /// holding its own. Deadlocked on the very first iteration before the fix (zero
    /// iterations completed); completes 200 iterations in ~0.2 s after it.
    ///
    /// The verdict is a *stall* detector rather than a total-runtime budget — see the
    /// comment in the body — so a regression reports instead of hanging the suite, without
    /// the pass/fail line depending on how loaded the machine is.
    ///
    /// Note for future fixers: removing the `lock { }` from `dependency(for:)` altogether
    /// (with a first-wins dependency-cache install) also makes this pass, but crashes the
    /// full parallel suite deterministically inside Swift-runtime generic-metadata
    /// instantiation. That lock does more than guard the cache check-then-act; the fix has
    /// to remove the foreign-lock edges from under it, not remove the lock.
    @Test func concurrentDependencyResolutionAcrossTreesDoesNotDeadlock() async {
        let iterations = 200
        let done = Flag()
        let stop = Flag()
        let progress = Counter()

        let worker = Thread {
            for _ in 0..<iterations {
                if stop.value { break }
                let (one, anchorOne) = LeafOne().returningAnchor()
                let (two, anchorTwo) = LeafTwo().returningAnchor()
                let ready = DispatchSemaphore(value: 0)
                let go = DispatchSemaphore(value: 0)
                let finished = DispatchSemaphore(value: 0)
                for model in [{ one.touch() }, { two.touch() }] as [@Sendable () -> Void] {
                    Thread {
                        ready.signal(); go.wait()
                        model()
                        finished.signal()
                    }.start()
                }
                ready.wait(); ready.wait()
                go.signal(); go.signal()
                finished.wait(); finished.wait()
                progress.increment()
                withExtendedLifetime((anchorOne, anchorTwo)) {}
            }
            done.value = true
        }
        worker.start()

        // Evidence-based verdict, not a wall-clock budget: an AB-BA parks both resolver
        // threads forever, so the iteration counter stops moving and never restarts. A
        // merely slow run (TSan is 5-15x, and this suite runs in parallel with 860+ other
        // tests) keeps incrementing it. So we fail only on a *stall* — no forward progress
        // for `stallBudget` — and treat "still progressing when the overall ceiling is
        // reached" as a pass, since sustained forward progress is exactly what the test
        // asserts. Both bounds honour SWIFT_MODEL_TIMEOUT_SCALE like the rest of the suite.
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
            concurrent cross-tree dependency resolution made no progress for \(stallBudget)s \
            after \(lastProgress)/\(iterations) iterations — the two hierarchy locks are \
            deadlocked again
            """
        )
        // Let the worker unwind before the test returns so its threads do not outlive it.
        while !done.value && !stalled && Date() < ceiling.addingTimeInterval(5 * scale) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}


#endif