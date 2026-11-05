import Testing
import Foundation
@testable import SwiftModel

/// A memoize that reads another memoize must be fresh right after a write. It used to learn of
/// the change only when the inner memoize's coalesced update ran, so a read in between returned
/// its old value. Each write-then-read below races that update, hence the iterations; a pass
/// never depends on timing, because the value must be fresh whenever it is read.
///
/// `disableObservationRegistrar` only covers a first write: a rapid second write on that path
/// can still read stale. See the [Unreleased] entry in CHANGELOG.md.
@Suite(.serialized)
struct MemoizeChainFreshnessTests {
    private static let iterations = 10

    /// Long enough for the coalesced updates of the previous write to have run.
    private func letUpdatesRun() async {
        try? await Task.sleep(nanoseconds: 3_000_000)
    }

    @Test func firstWriteWithoutRegistrar() {
        for _ in 0..<Self.iterations {
            let (model, anchor) = withModelOptions([.disableObservationRegistrar]) { ChainModel().returningAnchor() }
            #expect(model.middle == 20)
            model.base = 2
            #expect(model.middle == 40)
            withExtendedLifetime(anchor) {}
        }
    }

    @Test func writeAfterUpdatesHaveRun() async {
        for _ in 0..<Self.iterations {
            let (model, anchor) = ChainModel().returningAnchor()
            #expect(model.middle == 20)
            model.base = 2
            #expect(model.middle == 40)
            await letUpdatesRun()
            model.base = 3
            #expect(model.middle == 60)
            withExtendedLifetime(anchor) {}
        }
    }

    @Test func rapidWrites() async {
        for _ in 0..<Self.iterations {
            let (model, anchor) = ChainModel().returningAnchor()
            #expect(model.middle == 20)
            model.base = 2
            #expect(model.middle == 40)
            await letUpdatesRun()
            model.base = 3
            #expect(model.middle == 60)
            model.base = 4
            #expect(model.middle == 80)
            withExtendedLifetime(anchor) {}
        }
    }

    @Test func threeLevels() async {
        for _ in 0..<Self.iterations {
            let (model, anchor) = ChainModel().returningAnchor()
            #expect(model.outer == 21)
            model.base = 2
            #expect(model.outer == 41)
            await letUpdatesRun()
            model.base = 3
            #expect(model.outer == 61)
            withExtendedLifetime(anchor) {}
        }
    }

    /// A memoize first read during another memoize's dirty recompute must still register its
    /// own dependencies. It used to end up with none and stay wrong for good.
    @Test(arguments: UpdatePath.allCases)
    func dependencyPickedUpLater(updatePath: UpdatePath) async {
        for _ in 0..<Self.iterations {
            let (model, anchor) = updatePath.withOptions { SwitchingModel().returningAnchor() }
            #expect(model.selected == 2)
            model.useSecond = true
            #expect(model.selected == 30)
            await letUpdatesRun()
            model.second = 4
            #expect(model.selected == 40)
            withExtendedLifetime(anchor) {}
        }
    }

    /// `a` reads `b`, then the switch makes `b` read `a`. The old edge remains, so marking
    /// dirty sees a cycle and must end.
    @Test func cycleOfStaleEdgesEnds() async {
        let (model, anchor) = CycleModel().returningAnchor()
        #expect(model.a == 1)
        model.bReadsA = true
        await letUpdatesRun()
        #expect(model.b == 1)
        model.base = 2
        #expect(model.b == 2)
        withExtendedLifetime(anchor) {}
    }
}

@Model private struct ChainModel {
    var base = 1
    var inner: Int { node.memoize(for: "inner") { base * 2 } }
    var middle: Int { node.memoize(for: "middle") { inner * 10 } }
    var outer: Int { node.memoize(for: "outer") { middle + 1 } }
}

@Model private struct SwitchingModel {
    var useSecond = false
    var first = 1
    var second = 3
    var firstMemo: Int { node.memoize(for: "first") { first * 2 } }
    var secondMemo: Int { node.memoize(for: "second") { second * 10 } }
    var selected: Int { node.memoize(for: "selected") { useSecond ? secondMemo : firstMemo } }
}

@Model private struct CycleModel {
    var bReadsA = false
    var base = 1
    var a: Int { node.memoize(for: "a") { bReadsA ? base : b } }
    var b: Int { node.memoize(for: "b") { bReadsA ? a : base } }
}
