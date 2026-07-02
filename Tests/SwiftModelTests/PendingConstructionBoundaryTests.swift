import Foundation
import Testing
import ConcurrencyExtras
@testable import SwiftModel

// MARK: - The thread-local pending-construction boundary
//
// `@Model` init accessors accumulate property values on a thread-local stack of
// `PendingStorage` frames (`_PendingStack` in ModelSourceBox.swift). Historically a
// store merged into the top frame whenever its `_State` type matched — with no notion
// of which *construction* the frame belongs to. A same-type construction that begins
// while another's frame is still open would therefore merge into (and its pop would
// steal) the outer construction's frame: values bleed across instances, the outer
// frame's `pendingID` is adopted by the wrong instance, and the outer construction
// re-evaluates default expressions it had already evaluated (observable with impure
// defaults such as `UUID()` or counters, and as doubled side effects).
//
// When can a same-type construction start while a frame is open? Empirically (verified
// on the current toolchain, and pinned by the tests below):
//
//   * Init accessors fire ONLY in the init prologue — every tracked property with an
//     initializer fires its accessor there, in declaration order, even when the init
//     body also assigns the property (no suppression); body assignments are plain
//     setter calls routed via `_storePendingIfNeeded`. `_$modelSource`'s default (the
//     pop) also fires in the prologue, after all user-property defaults.
//   * A memberwise construction evaluates default arguments at the call site, so no
//     user code runs while its frame is open.
//
// The only window in which user code runs with an open frame is therefore the
// evaluation of a *default-value expression* in a user-written init's prologue. If
// that expression (transitively) constructs the same model type — e.g. through a
// conditional factory or registry — the nested construction's prologue stores used to
// merge into the outer frame. The `DefaultExpr*` tests below fail on the old
// type-only merging and pass with per-construction frame boundaries.

// MARK: - Audit shape 1: nested same-type construction in a user-written init body

@Model
private struct RecursiveNode {
    var v: Int
    var child: RecursiveNode?

    init(v: Int, depth: Int) {
        self.v = v
        self.child = depth > 0 ? RecursiveNode(v: v + 100, depth: depth - 1) : nil
    }
}

// MARK: - Audit shape 2: throwing user-written init

private struct BoundaryError: Error {}

@Model
private struct ThrowingBoundaryModel {
    var a: Int
    var b = 17
    var c: String

    init(a: Int, c: String, fail: Bool) throws {
        self.a = a
        if fail { throw BoundaryError() }
        self.c = c
    }
}

// MARK: - Same-type construction inside the FIRST default-value expression
//
// `first` (index 0, defaulted) gives the nested construction a `_threadLocalStoreFirst`
// entry while the outer frame is open. `derived`'s default conditionally constructs a
// sibling of the same type — the realistic stand-in for factory/registry patterns.

@Model
private struct DefaultExprNestingModel {
    var first: Int = DefaultExprFactory.nextTick()
    var derived: Int = DefaultExprFactory.makeNestedOnce()
    var tail: Int

    init(tail: Int) {
        self.tail = tail
    }

    init(first: Int, derived: Int, tail: Int) {
        self.first = first
        self.derived = derived
        self.tail = tail
    }
}

private enum DefaultExprFactory {
    static let ticks = LockIsolated(0)
    static let armed = LockIsolated(false)
    static let nestedValues = LockIsolated<[Int]>([])

    static func nextTick() -> Int {
        ticks.withValue { tick in
            tick += 1
            return tick
        }
    }

    /// Armed: constructs a sibling of the same model type (disarming first, so the
    /// sibling's own prologue doesn't recurse). Disarmed: inert.
    static func makeNestedOnce() -> Int {
        guard armed.value else { return -1 }
        armed.setValue(false)
        let nested = DefaultExprNestingModel(first: 1000, derived: 2000, tail: 3000)
        nestedValues.setValue([nested.first, nested.derived, nested.tail])
        return nested.first
    }
}

// MARK: - Same-type construction inside a MIDDLE default-value expression
//
// Here index 0 (`head`) has no default, so the nested construction's first prologue
// store is a *middle* accessor for `mid` — the boundary must be detected by the
// keypath collision with the outer frame's already-stored `mid`, not by
// `_threadLocalStoreFirst`.

@Model
private struct MiddleDefaultNestingModel {
    var head: Int
    var mid: Int = MiddleDefaultFactory.nextTick()
    var nest: Int = MiddleDefaultFactory.makeNestedOnce()
    var tail: Int

    init(head: Int, tail: Int) {
        self.head = head
        self.tail = tail
    }

    init(head: Int, mid: Int, nest: Int, tail: Int) {
        self.head = head
        self.mid = mid
        self.nest = nest
        self.tail = tail
    }
}

private enum MiddleDefaultFactory {
    static let ticks = LockIsolated(0)
    static let armed = LockIsolated(false)
    static let nestedValues = LockIsolated<[Int]>([])

