import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

/// Error thrown by `waitUntil` when its timeout elapses without the
/// predicate becoming true.
package struct WaitUntilTimeoutError: Error, CustomStringConvertible {
    package let file: StaticString
    package let line: UInt
    package let timeoutSeconds: Double

    package var description: String {
        "Timeout after \(timeoutSeconds)s waiting for condition at \(file):\(line)"
    }
}

/// Poll until `condition` becomes true, the deadline elapses, or the
/// Task is cancelled.
///
/// Use for predicates that read state **outside** the reactive system —
/// typically a `TestResult` / `LockIsolated` counter mutated from a
/// `forEach` callback. Predicates against tracked `@Model` state should
/// use `expect` / `require` / `settle`, which wake reactively via
/// `_noteActivity` and don't poll.
///
/// **Implementation**: each re-evaluation is scheduled through
/// `GlobalTickScheduler`. Callbacks fire from GCD's pool, NOT the Swift
/// cooperative pool, so re-checks happen on time even when the
/// cooperative pool is starved (which is precisely when polling-based
/// `Task.sleep` waits stop firing). All concurrent `waitUntil` calls
/// across parallel tests share one ticker — N tests = 1 GCD timer, not
/// N independent timers.
///
/// The continuation is resumed **exactly once**, by whichever of these
/// fires first:
///   • a poll evaluation returning `true` → returns normally
///   • the deadline being reached → throws `WaitUntilTimeoutError`
///   • the Task being cancelled → throws `CancellationError`
///
/// - Parameters:
///   - condition: Predicate to evaluate. Runs on GCD's pool inside the
///     scheduler tick; must be cheap and reentrant-safe.
///   - pollInterval: Minimum gap between re-evaluations, in nanoseconds.
///     Default 10 ms — matches `GlobalTickScheduler`'s tick granularity,
///     so this is the smallest cadence the scheduler can deliver in
///     practice. Smaller values are accepted but get rounded up by the
///     ticker.
///   - timeout: Maximum total wall-clock time before throwing
///     `WaitUntilTimeoutError`. Default 5 s. The effective timeout is the
///     value passed here **multiplied by `ModelTestingTraitOptions.timeoutScale`**
///     (env `SWIFT_MODEL_TIMEOUT_SCALE`, default 1.0) — so a test calling
///     `waitUntil(..., timeout: 15s)` waits 45 s on CI when scale=3.
///     This matches the framework-level budget scaling and removes the need
///     for individual tests to know about CI tolerance.
package func waitUntil(
    _ condition: @autoclosure @escaping @Sendable () -> Bool,
    pollInterval: UInt64 = 10_000_000,
    timeout: UInt64 = 5_000_000_000,
    file: StaticString = #file,
    line: UInt = #line
) async throws {
    if condition() { return }
    // With the per-test harness executor active, the wall-clock budget is not
    // the right cap: `waitUntil` already polls via GTS (non-starvable), so the
    // only failure mode under load was the deadline firing before the model —
    // slowed by contention — set the condition. Extend the cap to the deadlock
    // watchdog so the condition is caught whenever the model's work completes
    // (load-tolerant); a genuinely-never-true condition still fails, just at the
    // watchdog rather than a per-test budget.
    var executorActive = false
    #if canImport(Dispatch)
    if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
        executorActive = _TestExecutorBox.current is _DrainTestExecutor
    }
    #endif
    let scaledTimeout = executorActive
        ? 120_000_000_000   // watchdog (see `_executorHangDeadlineNs`)
        : UInt64(Double(timeout) * ModelTestingTraitOptions.timeoutScale)
    try await _waitUntil(
        condition: condition,
        pollInterval: pollInterval,
        timeout: scaledTimeout,
        file: file,
        line: line
    )
}

