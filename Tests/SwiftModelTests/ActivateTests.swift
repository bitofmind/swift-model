import Testing
@testable import SwiftModel
import Foundation

struct ActivateTests {
    @Test func testRootActivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            Leaf().withAnchor {
                $0.testResult = testResult
            }
        }

        #expect(testResult.value == "Ll")
    }

    @Test func testParentNonOptionalActivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            Parent().withAnchor {
                $0.testResult = testResult
            }
        }

        #expect(testResult.value == "PC0pc0")
    }

    @Test func testReplaceChild() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor() {
                $0.testResult = testResult
            }

            parent.child = Child(id: 1)
            return parent
        }

        #expect(testResult.value == "PC0c0C1pc1")
    }

    @Test func testChildOptionalActivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let child = Child(id: 0).withAnchor {
                $0.testResult = testResult
            }

            child.leaf = Leaf()
            child.leaf = nil
            child.leaf = Leaf()

            return child
        }

        #expect(testResult.value == "C0LlLc0l")
    }

    @Test func testParentChildLeafOptionalActivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.child.leaf = Leaf()
            parent.child.leaf = nil
            parent.child.leaf = Leaf()
            return parent
        }

        #expect(testResult.value == "PC0LlLpc0l")
    }

    @Test func testParentChildrenActivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.removeLast()
            parent.children.append(Child(id: 2))
            return parent
        }

        #expect(testResult.value == "PC0C1c1C2pc0c2")
    }

    @Test func testParentChildrenLeafActivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1, leaf: Leaf()))
            parent.children.removeLast()
            parent.children.append(Child(id: 2, leaf: Leaf()))
            return parent
        }

        #expect(testResult.value == "PC0C1Lc1lC2Lpc0c2l")
    }

    @Test func testParentMultipleChildrenActivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.append(Child(id: 2))
            return parent
        }

        #expect(testResult.value == "PC0C1C2pc0c1c2")
    }

    @Test func testParentMultipleChildrenAndRemoveActivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.append(Child(id: 2))
            parent.children.removeLast()
            return parent
        }

        #expect(testResult.value == "PC0C1C2c2pc0c1")
    }

    @Test func testParentMultipleChildrenLeafActivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.append(Child(id: 2, leaf: Leaf()))
            parent.children.removeLast()
            return parent
        }

        #expect(testResult.value == "PC0C1C2Lc2lpc0c1")
    }

    @Test func testParentMultipleChildrenSwapActivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.append(Child(id: 2))
            parent.children.swapAt(0, 1)
            parent.children.removeLast()
            return parent
        }

        #expect(testResult.value == "PC0C1C2c1pc0c2")
    }

    @Test func testParentMultipleChildrenSwapAltActivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.append(Child(id: 2))
            let child = parent.children.removeFirst()
            withKnownIssue {
                parent.children.append(child)
            }
            return parent
        }

        #expect(testResult.value == "PC0C1C2c1pc0c2")
    }

    @Test func testParentMultipleChildrenSwapAlt2Activation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.append(Child(id: 2))
            var children = parent.children
            let child = children.removeFirst()
            children.append(child)
            parent.children = children

            return parent
        }

        #expect(testResult.value == "PC0C1C2pc0c1c2")
    }

    @Test func testChildCaseActivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let parent = Parent().withAnchor {
                $0.testResult = testResult
            }

            parent.cases = .child(Child(id: 2))
            parent.cases = .child(Child(id: 3))
            parent.cases = .count(55)
            parent.cases = .child(Child(id: 4))
            parent.cases = nil
            return parent
        }

        #expect(testResult.value == "PC0C2c2C3c3C4c4pc0")
    }

    @Test func testChildrenCaseActivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
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

            return parent
        }

        #expect(testResult.value == "PC0C2C3c2c3C4c4C4c4pc0")
    }
}

@ModelContainer private enum Cases {
    case count(Int)
    case child(Child)
    case children([Child])
}

@Model private struct Parent {
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
private struct Child {
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
private struct Leaf {
    func onActivate() {
        node.testResult.add("L")
        node.onCancel {
            node.testResult.add("l")
        }
    }
}

