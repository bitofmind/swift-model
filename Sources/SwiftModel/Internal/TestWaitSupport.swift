import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

private func _monotonicNs() -> UInt64 {
    #if canImport(Dispatch)
    return DispatchTime.now().uptimeNanoseconds
    #else
    return UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    #endif
}

extension TestAccess {
    // MARK: - waitUntilSettled (debounce + total budget)

    /// Window sizes for `waitUntilSettled`'s debounce. In-test settle is the
    /// happy-case latency every test pays — kept short. Cleanup mode runs
    /// after `cancelAllRecursively`, so cancellation handlers need slightly
    /// more breathing room to fire their final writes.
    package static var settleDebounceInTestNs: UInt64 { 50_000_000 }   // 50 ms
    package static var settleDebounceCleanupNs: UInt64 { 200_000_000 } // 200 ms

    /// Total time budget for in-test `waitUntilSettled` (and `expect`) before
    /// it declares the model "never settled". A test that hits this cap is
    /// genuinely stuck — a runaway `onActivate` task, a deadlock, or a
    /// predicate that doesn't react to model state. Fast-fail surfaces these
    /// promptly.
    ///
    /// Scaled by `ModelTestingTraitOptions.timeoutScale` (env
    /// `SWIFT_MODEL_TIMEOUT_SCALE`). Output-snapshot tests override
    /// absolutely via `TestAccessOverrides.$hardCapNanoseconds`.
    package static var settleTotalBudgetNs: UInt64 {
        TestAccessOverrides.hardCapNanoseconds ?? UInt64(5_000_000_000 * ModelTestingTraitOptions.timeoutScale)
    }

    /// Total time budget for **cleanup** `waitUntilSettled` (after
    /// `cancelAllRecursively` at end-of-test). Cleanup has to absorb the
    /// cooperative pool scheduling cancelled task bodies so they can hit
    /// their `Task.isCancelled` guard, unwind through `defer { onDone() }`,
    /// and unregister themselves from `Cancellations.registered`. Under
    /// heavy parallel-test load (each iteration runs ~700 tests in
    /// parallel; per-test cancellation handlers compete for cooperative-pool
    /// slots), this can take several seconds. The cleanup-settle's
    /// `hasPendingStartTask` gate keeps re-arming the quiet window until
    /// every cancelled task has finally been scheduled long enough to
    /// unregister.
    ///
    /// 25 s sits just under the 30 s `.modelTesting` trait cap, so a
    /// cleanup that exceeds this surfaces a real bug (a leaked task that
    /// won't unregister) rather than a load symptom. The in-test budget is
    /// kept short for fast feedback on genuinely-stuck tests.
    ///
    /// Scaled by `ModelTestingTraitOptions.timeoutScale`.
    package static var settleCleanupTotalBudgetNs: UInt64 {
        TestAccessOverrides.hardCapNanoseconds ?? UInt64(25_000_000_000 * ModelTestingTraitOptions.timeoutScale)
    }

