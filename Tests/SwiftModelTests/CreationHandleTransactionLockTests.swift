#if canImport(Dispatch)
import Foundation
import Dispatch
import Testing
import ConcurrencyExtras
@testable import SwiftModel

/// A transaction through a model's creation handle must take the tester's write lock
/// before the context lock, like every other writer.
///
/// 1.1.4 let a write through a handle with no access fall back to the tree's tester
/// (`fallbackTestAccess`). Writes inside a transaction resolve that fallback and take
/// the tester lock, but the transaction's own lock chain didn't include it. So
/// `dup.node.transaction { dup.x = … }` held the context lock and then waited for the
/// tester lock, while a reader holding the tester lock waited for the context lock.
/// Downstream that was a deterministic deadlock: a stream-environment model updated
/// in a transaction while a media controller's task read model state.
///
/// The deadlock needs a racing reader, so the test checks the invariant directly:
/// while the transaction body runs, another thread must find the tester lock held.
@Suite
struct CreationHandleTransactionLockTests {

    @Test func nodeTransactionThroughCreationHandleHoldsTesterLock() {
        let tester = ModelTester(LockRoot(items: []), exhaustivity: .off)
        let root = tester.model
        let dup = LockItem(id: -1, value: 0)
        root.items.append(dup)

        let testerLock = tester.access.lock
        let heldByTransaction = LockIsolated<Bool?>(nil)
        dup.node.transaction {
            heldByTransaction.setValue(Self.isHeldByAnotherThread(testerLock))
            dup.value = 1
        }

        #expect(heldByTransaction.value == true)
        #expect(root.items[0].value == 1)
    }

    /// `NSRecursiveLock.try()` from a different thread fails exactly when some thread
    /// holds the lock.
    ///
    /// The probe runs on a dedicated `Thread`, not a GCD queue. The caller blocks until
    /// it answers, and it blocks a Swift-concurrency thread while holding locks. A
    /// `DispatchQueue.global()` block took ~60 s to be scheduled on a TSan CI runner,
    /// and parking a cooperative thread that long starved the parallel tests' model
    /// tasks. A new thread starts at once, so the caller waits only for one `try()`.
    static func isHeldByAnotherThread(_ lock: NSRecursiveLock) -> Bool {
        let result = LockIsolated(false)
        let done = DispatchSemaphore(value: 0)
        let probe = Thread {
            if lock.try() {
                lock.unlock()
                result.setValue(false)
            } else {
                result.setValue(true)
            }
            done.signal()
        }
        probe.start()
        done.wait()
        return result.value
    }
}

@Model private struct LockItem: Identifiable {
    var id: Int
    var value: Int
}

@Model private struct LockRoot {
    var items: [LockItem]
}
#endif
