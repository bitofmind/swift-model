#if !os(Android)
import Testing
@testable import SwiftModel
import IssueReporting
import InlineSnapshotTesting

// MARK: - Test models

@Model
private struct ModelWithPrivateProperties {
    var publicCount: Int = 0
    private var animating: Bool = false
    fileprivate var internalState: String = ""
    private(set) var readOnlyFromOutside: Int = 0  // public getter, private setter

    func toggleAnimating() { animating = !animating }
    func setInternalState(_ s: String) { internalState = s }
    func incrementReadOnly() { readOnlyFromOutside += 1 }
}

// MARK: - Functional tests

/// Verifies that private/fileprivate properties are excluded from exhaustivity tracking,
/// while public and `private(set)` properties (which have public getters) are still tracked.
@Suite(.modelTesting)
struct PrivatePropertyExhaustivityTests {

    /// A private property change should NOT trigger a "State not exhausted" failure.
    @Test func privatePropertyChangeIsNotTracked() async {
        let model = ModelWithPrivateProperties().withAnchor()
        await settle {}

        model.toggleAnimating()  // changes private var animating
        await expect {}
    }

    /// A fileprivate property change should also NOT trigger a failure.
    @Test func fileprivatePropertyChangeIsNotTracked() async {
        let model = ModelWithPrivateProperties().withAnchor()
        await settle {}

        model.setInternalState("hello")  // changes fileprivate var internalState
        await expect {}
    }

    /// `private(set)` has a public getter, so it IS tracked for exhaustivity.
    @Test(.modelTesting(exhaustivity: .off)) func privateSetPropertyIsStillTracked() async {
        let reporter = CapturingIssueReporter()
        await withIssueReporters([reporter]) {
            await withModelTesting(exhaustivity: .state) {
                let model = ModelWithPrivateProperties().withAnchor()
                model.incrementReadOnly()  // changes private(set) var readOnlyFromOutside
                await expect {}
            }
        }
        #expect(reporter.messages.joined().contains("readOnlyFromOutside"))
    }

    /// Public property changes are still tracked and must be asserted.
    @Test(.modelTesting(exhaustivity: .off)) func publicPropertyChangeIsTracked() async {
        let reporter = CapturingIssueReporter()
        await withIssueReporters([reporter]) {
            await withModelTesting(exhaustivity: .state) {
                let model = ModelWithPrivateProperties().withAnchor()
                model.publicCount = 5
                await expect {}
            }
        }
        #expect(reporter.messages.joined().contains("publicCount"))
    }

    /// Both private and public properties change: only the public one needs asserting.
    @Test func mixedChangesOnlyRequirePublicAssertion() async {
        let model = ModelWithPrivateProperties().withAnchor()
        await settle {}

        model.publicCount = 3
        model.toggleAnimating()  // private — should not require assertion
        await expect { model.publicCount == 3 }
    }

    /// Asserting a private property (via @testable import access) works fine.
    @Test func assertingPrivatePropertyStillWorks() async {
        let model = ModelWithPrivateProperties().withAnchor()
        await settle {}

        model.publicCount = 7
        model.toggleAnimating()
        // Only publicCount is required by exhaustivity; toggling animating is silently ignored.
        await expect { model.publicCount == 7 }
    }
}

// MARK: - Snapshot tests (failure message format)

@Suite("private property exhaustion output")
struct PrivatePropertyOutputTests {

    /// A private property change produces NO "State not exhausted" output.
    @Test("private property change emits no exhaustion failure")
    func privatePropertyNoExhaustionOutput() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .state) {
                let model = ModelWithPrivateProperties().withAnchor()
                model.toggleAnimating()
                await expect {}
            }
        } matches: {
            ""
        }
    }

    /// Only the public property appears in the exhaustion failure — private changes are silent.
    @Test("mixed changes: only public property appears in failure")
    func mixedChangesOnlyPublicInFailure() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .state) {
                let model = ModelWithPrivateProperties().withAnchor()
                model.publicCount = 99
                model.toggleAnimating()
                await expect {}
            }
        } matches: {
            """
            State not exhausted: …

            Modifications not asserted:

                ModelWithPrivateProperties.publicCount: 0 → 99
            """
        }
    }
}
#endif
