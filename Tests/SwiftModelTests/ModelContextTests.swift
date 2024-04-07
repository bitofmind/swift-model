@testable import SwiftModel
import XCTest
import ConcurrencyExtras

@Model
private struct ChildModel: Equatable, Identifiable, Sendable {
    let id = nextID()
    var count: Int = 77
    private(set) var privateCount: Int = 1177
}

struct NotEquatable {}

@ModelContainer
private enum Path: Equatable {
    case child(ChildModel)
    case count(Int)
}

@ModelContainer
private struct Part: Equatable {
    var count = 88
    var optChild: ChildModel? = .init()
}

@Model
private struct RootModel: Sendable, Equatable {
    var count: Int = 66
    //var notEquatable = NotEquatable()
    var child: ChildModel = .init()
    var optChild: ChildModel? = nil
    var children: [ChildModel] = []
    var path: Path = .child(.init())
    var path2: Path = .count(44)
    var optPath: Path? = .child(.init())

    var part: Part = Part()
    var optPart: Part? = Part()
}

final class ModelContextTests: XCTestCase {
    func testRootDetached() {
        let initChild = ChildModel()
        XCTAssertEqual(initChild.lifetime, .initial)
        let anchoredChild = initChild.withAnchor()
        XCTAssertEqual(initChild.lifetime, .active)

        XCTAssertEqual(anchoredChild.lifetime, .active)
        XCTAssertEqual(initChild.lifetime, .active)
    }

    func testCopy() {
        let child = ChildModel().withAnchor()
        child.count = 2
        let child2 = child
        let child3 = child.frozenCopy
        //let child4 = child.copy
        child.count = 3
        //child4.count = 4

        XCTAssertEqual(child.count, 3)
        XCTAssertEqual(child2.count, 3)
        XCTAssertEqual(child3.count, 2)
        //XCTAssertEqual(child4.count, 4)
    }

    func testEquatable() {
        let child = ChildModel().withAnchor()

        let childA = child
        let childB = child
        XCTAssertEqual(childA, childB)

        childA.count += 1
        XCTAssertEqual(childA, childB)

        let childC = childA.frozenCopy
        let childD = childC
        XCTAssertEqual(childA, childC)
        XCTAssertEqual(childC, childD)

        XCTExpectFailure {
            childC.count += 1
        }
    }
    
    func testAssigningAnchoredModel() {
        let root = RootModel().withAnchor()
        root.optChild = root.child

        root.optChild = ChildModel()

        root.child = root.optChild!
    }

    func testDetaching() {
        let initChild = ChildModel()
        XCTAssertEqual(initChild.lifetime, .initial)
        let anchoredChild = initChild.withAnchor()

        XCTAssertFalse(anchoredChild.lifetime == .initial)
        XCTAssertFalse(anchoredChild.lifetime == .initial)
        XCTAssertEqual(initChild.lifetime, .active)
        let copy = anchoredChild
        XCTAssertFalse(copy.lifetime == .initial)
        let frozenCopy = anchoredChild.frozenCopy
        XCTAssertTrue(frozenCopy.lifetime == .frozenCopy)
        XCTAssertEqual(frozenCopy, anchoredChild)
        anchoredChild.count += 1
        XCTAssertNotEqual(frozenCopy, anchoredChild)
    }

    func testNonOptionalChild() {
        let root = RootModel().withAnchor()
        XCTAssertFalse(root.lifetime == .initial)
        XCTAssertFalse(root.child.lifetime == .initial)

        root.child.count = 100
        XCTAssertFalse(root.child.lifetime == .initial)

        root.child.count += 1
        XCTAssertFalse(root.child.lifetime == .initial)

        root.child = ChildModel()
        XCTAssertFalse(root.child.lifetime == .initial)

        root.child.count = 100
        XCTAssertFalse(root.child.lifetime == .initial)

        root.child.count += 1
        XCTAssertFalse(root.child.lifetime == .initial)
    }

    func testAsyncSequence() async {
        let stream = AsyncStream<Int> {
            $0.yield(2)
            $0.yield(12)
            $0.finish()
        }

        for await value in stream {
            print(value)
        }
    }

    func testActivate() async throws {
        let test = TestModel().withAnchor()
        XCTAssertEqual(test.activateCount, 1)
        XCTAssertEqual(test.child.activateCount, 2)

        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 2)

        XCTAssertEqual(test.totalCount, (-1 + 2*1)*(3*2))
        //try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 1102)
    }
}

@Model private struct TestModel: Sendable {
    var activateCount: Int = 0
    var totalCount: Int = -1
    var child: ChildModel = ChildModel()

    func onActivate() {
        print("test activate")
        activateCount += 1
        totalCount += 2*activateCount

        let values = child.update(of: \.activateCount, initial: false)
        Task {
            for await count in values {
                totalCount *= 3*count
            }
            print("for loop ended")
        }
    }

    @Model struct ChildModel: Sendable {
        var activateCount: Int = 0
        var grandChild: GrandChildModel = GrandChildModel()

        func onActivate() {
            print("child activate")
            activateCount += 2
        }

        @Model struct GrandChildModel: Sendable {
            var activateCount: Int// = 0

            init(activateCount: Int = 0) {
                _activateCount = activateCount
            }

            func onActivate() {
                print("grandchild activate")
                activateCount += 10
            }
        }
    }
}

@ModelContainer
struct Text {
    var count: Int = 77
}

let _nextID = LockIsolated(0)
func nextID() -> Int {
    _nextID.withValue {
        $0 += 1
        return $0 // fix min called from both model and its state.
    }
}

