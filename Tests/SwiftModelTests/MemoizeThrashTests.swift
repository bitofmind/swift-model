import Foundation
import Testing
import ConcurrencyExtras
@testable import SwiftModel

/// Regression tests for memoize produce-per-access thrash (the parallel-apple
/// editor's "produce count 151 for a 200-access sweep" report).
///
/// Two mechanisms are covered:
///
/// 1. **Permanent dirty flag**: on the coalesced paths, the `performUpdate`
///    `onUpdate` used to *preserve* `isDirty` when storing a recomputed value
///    (it couldn't distinguish "the mutation this recompute already
///    incorporates" from "a concurrent mutation during produce"). One
///    value-changing dependency write then left the cache dirty forever, and
///    every later access ran `produce()` inline — produce-per-access on a
///    perfectly idle machine.
///
/// 2. **Starved revalidation**: while the async `performUpdate` has not yet
///    run (saturated cooperative pool), every access used to find the cache
///    dirty, produce inline, and *throw the result away* — so N accesses in
///    the starvation window cost N produces. The dirty access must instead
///    write its fresh value back so subsequent accesses hit the cache.
///
/// Starvation is injected deterministically: each test routes the memoize's
/// revalidation through its own `BackgroundCallQueue` (the same task-local
/// override `.modelTesting` uses) and blocks that queue's drain on a gate —
/// no reliance on machine load.
///
/// Deliberately *not* `.modelTesting`: these tests manage their own queue and
/// assert raw produce counters, with `waitUntil` polling off the cooperative
/// pool.
struct MemoizeThrashTests {

    // MARK: - Idle pool: produce count must settle after a dependency write

    @Test(arguments: UpdatePath.allCases)
    func produceCountSettlesAfterDependencyWrite(updatePath: UpdatePath) async throws {
        let queue = BackgroundCallQueue()
        let model = _BackgroundCallLocals.$queue.withValue(queue) {
            let model = updatePath.withOptions { SingleMemoizeModel().withAnchor() }
            #expect(model.layout.count == 120)  // first access produces once, inside the queue scope
            return model
        }
        #expect(model.produceCount.value == 1)

        model.dep += 1  // value-changing dependency write
        await queue.waitUntilIdle()  // revalidation (performUpdate) has fully run

        let settled = model.produceCount.value
        #expect(settled <= 3, "revalidation should cost O(1) produces, got \(settled)")
        #expect(model.layout.first == 1)

        // The handover scenario: a 200-access sweep over the (now clean) cache.
        for _ in 0..<200 {
            #expect(model.layout.count == 120)
        }
        let growth = model.produceCount.value - settled
        #expect(growth == 0, "memoize stayed dirty after revalidation: produce ran \(growth) extra times during a 200-access sweep")
    }

    @Test(arguments: UpdatePath.allCases)
    func chainedProduceCountSettlesAfterDependencyWrite(updatePath: UpdatePath) async throws {
        let queue = BackgroundCallQueue()
        let model = _BackgroundCallLocals.$queue.withValue(queue) {
            let model = updatePath.withOptions { ChainedMemoizeModel().withAnchor() }
            #expect(model.snapIndex == 120)  // produces snapIndex AND layout once each
            return model
        }
        #expect(model.layoutCount.value == 1)
        #expect(model.indexCount.value == 1)

        model.dep += 1
        await queue.waitUntilIdle()

        let settledLayout = model.layoutCount.value
        let settledIndex = model.indexCount.value
        #expect(settledLayout <= 4, "chained revalidation should cost O(chain) produces, got layout=\(settledLayout)")
        #expect(settledIndex <= 4, "chained revalidation should cost O(chain) produces, got index=\(settledIndex)")
        #expect(model.snapIndex == 121)

        for _ in 0..<200 {
            #expect(model.snapIndex == 121)
        }
        let layoutGrowth = model.layoutCount.value - settledLayout
        let indexGrowth = model.indexCount.value - settledIndex
        #expect(layoutGrowth == 0, "chained layout memoize stayed dirty: \(layoutGrowth) extra produces during sweep")
        #expect(indexGrowth == 0, "chained index memoize stayed dirty: \(indexGrowth) extra produces during sweep")
    }

    // MARK: - Starved revalidation: dirty access must not degrade to produce-per-access

    @Test(arguments: UpdatePath.allCases)
    func starvedRevalidationDoesNotProducePerAccess(updatePath: UpdatePath) async throws {
        let queue = BackgroundCallQueue()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }  // never leave the drain blocked, even on test failure

        let model = _BackgroundCallLocals.$queue.withValue(queue) {
            let model = updatePath.withOptions { SingleMemoizeModel().withAnchor() }
            #expect(model.layout.count == 120)
            return model
        }
        #expect(model.produceCount.value == 1)

        // Stall the revalidation queue: the drain blocks here, so any
        // performUpdate scheduled below queues behind it and cannot run —
        // deterministic equivalent of a saturated cooperative pool.
        queue { _ = gate.wait(timeout: .now() + 60) }

