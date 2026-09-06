import Testing
@testable import SwiftModel

// Regression tests for the collection-write reconcile fast paths (`_performCollectionSet` /
// `_performContainerCollectionSet` → `updateContextForCollection` /
// `updateContextForContainerCollection`): the registration record each child keeps
// (`Reference._registeredPosition`, refreshed when a removal shifts entries), the
// activate-only-what-was-registered rule after a structural change, and the id-sequence
// comparison folded into the reconcile pass. Every scenario pins observable semantics —
// `onActivate` / `onCancel` order via `TestResult`, context identity, stored values — so a
// regression in any fast path shows up as a wrong log or a lost context, not as a timing.

@Suite(.modelTesting(exhaustivity: .off))
struct CollectionReconcileFastPathTests {
    // MARK: `[Model]` — `_performCollectionSet`

    @Test func appendActivatesOnlyTheNewElement() async {
        let testResult = TestResult()
        let list = RcList(items: [RcItem(id: 1), RcItem(id: 2), RcItem(id: 3)]).withAnchor {
            $0.testResult = testResult
        }
        await settle {}
        #expect(testResult.value == "A1A2A3")
        let before = list.items.map { ObjectIdentifier($0.context!) }

        list.items.append(RcItem(id: 4))
        await settle {}
        #expect(testResult.value == "A1A2A3A4")                 // existing elements not re-activated
        #expect(list.items.prefix(3).map { ObjectIdentifier($0.context!) } == before)

        list.items.removeLast()
        await settle {}
        #expect(testResult.value == "A1A2A3A4d4")               // removed child torn down
        #expect(list.items.map { ObjectIdentifier($0.context!) } == before)

        list.items.append(RcItem(id: 5))
        await settle {}
        #expect(testResult.value == "A1A2A3A4d4A5")
        #expect(list.changeCount == 3)                           // append, remove, append
    }

    @Test func elementWriteThroughTheCollectionIsNotAStructuralChange() async {
        let testResult = TestResult()
        let list = RcList(items: [RcItem(id: 1), RcItem(id: 2), RcItem(id: 3)]).withAnchor {
            $0.testResult = testResult
        }
        await settle {}
        let before = list.items.map { ObjectIdentifier($0.context!) }

        // `items[1].value = 7` is a `_modify` through the collection: the element write goes to
        // the child's context, then the unchanged id sequence is written back — a reconcile
        // where every element takes the fast path.
        list.items[1].value = 7
        await settle {}
        #expect(list.items[1].value == 7)
        #expect(list.items.map { ObjectIdentifier($0.context!) } == before)
        #expect(testResult.value == "A1A2A3")                   // nothing activated
        #expect(list.changeCount == 0)                           // no structural change

        // Same for an explicit write-back of the live elements.
        list.items = list.items
        await settle {}
        #expect(list.items.map { ObjectIdentifier($0.context!) } == before)
        #expect(list.changeCount == 0)
    }

    @Test func appendingADuplicateIdConflatesOntoTheExistingChild() async {
        let testResult = TestResult()
        let list = RcList(items: [RcItem(id: 1, value: 10)]).withAnchor {
            $0.testResult = testResult
        }
        await settle {}
        let existing = ObjectIdentifier(list.items[0].context!)

        withKnownIssue("duplicate ids in a model collection are diagnosed in DEBUG") {
            list.items.append(RcItem(id: 1, value: 20))
        }
        await settle {}
        #expect(list.items.count == 2)
        #expect(ObjectIdentifier(list.items[1].context!) == existing)   // same-id → continues the child
        #expect(list.items[1].value == 10)                               // the new instance's state is ignored
        #expect(testResult.value == "A1")                                // no second activation
    }

    @Test func replacingAnElementWithADifferentIdAtTheSameIndex() async {
        let testResult = TestResult()
        let list = RcList(items: [RcItem(id: 1), RcItem(id: 2), RcItem(id: 3)]).withAnchor {
            $0.testResult = testResult
        }
        await settle {}
        let before = list.items.map { ObjectIdentifier($0.context!) }

        list.items[1] = RcItem(id: 9, value: 9)
        await settle {}
        #expect(testResult.value == "A1A2A3d2A9")               // old torn down before new activates
        #expect(list.items.map(\.id) == [1, 9, 3])
        #expect(list.items[1].value == 9)
        #expect(ObjectIdentifier(list.items[0].context!) == before[0])
        #expect(ObjectIdentifier(list.items[2].context!) == before[2])
        #expect(ObjectIdentifier(list.items[1].context!) != before[1])
    }

    @Test func removingWhileIteratingTearsDownEveryChild() async {
        let testResult = TestResult()
        let list = RcList(items: [RcItem(id: 1), RcItem(id: 2), RcItem(id: 3), RcItem(id: 4)]).withAnchor {
            $0.testResult = testResult
        }
        await settle {}
        let captured = list.items

        for item in list.items {
            list.items.removeAll { $0.id == item.id }
        }
        await settle {}
        #expect(list.items.isEmpty)
        #expect(testResult.value == "A1A2A3A4d1d2d3d4")
        #expect(captured.allSatisfy { $0.lifetime == .destructed })
    }

