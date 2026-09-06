import Testing
import Observation
import ConcurrencyExtras
@testable import SwiftModel
import SwiftModel

// The macro-generated accessors identify a tracked property to the framework by its
// declaration-order INDEX (an `Int` literal) and hand over the projection / write-back as
// closures; the key path is only an autoclosure evaluated by key-path-keyed consumers
// (`TestAccess`, undo, `excludeFromModifications`, the gap shadow). These tests pin the
// edges where the two sides must agree: the literal index the accessor passes must name the
// same `_State` field as `_trackedPropertyKeyPaths[index]`, whatever non-tracked members are
// interleaved with it, and every per-context table keyed by that index (registrar identity
// tokens, `onModify` callbacks, exclusions) must be per property and per instance.

@Model private struct IndexedChild: Sendable {
    var value = 0
}

/// Tracked fields interleaved with every member shape that has NO `_State` field — a `let`,
/// an `@_ModelIgnored` var, a computed property, a private property, a `didSet` property, a
/// child model and a tuple — so the accessor's index and the field order have to line up.
@Model private struct InterleavedModel: Sendable {
    let id: Int
    var first = 1                                   // index 0
    @_ModelIgnored var ignored = "ignored"
    var sum: Int { first + second }
    var second = 2                                  // index 1
    var child = IndexedChild()                      // index 2
    var pair: (Int, String) = (0, "")               // index 3 (parameter-pack overload)
    var name = "name" {                             // index 4 (willSet/didSet setter form)
        didSet { nameChanges += 1 }
    }
    var nameChanges = 0                             // index 5
    private var secret = 0                          // index 6
    var third = 3                                   // index 7

    // `secret` is private, which makes the memberwise init private too.
    init(id: Int) { self.id = id }

    var secretValue: Int { secret }
    func bumpSecret() { secret += 1 }
}

/// A generic `@Model`: `_State` is generic, the key-path literals are not interned by the
/// runtime, and the table is computed per specialisation.
@Model private struct GenericModel<T: Sendable & Equatable>: Sendable {
    var value: T
    var flag = false
}

/// A `@Model` nested in a generic type — `_State` is generic through its enclosing type.
private enum Host<T: Sendable & Equatable> {
    @Model struct Inner: Sendable {
        var value: T
        var count = 0
    }
}

/// Excludes `second` from `observeModifications()` — the exclusion is registered by key path
/// (through `BackingPathCollector`) and checked on the write path by the accessor's index.
@Model private struct ExcludingModel: Sendable {
    let id = 0
    var first = 0
    @_ModelIgnored var ignored = 0
    var second = 0
    var third = 0

    func onActivate() {
        node.excludeFromModifications(\.second)
        node.forEach(observeModifications()) { _ in
            node.testResult.add("hit")
        }
    }
}

/// `onChange` registrations on two properties of one model — `onModify` callbacks are
/// keyed by index, so each must fire for its own property only.
@Model private struct OnChangeModel: Sendable {
    let id = 0
    var a = 0
    var b = 0

    func onActivate() {
        node.onChange(of: a, initial: false) { _, new in
            node.testResult.add("a\(new)")
        }
        node.onChange(of: b, initial: false) { _, new in
            node.testResult.add("b\(new)")
        }
    }
}

@Suite(.modelTesting)
struct IndexKeyedAccessTests {

    @Test func indicesAgreeWithStateFields() {
        typealias State = InterleavedModel._State
        #expect(State._trackedPropertyCount == 8)
        #expect(State._trackedPropertyIndex(of: \State.first) == 0)
        #expect(State._trackedPropertyIndex(of: \State.second) == 1)
        #expect(State._trackedPropertyIndex(of: \State.child) == 2)
        #expect(State._trackedPropertyIndex(of: \State.pair) == 3)
        #expect(State._trackedPropertyIndex(of: \State.name) == 4)
        #expect(State._trackedPropertyIndex(of: \State.nameChanges) == 5)
        #expect(State._trackedPropertyIndex(of: \State.third) == 7)
    }

