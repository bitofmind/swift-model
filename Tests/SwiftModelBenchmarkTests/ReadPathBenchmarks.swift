import Testing
import Foundation
import Observation
@testable import SwiftModel

/// Per-tracked-read cost across observation modes, asserting RATIOS (not absolute
/// times) so the suite is stable across machines and load.
///
/// The constant measured here is the scaling factor for every O(N) model traversal
/// in client apps (hit-testing, snapping, repair pipelines). A large share of the
/// cost is Swift-runtime work that ships -O regardless of the app's build config
/// (KeyPath projection, ObservationRegistrar internals, locks), so Debug numbers
/// here understate the *relative* win of the untracked path in Release — run
/// `swift run -c release SwiftModelBenchmarks` for Release-mode absolute numbers.
@Suite(.serialized, .tags(.benchmark))
struct ReadPathBenchmarks {

    @Test func readPathComparison() {
        let iterations = 50_000

        struct RawCounter { var value = 0 }
        let raw = RawCounter()
        let rawNs = measureNsPerOp(iterations: iterations) {
            readPathSink &+= raw.value
        }

        let model = ReadPathModel().withAnchor()
        let trackedNs = measureNsPerOp(iterations: iterations) {
            readPathSink &+= model.value
        }

        let noRegistrarModel = withModelOptions([.disableObservationRegistrar]) {
            ReadPathModel().withAnchor()
        }
        let noRegistrarNs = measureNsPerOp(iterations: iterations) {
            readPathSink &+= noRegistrarModel.value
        }

        // Stamped propagating access — the shape of reads from a SwiftUI body
        // (pre-iOS 17 ViewAccess) or a ModelTester predicate.
        let stamped = model.withAccess(StampedAccess(useWeakReference: false))
        let stampedNs = measureNsPerOp(iterations: iterations) {
            readPathSink &+= stamped.value
        }

        // One tracking scope around all reads — what a body/scan pays while
        // Apple's withObservationTracking is active.
        var observationTrackingNs = Double.nan
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            withObservationTracking {
                observationTrackingNs = measureNsPerOp(iterations: iterations) {
                    readPathSink &+= model.value
                }
            } onChange: {}
        }

        var untrackedNs = Double.nan
        withUntrackedModelReads {
            untrackedNs = measureNsPerOp(iterations: iterations) {
                readPathSink &+= model.value
            }
        }

        func row(_ name: String, _ ns: Double) -> String {
            let nsCol = String(format: "%8.1f", ns)
            let ratioCol = ns.isNaN ? "     n/a" : String(format: "%7.1fx", ns / rawNs)
            return "  \(name.padding(toLength: 44, withPad: " ", startingAt: 0)) \(nsCol) ns/op  \(ratioCol) vs raw"
        }
        print("📊 READ PATH (\(iterations) iterations, min of rounds)")
        print(row("raw struct read", rawNs))
        print(row("tracked read (no listener)", trackedNs))
        print(row("tracked read (registrar disabled)", noRegistrarNs))
        print(row("tracked read (stamped propagating access)", stampedNs))
        print(row("tracked read (inside withObservationTracking)", observationTrackingNs))
        print(row("untracked read (withUntrackedModelReads)", untrackedNs))

        // Ratio assertions only where the margin is structural, not incidental:
        // the untracked path skips the registrar call, the KeyPath propID lookup,
        // the access dispatch, and the stamping — it must beat the tracked read.
        #expect(untrackedNs < trackedNs, "untracked read should be cheaper than tracked read")
        // And it can never beat a raw struct read (it still takes the context lock).
        #expect(rawNs < untrackedNs, "raw struct read should be cheaper than untracked read")
    }

    /// The motivating workload: O(N) scan reading 2 properties from each of N live
    /// child models. Asserts the untracked scan beats the tracked scan.
    @Test func scanComparison() {
        let n = 120
        let parent = ReadPathParent(items: (0..<n).map { ReadPathItem(id: $0, value: $0) }).withAnchor()
        let iterations = 500

        let trackedNs = measureNsPerOp(iterations: iterations) {
            for item in parent.items { readPathSink &+= item.value &+ item.id }
        }

        let untrackedNs = measureNsPerOp(iterations: iterations) {
            withUntrackedModelReads {
                for item in parent.items { readPathSink &+= item.value &+ item.id }
            }
        }

        let snapshot: [(Int, Int)] = withUntrackedModelReads { parent.items.map { ($0.id, $0.value) } }
        let snapshotNs = measureNsPerOp(iterations: iterations) {
            for (id, value) in snapshot { readPathSink &+= value &+ id }
        }

        print("📊 SCAN n=\(n) (\(iterations) iterations, min of rounds, ns per scan)")
        print(String(format: "  tracked scan:        %10.0f ns", trackedNs))
        print(String(format: "  untracked scan:      %10.0f ns", untrackedNs))
        print(String(format: "  value-snapshot scan: %10.0f ns", snapshotNs))

        #expect(untrackedNs < trackedNs, "untracked scan should be cheaper than tracked scan")
    }
}

// MARK: - Measurement helpers

/// Global accumulator the optimizer cannot see through — prevents pure reads
/// from being elided in -O builds.
nonisolated(unsafe) private var readPathSink = 0

/// Min-of-rounds ns/op. Min (not mean) is the standard for microbenchmarks:
/// noise is strictly additive, so the minimum is the best estimate of true cost.
private func measureNsPerOp(iterations: Int, rounds: Int = 3, _ body: () -> Void) -> Double {
    for _ in 0..<(iterations / 10) { body() }  // warmup
    var best = Double.infinity
    for _ in 0..<rounds {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start
        best = min(best, Double(elapsed) / Double(iterations))
    }
    return best
}

// MARK: - Test models

@Model private struct ReadPathModel: Sendable {
    var value = 0
}

@Model private struct ReadPathItem: Identifiable, Sendable {
    let id: Int
    var value = 0
}

@Model private struct ReadPathParent: Sendable {
    var items: [ReadPathItem] = []
}

/// Minimal propagating access — willAccess/didModify are the no-op base
/// implementations, so this measures just the dispatch + stamping overhead.
private final class StampedAccess: ModelAccess, @unchecked Sendable {
    override var shouldPropagateToChildren: Bool { true }
}
