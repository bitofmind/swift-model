import Testing
import SwiftModel

// Coverage for the per-property index table the `@Model` macro emits on `_State`
// (`_trackedPropertyCount`, `_trackedPropertyKeyPaths`) and the `_ModelStateType`
// lookup (`_trackedPropertyIndex(of:)`). The table is framework-facing groundwork:
// nothing on the read/write path consumes it yet. These tests pin the contract the
// follow-up relies on — the index set is exactly the `_State` field set, in
// declaration order, and every key path round-trips through the lookup.

@Model private struct IndexChild {
    var value = 0
}

/// Mixes every property shape the macro treats differently: a `let` (never in `_State`),
/// plain `var`s, a `var` with `didSet`, a child model, an optional child, and a collection.
@Model private struct IndexModel {
    let tag = "tag"
    var name = "name"
    var count = 0 {
        didSet { didSetCount += 1 }
    }
    var didSetCount = 0
    var child = IndexChild()
    var optionalChild: IndexChild? = nil
    var items: [IndexChild] = []
}

/// Only `let` fields: no `_State` is generated and `_ModelState` is `_EmptyModelState`.
@Model private struct NoTrackedModel {
    let tag = 1
}

/// A generic `@Model` makes `_State` generic too — the table must still compile and
/// resolve per specialisation.
@Model private struct GenericIndexModel<T: Sendable & Equatable> {
    var value: T
    var flag = false
}

struct TrackedPropertyIndexTests {
    private typealias State = IndexModel._State

    @Test func countMatchesStateFieldCount() {
        // `_State` has a default for every field, so the memberwise init takes no arguments.
        let fieldCount = Mirror(reflecting: State()).children.count
        #expect(fieldCount == 6)
        #expect(State._trackedPropertyCount == fieldCount)
        #expect(State._trackedPropertyKeyPaths.count == fieldCount)
        #expect(IndexModel._ModelState._trackedPropertyCount == fieldCount)
    }

    @Test func indicesFollowDeclarationOrder() {
        let expected: [PartialKeyPath<State>] = [
            \State.name, \State.count, \State.didSetCount, \State.child, \State.optionalChild, \State.items,
        ]
        #expect(State._trackedPropertyKeyPaths == expected)
        #expect(State._trackedPropertyIndex(of: \State.name) == 0)
        #expect(State._trackedPropertyIndex(of: \State.count) == 1)
        #expect(State._trackedPropertyIndex(of: \State.didSetCount) == 2)
        #expect(State._trackedPropertyIndex(of: \State.child) == 3)
        #expect(State._trackedPropertyIndex(of: \State.optionalChild) == 4)
        #expect(State._trackedPropertyIndex(of: \State.items) == 5)
    }

    @Test func everyKeyPathRoundTripsThroughIndex() {
        for (index, path) in State._trackedPropertyKeyPaths.enumerated() {
            #expect(State._trackedPropertyIndex(of: path) == index)
        }
    }

    @Test func letPropertyHasNoIndex() {
        // `tag` is a `let` on the model, so it is not a `_State` field at all — `\State.tag`
        // does not even type-check. The nearest runtime check: a `_State` key path that is
        // not a tracked field (the identity path) has no index either.
        #expect(State._trackedPropertyIndex(of: \State.self) == nil)
        #expect(!State._trackedPropertyKeyPaths.contains(\State.self))
    }

    @Test func modelWithoutTrackedPropertiesHasEmptyTable() {
        #expect(NoTrackedModel._ModelState.self == _EmptyModelState.self)
        #expect(NoTrackedModel._ModelState._trackedPropertyCount == 0)
        #expect(NoTrackedModel._ModelState._trackedPropertyKeyPaths.isEmpty)
        #expect(NoTrackedModel._ModelState._trackedPropertyIndex(of: \_EmptyModelState.self) == nil)
    }

    @Test func genericModelResolvesPerSpecialisation() {
        typealias IntState = GenericIndexModel<Int>._State
        typealias StringState = GenericIndexModel<String>._State
        #expect(IntState._trackedPropertyCount == 2)
        #expect(IntState._trackedPropertyKeyPaths == [\IntState.value, \IntState.flag])
        #expect(IntState._trackedPropertyIndex(of: \IntState.value) == 0)
        #expect(IntState._trackedPropertyIndex(of: \IntState.flag) == 1)
        #expect(StringState._trackedPropertyIndex(of: \StringState.value) == 0)
        #expect(StringState._trackedPropertyIndex(of: \StringState.flag) == 1)
    }
}
