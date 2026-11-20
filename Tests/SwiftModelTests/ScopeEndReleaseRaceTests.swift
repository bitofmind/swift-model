#if canImport(Dispatch)
import Testing
@testable import SwiftModel
import Foundation
import ConcurrencyExtras

// Regression test for a use-after-free in reads of a removed model whose Context has
// already deinitialised. Under a test scope, a removed model's last-seen state is
// released at the scope's end (`TestAccess.releaseLastSeen`). By then the removed
// model's Context is usually gone, so `Reference._hierarchyLock` is nil, and
// `withHierarchyLockIfLive` used to run the read with NO lock — while the release
// swapped `state` for genesis under the old hierarchy lock and `Reference.lock`.
// A read that loaded a field and then retained it could retain a freed object.
//
// Reported stack (parallel-apple editor tests, SIGBUS):
//   swift_retain ← initializeWithCopy (<Model>._State) ← _ModelSourceBox._directRead
//
// Neither TSan nor ASan sees this race (the load and the retain are in libswiftCore),
// so the test relies on many iterations of the real interleaving. The window is a few
// instructions wide: unfixed, 4 000 iterations crashed (SIGSEGV in the reader) in 2 of 6
// runs, and every one of those releases ran with the Context already gone. 100 iterations
// keeps the suite fast; raise the count locally to reproduce.
struct ScopeEndReleaseRaceTests {
    @Test func readOfRemovedModelDoesNotRaceItsScopeEndRelease() async {
        for _ in 0..<100 {
            let stop = LockIsolated(false)
            let done = DispatchGroup()

            await withModelTesting(exhaustivity: .off) {
                let parent = ScopeEndRaceParent().withAnchor()
                parent.child = ScopeEndRaceChild()
                // Differ from the anchor-time genesis, so the release frees this payload.
                parent.child?.payload = ScopeEndRacePayload()
                guard let removed = parent.child else { return }
                parent.child = nil

                // Keep reading the removed model through the scope's teardown, where
                // its deferred last-seen release runs. Plain threads, so the readers are
                // invisible to the harness and don't keep the scope from going quiet.
                for _ in 0..<4 {
                    done.enter()
                    Thread.detachNewThread {
                        while !stop.value {
                            _ = removed.payload.values.count
                        }
                        done.leave()
                    }
                }
            }
            stop.setValue(true)
            await withCheckedContinuation { continuation in
                done.notify(queue: .global()) { continuation.resume() }
            }
        }
    }
}

final class ScopeEndRacePayload: Sendable {
    let values: [Int] = Array(repeating: 1, count: 8)
}

@Model private struct ScopeEndRaceParent {
    var child: ScopeEndRaceChild? = nil
}

@Model private struct ScopeEndRaceChild {
    var payload = ScopeEndRacePayload()
}

#endif