    /// Every tracked property of the interleaved model round-trips through the anchored
    /// read/write path — and through `TestAccess`, which records each write by the KEY PATH
    /// the accessor's autoclosure hands it and compares against the value the accessor's
    /// index-keyed write-back stored: a misaligned index would fail these `expect`s.
    @Test func interleavedPropertiesReadAndWriteThroughTheirIndex() async {
        let model = InterleavedModel(id: 7).withAnchor()
        await expect(model.first == 1 && model.second == 2 && model.third == 3)
        #expect(model.id == 7)
        #expect(model.ignored == "ignored")
        #expect(model.sum == 3)

        model.first = 10
        model.second += 20
        model.third = 30
        model.child.value = 4
        model.name = "renamed"
        model.bumpSecret()

        // One predicate over every write: a passing `expect` runs the exhaustion check over
        // whatever is still un-asserted. (`secret` is private — excluded from exhaustivity.)
        await expect(
            model.first == 10 && model.second == 22 && model.third == 30
                && model.child.value == 4 && model.name == "renamed" && model.nameChanges == 1
        )
        #expect(model.secretValue == 1)
        #expect(model.sum == 32)
        #expect(withUntrackedModelReads { model.first + model.second + model.third } == 62)
    }

    /// Tuple properties keep the key-path form of the write (SILGen cannot lower the closure
    /// form for a parameter pack) but are index-keyed downstream like every other property.
    @Test func tuplePropertyWritesThroughBothSetterForms() async {
        let model = InterleavedModel(id: 1).withAnchor()
        await expect(model.pair.0 == 0)

        model.pair = (5, "five")           // `set`
        await expect(model.pair.0 == 5 && model.pair.1 == "five")

        model.pair.0 += 1                  // `_modify`
        await expect(model.pair.0 == 6)

        let frozen = model.frozenCopy
        #expect(frozen.pair.0 == 6 && frozen.pair.1 == "five")
    }

    @Test func genericModelReadsAndWrites() async {
        let model = GenericModel(value: "a").withAnchor()
        await expect(model.value == "a")
        model.value = "b"
        model.flag.toggle()
        await expect(model.value == "b" && model.flag == true)

        let ints = GenericModel(value: 1).returningAnchor()
        ints.model.value += 41
        #expect(withUntrackedModelReads { ints.model.value } == 42)
        withExtendedLifetime(ints.anchor) {}
    }

    @Test func modelNestedInGenericTypeReadsAndWrites() async {
        let model = Host<Double>.Inner(value: 1.5).withAnchor()
        await expect(model.value == 1.5)
        model.value *= 2
        model.count += 1
        await expect(model.value == 3.0 && model.count == 1)
    }

    /// The exclusion is registered by key path and consulted by index on the write path.
    @Test func exclusionRegisteredByKeyPathAppliesToIndexedWrite() async throws {
        let testResult = TestResult()
        let model = ExcludingModel().withAnchor { $0.testResult = testResult }
        await settle()

        model.second = 1
        await expect(model.second == 1)
        await settle()
        #expect(!testResult.value.contains("hit"), "excluded property must not trigger observeModifications()")

        model.third = 1
        await expect(model.third == 1)
        try await waitUntil(testResult.value.contains("hit"))
    }

    /// `onModify` callbacks are keyed by property index: each `onChange` fires for its own
    /// property only, in the order the writes land.
    @Test func onChangeCallbacksAreKeyedPerProperty() async throws {
        let testResult = TestResult()
        let model = OnChangeModel().withAnchor { $0.testResult = testResult }
        await settle()

        model.b = 1
        await expect(model.b == 1)
        try await waitUntil(testResult.value == "b1")

        model.a = 2
        await expect(model.a == 2)
        try await waitUntil(testResult.value == "b1a2")
    }
}

/// Registrar identity tokens are per (context, property): `withObservationTracking` on one
/// property must not fire on a write to another property of the same model, nor on a write
/// to the same property of another instance of the same type.
@Suite(.modelTesting(exhaustivity: .off))
struct IndexKeyedRegistrarIdentityTests {

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func tokensAreDistinctPerPropertyAndPerInstance() async {
        let a = InterleavedModel(id: 1).withAnchor()
        let (b, bAnchor) = InterleavedModel(id: 2).returningAnchor()
        defer { withExtendedLifetime(bAnchor) {} }

        let fired = LockIsolated<[String]>([])
        withObservationTracking {
            _ = a.first
        } onChange: {
            fired.withValue { $0.append("a.first") }
        }
        withObservationTracking {
            _ = a.third
        } onChange: {
            fired.withValue { $0.append("a.third") }
        }
        withObservationTracking {
            _ = b.first
        } onChange: {
            fired.withValue { $0.append("b.first") }
        }

        // Nobody tracks `second`; only the `a.third` tracker sees `third`. Off-main writes
        // notify the background registrar synchronously, so the trackers fire inline.
        a.second = 9
        #expect(fired.value.isEmpty)

        a.third = 9
        #expect(fired.value == ["a.third"])

        b.first = 9
        #expect(fired.value == ["a.third", "b.first"])

        a.first = 9
        #expect(fired.value == ["a.third", "b.first", "a.first"])
    }
}
