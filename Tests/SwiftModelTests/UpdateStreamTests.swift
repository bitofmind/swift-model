import Testing
@testable import SwiftModel
import SwiftModelTesting
import Observation

@Suite(.modelTesting)
struct UpdateStreamTests {
    @Test(arguments: ObservationPath.allCases)
    func testChangeOf(observationPath: ObservationPath) async throws {
        let model = ValuesModel(initial: false, recursive: false).withAnchor(options: observationPath.options)

        model.count += 5
        await expect {
            model.count == 5
            model.counts == [5]
        }

        model.count += 3
        await expect {
            model.count == 8
            model.counts == [5, 8]
        }
    }

    @Test(arguments: ObservationPath.allCases)
    func testChangeOfConcurrency(observationPath: ObservationPath) async throws {
        let model = ValuesModel(initial: false, recursive: false).withAnchor(options: observationPath.options)

        let range = 1...10
        await Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for _ in range {
                    group.addTask {
                        model.count += 1
                    }
                }
                
                await group.waitForAll()
            }
        }.value

        // Give time for background observation callbacks to process
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        await expect(timeoutNanoseconds: 5_000_000_000) {
            model.count == range.count
            model.counts.count > 0
            model.counts == model.counts.sorted()
            model.counts.last == range.count
        }
    }

    @Test(arguments: UpdatePath.allCases)
    func testChangeOfChild(updatePath: UpdatePath) async throws {
        let model = ValuesModel(child: ChildModel(count: 2), initial: true, recursive: false).withAnchor(options: updatePath.options)

        await expect {
            model.child.count == 2
            model.childCounts == [2]
            model.counts == [0]
            model.optChildCounts == [nil]
        }

        model.child.count += 5
        await expect {
            model.child.count == 7
            model.childCounts == [2, 7]
        }

        model.child.count += 3
        await expect {
            model.child.count == 10
            model.childCounts == [2, 7, 10]
        }
    }

    @Test(arguments: UpdatePath.allCases)
    func testChangeOfChildWhereChildIsUpdated(updatePath: UpdatePath) async throws {
        let model = ValuesModel(child: ChildModel(count: 2), initial: true, recursive: false).withAnchor(options: updatePath.options)

        await expect {
            model.child.count == 2
            model.childCounts == [2]
            model.counts == [0]
            model.optChildCounts == [nil]
        }
        
        model.child = ChildModel(count: 4)
        await expect {
            model.child.count == 4
            model.childCounts == [2, 4]
        }
    }

    @Test
    func testChangeOfChildConcurrency() async throws {
        let model = ValuesModel(child: ChildModel(count: 0), initial: false, recursive: false).withAnchor(options: [])

        let range = 1...10
        await Task.detached {
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
        }.value

        // Give time for background observation callbacks to process
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        await expect(timeoutNanoseconds: 5_000_000_000) {
            model.child.count == range.count
            model.childCounts.count > 0
            model.childCounts == model.childCounts.sorted()
            model.childCounts.last == range.count
        }
    }

    @Test func testChangeOfOptChildWhereChildIsUpdated() async throws {
        let model = ValuesModel(initial: false, recursive: false).withAnchor(options: [])

        model.optChild = ChildModel(count: 4)
        await expect {
            model.optChild?.count == 4
            model.optChildCounts == [4]
        }

        model.optChild = nil
        await expect {
            model.optChild?.count == nil
            model.optChildCounts == [4, nil]
        }

        model.optChild = ChildModel(count: 7)
        await expect {
            model.optChild?.count == 7
            model.optChildCounts == [4, nil, 7]
        }
    }

    @Test(.modelTesting(exhaustivity: .full.subtracting(.tasks)))
    func testRace() async throws {
        let model = RaceModel().withAnchor()

        Task {
            model.count = 7
        }

        model.collectCounts()

        await expect {
            model.counts.last == 7
            model.count == 7
        }
    }

    @Test(.modelTesting(exhaustivity: .full.subtracting(.tasks)))
    func testRaceVariant() async throws {
        let model = RaceModel().withAnchor()

        Task {
            model.count = 7
        }

        Task {
            model.collectCounts()
        }
        
        await expect {
            model.counts.last == 7
            model.count == 7
        }
    }

    @Test func testRecursiveChild() async throws {
        let model = ValuesModel(initial: false, recursive: true).withAnchor(options: [])

        await expect {
            model.child.count == 0
            model.childChanges == []
        }

        model.child.count += 1

        await expect {
            model.child.count == 1
            model.childCounts == [1]
            model.childChanges == [1]
        }

        model.child.count += 5

        await expect {
            model.child.count == 6
            model.childCounts == [1, 6]
            model.childChanges == [1, 6]
        }
    }

    @Test func testRecursiveOptChild() async throws {
        let model = ValuesModel(initial: false, recursive: true).withAnchor(options: [])

        await expect {
            model.optChild == nil
            model.opChildChanges == []
        }

        model.optChild = ChildModel(count: 5)

        await expect {
            model.optChild?.count == 5
            model.optChildCounts == [5]
            model.opChildChanges == [5]
        }

        model.optChild?.count += 1

        await expect {
            model.optChild?.count == 6
            model.optChildCounts == [5, 6]
            model.opChildChanges == [5, 6]
        }

        model.optChild = nil

        await expect {
            model.optChild == nil
            model.optChildCounts == [5, 6, nil]
            model.opChildChanges == [5, 6, nil]
        }
    }

    @Test func testRecursiveChildren() async throws {
        let model = ValuesModel(initial: false, recursive: true).withAnchor(options: [])

        await expect(model.childrenCounts == [])

        model.children.append(ChildModel(count: 5))

        await expect {
            model.children.count == 1
            model.childrenCounts == [[5]]
        }

        model.children[0].count += 1

        await expect {
            model.children[0].count == 6
            model.childrenCounts == [[5], [6]]
        }

        model.children.append(ChildModel(count: 10))

        await expect {
            model.children.count == 2
            model.childrenCounts == [[5], [6], [6, 10]]
        }

        model.children.remove(at: 0)

        await expect {
            model.children.count == 1
            model.childrenCounts == [[5], [6], [6, 10], [10]]
        }

        model.children.removeAll()

        await expect {
            model.children.count == 0
            model.childrenCounts == [[5], [6], [6, 10], [10], []]
        }
    }

    @Test(.modelTesting(exhaustivity: .full.subtracting(.tasks)))
    func testComputed() async throws {
        let model = ComputedModel().withAnchor(options: [])

        model.count1 = 7
        model.count2 = 4

        await expect {
            model.computes == [3, 9, 11]
            model.squareds == [1, 49]
            model.count1 == 7
            model.count2 == 4
        }
    }

    @Test(.modelTesting(exhaustivity: .off))
    func testNestedComputed() async throws {
        let model = NestedComputedModel().withAnchor(options: [])

        model.computed = ComputedModel(count1: 4, count2: 8)
        model.computed?.count1 = 5
        model.computed = ComputedModel()
        model.computed?.count2 = 5
        model.computed = nil

        await expect {
            model.computes == [nil, 12, 13, 3, 6, nil]
            model.squareds == [nil, 16, 25, 1, nil]
        }
    }

    @Test(.modelTesting(exhaustivity: .full.subtracting(.tasks)))
    func testMemoize() async throws {
        let model = ComputedModel().withAnchor(options: [.disableMemoizeCoalescing])

        #expect(model.memoizeComputed == 3)
        #expect(model.memoizeSquared == 1)

        model.count1 = 7
        #expect(model.memoizeComputed == 9)
        #expect(model.memoizeSquared == 49)

        model.count2 = 4
        #expect(model.memoizeComputed == 11)
        #expect(model.memoizeSquared == 49)

        await expect {
            model.computes == [3, 9, 11]
            model.squareds == [1, 49]
            model.count1 == 7
            model.count2 == 4
        }
    }
}

