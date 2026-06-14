import ConcurrencyExtras
import Foundation
import Testing
@testable import SwiftModel

/// Memoize access-path benchmarks: per-access cost of a cached (clean) memoized
/// property read × {tracked, untracked} × {idle pool, saturated pool}, plus a
/// chained-memoize case (a memoize whose `produce` reads another memoize).
///
/// This is the isolated counterpart of the parallel-apple editor probe that
/// reported produce-per-access thrash and a ~6× untracked access penalty
/// (docs/notes/swift-model-tracked-read-perf-handover.md, Addendum). The
/// produce-count *correctness* assertions live in the main suite
/// (`MemoizeThrashTests`, with deterministic starvation injection); this suite
/// owns the cost ratios and the real cooperative-pool-saturation variant.
///
/// Assertions are RATIOS (not absolute times) for CI stability, mirroring
/// `ReadPathBenchmarks`. This suite runs in CI via its own job — see the
/// `benchmarks` job in `.github/workflows/ci.yml`.
@Suite(.serialized, .tags(.benchmark))
struct MemoizeAccessBenchmarks {

    /// Cached memoize access cost: tracked vs untracked vs chained.
    ///
    /// The untracked path skips the registrar call and access dispatch, so it
    /// must NOT be materially slower than the tracked cached path. The
    /// parallel-apple editor reported untracked ~6× slower (the untracked branch
    /// missing the cached-return fast-path); this gate catches a regression to
    /// that class while tolerating CI measurement noise.
    ///
    /// Tracked and untracked are measured INTERLEAVED in fine-grained alternating
    /// blocks, and the gate is the MEDIAN per-block ratio. Measuring them in
    /// separate windows (as a naive benchmark would) lets a sustained contention
    /// spike land on one window but not the other and flip the ratio by 4–5×;
    /// interleaving makes any transient load hit both proportionally, so the
    /// ratio stays stable even when the absolute ns/op numbers are noisy.
    @Test func cachedAccessCostComparison() {
        let model = MemoBenchModel().withAnchor()
        _ = model.layout  // warm the cache (single produce)
        let chained = ChainedMemoBenchModel().withAnchor()
        _ = chained.snapIndex  // warms both memoizes

        let (singleRatio, singleT, singleU) = interleavedRatio(
            tracked: { memoizeBenchSink &+= model.layout.count },
            untracked: { withUntrackedModelReads { memoizeBenchSink &+= model.layout.count } }
        )
        let (chainedRatio, chainedT, chainedU) = interleavedRatio(
            tracked: { memoizeBenchSink &+= chained.snapIndex },
            untracked: { withUntrackedModelReads { memoizeBenchSink &+= chained.snapIndex } }
        )

        print("📊 MEMOIZE CACHED ACCESS (interleaved, median of blocks)")
        print(String(format: "  single:  tracked %7.1f ns/op  untracked %7.1f ns/op  (%.2fx)", singleT, singleU, singleRatio))
        print(String(format: "  chained: tracked %7.1f ns/op  untracked %7.1f ns/op  (%.2fx)", chainedT, chainedU, chainedRatio))

        // The cache must hold across all measurement sweeps.
        #expect(model.produceCount.value == 1, "tracked/untracked sweeps recomputed a clean memoize")
        #expect(chained.layoutCount.value == 1)
        #expect(chained.indexCount.value == 1)

        // Untracked skips observation work — it must not be materially slower
        // than tracked. Bound 1.5× (untracked is typically FASTER, ~0.8×); the
        // interleaved median makes this robust without needing a loose bound,
        // and it still trips well below the editor's reported ~6× regression.
        #expect(singleRatio < 1.5, "untracked cached memoize access is \(singleRatio)x tracked — should be ≤ 1.5x")
        #expect(chainedRatio < 1.5, "untracked chained memoize access is \(chainedRatio)x tracked — should be ≤ 1.5x")
    }

