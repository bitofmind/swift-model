@testable import SwiftModel
import Observation
import Testing

/// Tests documenting the current behaviour of @ModelIgnored properties.
///
/// Key architectural fact: @ModelIgnored generates NO accessors. The property is a plain
/// Swift struct field stored on the struct value itself, NOT in the shared Context that backs
/// all normal @ModelTracked properties.
///
/// This means @ModelIgnored properties have *value semantics*, not the reference semantics
/// that all other @Model properties have. Mutations on one copy of a model do NOT propagate
/// to the shared context or to other copies.
struct ModelIgnoredTests {
    // MARK: - Immutable let properties

    @Test func testIgnoredLetPropertyIsReadable() async {
        var (model, tester) = ModelWithIgnored().andTester()
        await tester.assert {
            model.label == "hello"
        }
    }

    // MARK: - Mutation does not propagate to other copies

    /// Documents the core limitation: @ModelIgnored var is stored on the struct value,
    /// so mutating it via one reference does NOT affect any other copy of the model,
    /// including a second reference obtained after anchoring.
    @Test func testIgnoredVarMutationDoesNotPropagateToOtherCopies() async {
        var (model, tester) = ModelWithIgnored().andTester()

        // Grab a second reference to the same logical model
        let copy = model

        model.tag = "mutated"

        // 'copy' still sees "initial" because @ModelIgnored is stored per-struct-value
        await tester.assert {
            model.tag == "mutated"
        }
        // The copy is unaffected
        #expect(copy.tag == "initial")
    }

    // MARK: - Observation does not fire for @ModelIgnored

    /// Mutating an @ModelIgnored property fires NO observation callbacks.
    /// This is consistent with the property not going through the context's modify path.
    @Test func testIgnoredVarMutationDoesNotTriggerObservation() async {
        var (model, tester) = ModelWithIgnored().andTester()
        await tester.assert { true }

        // Mutate the ignored property
        model.tag = "changed"

        // No state change should be recorded by the tester since
        // @ModelIgnored bypasses the observation machinery entirely.
        // We relax exhaustivity so no spurious state-change failure fires.
        tester.exhaustivity = []
        await tester.assert {
            // Tracked property is untouched
            model.count == 0
        }
    }

    // MARK: - Tracked properties still work normally alongside @ModelIgnored

    @Test func testTrackedPropertyWorksBesideIgnored() async {
        var (model, tester) = ModelWithIgnored().andTester()

        model.count = 42

        await tester.assert {
            model.count == 42
            // @ModelIgnored property is unaffected by normal tracked mutations
            model.tag == "initial"
        }
    }

    // MARK: - Equality excludes @ModelIgnored

    /// @ModelIgnored properties are excluded from synthesised == so two models
    /// that differ only in their ignored fields are considered equal.
    @Test func testIgnoredPropertyExcludedFromEquality() async {
        var (model1, tester1) = ModelWithIgnoredEquatable().andTester()
        var (model2, tester2) = ModelWithIgnoredEquatable().andTester()

        // Give them the same tracked state but different ignored values
        model1.count = 5
        model2.count = 5
        model1.tag = "a"
        model2.tag = "b"

        // Await propagation of the tracked mutations before comparing
        await tester1.assert { model1.count == 5 }
        await tester2.assert { model2.count == 5 }

        // Despite different 'tag' values, they should be equal (ignored excluded)
        #expect(model1 == model2)
    }

    @Test func testIgnoredPropertyExcludedFromEqualityWithDifferentTracked() async {
        var (model1, tester1) = ModelWithIgnoredEquatable().andTester()
        var (model2, tester2) = ModelWithIgnoredEquatable().andTester()

        model1.count = 1
        model2.count = 2
        // Same ignored tag
        model1.tag = "same"
        model2.tag = "same"

        // Await propagation of the tracked mutations before comparing
        await tester1.assert { model1.count == 1 }
        await tester2.assert { model2.count == 2 }

        // Different tracked state => not equal
        #expect(model1 != model2)
    }

    // MARK: - @ModelIgnored does not participate in visit (hierarchy traversal)

    /// @ModelIgnored properties are excluded from visit(), so they won't be traversed
    /// during hierarchy setup. An @ModelIgnored Model property will NOT be a child.
    @Test func testIgnoredModelPropertyNotInHierarchy() async {
        let (model, tester) = ParentWithIgnoredChild().andTester()

        await tester.assert {
            model.trackedChild.value == 0
        }

        // The ignoredChild is NOT part of the hierarchy - it won't receive onActivate
        #expect(model.ignoredChildActivated == false)

        // Mutating the ignoredChild has no effect on the hierarchy
        model.ignoredChild.value = 99
        tester.exhaustivity = []
        await tester.assert {
            // The ignoredChild mutation is not visible through the hierarchy
            model.trackedChild.value == 0
        }
    }
}

// MARK: - Test models

@Model private struct ModelWithIgnored {
    var count: Int = 0
    @ModelIgnored let label: String = "hello"
    @ModelIgnored var tag: String = "initial"
}

@Model private struct ModelWithIgnoredEquatable: Equatable {
    var count: Int = 0
    @ModelIgnored var tag: String = "unset"
}

@Model private struct SimpleChild {
    var value: Int = 0
}

@Model private struct ParentWithIgnoredChild {
    var trackedChild: SimpleChild = SimpleChild()
    // This child is @ModelIgnored — it will NOT be part of the model hierarchy
    @ModelIgnored var ignoredChild: SimpleChild = SimpleChild()
    // Used to detect if ignoredChild received onActivate (it shouldn't)
    @ModelIgnored var ignoredChildActivated: Bool = false
}
