@testable import SwiftModel
import Testing
import ConcurrencyExtras
import Observation

struct SharedModelTests {
    @Test func testBasicSharing() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor() {
                $0.testResult = testResult
            }

            parent.children.append(parent.child)

            return parent
        }

        #expect(testResult.value == "PC0pc0")
    }

    @Test func testReassign() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor() {
                $0.testResult = testResult
            }

            let child = Child(id: 2)
            parent.children.append(child)
            #expect(testResult.value == "PC0C2")
            parent.child = parent.children[0]
            #expect(testResult.value == "PC0C2c0")

            return parent
        }

        #expect(testResult.value == "PC0C2c0pc2")
    }

    @Test func testArray() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor() {
                $0.testResult = testResult
            }

            let child = Child(id: 2)
            parent.children.append(child)
            parent.children.append(child)

            return parent
        }

        #expect(testResult.value == "PC0C2pc0c2")
    }

    @Test func testArrayAlt() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor() {
                $0.testResult = testResult
            }

            parent.children.append(parent.child)
            parent.child = Child(id: 2)
            #expect(testResult.value == "PC0C2")

            parent.children.removeAll()
            #expect(testResult.value == "PC0C2c0")

            return parent
        }

        #expect(testResult.value == "PC0C2c0pc2")
    }

    @Test func testMultipleInit() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let leaf = Leaf()
            let _ = Parent(child: Child(id: 1, leaf: leaf), children: [Child(id: 2, leaf: leaf)]).withAnchor() {
                $0.testResult = testResult
            }

            return leaf
        }

        #expect(testResult.value == "PC1LC2pc1c2l")
    }

    @Test func testEvents() async throws {
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
private struct Parent {
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
private struct Child: Equatable {
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
private struct Leaf: Equatable {
    func onActivate() {
        node.testResult.add("L")
        node.onCancel {
            node.testResult.add("l")
        }
    }
}

@Model 
private struct EventParent {
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
private struct EventChild: Equatable {
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