    // A removal shifts the registration positions of every later entry; the next reconcile
    // must still recognise those elements as registered (no re-registration, no activation).
    @Test func removingTheFirstElementKeepsLaterElementsRegistered() async {
        let testResult = TestResult()
        let list = RcList(items: [RcItem(id: 1), RcItem(id: 2), RcItem(id: 3)]).withAnchor {
            $0.testResult = testResult
        }
        await settle {}
        let before = list.items.map { ObjectIdentifier($0.context!) }

        list.items.removeFirst()
        await settle {}
        #expect(testResult.value == "A1A2A3d1")
        #expect(list.items.map { ObjectIdentifier($0.context!) } == Array(before[1...]))

        list.items[0].value = 5                                  // shifted element, written back
        list.items.append(RcItem(id: 4))
        await settle {}
        #expect(testResult.value == "A1A2A3d1A4")
        #expect(list.items.prefix(2).map { ObjectIdentifier($0.context!) } == Array(before[1...]))
        #expect(list.items[0].value == 5)

        list.items.remove(at: 1)                                 // middle removal, then write-back
        list.items = list.items
        await settle {}
        #expect(testResult.value == "A1A2A3d1A4d3")
        #expect(list.items.map(\.id) == [2, 4])
        #expect(ObjectIdentifier(list.items[0].context!) == before[1])
    }

    @Test func reorderingIsAStructuralChangeThatKeepsEveryContext() async {
        let testResult = TestResult()
        let list = RcList(items: [RcItem(id: 1), RcItem(id: 2), RcItem(id: 3)]).withAnchor {
            $0.testResult = testResult
        }
        await settle {}
        let before = Dictionary(uniqueKeysWithValues: list.items.map { ($0.id, ObjectIdentifier($0.context!)) })

        list.items.reverse()
        await expect { list.changeCount == 1 }                   // observed as a change …
        #expect(list.items.map(\.id) == [3, 2, 1])
        #expect(testResult.value == "A1A2A3")                   // … but nothing (re)activated
        for item in list.items {
            #expect(ObjectIdentifier(item.context!) == before[item.id])
        }
    }

    // MARK: `ContiguousArray<@ModelContainer enum>` — `_performContainerCollectionSet`
    //
    // Context identity is read through `modelContext.context` here: the elements anchored with
    // the parent are `.live` copies (pre-existing on this path — `MakeInitialTransformer` leaves
    // them live and the container-element visitor never re-anchors on that basis), for which
    // the internal `Model.context` helper is nil by design.

    @Test func containerCollectionAppendRemoveAndReplace() async {
        let testResult = TestResult()
        let list = RcPathList(paths: [.item(RcItem(id: 1)), .item(RcItem(id: 2))]).withAnchor {
            $0.testResult = testResult
        }
        await settle {}
        #expect(testResult.value == "A1A2")
        let before = list.paths.map { ObjectIdentifier($0.item.modelContext.context!) }

        list.paths.append(.item(RcItem(id: 3)))
        await settle {}
        #expect(testResult.value == "A1A2A3")
        #expect(list.paths.prefix(2).map { ObjectIdentifier($0.item.modelContext.context!) } == before)

        list.paths.removeLast()
        await settle {}
        #expect(testResult.value == "A1A2A3d3")

        list.paths[0] = .item(RcItem(id: 9))
        await settle {}
        #expect(testResult.value == "A1A2A3d3d1A9")
        #expect(list.paths.map(\.id) == [9, 2])
        #expect(ObjectIdentifier(list.paths[1].item.modelContext.context!) == before[1])

        list.paths.removeFirst()                                 // shifts the remaining entry
        list.paths = list.paths                                  // write-back: fast path after the shift
        await settle {}
        #expect(testResult.value == "A1A2A3d3d1A9d9")
        #expect(ObjectIdentifier(list.paths[0].item.modelContext.context!) == before[1])
    }

    @Test func containerCollectionElementWriteIsNotAStructuralChange() async {
        let testResult = TestResult()
        let list = RcPathList(paths: [.item(RcItem(id: 1)), .item(RcItem(id: 2))]).withAnchor {
            $0.testResult = testResult
        }
        await settle {}
        let before = list.paths.map { ObjectIdentifier($0.item.modelContext.context!) }

        list.paths[1].item.value = 7
        list.paths = list.paths
        await settle {}
        #expect(list.paths[1].item.value == 7)
        #expect(list.paths.map { ObjectIdentifier($0.item.modelContext.context!) } == before)
        #expect(testResult.value == "A1A2")
    }
}

@Model private struct RcItem: Identifiable, Sendable {
    let id: Int
    var value: Int = 0

    func onActivate() {
        node.testResult.add("A\(id)")
        node.onCancel {
            node.testResult.add("d\(id)")
        }
    }
}

@Model private struct RcList {
    var items: [RcItem] = []
    var changeCount = 0

    func onActivate() {
        node.onChange(of: items.map(\.id), initial: false) { _, _ in
            changeCount += 1
        }
    }
}

@ModelContainer private enum RcPath: Identifiable, Sendable {
    case item(RcItem)

    var id: Int {
        switch self {
        case .item(let item): return item.id
        }
    }

    var item: RcItem {
        get {
            switch self {
            case .item(let item): return item
            }
        }
        set { self = .item(newValue) }
    }
}

/// `ContiguousArray` is a `MutableCollection` that is NOT a `ModelContainer` (only `Array` is),
/// so a `ContiguousArray` of `@ModelContainer` enums takes the `_performContainerCollectionSet`
/// write path — the one `IdentifiedArrayOf<@ModelContainer enum>` takes in apps.
@Model private struct RcPathList {
    var paths: ContiguousArray<RcPath> = []
}
