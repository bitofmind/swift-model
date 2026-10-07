#if !os(Android)
import Foundation
import Testing
import Dependencies
@testable import SwiftModel

/// Issue messages name the model they are about. Many of these reports land far
/// from their cause (teardown work and tasks that outlive a model report into
/// whatever test runs next), so the model type is often the only lead.
@Suite("issue messages name the model")
struct IssueModelNameTests {

    @Test("node call on a never-anchored model names its type")
    func nodeCallOnUnanchoredModel() async {
        await assertIssueSnapshot {
            let model = NamedIssueModel()
            model.node.cancelAll(for: "key")
        } matches: {
            """
            Calling cancelAll(for:) on an unanchored `NamedIssueModel` node is not allowed and has no effect
            """
        }
    }

    // Type-keyed: a key-keyed read names the dependency by its key path, which
    // prints as `<computed 0x… (Int)>` on Linux.
    @Test("dependency read on a never-anchored model names its type")
    func dependencyOnUnanchoredModel() async {
        await assertIssueSnapshot {
            let model = NamedIssueModel()
            _ = model.node[NamedIssueDependency.self]
        } matches: {
            """
            Accessing dependency `NamedIssueDependency` on an unanchored `NamedIssueModel` node is not allowed and will be redirected to the default dependency value
            """
        }
    }

    @Test("node call on a removed model names its type and points at teardown")
    func nodeCallOnRemovedModel() async {
        await assertIssueSnapshot {
            let model: NamedIssueModel = {
                let (model, anchor) = NamedIssueModel().returningAnchor()
                withExtendedLifetime(anchor) {}
                return model
            }()
            model.node.cancelAll(for: "key")
        } matches: {
            """
            Calling cancelAll(for:) on an unanchored `NamedIssueModel` node is not allowed and has no effect (it was already removed: a removed model can still be read, but work that outlives it, such as onTeardown() or a task, cannot start anything through its node)
            """
        }
    }

    @Test("write to a frozen copy names its type")
    func writeToFrozenCopy() async {
        await assertIssueSnapshot {
            let (model, anchor) = NamedIssueModel().returningAnchor()
            let frozen = model.frozenCopy
            frozen.count = 1
            withExtendedLifetime(anchor) {}
        } matches: {
            """
            Modifying a frozen copy of `NamedIssueModel` is not allowed and has no effect
            """
        }
    }
}

private struct NamedIssueDependency: DependencyKey, Sendable {
    static let liveValue = NamedIssueDependency()
    static let testValue = NamedIssueDependency()
}

@Model private struct NamedIssueModel {
    var count = 0
}

#endif
