import Testing
import AsyncAlgorithms
@testable import SwiftModel
import Dependencies
import Observation

struct ModelDependencyTests {
    @Test func testChildDependency() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let (model, tester) = Child(id: 2).andTester {
                $0.testResult = testResult
                $0[Dependency.self] = Dependency(value: 4)
            }

            await tester.assert {
                model.dependency.value == 4
            }

            return model
        }

        #expect(testResult.value == "D(2:4)d")
    }

    @Test func testParentChildDependency() async throws {
        let testResult = TestResult()
        await waitUntilRemoved {
            let (model, tester) = Parent().andTester {
                $0.testResult = testResult
                $0[Dependency.self] = Dependency(value: 4)
            }

            await tester.assert {
                model.child.dependency.value == 4
            }

            return model
        }

        #expect(testResult.value == "D(1:4)d")
    }

    @Test func testParentChildrenDependency() async throws {
        let testResult = TestResult()
        await waitUntilRemoved {
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
            await tester.assert {
                testResult.value.contains("->7")
            }

            model.children.append(Child(id:5))

            await tester.assert {
                model.children.count == 2
                model.child.dependency.value == 7
                testResult.value.contains("->7")
            }

            return model
        }

        #expect(testResult.value == "D(1:4)(3:4)(->7)(->7)(5:7)d")
    }

    @Test func testParentChildMultiDependency() async throws {
        let testResult = TestResult()
        await waitUntilRemoved {

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
                testResult.value.contains("->5")
            }

            return model
        }

        #expect(testResult.value == "D(1:4)D(3:8)d(->5)d")
    }

    @Test func testParentDependency() async throws {
        let testResult = TestResult()
        await waitUntilRemoved {
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
                testResult.value.contains("->9")
            }

            model.children.removeAll()

            await tester.assert {
                model.children.isEmpty
            }

            model.dependency = nil
            model.child.dependency.value = 8

            await tester.assert {
                model.dependency == nil
                testResult.value.contains("->8")
            }

            return model
        }

        #expect(testResult.value == "D(1:4)D(3:7)(->5)(->9)d(->8)d")
    }

    @Test func testSharedDependency() async throws {
        let testResult = TestResult()
        await waitUntilRemoved {
            let (model, tester) = Parent().andTester {
                $0[Dependency.self] = Dependency(value: 4711)
                $0.testResult = testResult
            }

            let sharedDep = Dependency(value: 8)
            model.children.append(Child(id: 3).withDependencies {
                $0[Dependency.self] = sharedDep
            })

            await tester.assert {
                model.children[0].dependency.value == 8
            }

            sharedDep.value -= 1

            await tester.assert {
                testResult.value.contains("(->7)")
            }


            model.children.append(Child(id: 4).withDependencies {
                $0[Dependency.self] = sharedDep
            })

            await tester.assert {
                model.children[0].dependency.value == 7
                model.children[1].dependency.value == 7
                testResult.value.contains("(4:7)")
            }

            sharedDep.value -= 2
            await tester.assert {
                model.children[0].dependency.value == 5
                testResult.value.contains("(->5)")
            }

            model.children.remove(at: 0)

            await tester.assert {
                model.children.count == 1
                model.children[0].dependency.value == 5
            }

            model.children.removeAll()

            await tester.assert {
                model.children.isEmpty
                sharedDep.lifetime == .destructed
                testResult.value.contains("(->5)(->5)")
            }

            #expect(testResult.value == "D(1:4711)D(3:8)(->7)(4:7)(->5)(->5)d")

            return model
        }

        #expect(testResult.value == "D(1:4711)D(3:8)(->7)(4:7)(->5)(->5)dd")
    }

    @Test func testDefaultDependency() async throws {
        #expect(Dependency.testValue.lifetime == .initial)

        let testResult = TestResult()
        await waitUntilRemoved {
            let (model, tester) = Parent().andTester {
                $0.testResult = testResult
            }

            model.child.dependency.value = 8

            await tester.assert {
                testResult.value.contains("(->8)")
            }

            model.children.append(Child(id: 3))

            await tester.assert {
                model.children[0].dependency.value == 8
            }

            model.child.dependency.value -= 1

            await tester.assert {
                testResult.value.contains("(->7)(->7)")
            }

            model.children.append(Child(id: 4))

            await tester.assert {
                model.children[0].dependency.value == 7
                model.children[1].dependency.value == 7
                testResult.value.contains("(4:7)")
            }

            model.child.dependency.value -= 2
            await tester.assert {
                model.children[0].dependency.value == 5
                model.children[1].dependency.value == 5
                testResult.value.contains("(->5)(->5)(->5)")
            }

            model.children.remove(at: 0)

            await tester.assert {
                model.children.count == 1
                model.children[0].dependency.value == 5
            }

            model.children.removeAll()

            await tester.assert {
                model.children.isEmpty
                Dependency.testValue.lifetime != .destructed
            }

            model.children.append(Child(id: 6))

            model.child.dependency.value -= 3

            await tester.assert {
                testResult.value.contains("(6:5)(->2)(->2)")
                model.children[0].dependency.value == 2
            }

            #expect(testResult.value == "D(1:3711)(->8)(3:8)(->7)(->7)(4:7)(->5)(->5)(->5)(6:5)(->2)(->2)")

            return model
        }

        #expect(testResult.value == "D(1:3711)(->8)(3:8)(->7)(->7)(4:7)(->5)(->5)(->5)(6:5)(->2)(->2)d")
        #expect(Dependency.testValue.lifetime == .initial)
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
    static let testValue = Dependency(value: 3711)
}

@Model private struct Child {
    let id: Int
    @ModelDependency var dependency: Dependency

    func onActivate() {
        node.testResult.add("(\(id):\(dependency.value))")
        node.forEach(Observe(initial: false) { dependency.value }) {
            node.testResult.add("(->\($0))")
        }
    }
}

@Model private struct Parent {
    var child: Child = Child(id: 1)
    var children: [Child] = []

    var dependency: Dependency?
}


