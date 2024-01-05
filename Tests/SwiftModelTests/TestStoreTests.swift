import XCTest
@testable import SwiftModel
import CustomDump

final class TestStoreTests: XCTestCase {
    func testLeaf() async throws {
        let (leaf, tester) = Leaf().andTester()

        leaf.increment()

        await tester.assert {
            //{ leaf.count = 5; return true }()
            //leaf.count == 2
            leaf.count == 1
            //leaf.count == 3
        }
    }

    func testChild() async throws {
        let (child, tester) = Child(leaf: Leaf()).andTester()
        //child.printStateUpdates()

        let leaf = try await tester.unwrap(child.leaf)
        //leaf.printStateUpdates()

        await tester.assert(leaf.count == 0)

        leaf.increment()
        await tester.assert(leaf.count == 1)

        leaf.increment()
        await tester.assert {
            leaf.count == 2
        }
    }

    func testChildLeafModify() async throws {
        let (child, tester) = Child(leaf: Leaf(count: 5)).andTester()

        let leaf = try await tester.unwrap(child.leaf)
        XCTAssertNotNil(leaf.access)
        child.leaf = Leaf(count: 6, isEnabled: true)
        await tester.assert {
            //leaf.count == 5
//            child.leaf == Leaf(count: 6, isEnabled: true)
            child.leaf?.count == 6
            child.leaf?.isEnabled == true
        }
    }

    func testChildOptionalLeaf() async throws {
        try await _testing_keepLastSeenAround {
            let (child, tester) = Child(leaf: Leaf(count: 5)).andTester()

            let prevLeaf = try await tester.unwrap(child.leaf)

            prevLeaf.count = 9
            await tester.assert(prevLeaf.count == 9)

            child.leaf = nil
            await tester.assert(child.leaf == nil)

            child.leaf = Leaf(count: 6, isEnabled: true)
            await tester.assert {
                //            child.leaf == Leaf(count: 6, isEnabled: true)
                child.leaf?.count == 6
                child.leaf?.isEnabled == true
            }

            XCTAssertEqual(prevLeaf.count, 9)
            //prevLeaf.count += 1

            //child.leaf?.count = 9
        }

    }
}

@Model
private struct Child: Sendable {
    var leaf: Leaf?
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
struct ClosureModel: Sendable {
    let callback: @Sendable () -> Void = {}
    var mutCallback: @Sendable () -> Void = {}
}

func closureTest(callback: (inout () -> Void) -> Void) {

}

@Model
private struct Leaf: Sendable {
    var count: Int = 0 {
        willSet {
            print("Count will set", count, newValue)
            _willSet(oldValue: count, newValue: newValue)
        }
        didSet {
            print("Count did set", oldValue, count)
            _didSet(oldValue: oldValue, newValue: count)
        }
    }// = 0 {
    var isEnabled: Bool = false
//    var notEquatable = NotEquatable()
//    var callback: (() -> Void)?
//
    func increment() { count += 1 }

    func _willSet(oldValue: Int, newValue: Int) {
        print("_Count will set", oldValue, newValue)
    }

    func _didSet(oldValue: Int, newValue: Int) {
        print("_Count did set", oldValue, newValue)
    }

}
