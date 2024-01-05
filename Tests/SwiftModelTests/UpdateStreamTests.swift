import XCTest
@testable import SwiftModel

final class UpdateStreamTests: XCTestCase {
    func testChangeOf() async throws {
        let (model, tester) = ValuesModel(initial: false, recursive: false).andTester()

        model.count += 5
        await tester.assert {
            model.count == 5
            model.counts == [5]
        }

        model.count += 3
        await tester.assert {
            model.count == 8
            model.counts == [5, 8]
        }
    }

    func testChangeOfConcurrency() async throws {
        let (model, tester) = ValuesModel(initial: false, recursive: false).andTester()

        let range = 1...10
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for _ in range {
                    group.addTask {
                        model.count += 1
                    }
                }
                
                await group.waitForAll()
            }
        }

        await tester.assert {
            model.count == range.count
            model.counts.sorted() == Array(range)
        }
    }

    func testChangeOfChild() async throws {
        let (model, tester) = ValuesModel(child: ChildModel(count: 2), initial: true, recursive: false).andTester()

        await tester.assert {
            model.child.count == 2
            model.childCounts == [2]
            model.counts == [0]
            model.optChildCounts == [nil]
        }

        model.child.count += 5
        await tester.assert {
            model.child.count == 7
            model.childCounts == [2, 7]
        }

        model.child.count += 3
        await tester.assert {
            model.child.count == 10
            model.childCounts == [2, 7, 10]
        }
    }

    func testChangeOfChildWhereChildIsUpdated() async throws {
        let (model, tester) = ValuesModel(child: ChildModel(count: 2), initial: true, recursive: false).andTester()

        await tester.assert {
            model.child.count == 2
            model.childCounts == [2]
            model.counts == [0]
            model.optChildCounts == [nil]
        }
        
        model.child = ChildModel(count: 4)
        await tester.assert {
            model.child.count == 4
            model.childCounts == [2, 4]
        }
    }

    func testChangeOfChildConcurrency() async throws {
        let (model, tester) = ValuesModel(child: ChildModel(count: 0), initial: false, recursive: false).andTester()

        let range = 1...10
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for _ in range {
                    group.addTask {
                        model.transaction {
                            model.child = ChildModel(count: model.child.count + 1)
                        }
                    }
                }

                await group.waitForAll()
            }
        }

        await tester.assert {
            model.child.count == range.count
            model.childCounts.sorted() == Array(range)
        }
    }

    func testChangeOfOptChildWhereChildIsUpdated() async throws {
        let (model, tester) = ValuesModel(initial: false, recursive: false).andTester()

        model.optChild = ChildModel(count: 4)
        await tester.assert {
            model.optChild?.count == 4
            model.optChildCounts == [4]
        }

        model.optChild = nil
        await tester.assert {
            model.optChild?.count == nil
            model.optChildCounts == [4, nil]
        }

        model.optChild = ChildModel(count: 7)
        await tester.assert {
            model.optChild?.count == 7
            model.optChildCounts == [4, nil, 7]
        }
    }

    func testRace() async throws {
        let (model, tester) = RaceModel().andTester()
        tester.exhaustivity = .full.subtracting(.tasks)

        Task {
            model.count = 7
        }

        model.collectCounts()

        await tester.assert {
            model.counts.last == 7
            model.count == 7
        }
    }

    func testRaceVariant() async throws {
        let (model, tester) = RaceModel().andTester()
        tester.exhaustivity = .full.subtracting(.tasks)

        Task {
            model.count = 7
        }

        Task {
            model.collectCounts()
        }
        
        await tester.assert {
            model.counts.last == 7
            model.count == 7
        }
    }

    func testRecursiveChild() async throws {
        let (model, tester) = ValuesModel(initial: false, recursive: true).andTester()

        await tester.assert {
            model.child.count == 0
            model.childChanges == []
        }

        model.child.count += 1

        await tester.assert {
            model.child.count == 1
            model.childCounts == [1]
            model.childChanges == [1]
        }

        model.child.count += 5

        await tester.assert {
            model.child.count == 6
            model.childCounts == [1, 6]
            model.childChanges == [1, 6]
        }
    }

    func testRecursiveOptChild() async throws {
        let (model, tester) = ValuesModel(initial: false, recursive: true).andTester()

        await tester.assert {
            model.optChild == nil
            model.opChildChanges == []
        }

        model.optChild = ChildModel(count: 5)

        await tester.assert {
            model.optChild?.count == 5
            model.optChildCounts == [5]
            model.opChildChanges == [5]
        }

        model.optChild?.count += 1

        await tester.assert {
            model.optChild?.count == 6
            model.optChildCounts == [5, 6]
            model.opChildChanges == [5, 6]
        }

        model.optChild = nil

        await tester.assert {
            model.optChild == nil
            model.optChildCounts == [5, 6, nil]
            model.opChildChanges == [5, 6, nil]
        }
    }

    func testRecursiveChildren() async throws {
        let (model, tester) = ValuesModel(initial: false, recursive: true).andTester()

        await tester.assert {
            model.childrenCounts == []
        }

        model.children.append(ChildModel(count: 5))

        await tester.assert {
            model.children.count == 1
            model.childrenCounts == [[5]]
        }

        model.children[0].count += 1

        await tester.assert {
            model.children[0].count == 6
            model.childrenCounts == [[5], [6]]
        }

        model.children.append(ChildModel(count: 10))

        await tester.assert {
            model.children.count == 2
            model.childrenCounts == [[5], [6], [6, 10]]
        }

        model.children.remove(at: 0)

        await tester.assert {
            model.children.count == 1
            model.childrenCounts == [[5], [6], [6, 10], [10]]
        }

        model.children.removeAll()

        await tester.assert {
            model.children.count == 0
            model.childrenCounts == [[5], [6], [6, 10], [10], []]
        }
    }
}

@Model private struct ValuesModel: Sendable {
    var count = 0
    var counts: [Int] = []
    var childCounts: [Int] = []
    var childChanges: [Int] = []
    var optChildCounts: [Int?] = []
    var opChildChanges: [Int?] = []
    var child = ChildModel()
    var optChild: ChildModel? = nil
    var children: [ChildModel] = []
    var childrenCounts: [[Int]] = []
    let initial: Bool
    let recursive: Bool

    func onActivate() {
        node.forEach(update(of: \.count, initial: initial, recursive: recursive)) { count in
            counts.append(count)
        }

        node.forEach(update(of: \.child.count, initial: initial, recursive: recursive)) { count in
            childCounts.append(count)
        }

        if recursive {
            node.forEach(update(of: \.child, initial: initial, recursive: recursive)) { child in
                childChanges.append(child.count)
            }

            node.forEach(update(of: \.optChild, initial: initial, recursive: recursive)) { child in
                opChildChanges.append(child?.count)
            }

            node.forEach(update(of: \.children, initial: initial, recursive: recursive)) { children in
                childrenCounts.append(children.map(\.count))
            }
        }

        node.forEach(update(of: \.optChild?.count, initial: initial, recursive: recursive)) { count in
            optChildCounts.append(count)
        }
    }
}

@Model private struct ChildModel: Sendable, Equatable {
    var count: Int = 0
}

@Model private struct RaceModel: Sendable {
    var count: Int = 0
    var counts: [Int] = []

    func collectCounts() {
        node.forEach(update(of: \.count, initial: true)) { count in
            counts.append(count)
        }
    }
}

