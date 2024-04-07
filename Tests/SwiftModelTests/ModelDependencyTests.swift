import XCTest
import AsyncAlgorithms
@testable import SwiftModel
import Dependencies

final class ModelDependencyTests: XCTestCase {
    func testChildDependency() async throws {
        let testResult = TestResult()
        do {
            let (model, tester) = Child(id: 2).andTester {
                $0.testResult = testResult
                $0[Dependency.self] = Dependency(value: 4)
            }

            await tester.assert {
                model.dependency.value == 4
            }
        }

        XCTAssertEqual(testResult.value, "D(2:4)d")
    }

    func testParentChildDependency() async throws {
        let testResult = TestResult()
        do {
            let (model, tester) = Parent().andTester {
                $0.testResult = testResult
                $0[Dependency.self] = Dependency(value: 4)
            }

            await tester.assert {
                model.child.dependency.value == 4
            }
        }

        XCTAssertEqual(testResult.value, "D(1:4)d")
    }

    func testParentChildrenDependency() async throws {
        let testResult = TestResult()
        do {
            let (model, tester) = Parent().andTester {
                $0.testResult = testResult
                $0[Dependency.self] = Dependency(value: 4)
            }

            model.children.append(Child(id:3))

            await tester.assert {
                model.children.count == 1
                model.child.dependency.value == 4
            }

            model.child.dependency.value = 7

            model.children.append(Child(id:5))

            await tester.assert {
                model.children.count == 2
                model.child.dependency.value == 7
            }
        }

        XCTAssertEqual(testResult.value, "D(1:4)(3:4)(->7)(->7)(5:7)d")
    }

    func testParentChildMultiDependency() async throws {
        let testResult = TestResult()
        do {
            let (model, tester) = Parent().andTester {
                $0.testResult = testResult
                $0[Dependency.self] = Dependency(value: 4)
            }

            model.children.append(Child(id:3).withDependencies {
                $0[Dependency.self] = Dependency(value: 8)
            })

            await tester.assert {
                model.child.dependency.value == 4
                model.children[0].dependency.value == 8
            }

            model.children.removeAll()

            await tester.assert {
                model.children.isEmpty
            }

            model.child.dependency.value = 5

            await tester.assert {
                model.child.dependency.value == 5
            }
        }

        XCTAssertEqual(testResult.value, "D(1:4)D(3:8)d(->5)d")
    }

    func testParentDependency() async throws {
        let testResult = TestResult()
        do {
            let (model, tester) = Parent(dependency: Dependency(value: 7)).andTester {
                $0.testResult = testResult
                $0[Dependency.self] = Dependency(value: 4)
            }

            model.children.append(Child(id:3).withDependencies {
                $0[Dependency.self] = model.dependency!
            })

            await tester.assert {
                model.child.dependency.value == 4
                model.children[0].dependency.value == 7
            }

            model.children[0].dependency.value = 5

            await tester.assert {
                model.dependency?.value == 5
                model.children[0].dependency.value == 5
            }

            model.dependency?.value = 9

            await tester.assert {
                model.dependency?.value == 9
                model.children[0].dependency.value == 9
            }

            model.children.removeAll()

            await tester.assert {
                model.children.isEmpty
            }

            model.dependency = nil
            model.child.dependency.value = 8

            await tester.assert {
                model.dependency == nil
            }
        }

        XCTAssertEqual(testResult.value, "D(1:4)D(3:7)(->5)(->9)d(->8)d")
    }
}

@Model
private struct Dependency {
    var value: Int

    func onActivate() {
        node.testResult.add("D")
        node.onCancel {
            node.testResult.add("d")
        }
    }
}

extension Dependency: DependencyKey {
    static let liveValue = Dependency(value: 4711)
}

@Model private struct Child {
    let id: Int
    @ModelDependency var dependency: Dependency

    func onActivate() {
        node.testResult.add("(\(id):\(dependency.value))")
        node.forEach(dependency.change(of: \.value, initial: false)) {
            node.testResult.add("(->\($0))")
        }
    }
}

@Model private struct Parent: Sendable {
    var child: Child = Child(id: 1)
    var children: [Child] = []

    var dependency: Dependency?
}


