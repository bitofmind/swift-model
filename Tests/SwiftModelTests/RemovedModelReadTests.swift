import Testing
@testable import SwiftModel
import Dependencies
import IssueReporting

// A removed model is a read-only view of its last state: reads (properties, memoize,
// dependencies, ancestor lookups) answer without reporting, while effects (tasks,
// events, observation) still report. The motivating case: a memoized recompute on a
// live model iterates a list that still holds a just-removed child, and the child's
// accessor walks to an ancestor through memoize. That used to report "Calling memoize
// on an unanchored node" and find no ancestor, so the accessor fell back to an empty
// stand-in model and the recompute read wrong data.

private struct RemovedReadGreeting: DependencyKey, Sendable {
    var text: String
    static let liveValue = RemovedReadGreeting(text: "live")
    static let testValue = RemovedReadGreeting(text: "test")
}

extension DependencyValues {
    fileprivate var removedReadGreeting: RemovedReadGreeting {
        get { self[RemovedReadGreeting.self] }
        set { self[RemovedReadGreeting.self] = newValue }
    }
}

@Model private struct RemovedReadRoot {
    var title = "root"
    var child: RemovedReadChild? = RemovedReadChild()
}

@Model private struct RemovedReadChild {
    var name = "child"

    /// The non-optional child → ancestor accessor shape: memoized, falling back to a
    /// stand-in when no ancestor is found.
    var root: RemovedReadRoot {
        node.memoize {
            node.mapHierarchy(for: .ancestors) { $0 as? RemovedReadRoot }.first ?? RemovedReadRoot(title: "stand-in", child: nil)
        }
    }

    var rootTitle: String {
        node.mapHierarchy(for: .ancestors) { $0 as? RemovedReadRoot }.first?.title ?? "none"
    }

    var selfAndAncestorCount: Int {
        node.mapHierarchy(for: [.self, .ancestors]) { $0 }.count
    }

    var greeting: String { node.removedReadGreeting.text }
}

@Model private struct RemovedReadSubtreeRoot {
    var title = "root"
    var middle: RemovedReadMiddle? = RemovedReadMiddle()
}

@Model private struct RemovedReadMiddle {
    var leaf = RemovedReadSubtreeLeaf()
}

@Model private struct RemovedReadSubtreeLeaf {
    var rootTitle: String {
        node.mapHierarchy(for: .ancestors) { $0 as? RemovedReadSubtreeRoot }.first?.title ?? "none"
    }

    var greeting: String { node.removedReadGreeting.text }
}

@Model private struct TeardownReader {
    let seen: TestProbe

    func onActivate() {
        node.onCancel {
            seen("\(rootTitle) \(greeting)")
        }
    }

    var rootTitle: String {
        node.memoize {
            node.mapHierarchy(for: .ancestors) { $0 as? TeardownReaderRoot }.first?.title ?? "none"
        }
    }

    var greeting: String { node.removedReadGreeting.text }
}

@Model private struct TeardownReaderRoot {
    var title = "root"
    var reader: TeardownReader?
}

@Suite(.modelTesting(exhaustivity: .off))
struct RemovedModelReadTests {
    @Test func removedChildReadsItsLiveAncestorsWithoutReporting() async {
        let root = RemovedReadRoot().withAnchor()
        let child = root.child!
        #expect(child.root.title == "root")

        root.child = nil
        await child.waitUntilRemoved()

        // Context gone: memoize is uncached, the ancestor walk starts from the last parent.
        #expect(child.root.title == "root")
        #expect(child.rootTitle == "root")
        #expect(child.selfAndAncestorCount == 2)
        #expect(child.name == "child")

        // The ancestor is the live one, not a copy of what it was.
        root.title = "renamed"
        #expect(child.root.title == "renamed")
        #expect(child.rootTitle == "renamed")
    }

    @Test func removedChildReadsTheDependenciesItsTreeUsed() async {
        let root = RemovedReadRoot().withAnchor {
            $0.removedReadGreeting = RemovedReadGreeting(text: "override")
        }
        let child = root.child!
        #expect(child.greeting == "override")

        root.child = nil
        await child.waitUntilRemoved()

        #expect(child.greeting == "override")
    }

    @Test func descendantOfARemovedSubtreeReadsTheSurvivingAncestors() async {
        let root = RemovedReadSubtreeRoot().withAnchor {
            $0.removedReadGreeting = RemovedReadGreeting(text: "override")
        }
        let leaf = root.middle!.leaf

        // Removing `middle` removes `leaf` with it; `middle`'s context is gone right after.
        root.middle = nil
        await leaf.waitUntilRemoved()

        #expect(leaf.rootTitle == "root")
        #expect(leaf.greeting == "override")
        root.title = "renamed"
        #expect(leaf.rootTitle == "renamed")
    }

    @Test func teardownCanReadAncestorsAndDependencies() async {
        let seen = TestProbe()
        let root = TeardownReaderRoot(reader: TeardownReader(seen: seen)).withAnchor {
            $0.removedReadGreeting = RemovedReadGreeting(text: "override")
        }

        root.reader = nil

        // `onCancel` runs while the context is torn down but still alive.
        await expect(seen.wasCalled(with: "root override"))
    }

    @Test func removedModelStillReportsEffects() async {
        let root = RemovedReadRoot().withAnchor()
        let child = root.child!
        root.child = nil
        await child.waitUntilRemoved()

        withKnownIssue {
            child.node.task {}
        } matching: { issue in
            issue.description.contains("it was already removed")
        }
    }

    @Test func neverAnchoredModelStillReportsMemoize() {
        let child = RemovedReadChild()
        withKnownIssue {
            _ = child.root
        } matching: { issue in
            issue.description.contains("Calling memoize") && !issue.description.contains("already removed")
        }
    }
}