        model.dep += 1  // marks the memoize dirty; revalidation is stuck behind the gate

        // 200-access sweep entirely within the starvation window.
        for _ in 0..<200 {
            #expect(model.layout.first == 1, "dirty access must still return fresh values")
        }
        let duringStarvation = model.produceCount.value - 1
        #expect(duringStarvation <= 2, "starved revalidation degraded to produce-per-access: \(duringStarvation) produces for a 200-access sweep")

        gate.signal()
        await queue.waitUntilIdle()
        #expect(model.layout.first == 1)
    }

    @Test(arguments: UpdatePath.allCases)
    func starvedChainedRevalidationDoesNotProducePerAccess(updatePath: UpdatePath) async throws {
        let queue = BackgroundCallQueue()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }

        let model = _BackgroundCallLocals.$queue.withValue(queue) {
            let model = updatePath.withOptions { ChainedMemoizeModel().withAnchor() }
            #expect(model.snapIndex == 120)
            return model
        }

        queue { _ = gate.wait(timeout: .now() + 60) }

        model.dep += 1

        for _ in 0..<200 {
            #expect(model.snapIndex == 121, "dirty chained access must still return fresh values")
        }
        // A chained dirty access may produce once per chain hop (the inner
        // memoize's write-back re-dirties the outer one once), but must not
        // scale with access count.
        let layoutProduces = model.layoutCount.value - 1
        let indexProduces = model.indexCount.value - 1
        #expect(layoutProduces <= 3, "starved chained layout memoize: \(layoutProduces) produces for a 200-access sweep")
        #expect(indexProduces <= 3, "starved chained index memoize: \(indexProduces) produces for a 200-access sweep")

        gate.signal()
        await queue.waitUntilIdle()
        #expect(model.snapIndex == 121)
    }

    // MARK: - Untracked access

    @Test(arguments: UpdatePath.allCases)
    func untrackedAccessUsesCachedFastPath(updatePath: UpdatePath) async throws {
        let queue = BackgroundCallQueue()
        let model = _BackgroundCallLocals.$queue.withValue(queue) {
            let model = updatePath.withOptions { SingleMemoizeModel().withAnchor() }
            #expect(model.layout.count == 120)
            return model
        }

        // Untracked sweep over a clean cache: zero produces.
        withUntrackedModelReads {
            for _ in 0..<200 {
                #expect(model.layout.count == 120)
            }
        }
        #expect(model.produceCount.value == 1, "untracked access of a clean memoize must hit the cache")

        // After a dependency write + settle, untracked sweeps stay clean too.
        model.dep += 1
        await queue.waitUntilIdle()
        let settled = model.produceCount.value

        withUntrackedModelReads {
            for _ in 0..<200 {
                #expect(model.layout.first == 1)
            }
        }
        let growth = model.produceCount.value - settled
        #expect(growth == 0, "untracked access after revalidation produced \(growth) extra times")
    }

    /// A memoize whose *first* access happens inside `withUntrackedModelReads`
    /// must still register its own dependencies (dependency collection is
    /// immune to the caller's untracked scope) — guard against the fast path
    /// short-circuiting setup.
    @Test(arguments: UpdatePath.allCases)
    func firstAccessInsideUntrackedScopeStillTracksDependencies(updatePath: UpdatePath) async throws {
        let queue = BackgroundCallQueue()
        let model = _BackgroundCallLocals.$queue.withValue(queue) {
            let model = updatePath.withOptions { SingleMemoizeModel().withAnchor() }
            withUntrackedModelReads {
                #expect(model.layout.count == 120)
            }
            return model
        }
        #expect(model.produceCount.value == 1)

        model.dep += 1
        await queue.waitUntilIdle()
        #expect(model.layout.first == 1, "memoize set up inside an untracked scope went stale after a dependency write")
    }
}

// MARK: - Test models

@Model private struct SingleMemoizeModel {
    var dep = 0
    // LockIsolated so counter writes don't register as @Model mutations
    // (which would re-dirty the memoize from inside produce).
    let produceCount = LockIsolated(0)

    /// 120-entry layout array — mirrors the editor's memoized layout shape.
    var layout: [Int] {
        node.memoize(for: "layout") {
            produceCount.withValue { $0 += 1 }
            return (0..<120).map { $0 &+ dep }
        }
    }
}

@Model private struct ChainedMemoizeModel {
    var dep = 0
    let layoutCount = LockIsolated(0)
    let indexCount = LockIsolated(0)

    var layout: [Int] {
        node.memoize(for: "layout") {
            layoutCount.withValue { $0 += 1 }
            return (0..<120).map { $0 &+ dep }
        }
    }

    /// Memoize whose produce reads another memoized property — the editor's
    /// snap-edge-index-over-layout shape that lowered the thrash threshold.
    var snapIndex: Int {
        node.memoize(for: "snapIndex") {
            indexCount.withValue { $0 += 1 }
            return layout.count &+ dep
        }
    }
}
