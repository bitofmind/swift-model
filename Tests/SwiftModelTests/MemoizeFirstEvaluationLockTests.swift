import Foundation
import Testing
import ConcurrencyExtras
@testable import SwiftModel

/// A memoize's first evaluation runs `produce()` without holding the model tree's lock.
///
/// It used to run inside `context.transaction`, so user code of any cost held the tree
/// lock and every other thread's reads of the tree waited for it. Downstream, an editor's
/// main thread spent a third of a layer switch waiting on a background memoize's first
/// evaluation.
@Suite(.modelTesting(exhaustivity: .off))
struct MemoizeFirstEvaluationLockTests {

    @Test func treeLockIsFreeDuringFirstProduce() async {
        let model = LockProbeModel().withAnchor()
        let lock = model.node._context!.lock

        model.probe.setValue { tryLockFromAnotherThread(lock) }
        _ = model.probed

        #expect(model.lockWasFree.value == [true])
    }

    @Test func dependencyChangeDuringFirstProduceIsNotLost() async {
        let model = WriteDuringProduceModel().withAnchor()

        // The first evaluation reads `value` (1), then changes it to 2 before the cache
        // entry exists. The entry must start dirty, so the next read recomputes, rather than
        // cache 2 as clean until the scheduled re-evaluation gets around to it. The first
        // read returns 2, or 4 when that re-evaluation finished first (`updateInitial`
        // then serves the fresher value).
        let first = model.doubled
        #expect(first == 2 || first == 4)
        let context = model.node._context!
        let (isDirty, cached): (Bool, Int?) = context.lock {
            let entry = context._memoizeCache[AnyHashableSendable("doubled")]
            return (entry?.isDirty ?? false, entry?.value as? Int)
        }
        #expect(isDirty || cached == 4)
        #expect(model.value == 2)
        #expect(model.doubled == 4)
    }
}

/// `lock.try()` from a dedicated thread: `true` if no other thread holds the lock.
private func tryLockFromAnotherThread(_ lock: NSRecursiveLock) -> Bool {
    let result = LockIsolated(false)
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        if lock.try() {
            lock.unlock()
            result.setValue(true)
        }
        done.signal()
    }
    thread.start()
    done.wait()
    return result.value
}

@Model private struct LockProbeModel {
    var value = 1
    let probe = LockIsolated<(@Sendable () -> Bool)?>(nil)
    let lockWasFree = LockIsolated<[Bool]>([])

    var probed: Int {
        node.memoize(for: "probed") {
            if let probe = probe.value {
                lockWasFree.withValue { $0.append(probe()) }
            }
            return value
        }
    }
}

@Model private struct WriteDuringProduceModel {
    var value = 1

    var doubled: Int {
        node.memoize(for: "doubled") {
            let current = value
            if current == 1 { value = 2 }
            return current * 2
        }
    }
}
