import Foundation
#if canImport(Dispatch)
import Dispatch
#endif
import CustomDump
import IssueReporting
import Dependencies

private func monotonicNanoseconds() -> UInt64 {
    #if canImport(Dispatch)
    return DispatchTime.now().uptimeNanoseconds
    #else
    return UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    #endif
}

extension TestAccess {
    /// Suspends briefly so the async pipeline can settle, then returns so the outer
    /// assert loop can re-check its predicate.
    ///
    /// Uses an escalation strategy based on `retryCount` to balance two competing needs:
    ///
    /// - **Fast conditions** (e.g. a model property set by a cancellation handler):
    ///   The value is written directly to `lastState` synchronously. A short kernel
    ///   timer is sufficient — no need to wait for `backgroundCall` at all.
    ///
    /// - **Async conditions** (memoized properties, `Observed` streams):
    ///   Both go through `backgroundCall` — memoize's performUpdate and Observed stream
    ///   updates all use the same per-test task-local queue. A FIFO sentinel via
    ///   `waitForCurrentItems` ensures the update has run before re-checking.
    ///
    /// Escalation by retry count:
    ///   0-1: Short kernel timer (1ms) — fast path for already-settled conditions.
    ///   2+:  Use `waitForCurrentItems(deadline:)` then `waitUntilIdle()`. Ensures
    ///        the drain loop has run so stream consumers have had a scheduler turn.
    ///
    /// All waiting is done via `onAnyModification` callbacks and timers (kernel-level on
    /// platforms with `libdispatch`, `Task.sleep` on WASM). `Task.yield()` alone is not used
    /// for the timer because on a saturated cooperative pool it can suspend for minutes.
    ///
    /// Returns `true` if a state modification was observed during the wait (progress was made).
    @discardableResult
    package func waitForModification(timeoutNanoseconds remaining: UInt64, yieldRoundNs: UInt64, retryCount: Int = 0) async -> Bool {
        guard remaining > 0 else { return false }

        let bgQueue = backgroundCall

        // A continuation slot shared between the onAnyModification callback and the
        // DispatchQueue timer. Protected by LockIsolated so exactly one of them resumes
        // the continuation (the first one sets slot to nil, preventing a double-resume).
        let contSlot = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
        let didModify = LockIsolated(false)

        // Resumes the continuation exactly once. Called from the onAnyModification
        // callback (on the model-writing thread) and from the DispatchQueue timer.
        let signal: @Sendable () -> Void = {
            didModify.setValue(true)
            contSlot.withValue { slot in
                slot?.resume()
                slot = nil
            }
        }

        // Register BEFORE any queue drain so modifications during drain are captured.
        let cancelModification = context.onAnyModification { _ in signal }
        defer { cancelModification() }

        // For retryCount >= 2 with pending queue items, drain the queue first.
        // Any modifications that arrive during the drain are captured via signal().
        if retryCount >= 2 && !bgQueue.isIdle {
            // FIFO sentinel: suspend until all items currently in the queue have been
            // processed. When it fires, any pending performUpdate has already run.
            //
            // Deadline: use the full remaining timeout. By retry 2, fast conditions
            // (e.g. testCancelInFlight) have already passed on earlier retries, so we
            // know this is a genuinely async condition.
            let deadline = monotonicNanoseconds() + remaining
            await bgQueue.waitForCurrentItems(deadline: deadline)
            // waitUntilIdle() ensures the drain loop has fully settled so stream
            // consumers have had a scheduling opportunity before we re-check.
            if !bgQueue.isIdle {
                await bgQueue.waitUntilIdle(deadline: deadline)
            }
            // If a modification was signalled during the drain, return now without
            // starting another kernel timer.
            if didModify.value { return true }
        }

        // Wait for either a modification signal or a kernel timer (whichever fires first).
        // Timer delay:
        // - Early retries (0-1): 1ms — fast path for already-satisfied conditions.
        // - Later retries (2+): yieldRoundNs — avoids busy-spinning while waiting for
        //   an async modification (e.g. forEach callback writing canUndo/canRedo).
        if !didModify.value {
            let delayNs: UInt64 = retryCount < 2 ? 1_000_000 : yieldRoundNs
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let alreadyModified = contSlot.withValue { slot -> Bool in
                    if didModify.value { return true }
                    slot = cont
                    return false
                }
                if alreadyModified {
                    cont.resume()
                    return
                }
                // Timer to wake the continuation after delayNs.
                scheduleAfter(nanoseconds: delayNs) {
                    contSlot.withValue { slot in
                        slot?.resume()
                        slot = nil
                    }
                }
            }
        }

