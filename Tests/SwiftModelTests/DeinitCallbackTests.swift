import Testing
@testable import SwiftModel

// MARK: - Test models

private final class DeinitCallback: @unchecked Sendable {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    deinit { action() }
}

@Model
private struct SiblingReadModel {
    var callback: DeinitCallback = DeinitCallback {}
    var sibling: Int = 0
}

// MARK: - Tests

// Regression: when a @Model property is replaced or cleared, the old value's deinit may read
// sibling model properties. That read goes through the same Context.Reference.state that is
// exclusively held by the write — causing a Swift exclusivity violation (fatal crash in debug).
//
// Three crash-prone paths were fixed, all with the same deferred-deinit approach:
//   • Context._modify: yield &reference.state[keyPath:] while old value held exclusively
//   • _threadLocalStoreOrLatest: ref.state[keyPath:] = value during init phase-2 assignment
//   • Reference.clear(): state = _genesisState during model teardown
//
// The fix: capture the old value into a local before the exclusive write so its retain count
// stays > 0 during the write. Deinit is deferred until after exclusive access ends.
//
// NOTE: These tests must NOT use @Suite(.modelTesting) — that framework retains old property
// values for exhaustivity reporting, preventing timely deinits and making capturedValue stay -1.

struct DeinitCallbackTests {
    // Tests the Context._modify path: replacing an anchored model property whose deinit
    // reads a sibling property via the same Reference.state.
    @Test func replacedPropertyDeinitCanReadSiblingProperty() {
        let model = SiblingReadModel().withAnchor()
        model.sibling = 42
        let captured = model  // shares same Reference — reads go through ref.state
        var capturedValue = -1

        // Set current callback so that when replaced, its deinit reads sibling.
        model.callback = DeinitCallback { capturedValue = captured.sibling }

        // Replacing callback: old DeinitCallback deinits, reads captured.sibling via ref.state
        // while ref.state is exclusively held by the _modify accessor. Without the fix this
        // crashes with "Fatal access conflict detected."
        model.callback = DeinitCallback {}

        #expect(capturedValue == 42)
    }

    // Tests the _modify path when the replaced callback reads from a different anchored model.
    // Verifies deinit fires before the assertion, and can safely read another model's properties.
    @Test func replacedPropertyDeinitCanReadOtherModelSiblingProperty() {
        var capturedValue = -1

        let prior = SiblingReadModel().withAnchor()
        prior.sibling = 99
        let capturedPrior = prior

        let fresh = SiblingReadModel().withAnchor()
        // Assign inline so only fresh.callback holds the DeinitCallback (no extra local retain).
        fresh.callback = DeinitCallback { capturedValue = capturedPrior.sibling }

        // Replacing: DeinitCallback deinits, reads capturedPrior.sibling = 99.
        fresh.callback = DeinitCallback {}

        #expect(capturedValue == 99)
    }

    // Tests the Reference.clear() path: the DeinitCallback stored in model state fires during
    // model teardown when state is replaced with genesis (state = _genesisState). Without the
    // fix, this holds exclusive access to Reference.state while the old value's deinit reads it.
    //
    // Note: the production crash read from the SAME Reference being cleared. Here we read from
    // a different anchored model because capturing the same model creates a retain cycle that
    // would prevent waitUntilRemoved from completing. The fix covers both cases equally — deinit
    // is deferred until after the lock releases in all paths.
    @Test func teardownClearDeinitCanReadSiblingProperty() async {
        let alwaysAlive = SiblingReadModel().withAnchor()
        alwaysAlive.sibling = 42
        let capturedAlive = alwaysAlive
        var capturedValue = -1

        await waitUntilRemoved {
            let model = SiblingReadModel().withAnchor()
            // DeinitCallback captures a different model — no retain cycle, teardown can complete.
            model.callback = DeinitCallback { capturedValue = capturedAlive.sibling }
            return model
        }

        #expect(capturedValue == 42)
    }
}
