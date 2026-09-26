import Testing
@testable import SwiftModel
import ConcurrencyExtras
import IssueReporting

// A memoize whose producer resolves an ancestor, falling back to a fresh (never-anchored)
// model when there is none, then calls a memoize on the result — the shape of a
// real-world `timelineModel` accessor (`node.memoize { node.member(in: .ancestors) ??
// TimelineModel() }`). Tearing the tree down cuts the child's parent link first; that
// wakes the child's memoizes, and a re-evaluation racing the teardown cascade ran the
// producer on a model being torn down: the ancestor was gone, the fallback was used, and
// memoize on the never-anchored fallback reported "memoize(...) on an unanchored model
// node is not allowed" — unattributed to any test, after the test had finished.
struct MemoizeDuringTeardownTests {
    @Test func reevaluationRacingTeardownDoesNotRunTheProducer() async {
        // The reports are raised on the background queue, outside any task-local issue
        // reporter (they surface as unattributed issues), so assert on their cause: the
        // producer running on a torn-down model, i.e. the ancestor fallback being taken.
        let fallbacks = LockIsolated(0)
        for _ in 0..<60 {
            await withModelTesting(exhaustivity: .off) {
                let root = Timeline(segments: (0..<8).map { _ in Segment(fallbacks: fallbacks) }).withAnchor()
                for segment in root.segments { _ = segment.visibleCount }
            }
        }
        await backgroundCall.waitUntilIdle(deadline: _monotonicNs() + 5_000_000_000)
        #expect(fallbacks.value == 0)
    }
}

@Model private struct Timeline {
    var media: [Int] = [1, 2, 3]
    var segments: [Segment]

    var mediaCount: Int {
        node.memoize { media.count }
    }
}

@Model private struct Segment {
    let fallbacks: LockIsolated<Int>

    var timeline: Timeline {
        node.memoize {
            if let timeline = node.mapHierarchy(for: .ancestors, transform: { $0 as? Timeline }).first {
                return timeline
            }
            fallbacks.withValue { $0 += 1 }
            return Timeline(segments: [])
        }
    }

    var visibleCount: Int {
        node.memoize { timeline.mediaCount }
    }
}