        return didModify.value
    }

    // MARK: - TaskLifecycleDelegate

    func activationTaskCreated() {
        lock { _activationTasksInFlight += 1 }
    }

    func activationTaskEntered() {
        lock { _activationTasksInFlight -= 1 }
    }

    func taskCreated() {
        lock { _activeTaskCount += 1 }
    }

    func taskCompleted() {
        lock { _activeTaskCount -= 1 }
    }

    /// True when all tasks born from `onActivate()` have begun executing their body.
    var activationTasksInFlight: Int {
        lock { _activationTasksInFlight }
    }

    /// True when no tasks are currently running anywhere in the hierarchy.
    var isCompletelyIdle: Bool {
        lock { _activeTaskCount == 0 }
    }

    /// Builds a diagnostic string for settle() timeout failures.
    private func settleTimeoutDiagnostics() -> String {
        var lines: [String] = []
        let taskInfos = context.activeTasks
        for info in taskInfos {
            for (taskName, fl) in info.tasks {
                lines.append("  \(info.modelName): \"\(taskName)\" @ \(fl.fileID):\(fl.line)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Shared calibration and settling

    /// Measures scheduler latency and computes adaptive timeouts.
    ///
    /// The calibration yield measures how long a `yieldToScheduler()` takes under current
    /// system load, then scales all timeouts proportionally. This makes the wait loops
    /// robust under both light (single test) and heavy (100× parallel) conditions.
    ///
    /// - Parameter timeout: Base timeout for predicate waiting (default 1 s). Short explicit
    ///   timeouts (e.g. from output snapshot tests) are preserved as-is.
    package func calibrate(timeout: UInt64 = nanosPerSecond) async -> WaitCalibration {
        let calibrationStart = monotonicNanoseconds()
        await yieldToScheduler()
        let yieldLatencyNs = monotonicNanoseconds() - calibrationStart
        lock { _lastYieldLatencyNs = yieldLatencyNs }
        return makeCalibration(yieldLatencyNs: yieldLatencyNs, timeout: timeout)
    }

    /// Builds a `WaitCalibration` from the most recently measured scheduler latency,
    /// without performing a new GCD hop. Intended for end-of-test cleanup paths that
    /// are called by hundreds of parallel tests simultaneously — a fresh GCD hop from
    /// each would saturate the global queue and add seconds of overhead to every test.
    package func calibrateWithCachedLatency(timeout: UInt64 = nanosPerSecond) -> WaitCalibration {
        let yieldLatencyNs = lock { _lastYieldLatencyNs }
        return makeCalibration(yieldLatencyNs: yieldLatencyNs, timeout: timeout)
    }

    private func makeCalibration(yieldLatencyNs: UInt64, timeout: UInt64) -> WaitCalibration {
        let scaledTimeout = timeout >= nanosPerSecond
            ? min(10 * nanosPerSecond, max(timeout, yieldLatencyNs * 100))
            : timeout
        let yieldRoundNs = max(1_000_000, min(500_000_000, yieldLatencyNs))
        let hardCap = TestAccessOverrides.hardCapNanoseconds
            ?? min(30 * nanosPerSecond, max(5 * nanosPerSecond, scaledTimeout * 10))
        return WaitCalibration(
            yieldLatencyNs: yieldLatencyNs,
            yieldRoundNs: yieldRoundNs,
            scaledTimeout: scaledTimeout,
            hardCap: hardCap,
            start: monotonicNanoseconds()
        )
    }

    /// Waits for the model hierarchy to become idle using adaptive calibration.
    ///
    /// Phase 1: Wait for all `onActivate()`-born tasks to begin executing their body.
    /// Phase 2: Idle cycle — wait until `modificationCount` stabilizes across a full
    /// scheduling round with no active tasks running.
    ///
    /// Used by `expect`'s settle path and by end-of-test `checkExhaustion`.
    /// Returns `true` on success, `false` if the hard cap was hit.
    /// - Parameter reportTimeout: When `true` (default), reports a test failure if the
    ///   hard cap is hit. Pass `false` from `checkExhaustion` where the subsequent
    ///   exhaustivity check handles failure reporting through proper exhaustivity bits.
    @discardableResult
    package func waitUntilSettled(calibration cal: WaitCalibration, reportTimeout: Bool = true, at fileAndLine: FileAndLine) async -> Bool {
        // Phase 1: Wait for all activation tasks to enter their body.
        // In practice this completes almost immediately because activationTaskEntered()
        // fires at the start of the task body.
        //
        // Skip when called from checkExhaustion (reportTimeout: false): activation tasks
        // that haven't started yet have already been cancelled by cancelAllRecursively()
        // and removed from Cancellations.registered / activeTasks. Waiting for them to
        // start under 500+ parallel test load can take 30 s (cooperative pool saturation
        // causes 30,000 × 1ms iterations). The subsequent checkExhaustion(checkTasks:)
        // call won't see them — safe to skip.
        if reportTimeout {
            while activationTasksInFlight > 0 {
                await waitForModification(timeoutNanoseconds: cal.scaledTimeout, yieldRoundNs: cal.yieldRoundNs, retryCount: 0)
                if cal.start.distance(to: monotonicNanoseconds()) > cal.hardCap {
                    let taskInfo = settleTimeoutDiagnostics()
                    fail("settle() timed out: model still has active tasks.\n\(taskInfo)", at: fileAndLine)
                    return false
                }
            }
        }

        // Phase 2: Idle cycle — wait until one full scheduling round passes
        // with no state changes. Uses modificationCount on the root context as
        // a version number.
        var lastChangeVersion = context.modificationCount
        // Tracks whether we already confirmed _activeTaskCount == 0 with a stable
        // modificationCount in the previous outer-loop iteration.
        //
        // The race we guard against: a just-completed task dispatches its final model
        // mutation to backgroundCall AND decrements _activeTaskCount in the same
        // cooperative-pool turn. The next check sees _activeTaskCount == 0 and a stable
        // modificationCount (backgroundCall hasn't committed the mutation yet), and
        // would break prematurely — baseline captures the pre-mutation value.
        //
        // Fix: require two consecutive outer-loop iterations that both see
        // _activeTaskCount == 0 with no modificationCount change. The
        // waitForCurrentItems at the START of the NEXT iteration (line 1332) naturally
        // drains the pending mutation, so modificationCount changes and we loop once
        // more to re-confirm. No extra drain is added; the existing loop structure
        // handles it. For observation-heavy models this adds at most two cheap
        // no-op iterations rather than triggering cascading observation re-fires.
        var sawZeroActiveTasks = false
        while true {
            await backgroundCall.waitForCurrentItems(deadline: cal.start + cal.hardCap)
            await yieldToScheduler()

            // Re-check activation tasks: backgroundCall drain or yieldToScheduler
            // may have triggered child model activations (e.g. SearchResultItem
            // activated when results is set), creating new tasks that haven't entered
            // their body yet. Wait for them before evaluating idle state.
            // Skipped when called from checkExhaustion (reportTimeout: false) for the
            // same reason as Phase 1: cancelled tasks that haven't started yet are safe
            // to ignore (removed from activeTasks by cancelAllRecursively).
            if reportTimeout {
                while activationTasksInFlight > 0 {
                    await waitForModification(timeoutNanoseconds: cal.scaledTimeout, yieldRoundNs: cal.yieldRoundNs, retryCount: 0)
                    if cal.start.distance(to: monotonicNanoseconds()) > cal.hardCap {
                        let taskInfo = settleTimeoutDiagnostics()
                        fail("settle() timed out: model still has active tasks.\n\(taskInfo)", at: fileAndLine)
                        return false
                    }
                }
            }

            let currentVersion = context.modificationCount
            if currentVersion == lastChangeVersion {
                if lock({ _activeTaskCount }) == 0 {
                    if sawZeroActiveTasks {
                        break // confirmed: two consecutive checks with no active tasks and no changes
                    }
                    sawZeroActiveTasks = true
                    continue // loop once more; waitForCurrentItems at top drains any pending mutations
                }
                sawZeroActiveTasks = false
                // Tasks are still running but no state changed yet. Use a GCD-backed
                // timer (waitForModification) rather than Task.yield() loops. Under
                // 500+ parallel tests the cooperative pool is saturated — each
                // Task.yield() can take 1-2s, so 20 yields × 1.5s = 30s = hardCap.
                // waitForModification uses a DispatchQueue timer and an
                // onAnyModification callback, so it wakes immediately on any write
                // regardless of cooperative pool pressure.
                //
                // Patience is context-dependent:
                //
                // reportTimeout: true  (active test — tasks are still running and may write)
                //   max(yieldRoundNs × 3, 300ms): scales with load. Under saturation
                //   (yieldRoundNs ~500ms) a completing task may need 1–2 cooperative pool
                //   turns (~500ms–1s) before it can write; 1.5s ensures we don't break
                //   out before the write arrives.
                //
                // reportTimeout: false (checkExhaustion cleanup — tasks are cancelled)
                //   min(yieldRoundNs × 30, 300ms): always ≤ 300ms. Cancelled tasks won't
                //   write again; we only need to detect observation loops. The outer
                //   yieldToScheduler() loop then gives cancelled tasks cooperative-pool
                //   turns to exit and decrement _activeTaskCount without the 1.5s
                //   per-test overhead that accumulates across 500+ parallel tests.
                let patience = reportTimeout
                    ? max(cal.yieldRoundNs * 3, 300_000_000)
                    : min(cal.yieldRoundNs * 30, 300_000_000)
                await waitForModification(timeoutNanoseconds: patience, yieldRoundNs: patience, retryCount: 2)
                if context.modificationCount == currentVersion {
                    break // No progress — remaining tasks are observation loops or cancelled tasks
                }
                lastChangeVersion = context.modificationCount
                sawZeroActiveTasks = false
            } else {
                lastChangeVersion = currentVersion
                sawZeroActiveTasks = false
            }
            if cal.start.distance(to: monotonicNanoseconds()) > cal.hardCap {
                if reportTimeout {
                    let taskInfo = settleTimeoutDiagnostics()
                    fail("settle() timed out: model still has active tasks.\n\(taskInfo)", at: fileAndLine)
                }
                return false
            }
        }

        return true
    }

    // Checks that no state changed without being asserted (exhaustion check).
    //
    // At the end, resets expectedState = lastState so the next assert starts from a
    // clean baseline.
}
