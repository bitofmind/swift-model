import XCTest
import SwiftModel
import Dependencies

class TestResult: @unchecked Sendable {
    let lock = NSLock()
    var values: [String] = []
    var value: String { lock { values.joined() } }

    func add(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

//    func add(_ value: Any) {
//        add(String(describing: value))
//    }
}

extension DependencyValues {
    var testResult: TestResult {
        get { self[Key.self] }
        set { self[Key.self] = newValue }
    }

    private enum Key: DependencyKey {
        static let liveValue = TestResult()
    }
}

final class ActivateTests: XCTestCase {
    func testRootActivation() throws {
        let testResult = TestResult()
        do {
            let _ = Leaf().withAnchor {
                $0.testResult = testResult
            }
        }

        XCTAssertEqual(testResult.value, "Ll")
    }

    func testParentNonOptionalActivation() throws {
        let testResult = TestResult()
        do {
            let _ = Parent().withAnchor {
                $0.testResult = testResult
            }
        }

        XCTAssertEqual(testResult.value, "PC0pc0")
    }

    func testReplaceChild() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor() {
                $0.testResult = testResult
            }

            parent.child = Child(id: 1)
        }

        XCTAssertEqual(testResult.value, "PC0c0C1pc1")
    }


    func testChildOptionalActivation() throws {
        let testResult = TestResult()
        do {
            let child = Child(id: 0).withAnchor {
                $0.testResult = testResult
            }

            child.leaf = Leaf()
            child.leaf = nil
            child.leaf = Leaf()
        }

        XCTAssertEqual(testResult.value, "C0LlLc0l")
    }

    func testParentChildLeafOptionalActivation() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.child.leaf = Leaf()
            parent.child.leaf = nil
            parent.child.leaf = Leaf()
        }

        XCTAssertEqual(testResult.value, "PC0LlLpc0l")
    }

    func testParentChildrenActivation() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.removeLast()
            parent.children.append(Child(id: 2))
        }

        XCTAssertEqual(testResult.value, "PC0C1c1C2pc0c2")
    }

    func testParentChildrenLeafActivation() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1, leaf: Leaf()))
            parent.children.removeLast()
            parent.children.append(Child(id: 2, leaf: Leaf()))
        }

        XCTAssertEqual(testResult.value, "PC0C1Lc1lC2Lpc0c2l")
    }

    func testParentMultipleChildrenActivation() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.append(Child(id: 2))
        }

        XCTAssertEqual(testResult.value, "PC0C1C2pc0c1c2")
    }

    func testParentMultipleChildrenAndRemoveActivation() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.append(Child(id: 2))
            parent.children.removeLast()
        }

        XCTAssertEqual(testResult.value, "PC0C1C2c2pc0c1")
    }

    func testParentMultipleChildrenLeafActivation() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.append(Child(id: 2, leaf: Leaf()))
            parent.children.removeLast()
        }

        XCTAssertEqual(testResult.value, "PC0C1C2Lc2lpc0c1")
    }

    func testParentMultipleChildrenSwapActivation() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.append(Child(id: 2))
            parent.children.swapAt(0, 1)
            parent.children.removeLast()
        }

        XCTAssertEqual(testResult.value, "PC0C1C2c1pc0c2")
    }

    func testParentMultipleChildrenSwapAltActivation() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.append(Child(id: 2))
            let child = parent.children.removeFirst()
            XCTExpectFailure {
                parent.children.append(child)
            }
        }

        XCTAssertEqual(testResult.value, "PC0C1C2c1pc0c2")
    }

    func testParentMultipleChildrenSwapAlt2Activation() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.append(Child(id: 2))
            var children = parent.children
            let child = children.removeFirst()
            children.append(child)
            parent.children = children
        }

        XCTAssertEqual(testResult.value, "PC0C1C2pc0c1c2")
    }

    func testChildCaseActivation() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.cases = .child(Child(id: 2))
            parent.cases = .child(Child(id: 3))
            parent.cases = .count(55)
            parent.cases = .child(Child(id: 4))
            parent.cases = nil
        }

        XCTAssertEqual(testResult.value, "PC0C2c2C3c3C4c4pc0")
    }

    func testChildrenCaseActivation() throws {
        let testResult = TestResult()
        do {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.cases = .children([])
            parent.cases = .children([Child(id: 2)])
            parent.cases = .children([Child(id: 2), Child(id: 3)])
            parent.cases = .children([Child(id: 3)])
            parent.cases = .count(55)
            parent.cases = .children([Child(id: 4)])
            parent.cases = .child(Child(id: 4))
            parent.cases = nil
        }

        XCTAssertEqual(testResult.value, "PC0C2C3c2c3C4c4C4c4pc0")
    }
}

@ModelContainer private enum Cases {
    case count(Int)
    case child(Child)
    case children([Child])
}

@Model private struct Parent: Sendable {
    var child: Child = Child(id: 0)
    var children: [Child] = []
    var cases: Cases?

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

