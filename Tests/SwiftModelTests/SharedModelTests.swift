@testable import SwiftModel
import XCTest
import ConcurrencyExtras

final class SharedModelTests: XCTestCase {
    func testBasicSharing() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor() {
                $0.testResult = testResult
            }

            parent.children.append(parent.child)
        }

        XCTAssertEqual(testResult.value, "PC0pc0")
    }

    func testReassign() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor() {
                $0.testResult = testResult
            }

            let child = Child(id: 2)
            parent.children.append(child)
            XCTAssertEqual(testResult.value, "PC0C2")
            parent.child = parent.children[0]
            XCTAssertEqual(testResult.value, "PC0C2c0")
        }

        XCTAssertEqual(testResult.value, "PC0C2c0pc2")
    }

    func testArray() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor() {
                $0.testResult = testResult
            }

            let child = Child(id: 2)
            parent.children.append(child)
            parent.children.append(child)
        }

        XCTAssertEqual(testResult.value, "PC0C2pc0c2")
    }

    func testArrayAlt() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor() {
                $0.testResult = testResult
            }

            parent.children.append(parent.child)
            parent.child = Child(id: 2)
            XCTAssertEqual(testResult.value, "PC0C2")

            parent.children.removeAll()
            XCTAssertEqual(testResult.value, "PC0C2c0")
        }

        XCTAssertEqual(testResult.value, "PC0C2c0pc2")
    }

    func testMultipleInit() throws {
        let testResult = TestResult()
        do {
            let leaf = Leaf()
            let _ = Parent(child: Child(id: 1, leaf: leaf), children: [Child(id: 2, leaf: leaf)]).withAnchor() {
                $0.testResult = testResult
            }
        }

        XCTAssertEqual(testResult.value, "PC1LC2pc1c2l")
    }

    func testEvents() async throws {
        let testResult = TestResult()

        let (parent, tester) = EventParent().andTester {
            $0.testResult = testResult
        }

        parent.children.append(parent.child)
        parent.sendEvent("p")
        parent.child.sendEvent("c")

        await tester.assert {
            parent.children.count == 1
            parent.didSend("p")
            parent.child.didSend("c")
            testResult.value == "CpPc" || testResult.value == "PcCp"
        }
    }
}

@Model
private struct Parent: Sendable {
    var child: Child = Child(id: 0)
    var children: [Child] = []

    func onActivate() {
        node.testResult.add("P")
        node.onCancel {
            node.testResult.add("p")
        }
    }
}

@Model
private struct Child: Sendable, Equatable {
    var id: Int
    var leaf: Leaf? = nil

    func onActivate() {
        node.testResult.add("C\(id)")
        node.onCancel {
            node.testResult.add("c\(id)")
        }

        node.forEach(node.uniquelyReferenced()) {
            print("uniquelyReferenced", id, $0)
        }
    }
}

@Model
private struct Leaf: Sendable, Equatable {
    func onActivate() {
        node.testResult.add("L")
        node.onCancel {
            node.testResult.add("l")
        }
    }
}

@Model 
private struct EventParent: Sendable {
    var child: EventChild = EventChild(id: 0)
    var children: [EventChild] = []

    func sendEvent(_ event: String) {
        node.send(event, to: .descendants)
    }

    func onActivate() {
        node.forEach(node.event(ofType: String.self)) {
            node.testResult.add("P" + $0)
        }
    }
}

@Model
private struct EventChild: Sendable, Equatable {
    var id: Int

    func sendEvent(_ event: String) {
        node.send(event, to: .ancestors)
    }

    func onActivate() {
        node.forEach(node.event(ofType: String.self)) {
            node.testResult.add("C" + $0)
        }
    }
}