    /// Produce-count under genuine cooperative-pool saturation: flood the pool
    /// with non-yielding low-priority spinners so the memoize's revalidation
    /// `performUpdate` cannot run, then sweep the memoized property 200×
    /// (tracked) and 200× (untracked) after a dependency write.
    ///
    /// Pre-fix behaviour was one produce per access (the editor's "151 of 200"
    /// thrash); the dirty-access write-back bounds it at one produce per write
    /// regardless of sweep length. The flood section is fully synchronous — no
    /// `await` may appear while the pool is saturated, or the test itself
    /// deadlocks against its own spinners.
    @Test func saturatedPoolSweepProduceCount() async {
        let model = MemoBenchModel().withAnchor()
        #expect(model.layout.count == 120)
        #expect(model.produceCount.value == 1)

        let stopFlood = LockIsolated(false)
        let floodWidth = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        for _ in 0..<floodWidth {
            Task.detached(priority: .low) {
                while !stopFlood.value { /* spin: hold a cooperative-pool thread */ }
            }
        }
        // From here to stopFlood: synchronous code only.

        model.dep += 1  // dirty; revalidation is queued behind the flood

        for _ in 0..<200 {
            memoizeBenchSink &+= model.layout.first ?? 0
        }
        let trackedProduces = model.produceCount.value - 1

        model.dep += 1
        withUntrackedModelReads {
            for _ in 0..<200 {
                memoizeBenchSink &+= model.layout.first ?? 0
            }
        }
        let totalProduces = model.produceCount.value - 1

        stopFlood.setValue(true)

        let untrackedProduces = totalProduces - trackedProduces
        print("📊 SATURATED-POOL SWEEP: tracked sweep produces=\(trackedProduces), untracked sweep produces=\(untrackedProduces) (200 accesses each, 1 dependency write each)")

        // The invariant the editor needs: produce count is a small constant per
        // dependency write, NOT proportional to the 200-access sweep (the
        // reported "151 of 200" thrash). Bound generously (≤ 5) so an occasional
        // revalidation slice sneaking through the real flood doesn't flake CI;
        // the tight produce-count==1 contract is proven deterministically in
        // `MemoizeThrashTests`.
        #expect(trackedProduces <= 5, "tracked sweep under saturation produced \(trackedProduces)× for one write — should be O(1), not O(accesses)")
        #expect(untrackedProduces <= 5, "untracked sweep under saturation produced \(untrackedProduces)× for one write — should be O(1), not O(accesses)")

        // Value correctness is asserted only AFTER the queued revalidations
        // drain. The flood spinners run at `.low` priority but `backgroundCall`
        // drains at `.userInitiated` (higher), so the OS scheduler can run a
        // `performUpdate` *during* the sweeps — fine for the produce-COUNT
        // invariant above (it tolerates a sneaking revalidation), but it means
        // the cached value can be mid-flight between the two `dep += 1` writes
        // until things settle. After waitUntilIdle the last revalidation has
        // committed the live-`dep` value (dep == 2 → layout.first == 2).
        await backgroundCall.waitUntilIdle()
        #expect(model.layout.first == 2, "memoize settled to a stale value after saturation: \(String(describing: model.layout.first))")
    }

