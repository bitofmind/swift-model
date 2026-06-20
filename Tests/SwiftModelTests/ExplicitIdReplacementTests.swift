import Testing
@testable import SwiftModel

// Characterization of SwiftModel's child-identity semantics for `@Model`s with an EXPLICIT,
// reusable Identifiable `id` (e.g. imagien-apple's StreamModel `let id: StreamID`). These tests
// document DESIGNED behavior, not a bug fix — they pass on stock SwiftModel.
//
// SwiftModel keys child-context identity by the element's Identifiable `.id` (Context.swift
// `childContextForCollection` etc.). For a default-`id` @Model `.id` IS the globally-unique
// `ModelID`; for an explicit reusable id it is the domain id. The contract is the ForEach /
// IdentifiedArray stable-identity model: **same `.id` = the same logical child**. Consequences,
// all verified below:
//
//   • Replacing a collection element / reassigning a collection with a NEW instance that has an
//     EXISTING `.id` CONTINUES the existing live child: its context, activation, tasks and state
//     are preserved, and the new instance's birth state is intentionally ignored. The child is the
//     source of truth for its own state — to change it you MUTATE it, you do not replace it. (See
//     ActivateTests.testChildrenCaseActivation, which depends on this continuity.)
//   • Because nothing about the live child changed, such a reassignment fires no observation.
//   • A DIFFERENT `.id` is a different child: fresh context, new state.
//
// The one genuinely sharp edge is two DISTINCT instances sharing one `.id` in a single collection
// at the same instant — that violates the Identifiable uniqueness contract and conflates them.
//
// FIELD BUG NOTE: the StreamModel "frozen at birth state" symptom is this continuity contract met
// by app misuse — replacing the pool element with a fresh same-id StreamModel (whose new state is
// ignored) and/or binding the view to that fresh, never-anchored instance instead of mutating the
// live pool child. The fix is app-side; see the investigation summary.

@Suite(.modelTesting)
struct ExplicitIdReplacementTests {
    // Continuity: a captured value and the live slot share the one reused context after a same-id
    // in-place replacement, so the captured value reflects subsequent live mutations.
    @Test func capturedChildFollowsLiveAfterSameIdReplace() async {
        let pool = ExIdPool(items: [ExIdItem(id: 1)]).withAnchor()
        await settle {}
        let captured = pool.items[0]
        pool.items[0] = ExIdItem(id: 1, value: 0)   // new instance, same id → continues child
        pool.items[0].value = 42                     // mutate the (continued) live child
        await expect { pool.items[0].value == 42 }
        await expect { captured.value == 42 }
    }

    @Test func mutationThroughCapturedReachesLiveAfterSameIdReplace() async {
        let pool = ExIdPool(items: [ExIdItem(id: 1)]).withAnchor()
        await settle {}
        let captured = pool.items[0]
        pool.items[0] = ExIdItem(id: 1, value: 0)
        captured.value = 7
        await expect { pool.items[0].value == 7 }
    }
}

// Identity probes. Exhaustivity off: these read `.context` identity and use `#expect` directly
// rather than driving the reactive system.
@Suite(.modelTesting(exhaustivity: .off))
struct ExplicitIdReconcileTests {
    // Same-id replacement REUSES the existing context (continuity) and DISCARDS the new instance's
    // state. To change the child you mutate it; replacing with a fresh same-id instance is a no-op
    // for state. This is the behavior that surprised the field user.
    @Test func sameIdReplaceReusesContextAndDiscardsNewState() async {
        let pool = ExIdPool(items: [ExIdItem(id: 1, value: 99)]).withAnchor()
        await settle {}
        let before = ObjectIdentifier(pool.items[0].context!)
        pool.items[0] = ExIdItem(id: 1, value: 5)
        await settle {}
        #expect(ObjectIdentifier(pool.items[0].context!) == before)  // context reused (continuity)
        #expect(pool.items[0].value == 99)                           // new state discarded
    }

    // A DIFFERENT id is a different child: fresh context, new state applied.
    @Test func differentIdReplaceMakesNewContext() async {
        let pool = ExIdPool(items: [ExIdItem(id: 1, value: 99)]).withAnchor()
        await settle {}
        let before = ObjectIdentifier(pool.items[0].context!)
        pool.items[0] = ExIdItem(id: 2, value: 5)
        await settle {}
        #expect(ObjectIdentifier(pool.items[0].context!) != before)
        #expect(pool.items[0].value == 5)
    }

    // Removal tears the context down; a later same-id re-add is a genuinely new identity, and a
    // value captured before removal stays pinned to the destructed context.
    @Test func capturedValuePinnedAcrossRemoveAndReadd() async {
        let pool = ExIdPool(items: [ExIdItem(id: 1, value: 11)]).withAnchor()
        await settle {}
        let captured = pool.items[0]
        pool.items.removeAll()
        await settle {}
        pool.items.append(ExIdItem(id: 1, value: 22))   // same reusable domain id, new instance
        await settle {}
        // The re-added instance is live with its own new state.
        #expect(pool.items[0].context != nil)
        #expect(pool.items[0].value == 22)
        // The captured value is pinned to its (torn-down) instance and does NOT follow the
        // re-added one — it reads its last-seen state, not 22. (Don't compare context
        // ObjectIdentifiers across teardown: a freed context's address can be reused.)
        #expect(captured.value == 11)
    }

