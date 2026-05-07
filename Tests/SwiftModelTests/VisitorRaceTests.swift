import Testing
@testable import SwiftModel
import Foundation

// Regression tests for the TOCTOU race in ModelTransformerVisitor.visitCollection /
// visitContainerCollection. The loop previously read root[keyPath: fullPath] multiple
// times (once for .indices, once per element), routing each read through the live
// Context. A concurrent removal between the .indices read and the element read
// shrank the array → index out of range / EXC_BAD_ACCESS.
//
// The fix: snapshot root[keyPath: fullPath] once before the loop so all index reads
// hit the local copy.
//
// withDeepAccess calls transformModel(with: WithAccessTransformer), which drives
// ModelTransformerVisitor — the smallest public trigger for visitCollection /
// visitContainerCollection. A detached task removes items while the main body
// calls withDeepAccess(), creating a genuine concurrent mutation window.
struct VisitorRaceTests {

    // Tests that removing elements from a [ChildModel] collection while
    // withDeepAccess() traverses it does not produce an index-out-of-range crash.
    @Test func visitCollectionDoesNotRaceWithConcurrentRemoval() async {
        for _ in 0..<20 {
            let (parent, anchor) = VisitorRaceParent().returningAnchor()

            // Detached task removes items concurrently with the withDeepAccess
            // traversal below. Not a model task, so not cancelled by onRemoval.
            let mutator = Task.detached {
                for _ in 0..<50 {
                    if !parent.children.isEmpty {
                        parent.children.removeFirst()
                    }
                }
            }

            // withDeepAccess → transformModel → ModelTransformerVisitor.visitCollection
            // Previously crashed here with "Index out of range" when the detached
            // task removed an element between the .indices read and element access.
            for _ in 0..<50 {
                _ = parent.withDeepAccess(nil)
            }

            await mutator.value
            withExtendedLifetime(anchor) {}
        }
    }
}

@Model private struct VisitorRaceParent {
    var children: [VisitorRaceChild] = (0..<20).map { VisitorRaceChild(id: $0, value: $0) }
}

@Model private struct VisitorRaceChild: Identifiable {
    let id: Int
    var value: Int
}