#if canImport(Dispatch)
private func _waitUntil(
    condition: @escaping @Sendable () -> Bool,
    pollInterval: UInt64,
    timeout: UInt64,
    file: StaticString,
    line: UInt
) async throws {
    let startNs = DispatchTime.now().uptimeNanoseconds
    let deadlineNs = startNs &+ timeout

    // Shared state: tracks the in-flight GTS cancel handle, whether the
    // continuation has already been resumed (so the cancellation path
    // and the tick callback don't double-resume), and the continuation
    // itself. Class so the GTS callback and onCancel can both capture by
    // reference.
    final class State: @unchecked Sendable {
        var cont: CheckedContinuation<Result<Void, Error>, Never>?
        var cancelHandle: (@Sendable () -> Void)?
        var resumed: Bool = false
    }
    let state = State()
    let lock = NSLock()

    /// Schedules the next poll tick at `pollDeadline` (absolute monotonic ns).
    /// On fire, runs `condition()` (still on the GCD pool) and resolves the
    /// continuation if the predicate passes or the overall deadline has
    /// elapsed; otherwise re-schedules the next tick.
    @Sendable func schedulePoll(at pollDeadline: UInt64) {
        let cancel = GlobalTickScheduler.shared.schedule(deadlineNs: pollDeadline) {
            let now = DispatchTime.now().uptimeNanoseconds

            // Test the predicate from GCD's pool (not the cooperative pool).
            let passed = condition()

            let resolution: Result<Void, Error>?
            if passed {
                resolution = .success(())
            } else if now >= deadlineNs {
                resolution = .failure(WaitUntilTimeoutError(
                    file: file,
                    line: line,
                    timeoutSeconds: Double(timeout) / 1_000_000_000.0
                ))
            } else {
                resolution = nil
            }

            if let resolution {
                let toResume: CheckedContinuation<Result<Void, Error>, Never>? = lock.withLock {
                    guard !state.resumed, let c = state.cont else { return nil }
                    state.resumed = true
                    state.cont = nil
                    state.cancelHandle = nil
                    return c
                }
                toResume?.resume(returning: resolution)
            } else {
                let nextPollAt = min(now &+ pollInterval, deadlineNs)
                schedulePoll(at: nextPollAt)
            }
        }
        // Replace the previous cancel handle with this one. The previous
        // GTS entry has already fired by the time we get here (we're
        // inside its callback), so cancelling it is a no-op — we only
        // store the new handle for the cancellation path.
        lock.withLock {
            if !state.resumed {
                state.cancelHandle = cancel
            } else {
                // Cancellation path beat us to it — release the just-scheduled tick.
                cancel()
            }
        }
    }

    let result = await withTaskCancellationHandler {
        await withCheckedContinuation { (cont: CheckedContinuation<Result<Void, Error>, Never>) in
            let immediate: Result<Void, Error>? = lock.withLock {
                if Task.isCancelled {
                    state.resumed = true
                    return .failure(CancellationError())
                }
                state.cont = cont
                return nil
            }
            if let immediate {
                cont.resume(returning: immediate)
                return
            }
            // Schedule the first poll one `pollInterval` from now.
            let firstPoll = min(startNs &+ pollInterval, deadlineNs)
            schedulePoll(at: firstPoll)
        }
    } onCancel: {
        let toResume: CheckedContinuation<Result<Void, Error>, Never>? = lock.withLock {
            guard !state.resumed else { return nil }
            state.resumed = true
            state.cancelHandle?()
            state.cancelHandle = nil
            let c = state.cont
            state.cont = nil
            return c
        }
        toResume?.resume(returning: .failure(CancellationError()))
    }

    try result.get()
}
#else
// Fallback for platforms without Dispatch (WASI): fall back to
// `Task.sleep`-based polling. GTS doesn't exist on WASM.
private func _waitUntil(
    condition: @escaping @Sendable () -> Bool,
    pollInterval: UInt64,
    timeout: UInt64,
    file: StaticString,
    line: UInt
) async throws {
    let startNs = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    let deadlineNs = startNs &+ timeout
    while !condition() {
        let now = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        if now >= deadlineNs {
            throw WaitUntilTimeoutError(
                file: file,
                line: line,
                timeoutSeconds: Double(timeout) / 1_000_000_000.0
            )
        }
        try await Task.sleep(nanoseconds: pollInterval)
    }
}
#endif