    /// Returns when no model write / event send has occurred for one
    /// debounce window. The window resets on every activity (debounce
    /// semantic), so settle returns once the model has been genuinely
    /// quiet for the window — not when there are no active tasks. That
    /// last point matters: tests with healthy long-lived consumers
    /// (`forEach` over an async sequence, `onChange(initial: true)`,
    /// captured `Observed`) keep their consumer tasks alive indefinitely;
    /// they correctly settle here as long as they aren't currently
    /// writing.
    ///
    /// If activity keeps arriving faster than the debounce window can
    /// expire (runaway task that writes continuously),
    /// `settleTotalBudgetNs` provides a safety net: after that total
    /// time, settle reports `settle() timed out: model still has active
    /// tasks` and returns `false`. In `cleanup: true` mode the message
    /// is suppressed (`checkExhaustion` will report any still-running
    /// tasks via the `.tasks` exhaustivity bit instead).
    ///
    /// - Parameter cleanup: `false` (default) for in-test settle —
    ///   50 ms debounce. `true` for end-of-test cleanup after
    ///   `cancelAllRecursively` — 200 ms debounce, since cancel
    ///   handlers may take longer to fire their final writes.
    ///
    /// Returns `true` on debounce expiry (settled), `false` if the
    /// awaiting Task was cancelled (trait cap fired) or the total
    /// budget was exhausted.
    @discardableResult
    package func waitUntilSettled(cleanup: Bool = false, at fileAndLine: FileAndLine) async -> Bool {
        let window = cleanup ? Self.settleDebounceCleanupNs : Self.settleDebounceInTestNs
        let totalBudgetNs = cleanup ? Self.settleCleanupTotalBudgetNs : Self.settleTotalBudgetNs
        let startNs = _monotonicNs()
        let budgetEndNs = startNs &+ totalBudgetNs

        // Treat the wait's start as the last activity, so a model that never
        // writes still needs a full quiet window of real time to elapse
        // before the budget-cap quiescence check (below) can pass.
        noteWaitArmed()

        // Single-await settle.
        //
        // `awaitSettled` registers ONE pending entry with combined
        // semantics:
        //   • Quiet window: each `_noteActivity` (didModify / didSend /
        //     probe) re-arms the GTS deadline forward by `window`, capped
        //     at `budgetEnd`.
        //   • Background-call idle: when the GTS deadline finally fires,
        //     if `backgroundCall` is still busy (e.g. a queued memoize
        //     `performUpdate` whose `isSame` recompute is silent — no
        //     `didModify` and so invisible to the quiet window), a
        //     one-shot `bg.onIdle` observer is registered. Once bg
        //     drains AND no activity arrived during the wait, the
        //     observer fires and the continuation resumes.
        //   • Activity in the bg-idle wait sub-state cancels the
        //     observer and re-arms the GTS deadline — back to
        //     waiting-on-quiet.
        //
        // The continuation suspends exactly once. The whole state
        // machine lives inside `_noteActivity`, `_fireDeadline`, and
        // `_fireBgIdle` under `TestAccess.lock`.
        //
        // Outcome → return value:
        //   • `.cancelled` → trait cap fired (or external cancel); return
        //     `false` without reporting an issue (the trait already did).
        //   • `.passed` / `.timeout` → entry resolved. Compare `now` to
        //     `budgetEndNs`: if `now < budgetEndNs` we settled inside the
        //     budget; otherwise the 5 s hard cap exhausted and we report
        //     the diagnostic (in non-cleanup mode).
        // Cleanup settle uses `.responsive` callback priority — by this
        // point `cancelAllRecursively` has torn down the active tasks
        // and the 200 ms cleanup window already absorbs cancel-handler
        // writes, so we don't need the `.background`-queue hop here.
        // Without this, every test's teardown stalls behind the
        // `.background` queue's drain cadence and parallel tests
        // finish in synchronised clusters (~2 s, ~3 s, ~3.5 s buckets).
        // In-test settle keeps the default `.deferential` priority to
        // close the toggleExpanded class of race.
        let outcome = await awaitSettled(
            quietWindowNs: window,
            totalBudgetNs: totalBudgetNs,
            bg: backgroundCall,
            priority: cleanup ? .responsive : .deferential
        )
        switch outcome {
        case .cancelled:
            return false
        case .passed, .timeout:
            let now = _monotonicNs()
            if now >= budgetEndNs {
                // The total-budget cap tripped. This resolves via the
                // `.responsive` budget backstop, which fires INLINE on the
                // GTS `.userInitiated` queue — so it trips on time even when
                // the primary `.deferential` quiet-window callback is starved
                // on the `.background` queue. But "budget elapsed" alone does
                // NOT mean the model is stuck: under cross-process CPU
                // saturation (e.g. a concurrent `xcodebuild` on a shared CI
                // host) the `.background` quiet-window confirmation can be
                // starved for the whole budget while the model has actually
                // been idle the entire time. Reporting a failure there is a
                // false negative — the misleading "model still has active
                // tasks" with an empty task list.
                //
                // So before failing, re-check actual quiescence inline — the
                // same conditions the quiet-window callback would have checked
                // had it been scheduled:
                //   • bg idle (no in-flight pipeline / silent-memoize work),
                //   • no task registered-but-not-yet-started (a body still
                //     queued in the cooperative pool would write after we
                //     return), and
                //   • no activity for at least one debounce window
                //     (the model has genuinely been quiet, not still writing).
                // If all hold, the settle succeeded and the confirmation was
                // merely late — return success. A genuinely churning model
                // (recent activity), busy bg, or a task still pending its
                // first run fails as before.
                let quiescent = backgroundCall.isIdle
                    && !context.hasPendingStartTask
                    && (now &- lock { lastActivityNs }) >= window
                if quiescent {
                    return true
                }
                if !cleanup {
                    fail("settle() timed out: model still has active tasks.\n\(settleDiagnostics())", at: fileAndLine)
                }
                return false
            }
            return true
        }
    }

    /// Compact diagnostic listing models with active tasks at settle-timeout
    /// time. One line per task with model name and source location.
    private func settleDiagnostics() -> String {
        var lines: [String] = []
        for info in context.activeTasks {
            for (taskName, fl) in info.tasks {
                lines.append("  \(info.modelName): \"\(taskName)\" @ \(fl.fileID):\(fl.line)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