    // SHARP EDGE: two DISTINCT instances sharing one `.id` in a single collection are conflated
    // onto one context (the second resolves to the first), and the second's state is lost. This
    // violates the Identifiable/ForEach uniqueness contract; SwiftModel does not currently
    // diagnose it (SwiftUI's ForEach reports a runtime issue for duplicate ids). Recommended
    // framework improvement: a DEBUG `reportIssue` for duplicate ids in one collection.
    @Test func duplicateDomainIdConflatesContexts() async {
        let pool = ExIdPool(items: [ExIdItem(id: 1, value: 10), ExIdItem(id: 1, value: 20)]).withAnchor()
        await settle {}
        let c0 = pool.items[0].context.map(ObjectIdentifier.init)
        let c1 = pool.items[1].context.map(ObjectIdentifier.init)
        #expect(c0 == c1)                   // conflated onto a single context
        #expect(pool.items[1].value == 10)  // index 1 reads index 0's state
    }

    // A duplicate-id collection WRITE now emits a DEBUG diagnostic (mirrors SwiftUI ForEach).
    @Test func duplicateIdOnCollectionWriteEmitsDiagnostic() async {
        let pool = ExIdPool(items: [ExIdItem(id: 1, value: 10)]).withAnchor()
        await settle {}
        withKnownIssue("duplicate ids in a model collection are diagnosed in DEBUG") {
            pool.items = [ExIdItem(id: 2, value: 1), ExIdItem(id: 2, value: 2)]
        }
    }
}

@Model fileprivate struct ExIdPool { var items: [ExIdItem] = [] }
@Model fileprivate struct ExIdItem { let id: Int; var value: Int = 0 }

// Same-explicit-id replacement is INCONSISTENT across child shapes. These assert the CURRENT
// behavior; the `optionalChild` case is a genuine bug (see comment).
@Suite(.modelTesting(exhaustivity: .off))
struct ExplicitIdShapeMatrixTests {
    // Single `var child: M`: REPLACEMENT — new context, new state applied. (The single-Model write
    // path skips by `modelID` and does removeChild + updateContext.)
    @Test func singleChild_sameIdReplace() async {
        let p = SMParent(child: SMChild(id: 1, value: 99)).withAnchor()
        await settle {}
        let before = p.child.context.map(ObjectIdentifier.init)
        p.child = SMChild(id: 1, value: 5)
        await settle {}
        #expect(p.child.context != nil)                                    // anchored
        #expect(p.child.context.map(ObjectIdentifier.init) != before)      // new context
        #expect(p.child.value == 5)                                        // new state applied
    }

    // Collection `var items: [M]`: CONTINUITY — context reused, new state discarded.
    @Test func collectionChild_sameIdReplace() async {
        let p = ExIdPool(items: [ExIdItem(id: 1, value: 99)]).withAnchor()
        await settle {}
        let before = p.items[0].context.map(ObjectIdentifier.init)
        p.items[0] = ExIdItem(id: 1, value: 5)
        await settle {}
        #expect(p.items[0].context.map(ObjectIdentifier.init) == before)   // context reused
        #expect(p.items[0].value == 99)                                    // new state discarded
    }

    // Optional `var child: M?`: same-id replacement now keeps the child ANCHORED and follows the
    // collection CONTINUITY semantics (context reused, new instance's state discarded). Previously
    // this left the child unanchored (nil context) — the ModelContainer write fast-path stored the
    // pre-anchor value raw; that fast path was removed. (Different-id replace and nil→set already
    // anchored correctly.)
    @Test func optionalChild_sameIdReplace_staysAnchored() async {
        let p = OMParent(child: OMChild(id: 1, value: 99)).withAnchor()
        await settle {}
        let before = p.child?.context.map(ObjectIdentifier.init)
        #expect(before != nil)                                             // initially anchored
        p.child = OMChild(id: 1, value: 5)
        await settle {}
        #expect(p.child?.context != nil)                                   // FIXED: still anchored
        #expect(p.child?.context.map(ObjectIdentifier.init) == before)     // context reused
        #expect(p.child?.value == 99)                                      // continuity: old state
    }

    @Test func optionalChild_differentIdReplace_isAnchored() async {
        let p = OMParent(child: OMChild(id: 1, value: 99)).withAnchor()
        await settle {}
        p.child = OMChild(id: 2, value: 5)
        await settle {}
        #expect(p.child?.context != nil)                                   // control: anchored
        #expect(p.child?.value == 5)
    }
}

@Model fileprivate struct SMParent { var child: SMChild }
@Model fileprivate struct SMChild { let id: Int; var value: Int = 0 }
@Model fileprivate struct OMParent { var child: OMChild? }
@Model fileprivate struct OMChild { let id: Int; var value: Int = 0 }
