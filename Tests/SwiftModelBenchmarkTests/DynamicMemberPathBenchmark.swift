import Testing
import Foundation
@testable import SwiftModel

/// Per-read cost of the paths that route through
/// `_ModelSourceBox.subscript(dynamicMember:)`.
///
/// `ReadPathBenchmarks` does NOT cover these: every case it measures is an
/// anchored+tracked read going through `Context.readLocked`.
/// The `dynamicMember` getter is reached instead when `forceDirectAccess ||
/// _isLive`, or when `reference.context == nil` (pre-anchor / snapshot copies) —
/// and `forceDirectAccess` is what wraps the per-element `.id` reads in
/// collection reconciliation, so this is O(N)-traversal cost.
///
/// Added when that getter was changed to project under the hierarchy lock (it
/// previously read `reference.state[keyPath:]` unlocked, racing
/// `Reference.clear(ifGeneration:)`'s state swap). That fix is what makes these
/// numbers worth tracking: the locked projection costs a lock acquisition on every
/// non-snapshot read. Absolute times are machine-dependent — compare branches on one
/// machine rather than reading the constants.
///
/// Two `forceDirectAccess` cases are measured because the thread-local scope, not the
/// read, used to dominate them:
/// - `forceDirectAccess read` keeps the `withValue(_:at:)` keypath helper the traversal
///   sites originally used. Kept unchanged so the number stays comparable across
///   branches back through the pre-#50 baseline.
/// - `forceDirectAccess, direct TL scope` enters the scope by direct field access, which
///   is what those sites do now (`ThreadLocals.withForceDirectAccess`). This is the
///   per-element figure that actually multiplies across an O(N) reconciliation walk.
@Suite(.serialized, .tags(.benchmark))
struct DynamicMemberPathBenchmark {

    @Test func dynamicMemberPaths() {
        let iterations = 50_000

        // Pre-anchor: reference.context == nil → dynamicMember getter.
        let preAnchor = DMModel()
        let preAnchorNs = measureNs(iterations: iterations) {
            dmSink &+= preAnchor.value
        }

        // Frozen copy: reference.context == nil, snapshot reference.
        let frozen = frozenCopy(DMModel().withAnchor())
        let frozenNs = measureNs(iterations: iterations) {
            dmSink &+= frozen.value
        }

        // forceDirectAccess: anchored model, but routed to the dynamicMember getter.
        let anchored = DMModel().withAnchor()
        let directNs = measureNs(iterations: iterations) {
            threadLocals.withValue(true, at: \.forceDirectAccess) {
                dmSink &+= anchored.value
            }
        }

        // Same read, but with the thread-local scope entered by direct field access rather
        // than the `ReferenceWritableKeyPath`-based `withValue(_:at:)` helper — this is the
        // shape the traversal call sites actually use. Written out longhand (rather than
        // calling the shared helper) so the case compiles identically on either branch.
        let directFastNs = measureNs(iterations: iterations) {
            let tl = threadLocals
            let previous = tl.forceDirectAccess
            tl.forceDirectAccess = true
            dmSink &+= anchored.value
            tl.forceDirectAccess = previous
        }

        print("📊 DYNAMICMEMBER PATHS (\(iterations) iterations, min of rounds)")
        print(String(format: "  pre-anchor read (context == nil)   %8.1f ns/op", preAnchorNs))
        print(String(format: "  frozen-copy read                   %8.1f ns/op", frozenNs))
        print(String(format: "  forceDirectAccess read (has ctx)   %8.1f ns/op", directNs))
        print(String(format: "  forceDirectAccess, direct TL scope %8.1f ns/op", directFastNs))
    }
}

nonisolated(unsafe) private var dmSink = 0

private func measureNs(iterations: Int, rounds: Int = 3, _ body: () -> Void) -> Double {
    for _ in 0..<(iterations / 10) { body() }
    var best = Double.infinity
    for _ in 0..<rounds {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start
        best = min(best, Double(elapsed) / Double(iterations))
    }
    return best
}

@Model private struct DMModel: Sendable {
    var value = 0
}