    /// Chained memoizes under saturation — the editor's snap-edge-index-over-
    /// layout shape that lowered the thrash threshold. A chained dirty access
    /// may produce once per chain hop, but must not scale with access count.
    @Test func saturatedPoolChainedSweepProduceCount() async {
        let model = ChainedMemoBenchModel().withAnchor()
        #expect(model.snapIndex == 120)

        let stopFlood = LockIsolated(false)
        let floodWidth = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        for _ in 0..<floodWidth {
            Task.detached(priority: .low) {
                while !stopFlood.value { /* spin */ }
            }
        }

        model.dep += 1

        for _ in 0..<200 {
            memoizeBenchSink &+= model.snapIndex
        }
        let layoutProduces = model.layoutCount.value - 1
        let indexProduces = model.indexCount.value - 1

        stopFlood.setValue(true)

        print("📊 SATURATED-POOL CHAINED SWEEP: layout produces=\(layoutProduces), index produces=\(indexProduces) (200 accesses, 1 dependency write)")

        // Chaining adds a hop (the index memoize's produce reads the layout
        // memoize), so a single write can cascade a couple extra produces — but
        // it must stay O(1), not the 200-scaling thrash the editor reported for
        // chained memoizes at moderate load. Bound ≤ 10 (observed 2–4); the
        // deterministic tight bound lives in `MemoizeThrashTests`.
        #expect(layoutProduces <= 10, "chained layout memoize produced \(layoutProduces)× during a saturated 200-access sweep — should be O(1), not O(accesses)")
        #expect(indexProduces <= 10, "chained index memoize produced \(indexProduces)× during a saturated 200-access sweep — should be O(1), not O(accesses)")

        // Value correctness only after the queued revalidations drain — see
        // `saturatedPoolSweepProduceCount` for why the cached value can be
        // mid-flight during the saturated section. dep == 1 → snapIndex == 121.
        await backgroundCall.waitUntilIdle()
        #expect(model.snapIndex == 121, "chained memoize settled to a stale value after saturation: \(model.snapIndex)")
    }
}

// MARK: - Measurement helpers

/// Global accumulator the optimizer cannot see through.
nonisolated(unsafe) private var memoizeBenchSink = 0

/// Measures `tracked` and `untracked` INTERLEAVED in fine-grained alternating
/// blocks and returns `(medianRatio, medianTrackedNs, medianUntrackedNs)`.
///
/// Each block times `blockOps` iterations of one closure immediately after the
/// other, so any transient machine load during a block is shared by both — the
/// per-block ratio is stable even when absolute ns/op swings 4–5× across blocks.
/// The reported ratio is the median of per-block ratios (robust to the
/// occasional outlier block); the reported ns/op are medians too, for the log.
private func interleavedRatio(
    blocks: Int = 25,
    blockOps: Int = 2_000,
    tracked: () -> Void,
    untracked: () -> Void
) -> (ratio: Double, trackedNs: Double, untrackedNs: Double) {
    // Warmup both paths.
    for _ in 0..<(blockOps / 2) { tracked(); untracked() }

    var ratios: [Double] = []
    var trackedNs: [Double] = []
    var untrackedNs: [Double] = []
    ratios.reserveCapacity(blocks)
    for _ in 0..<blocks {
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<blockOps { tracked() }
        let t1 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<blockOps { untracked() }
        let t2 = DispatchTime.now().uptimeNanoseconds

        let tNs = Double(t1 &- t0) / Double(blockOps)
        let uNs = Double(t2 &- t1) / Double(blockOps)
        trackedNs.append(tNs)
        untrackedNs.append(uNs)
        ratios.append(tNs > 0 ? uNs / tNs : .infinity)
    }
    func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        return s[s.count / 2]
    }
    return (median(ratios), median(trackedNs), median(untrackedNs))
}

// MARK: - Test models

@Model private struct MemoBenchModel {
    var dep = 0
    // LockIsolated so counter writes don't register as @Model mutations.
    let produceCount = LockIsolated(0)

    /// 120-entry layout array — the editor's memoized layout shape.
    var layout: [Int] {
        node.memoize(for: "layout") {
            produceCount.withValue { $0 += 1 }
            return (0..<120).map { $0 &+ dep }
        }
    }
}

@Model private struct ChainedMemoBenchModel {
    var dep = 0
    let layoutCount = LockIsolated(0)
    let indexCount = LockIsolated(0)

    var layout: [Int] {
        node.memoize(for: "layout") {
            layoutCount.withValue { $0 += 1 }
            return (0..<120).map { $0 &+ dep }
        }
    }

    var snapIndex: Int {
        node.memoize(for: "snapIndex") {
            indexCount.withValue { $0 += 1 }
            return layout.count &+ dep
        }
    }
}
