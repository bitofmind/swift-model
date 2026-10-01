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

    @Test("dependency read on a never-anchored model names its type")
    func dependencyOnUnanchoredModel() async {
        await assertIssueSnapshot {
            let model = NamedIssueModel()
            _ = model.node.namedIssueValue
        } matches: {
            """
            Accessing dependency `namedIssueValue` on an unanchored `NamedIssueModel` node is not allowed and will be redirected to the default dependency value
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
            Calling cancelAll(for:) on an unanchored `NamedIssueModel` node is not allowed and has no effect (it was already removed: work that outlives a model, such as onTeardown(), must capture what it needs instead of using its node)
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

private struct NamedIssueValueKey: DependencyKey {
    static let liveValue = 1
    static let testValue = 1
}

extension DependencyValues {
    fileprivate var namedIssueValue: Int {
        get { self[NamedIssueValueKey.self] }
        set { self[NamedIssueValueKey.self] = newValue }
    }
}

@Model private struct NamedIssueModel {
    var count = 0
}

#endif
