import Foundation
import Testing
@testable import SwiftModel

/// Writes through the handle a model was created with, after that model joined a
/// tester's tree.
///
/// The handle's access is stamped only when a model is read out of the tree, so a
/// model created outside it and then appended keeps an access-less handle. Writes
/// through it reached the live context but not the `TestAccess`: `lastState` kept
/// the old value, and an `expect` on the new value failed its "recorded matches
/// live" check with no further wake. It then ended at the drive's quiet window
/// (2 s × scale; indefinitely under parallel load) as a timeout that reported
/// nothing, because the predicate itself held. Downstream: an editor's
/// split-then-duplicate tests took 20 s alone and hit the 120 s cap on CI.
@Suite(.modelTesting)
struct PreAnchorHandleWriteTests {

    @Test func writeThroughCreationHandleAfterAppendIsRecorded() async throws {
        let root = HandleRoot(items: [HandleItem(id: 1, start: 0, offset: 5)]).withAnchor()

        root.split()

        let dup = try await require(root.items.first { $0.start == 30 })
        await expect {
            dup.offset == 35
            root.items.count == 2
        }
    }

    @Test func writeThroughCreationHandleFromChildMethodIsRecorded() async throws {
        let root = HandleRoot(items: [HandleItem(id: 1, start: 0, offset: 5)]).withAnchor()

        root.items[0].splitIntoParent()

        let dup = try await require(root.items.first { $0.start == 30 })
        await expect {
            dup.offset == 35
            root.items.count == 2
        }
    }
}

/// A timeout whose predicates hold on live state but whose recorded state lags
/// must report itself, not end the wait as if it had passed.
@Suite(.modelTesting(exhaustivity: .off))
struct LaggingRecordedStateTimeoutTests {

    @Test func timeoutWithLaggingRecordedStateIsReported() async {
        let root = HandleRoot(items: [HandleItem(id: 1, start: 0, offset: 5)]).withAnchor()
        let item = root.items[0]

        // A write that notifies another access instead of the tester: live state
        // changes, `lastState` doesn't, which is the state the bug above left.
        usingActiveAccess(SilentAccess(useWeakReference: false)) {
            item.offset = 6
        }

        await withKnownIssue {
            await expect(item.offset == 6)
        } matching: { issue in
            issue.description.contains("recorded state never caught up: HandleItem.offset")
        }
    }
}

private final class SilentAccess: ModelAccess, @unchecked Sendable {}

@Model private struct HandleItem: Identifiable {
    var id: Int
    var start: Int
    var offset: Int

    func splitIntoParent() {
        guard let parent = node.mapHierarchy(for: .ancestors, transform: { $0 as? HandleRoot }).first else { return }
        let dup = HandleItem(id: -1, start: start, offset: offset)
        parent.items.append(dup)
        dup.start = 30
        dup.offset += 30
    }
}

@Model private struct HandleRoot {
    var items: [HandleItem]

    func split() {
        let dup = HandleItem(id: -1, start: items[0].start, offset: items[0].offset)
        items.append(dup)
        dup.start = 30
        dup.offset += 30
    }
}
