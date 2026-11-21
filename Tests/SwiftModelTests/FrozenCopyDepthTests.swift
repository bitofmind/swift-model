import Testing
@testable import SwiftModel

// Regression tests for a shallow `frozenCopy`. The transform visitor freezes a parent
// before its children and then writes each frozen child back into the parent, which by
// then is itself a frozen copy. A frozen copy's setters drop writes unless a snapshot is
// being applied, so every write-back was silently lost: only the root got a new
// `Reference`, and every child kept the source's.
//
// That broke `TestAccess.checkExhaustion`, which deep-copies `lastState` under its lock
// so the diff can walk it outside the lock. `didModify` mutates `lastState`'s frozen
// children in place, so the diff walked nodes another thread was writing, through the
// unlocked snapshot read. Reported stack (parallel-apple editor tests, SIGBUS/SIGSEGV):
//   swift_retain ← initializeWithCopy (<Model>._State) ← _ModelSourceBox._directRead
//   ← customMirror ← isMirrorEqual ← diffMessage ← TestAccess.checkExhaustion
//
// The race itself is a few instructions wide and needs a freed field to be reused before
// the stale retain, so these tests check the structural cause deterministically instead.
struct FrozenCopyDepthTests {
    @Test func frozenCopyRebuildsEveryNode() {
        let live = DepthParent().withAnchor()
        let frozen = frozenCopy(live)
        let refrozen = frozenCopy(frozen)

        for (source, copy) in [(live, frozen), (frozen, refrozen)] {
            #expect(ref(source) != ref(copy))
            #expect(ref(source.child) != ref(copy.child))
            #expect(ref(source.child.grandchild) != ref(copy.child.grandchild))
            #expect(ref(source.items[0]) != ref(copy.items[0]))
            #expect(ref(source.optional!) != ref(copy.optional!))
        }
        #expect(frozen.child.lifetime == .frozenCopy)
        #expect(frozen.child.grandchild.lifetime == .frozenCopy)
        #expect(frozen.items[1].lifetime == .frozenCopy)
        #expect(frozen.optional?.lifetime == .frozenCopy)
    }

    // The `checkExhaustion` shape: copy a `lastState`-like tree, then mutate the tree's
    // frozen child in place the way `didModify` does. The copy must not see the write.
    @Test func inPlaceWriteToSourceDoesNotReachCopy() {
        let tree = frozenCopy(DepthParent().withAnchor())
        let copy = frozenCopy(tree)

        // `didModify` writes `lastState` through `_writeToFrozenState`, not the setter chain.
        tree.child.modelContext._source._writeToFrozenState(\DepthChild._ModelState.value, 1)
        tree.child.grandchild.modelContext._source._writeToFrozenState(\DepthGrandchild._ModelState.value, 2)
        tree.items[0].modelContext._source._writeToFrozenState(\DepthChild._ModelState.value, 3)

        #expect(tree.child.value == 1)
        #expect(tree.child.grandchild.value == 2)
        #expect(tree.items[0].value == 3)
        #expect(copy.child.value == 0)
        #expect(copy.child.grandchild.value == 0)
        #expect(copy.items[0].value == 0)
    }

    private func ref<M: Model>(_ model: M) -> ObjectIdentifier {
        ObjectIdentifier(model.modelContext._source.reference)
    }
}

@Model private struct DepthParent {
    var child = DepthChild()
    var items: [DepthChild] = [DepthChild(), DepthChild()]
    var optional: DepthChild? = DepthChild()
}

@Model private struct DepthChild {
    var value = 0
    var grandchild = DepthGrandchild()
}

@Model private struct DepthGrandchild {
    var value = 0
}