@Model private struct ValuesModel {
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
        node.forEach(Observed(initial: initial, coalesceUpdates: false) { count }) { count in
            counts.append(count)
        }

        node.forEach(Observed(initial: initial, coalesceUpdates: false) { child.count }) { count in
            childCounts.append(count)
        }

        if recursive {
            node.forEach(Observed(initial: initial, coalesceUpdates: false) { child.count }) { count in
                childChanges.append(count)
            }

            node.forEach(Observed(initial: initial, coalesceUpdates: false) { optChild?.count }) { count in
                opChildChanges.append(count)
            }

            node.forEach(Observed(initial: initial, coalesceUpdates: false) { children.map(\.count) }) { counts in
                childrenCounts.append(counts)
            }
        }

        node.forEach(Observed(initial: initial, coalesceUpdates: false) { optChild?.count }) { count in
            optChildCounts.append(count)
        }
    }
}

@Model private struct ChildModel: Equatable {
    var count: Int = 0
}

@Model private struct RaceModel {
    var count: Int = 0
    var counts: [Int] = []

    func collectCounts() {
        node.forEach(Observed(coalesceUpdates: false) { count }) { count in
            counts.append(count)
        }
    }
}

@Model private struct ComputedModel: Equatable {
    var count1: Int = 1
    var count2: Int = 2
    var computed: Int { count1 + count2 }
    var squared: Int { count1 * count1 }


    var memoizeComputed: Int {
        node.memoize { computed }
    }

    var memoizeSquared: Int {
        node.memoize { squared }
    }

    var computes: [Int] = []
    var squareds: [Int] = []

    func onActivate() {
        node.forEach(Observed(coalesceUpdates: false) { computed }) {
            computes.append($0)
        }

        node.forEach(Observed(coalesceUpdates: false) { squared }) {
            squareds.append($0)
        }
    }
}

@Model private struct NestedComputedModel: Equatable {
    var computed: ComputedModel?

    var computes: [Int?] = []
    var squareds: [Int?] = []

    func onActivate() {
        node.forEach(Observed(coalesceUpdates: false) { computed?.computed }) {
            computes.append($0)
        }
        node.forEach(Observed(coalesceUpdates: false) { computed?.squared }) {
            squareds.append($0)
        }
    }
}
