import Testing
import Observation
import Foundation
import ConcurrencyExtras
@testable import SwiftModel

/// Comprehensive tests for transaction semantics
///
/// Transactions in SwiftModel provide:
/// 1. **Atomicity**: Multiple mutations appear as a single atomic update
/// 2. **Consistency**: External observers don't see intermediate states
/// 3. **Batching**: Notifications are deferred until transaction completes
struct TransactionTests {

    // MARK: - Basic Transaction Semantics

    @Test func testTransactionAtomicity() async throws {
        let model = AtomicModel().withAnchor()

        // Setup observer to track updates
        let updateCount = LockIsolated(0)
        model.node.forEach(Observed { model.balance }) { _ in
            updateCount.withValue { $0 += 1 }
        }

        // Wait for initial observation
        try await waitUntil(updateCount.value == 1)
        #expect(updateCount.value == 1)  // Initial value

        // Without transaction: multiple updates
        model.balance = 100
        try await waitUntil(updateCount.value == 2)
        model.balance = 200
        try await waitUntil(updateCount.value == 3)
        #expect(updateCount.value == 3)  // Initial + 2 updates

        // With transaction: single atomic update
        let before = updateCount.value
        model.transaction {
            model.balance = 300
            model.balance = 400
            model.balance = 500
        }
        try await waitUntil(updateCount.value == before + 1)
        #expect(updateCount.value == before + 1)  // Only 1 update for entire transaction
    }

    @Test func testTransactionConsistency() async throws {
        let model = ConsistencyModel().withAnchor()

        // Track invariant: total should always equal sum of parts
        let invariantViolations = LockIsolated(0)
        model.node.forEach(Observed { (model.partA, model.partB, model.total) }) { tuple in
            let (a, b, total) = tuple
            if a + b != total {
                invariantViolations.withValue { $0 += 1 }
            }
        }

        // Wait for initial observation
        try await waitUntil(invariantViolations.value == 0)
        #expect(invariantViolations.value == 0)

        // Without transaction: invariant can be violated mid-update
        model.partA = 50
        // At this point, partA=50, partB=0, total=0 (INCONSISTENT)
        try await waitUntil(invariantViolations.value > 0)
        #expect(invariantViolations.value > 0)  // Invariant violated!

        model.total = 50  // Fix it
        // Give time for fix to propagate
        try await Task.sleep(for: .milliseconds(10))

        // With transaction: invariant never violated
        let beforeViolations = invariantViolations.value
        model.transaction {
            model.partA = 100
            model.partB = 200
            model.total = 300
        }
        // Observer only sees final consistent state
        try await Task.sleep(for: .milliseconds(10))
        #expect(invariantViolations.value == beforeViolations)  // No new violations
    }

    @Test func testNestedTransactions() async throws {
        let model = NestedTransactionModel().withAnchor()

        let updateCount = LockIsolated(0)
        model.node.forEach(Observed { model.value }) { _ in
            updateCount.withValue { $0 += 1 }
        }

        try await waitUntil(updateCount.value == 1)
        #expect(updateCount.value == 1)  // Initial

        // Nested transactions should behave as single transaction
        model.transaction {
            model.value = 10

            model.transaction {
                model.value = 20
                model.value = 30
            }

            model.value = 40
        }

        try await waitUntil(updateCount.value == 2)
        #expect(updateCount.value == 2)  // Initial + 1 (not 4)
        #expect(model.value == 40)
    }

    // MARK: - Transaction Read Semantics

    @Test func testReadDuringTransaction() async throws {
        let model = ReadDuringTransactionModel().withAnchor()

        model.transaction {
            model.value = 10

            // Reads within transaction should see latest value
            #expect(model.value == 10)

            model.value = 20
            #expect(model.value == 20)
        }
    }

    @Test func testComputedPropertyDuringTransaction() async throws {
        let model = ComputedDuringTransactionModel().withAnchor()

        model.transaction {
            model.a = 10
            model.b = 20

            // Computed property should see latest values
            #expect(model.sum == 30)

            model.a = 100
            #expect(model.sum == 120)
        }
    }

    // MARK: - Transaction Isolation

    @Test func testConcurrentReadsDuringTransaction() async throws {
        let model = IsolationModel().withAnchor()
        model.value = 100

        let observedValues = LockIsolated<[Int]>([])

        // Start a long transaction (synchronous, so actually blocks)
        Task.detached {
            model.transaction {
                model.value = 200
                Thread.sleep(forTimeInterval: 0.05)
                model.value = 300
                Thread.sleep(forTimeInterval: 0.05)
                model.value = 400
            }
        }

        // Concurrent reads from another thread
        await Task.detached {
            for _ in 0..<10 {
                let val = model.value
                observedValues.withValue { $0.append(val) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }.value

        try await Task.sleep(for: .milliseconds(200))

        // External reads should see either old value (100) or final value (400)
        // But NEVER intermediate values (200, 300) due to lock
        for val in observedValues.value {
            #expect(val == 100 || val == 400)
        }
    }

    // MARK: - Notification Batching

    @Test func testNotificationBatching() async throws {
        let model = NotificationBatchingModel().withAnchor()

        let notificationCount = LockIsolated(0)
        let notifiedValues = LockIsolated<[Int]>([])

        model.node.forEach(Observed { model.value }) { value in
            notificationCount.withValue { $0 += 1 }
            notifiedValues.withValue { $0.append(value) }
        }

        try await waitUntil(notificationCount.value == 1)

        // Many mutations in transaction
        model.transaction {
            for i in 1...100 {
                model.value = i
            }
        }

        try await waitUntil(notificationCount.value == 2)

        // Should receive exactly 2 notifications: initial + final
        #expect(notificationCount.value == 2)
        #expect(notifiedValues.value == [0, 100])
    }

    // MARK: - Error Handling

    @Test func testTransactionRollback() async throws {
        let model = RollbackModel().withAnchor()
        model.value = 10

        do {
            try model.transaction {
                model.value = 20
                model.value = 30
                throw TestError.intentional
            }
        } catch {
            // Transaction threw
        }

        // Note: SwiftModel does NOT rollback on error
        // The mutations stick
        #expect(model.value == 30)
    }
}

// MARK: - Test Models

@Model private struct AtomicModel {
    var balance = 0
}

@Model private struct ConsistencyModel {
    var partA = 0
    var partB = 0
    var total = 0
}

@Model private struct NestedTransactionModel {
    var value = 0
}

@Model private struct ReadDuringTransactionModel {
    var value = 0
}

@Model private struct ComputedDuringTransactionModel {
    var a = 0
    var b = 0

    var sum: Int {
        a + b
    }
}

@Model private struct IsolationModel {
    var value = 0
}

@Model private struct NotificationBatchingModel {
    var value = 0
}

@Model private struct RollbackModel {
    var value = 0
}

private enum TestError: Error {
    case intentional
}
