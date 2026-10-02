import Foundation
import Testing
@testable import SwiftModel

/// Writes to a model whose context took over a freed context's address.
///
/// `TestAccess` drops a write whose sequence number is lower than the last one it
/// recorded for the same (context, path), so a late post-lock closure can't
/// overwrite a newer value. It keyed that by the context's address and never
/// forgot an entry. A model rebuilt after another was removed often gets the same
/// address, and its counter starts again at zero, so its writes were dropped as
/// stale until it had made more writes than the old one. `lastState` lagged, and
/// `expect` ended in "the tester's recorded state never caught up". Downstream: a
/// media-player controller that is rebuilt in place.
@Suite(.modelTesting(exhaustivity: .off))
struct ReusedContextAddressTests {

    @Test func writesToARebuiltChildAreRecorded() async {
        let root = ReuseRoot().withAnchor()

        for round in 1...20 {
            let leaf = ReuseLeaf()
            root.leaf = leaf
            // More writes than the next leaf will make, so a stale entry outranks it.
            for i in 0..<50 { leaf.value = i }
            await expect(root.leaf?.value == 49)

            root.leaf = nil
            await expect(root.leaf == nil)

            let next = ReuseLeaf()
            root.leaf = next
            next.value = 1000 + round
            await expect(root.leaf?.value == 1000 + round)
            root.leaf = nil
        }
    }
}

@Model private struct ReuseLeaf {
    var value = 0
}

@Model private struct ReuseRoot {
    var leaf: ReuseLeaf?
}
