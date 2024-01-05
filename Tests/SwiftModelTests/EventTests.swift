import XCTest
import AsyncAlgorithms
@testable import SwiftModel

final class EventTests: XCTestCase {
    func testEvent() async throws {
        let (model, tester) = Child().andTester()

        await tester.assert {
            model.didSend(.basic)
            model.didSend(.third)
        }
    }
    
    func testModelEvents() async throws {
        let (model, tester) = EventModel().andTester()

        await tester.assert(model.count == 3)

        try await Task.sleep(nanoseconds: NSEC_PER_MSEC*1)

        model.testNode.send(.empty)
        model.increment()
        model.increment()
        model.testNode.send(.empty)

        await tester.assert() {
            model.count == 3 + 1 + 1
            model.receivedEvents == [.empty, .count(4) , .count(5), .empty]

            model.didSend(.empty)
            model.didSend(.count(4))
            model.didSend(.count(5))
            model.didSend(.empty)
        }
    }

    func testChildEvents() async throws {
        let (parent, tester) = ParentModel().andTester()
        let child = parent.child

        await tester.assert(child.id == 1)
        child.testNode.send(.count(3))

        await tester.assert {
            parent.receivedEvents == [.count(3)]
            parent.receivedIds == [10 + child.id]
            child.didSend(.count(3))
        }

        let childAlt = parent.childAlt
        childAlt.testNode.send(.count(9))

        await tester.assert {
            parent.receivedEvents.count == 2
            parent.receivedEvents.last == .count(9)
            parent.receivedIds.last == (30 + childAlt.id)
            childAlt.didSend(.count(9))
        }

        parent.setOptChild(id: 5)
        await tester.assert(parent.optChild == ChildModel(id: 5))

        let optChild = try await tester.unwrap(parent.optChild)
        optChild.testNode.send(.count(7))

        await tester.assert {
            parent.receivedEvents.count == 3
            parent.receivedEvents.last == .count(7)
            parent.receivedIds.last == 20 + optChild.id
            optChild.didSend(.count(7))
        }

        parent.addChild(id: 8)
        parent.addChild(id: 3)

        await tester.assert(parent.children == [ChildModel(id: 8), ChildModel(id: 3)])
        let child1 = parent.children[0]
        let child2 = parent.children[1]

        child2.testNode.send(.count(1))

        await tester.assert {
            parent.receivedEvents.count == 4
            parent.receivedEvents.last == .count(1)
            parent.receivedIds.last == 40 + child2.id
            child2.didSend(.count(1))
        }

        child1.testNode.send(.empty)
        child2.testNode.send(.count(2))

        await tester.assert {
            parent.receivedEvents.count == 6
            parent.receivedEvents.suffix(2) ==  [.empty, .count(2)]
            parent.receivedIds.suffix(2) ==  [40 + child1.id, 40 + child2.id]
            child1.didSend(.empty)
            child2.didSend(.count(2))
        }
    }
}

@Model private struct ChildModel: Sendable, Equatable {
    var id = 0

    enum Event: Equatable {
        case empty
        case count(Int)
    }

    var testNode: ModelNode<Self> { node }
}

@Model private struct ParentModel: Sendable {
    var child = ChildModel(id: 1)
    var childAlt = ChildModel(id: 9)
    var optChild: ChildModel? = nil
    var children: [ChildModel] = []

    var receivedEvents: [ChildModel.Event] = []
    var receivedIds: [Int] = []

    func onActivate() {
        node.forEach(node.event(fromType: ChildModel.self)) { event, child in
            if child.id == self.child.id {
                receivedEvents.append(event)
                receivedIds.append(10 + child.id)
            } else if child.id == childAlt.id {
                receivedEvents.append(event)
                receivedIds.append(30 + childAlt.id)
            } else if child.id == optChild?.id {
                receivedEvents.append(event)
                receivedIds.append(20 + child.id)
            } else if children.map(\.id).contains(child.id) {
                receivedEvents.append(event)
                receivedIds.append(40 + child.id)
            }
        }
    }

    func setOptChild(id: Int) {
        optChild = .init(id: id)
    }

    func addChild(id: Int) {
        children.append(.init(id: id))
    }
}

@Model private struct Child: Sendable {
    enum Event {
        case basic
        case other
        case third
    }

    func onActivate() {
        node.send(.basic)
        node.send(.third)
    }

    var testNode: ModelNode<Self> { node }
}

@Model private struct EventModel: Sendable {
    var id: Int = 0
    var count: Int = 0
    var receivedEvents: [EventModel.Event] = []

    enum Event: Equatable {
        case empty
        case count(Int)
    }

    func onActivate() {
        node.forEach(node.event(fromType: Self.self)) {
            receivedEvents.append($0.0)
        }

        count += 3
    }

    func increment() {
        count += 1
        node.send(.count(count))
    }

    var testNode: ModelNode<Self> { node }
}
