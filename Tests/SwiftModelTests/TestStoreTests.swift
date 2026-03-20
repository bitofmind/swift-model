import Testing
@testable import SwiftModel
import SwiftModelTesting
import CustomDump
import Observation

@Suite(.modelTesting)
struct TestStoreTests {
    @Test func testLeaf() async throws {
        let leaf = Leaf().withAnchor()

        leaf.increment()

        await expect(leaf.count == 1)
    }

    @Test func testChild() async throws {
        let child = Child(leaf: Leaf()).withAnchor()

        let leaf = try await require(child.leaf)

        await expect(leaf.count == 0)

        leaf.increment()
        await expect(leaf.count == 1)

        leaf.increment()
        await expect(leaf.count == 2)
    }

    @Test func testChildLeafModify() async throws {
        let child = Child(leaf: Leaf(count: 5)).withAnchor()

        let leaf = try await require(child.leaf)
        #expect(leaf.access != nil)
        child.leaf = Leaf(count: 6, isEnabled: true)
        await expect {
            child.leaf?.count == 6
            child.leaf?.isEnabled == true
        }
    }

    // Regression test: asserting on a collection item then removing that item must not
    // crash with a force-unwrap in the ModelContainer key path getter.
    @Test(.modelTesting(exhaustivity: .off)) func testAssertAfterRemovingCollectionItem() async {
        let parent = CollectionParent(items: [
            CollectionItem(value: 1),
            CollectionItem(value: 2),
        ]).withAnchor()

        await expect(parent.items.count == 2 && parent.items[0].value == 1)

        parent.items.removeFirst()
        await expect(parent.items.count == 1 && parent.items[0].value == 2)
    }

    @Test func testChildOptionalLeaf() async throws {
        try await _testing_keepLastSeenAround {
            let child = Child(leaf: Leaf(count: 5)).withAnchor()

            let prevLeaf = try await require(child.leaf)

            prevLeaf.count = 9
            await expect(prevLeaf.count == 9)

            child.leaf = nil
            await expect(child.leaf == nil)

            child.leaf = Leaf(count: 6, isEnabled: true)
            await expect {
                child.leaf?.count == 6
                child.leaf?.isEnabled == true
            }

            #expect(prevLeaf.count == 9)
        }
    }
}

@Model
private struct Child {
    var leaf: Leaf?
}

@Model
private struct CollectionParent {
    var items: [CollectionItem]
}

@Model
private struct CollectionItem {
    var value: Int
}

struct ClosureTest {
    var _callback: () -> Void = {}

    var callback: () -> Void
    {
        @storageRestrictions(initializes: _callback)
        init {
          _callback = newValue
        }

        _read {
            yield _callback
        }

        _modify {
            yield &_callback
        }
    }
}

@Model
struct ClosureModel {
    let callback: @Sendable () -> Void = {}
    var mutCallback: @Sendable () -> Void = {}
}

func closureTest(callback: (inout () -> Void) -> Void) {

}

@Model
private struct Leaf {
    var count: Int = 0 {
        willSet {
            print("Count will set", count, newValue)
            _willSet(oldValue: count, newValue: newValue)
        }
        didSet {
            print("Count did set", oldValue, count)
            _didSet(oldValue: oldValue, newValue: count)
        }
    }
    var isEnabled: Bool = false
    func increment() { count += 1 }

    func _willSet(oldValue: Int, newValue: Int) {
        print("_Count will set", oldValue, newValue)
    }

    func _didSet(oldValue: Int, newValue: Int) {
        print("_Count did set", oldValue, newValue)
    }

}
