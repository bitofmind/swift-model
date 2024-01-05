import XCTest
import SwiftModel

final class DependencyTests: XCTestCase {
    func testParent() throws {
        let testResult = TestResult()
        do {
            let _ = Parent().withAnchor {
                $0.testResult = testResult
            }
        }

        XCTAssertEqual(testResult.value, "PC0c0p")
    }

    func testParentOverride() throws {
        let testResult = TestResult()
        let parentResult = TestResult()
        do {
            let _ = Parent().withDependencies {
                $0.testResult = parentResult
            }.withAnchor {
                $0.testResult = testResult
            }
        }

        XCTAssertEqual(parentResult.value, "PC0c0p")
        XCTAssertEqual(testResult.value, "")
    }

    func testChildOverride() throws {
        let testResult = TestResult()
        let childResult = TestResult()
        do {
            let _ = Parent(child: Child(id: 1).withDependencies {
                $0.testResult = childResult
            }).withAnchor {
                $0.testResult = testResult
            }
        }

        XCTAssertEqual(testResult.value, "Pp")
        XCTAssertEqual(childResult.value, "C1c1")
    }

    func testParentChildOverride() throws {
        let testResult = TestResult()
        let parentResult = TestResult()
        let childResult = TestResult()
        do {
            let _ = Parent(child: Child(id: 1).withDependencies {
                $0.testResult = childResult
            }).withDependencies {
                $0.testResult = parentResult
            }.withAnchor {
                $0.testResult = testResult
            }
        }

        XCTAssertEqual(testResult.value, "")
        XCTAssertEqual(parentResult.value, "Pp")
        XCTAssertEqual(childResult.value, "C1c1")
    }

    func testChildrenOverride() throws {
        let testResult = TestResult()
        let childrenResult = TestResult()
        do {
            let parent = Parent(child: Child(id: 0)).withAnchor {
                $0.testResult = testResult
            }

            parent.children.append(Child(id: 1))
            parent.children.append(Child(id: 2).withDependencies {
                $0.testResult = childrenResult
            })
            parent.children.append(Child(id: 3))
            parent.children[0] = Child(id: 4).withDependencies {
                $0.testResult = childrenResult
            }
        }

        XCTAssertEqual(testResult.value, "PC0C1C3c1c0c3p")
        XCTAssertEqual(childrenResult.value, "C2C4c2c4")
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
    var leaf: Leaf?

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
