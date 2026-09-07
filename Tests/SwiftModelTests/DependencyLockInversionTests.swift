import Testing
import Foundation
@testable import SwiftModel
import SwiftModel
import Dependencies

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

struct DependencyLockInversionTests {
    /// KNOWN ISSUE — this deadlocks on `main` today. It is the reproduction for the
    /// production bug diagnosed on 2026-09-07 from a live `sample` of a wedged CI run.
    /// Wrapped in `withKnownIssue` so it documents the bug without reddening CI; delete the
    /// wrapper when the fix lands. Bounded at 30 s so a regression reports instead of hanging.
    ///
    /// A first fix attempt — dropping the hierarchy lock from `AnyContext.dependency(for:)`
    /// and making the dependency-cache install first-wins — DOES make this pass (0.15 s
    /// instead of a 30 s deadlock) but crashes the full parallel suite deterministically
    /// (3/3 runs) inside Swift-runtime generic-metadata instantiation, reached from a
    /// generic `ModelAccess.willAccess` override in `ObservedModelDebugIsolationTests`. So
    /// that lock is doing more than guarding the check-then-act, and the real fix has to
    /// narrow what runs unlocked rather than remove the lock wholesale.
    @Test func concurrentDependencyResolutionAcrossTreesDoesNotDeadlock() async {
        let iterations = 200
        let done = Flag()
        let progressed = Flag()

        await withKnownIssue("AB-BA between two contexts' hierarchy locks — see the doc comment") {
        let worker = Thread {
            for _ in 0..<iterations {
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
                progressed.value = true
                withExtendedLifetime((anchorOne, anchorTwo)) {}
            }
            done.value = true
        }
        worker.start()

        let deadline = Date().addingTimeInterval(30)
        while !done.value && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(done.value, "concurrent cross-tree dependency resolution deadlocked (progressed at least once: \(progressed.value))")
        }
    }
}
