@testable import SwiftModel
import Testing
import ConcurrencyExtras
import Observation
import Foundation

@Model
private struct ChildModel: Equatable, Identifiable {
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
private struct RootModel: Equatable {
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

struct ModelContextTests {
    @Test func testRootDetached() {
        let initChild = ChildModel()
        #expect(initChild.lifetime == .initial)
        let anchoredChild = initChild.withAnchor()
        #expect(initChild.lifetime == .active)

        #expect(anchoredChild.lifetime == .active)
        #expect(initChild.lifetime == .active)
    }

    @Test func testCopy() {
        let child = ChildModel().withAnchor()
        child.count = 2
        let child2 = child
        let child3 = child.frozenCopy
        child.count = 3

        #expect(child.count == 3)
        #expect(child2.count == 3)
        #expect(child3.count == 2)
    }

    @Test func testEquatable() {
        let child = ChildModel().withAnchor()

        let childA = child
        let childB = child
        #expect(childA == childB)

        childA.count += 1
        #expect(childA == childB)

        let childC = childA.frozenCopy
        let childD = childC
        #expect(childA == childC)
        #expect(childC == childD)

        withKnownIssue {
            childC.count += 1
        }
    }
    
    @Test func testAssigningAnchoredModel() {
        let root = RootModel().withAnchor()
        root.optChild = root.child

        root.optChild = ChildModel()

        root.child = root.optChild!
    }

    @Test func testDetaching() {
        let initChild = ChildModel()
        #expect(initChild.lifetime == .initial)
        let anchoredChild = initChild.withAnchor()

        #expect(anchoredChild.lifetime != .initial)
        #expect(anchoredChild.lifetime != .initial)
        #expect(initChild.lifetime == .active)
        let copy = anchoredChild
        #expect(copy.lifetime != .initial)
        let frozenCopy = anchoredChild.frozenCopy
        #expect(frozenCopy.lifetime == .frozenCopy)
        #expect(frozenCopy == anchoredChild)
        anchoredChild.count += 1
        #expect(frozenCopy != anchoredChild)
    }

    @Test func testNonOptionalChild() {
        let root = RootModel().withAnchor()
        #expect(root.lifetime != .initial)
        #expect(root.child.lifetime != .initial)

        root.child.count = 100
        #expect(root.child.lifetime != .initial)

        root.child.count += 1
        #expect(root.child.lifetime != .initial)

        root.child = ChildModel()
        #expect(root.child.lifetime != .initial)

        root.child.count = 100
        #expect(root.child.lifetime != .initial)

        root.child.count += 1
        #expect(root.child.lifetime != .initial)
    }

    @Test func testAsyncSequence() async {
        let stream = AsyncStream<Int> {
            $0.yield(2)
            $0.yield(12)
            $0.finish()
        }

        for await value in stream {
            print(value)
        }
    }

    @Test func testActivate() async throws {
        let test = TestModel().withAnchor()
        #expect(test.activateCount == 1)
        #expect(test.child.activateCount == 2)

        try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 2)

        let result = (-1 + 2*1)*(3*2)
        #expect(test.totalCount == result)
        //try await Task.sleep(nanoseconds: NSEC_PER_MSEC * 1102)
    }
}

@Model private struct TestModel {
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

    @Model struct ChildModel {
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

