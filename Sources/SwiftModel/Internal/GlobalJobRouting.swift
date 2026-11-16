import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Routing global-executor jobs into the per-test drain executor
//
// A plain `Task {}` (or `Task.detached`, or a task-group child of one) has no
// task-executor preference, so its jobs go to the global concurrent executor,
// where the drive can't count them. Third-party async operators start such tasks
// internally — AsyncAlgorithms' combineLatest/merge/zip/debounce/... — so a
// write → operator task → model consumer chain has a hop `settle()` can't see.
//
// `Task {}` does inherit task-locals, though, including `_TestExecutorBox.current`.
// The runtime calls `swift_task_enqueueGlobal_hook` for every global enqueue, on
// the enqueuing thread. If the enqueuing task belongs to a `.modelTesting` test,
// the job is handed to that test's drain executor instead, so it is counted like
// any model job. Its task keeps no preference: when it next suspends, its resume
// goes through this hook again.

#if canImport(Dispatch) && (canImport(Darwin) || canImport(Glibc))
private typealias _EnqueueGlobalOriginal = @convention(thin) (UnownedJob) -> Void
private typealias _EnqueueGlobalHook = @convention(thin) (UnownedJob, _EnqueueGlobalOriginal) -> Void

private nonisolated(unsafe) let _enqueueGlobalHookSlot: UnsafeMutablePointer<_EnqueueGlobalHook?>? = {
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), "swift_task_enqueueGlobal_hook") else { return nil }
    return sym.assumingMemoryBound(to: _EnqueueGlobalHook?.self)
}()

/// The hook installed before ours, if any (e.g. ConcurrencyExtras'
/// `withMainSerialExecutor`); jobs we don't route go to it.
private nonisolated(unsafe) var _previousEnqueueGlobalHook: _EnqueueGlobalHook?

private let _installGlobalJobRouting: Bool = {
    if ProcessInfo.processInfo.environment["SWIFT_MODEL_ROUTE_GLOBAL_JOBS"] == "0" { return false }
    guard let slot = _enqueueGlobalHookSlot else { return false }
    _previousEnqueueGlobalHook = slot.pointee
    slot.pointee = { job, original in
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *),
           !_GlobalJobRouting.bypass,
           let exec = (_TestExecutorBox.current as? _DrainTestExecutor) ?? _DrainTestExecutor.runningOnThisThread {
            exec.enqueueRouted(job)
            return
        }
        if let previous = _previousEnqueueGlobalHook {
            previous(job, original)
        } else {
            original(job)
        }
    }
    return true
}()


enum _GlobalJobRouting {
    /// Set while SwiftModel's own harness tasks enqueue jobs that the drive already
    /// tracks another way (the background-call drain task), so they are not routed.
    @TaskLocal static var bypass = false
}

/// Installs the hook once per process. Called when a test's drain executor is made.
func _ensureGlobalJobRouting() {
    _ = _installGlobalJobRouting
}
#else
enum _GlobalJobRouting {
    @TaskLocal static var bypass = false
}

func _ensureGlobalJobRouting() {}
#endif