    static func nextTick() -> Int {
        ticks.withValue { tick in
            tick += 1
            return tick
        }
    }

    static func makeNestedOnce() -> Int {
        guard armed.value else { return -1 }
        armed.setValue(false)
        let nested = MiddleDefaultNestingModel(head: 10, mid: 20, nest: 30, tail: 40)
        nestedValues.setValue([nested.head, nested.mid, nested.nest, nested.tail])
        return nested.mid
    }
}

// MARK: - Tests

@Suite(.modelTesting(exhaustivity: .off))
private struct PendingConstructionBoundaryTests {

    /// Audit shape: a recursive `@Model` whose user-written init constructs a nested
    /// same-type instance in its body. On the current toolchain the outer frame is
    /// already popped (prologue) when the body runs, so the nested construction sees a
    /// clean stack — this test pins that assumption AND guards the boundary rules on
    /// any toolchain that fires init accessors from body assignments instead.
    @Test func nestedSameTypeConstructionInInitBody() async {
        let root = RecursiveNode(v: 1, depth: 3)

        #expect(root.v == 1)
        #expect(root.child?.v == 101)
        #expect(root.child?.child?.v == 201)
        #expect(root.child?.child?.child?.v == 301)
        #expect(root.child?.child?.child?.child == nil)

        // Every node in the chain must have its own identity — a merged/stolen
        // pending frame would duplicate a pendingID down the chain.
        let anchored = root.withAnchor()
        let ids = [
            anchored.modelID,
            anchored.child?.modelID,
            anchored.child?.child?.modelID,
            anchored.child?.child?.child?.modelID,
        ].compactMap { $0 }
        #expect(Set(ids).count == 4)

        // Mutations stay isolated per node.
        anchored.child?.v = -5
        await expect { anchored.v == 1 && anchored.child?.v == -5 && anchored.child?.child?.v == 201 }
    }

    /// Audit shape: an aborted (throwing) init must not poison the next same-type
    /// construction on the same thread with stale pending values or a reused
    /// pendingID.
    @Test func throwingInitLeavesNoResidueForNextConstruction() async {
        #expect(throws: BoundaryError.self) {
            _ = try ThrowingBoundaryModel(a: 99, c: "doomed", fail: true)
        }

        let fresh = try! ThrowingBoundaryModel(a: 1, c: "ok", fail: false)
        #expect(fresh.a == 1)
        #expect(fresh.b == 17)
        #expect(fresh.c == "ok")

        // And a second, independent construction gets its own identity.
        let second = try! ThrowingBoundaryModel(a: 2, c: "two", fail: false)
        let a = fresh.withAnchor()
        let b = second.withAnchor()
        #expect(a.modelID != b.modelID)
        #expect(a.a == 1 && b.a == 2)
    }

    /// RED before the per-construction boundary fix: the nested sibling's prologue
    /// stores merged into the outer construction's open frame and its pop stole the
    /// frame, so the outer construction re-evaluated `first`'s (impure) default —
    /// `outer.first` ended up as a third tick instead of the first, and the tick
    /// counter showed 3 evaluations for 2 constructions.
    @Test func sameTypeConstructionInsideFirstDefaultExpression() {
        DefaultExprFactory.ticks.setValue(0)
        DefaultExprFactory.nestedValues.setValue([])
        DefaultExprFactory.armed.setValue(true)

        let outer = DefaultExprNestingModel(tail: 9)

        // One default evaluation per construction: outer's prologue (tick 1) and the
        // nested sibling's prologue (tick 2). No re-evaluation.
        #expect(DefaultExprFactory.ticks.value == 2)
        #expect(outer.first == 1, "outer must keep its own first default evaluation")
        #expect(outer.derived == 1000)
        #expect(outer.tail == 9)
        // The nested sibling's user init assigns all properties in its body.
        #expect(DefaultExprFactory.nestedValues.value == [1000, 2000, 3000])
    }

    /// Same as above, but the model's first defaulted property is a *middle* accessor
    /// (index 0 has no default) — exercises the keypath-collision boundary rather than
    /// the `_threadLocalStoreFirst` boundary.
    @Test func sameTypeConstructionInsideMiddleDefaultExpression() {
        MiddleDefaultFactory.ticks.setValue(0)
        MiddleDefaultFactory.nestedValues.setValue([])
        MiddleDefaultFactory.armed.setValue(true)

        let outer = MiddleDefaultNestingModel(head: 5, tail: 9)

        #expect(MiddleDefaultFactory.ticks.value == 2)
        #expect(outer.head == 5)
        #expect(outer.mid == 1, "outer must keep its own mid default evaluation")
        #expect(outer.nest == 20)
        #expect(outer.tail == 9)
        #expect(MiddleDefaultFactory.nestedValues.value == [10, 20, 30, 40])
    }
}
