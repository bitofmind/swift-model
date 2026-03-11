import Testing
import SwiftModel
import Observation
import Dependencies

struct DependencyTests {
    @Test func testParent() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            Parent().withAnchor {
                $0.testResult = testResult
            }
        }

        #expect(testResult.value == "PC0pc0")
    }

    @Test func testParentOverride() async {
        let testResult = TestResult()
        let parentResult = TestResult()
        await waitUntilRemoved {
            Parent().withDependencies {
                $0.testResult = parentResult
            }.withAnchor {
                $0.testResult = testResult
            }
        }

        #expect(parentResult.value == "PC0pc0")
        #expect(testResult.value == "")
    }

    @Test func testChildOverride() async {
        let testResult = TestResult()
        let childResult = TestResult()
        await waitUntilRemoved {
            Parent(child: Child(id: 1).withDependencies {
                $0.testResult = childResult
            }).withAnchor {
                $0.testResult = testResult
            }
        }

        #expect(testResult.value == "Pp")
        #expect(childResult.value == "C1c1")
    }

    @Test func testParentChildOverride() async {
        let testResult = TestResult()
        let parentResult = TestResult()
        let childResult = TestResult()
        await waitUntilRemoved {
            Parent(child: Child(id: 1).withDependencies {
                $0.testResult = childResult
            }).withDependencies {
                $0.testResult = parentResult
            }.withAnchor {
                $0.testResult = testResult
            }
        }

        #expect(testResult.value == "")
        #expect(parentResult.value == "Pp")
        #expect(childResult.value == "C1c1")
    }

    @Test func testDependencyInTask() async {
        let testResult = TestResult()
        let (model, tester) = TaskModel().andTester {
            $0.testResult = testResult
        }
        tester.exhaustivity = []
        await tester.assert(timeoutNanoseconds: 5_000_000_000) {
            model.taskDone == true
        }

        #expect(testResult.value == "task")
    }

    @Test func testChildrenOverride() async {
        let testResult = TestResult()
        let childrenResult = TestResult()
        await waitUntilRemoved {
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

            return parent
        }

        #expect(testResult.value == "PC0C1C3c1pc0c3")
        #expect(childrenResult.value == "C2C4c2c4")
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
private struct Child {
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
private struct Leaf {
    func onActivate() {
        node.testResult.add("L")
        node.onCancel {
            node.testResult.add("l")
        }
    }
}

@Model
private struct TaskModel {
    var taskDone = false

    func onActivate() {
        node.task {
            // @Dependency should resolve using the context's dependencies, not the global default
            @Dependency(\.testResult) var result
            result.add("task")
            taskDone = true
        }
    }
}
