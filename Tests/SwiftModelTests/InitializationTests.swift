import Testing
@testable import SwiftModel
import Observation

struct InitializationTests {
    @Test func testMyModel() throws {
        let myModel = MyModel(id: 5, integer: 4)
        Task {
            let _ = MyModel(id: 5, integer: 4)
        }

        #expect(myModel.id == 5)
        #expect(myModel.integer == 4)
    }

    // Regression: Reference.init previously used _zeroInit() for _genesisState, which called
    // initializeWithCopy on zero memory — retaining a nil class pointer crashes.
    // Crash fires at construction time since Reference.init fires inside _threadLocalStoreAndPop.
    @Test func modelWithClassBackedPropertyDoesNotCrashOnInit() {
        _ = ClassBackedModel()
    }

    // Regression: Reference.clear() previously called state = _zeroInit(), crashing in the
    // same way during model teardown. Anchor → destruct exercises the clear() path.
    @Test func modelWithClassBackedPropertyDoesNotCrashOnTeardown() async {
        await waitUntilRemoved {
            ClassBackedModel().withAnchor()
        }
    }

    // Regression: the snapshot Reference.init (frozenCopy/lastSeen) also had _genesisState =
    // _zeroInit(). Creating a frozen copy exercises that path.
    @Test(.modelTesting) func modelWithClassBackedPropertyDoesNotCrashOnFrozenCopy() async {
        let model = ClassBackedModel().withAnchor()
        _ = model.frozenCopy
    }
}

@Model
private struct MyModel {
    let id: Int
    private(set) var integer: Int?
}

// A class-reference-containing value type, analogous to SwiftUI.ScrollPosition.
private final class _BackingObject: Sendable {}
private struct ClassBackedValue: Sendable {
    var ref: _BackingObject = .init()
}

@Model
private struct ClassBackedModel {
    var value: ClassBackedValue = .init()
}
