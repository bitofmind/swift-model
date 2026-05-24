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

    /// Total time budget for `waitUntilSettled` before it declares the model
    /// "never settled". A test that hits this cap is either truly stuck
    /// (deadlock, infinite `onActivate` loop) or running on a CI box so
    /// loaded that even the `.deferential` `.background` GTS callback
    /// never got a slot within the budget.
    ///
    /// **Why 25 s, not 5 s** — settle uses `.deferential` priority on its
    /// quiet-window check; the callback runs at `.background` QoS and only
    /// fires once all higher-priority cooperative-pool Tasks have drained.
    /// On well-provisioned machines this happens in milliseconds; on a
    /// 2-vCPU CI runner with 700-way Task fan-out, it can take seconds.
    ///
    /// A wall-clock cap shorter than that drain time fights the very
    /// mechanism `.deferential` provides — it fails the test based on
    /// wall-clock without ever consulting the scheduler signal we built
    /// the callback to listen for. Under parallel execution there's also
    /// no fast-fail benefit: the test slot would have been busy with other
    /// tests' work regardless, so fast-failing one test buys no wall-clock.
    ///
    /// 25 s is the natural value: just under the 30 s `.modelTesting`
    /// trait cap, so when the budget *does* fire, the settle-specific
    /// diagnostic (model name + active task list) lands first instead
    /// of being swallowed by the trait timeout. The 5 s headroom catches
    /// post-settle assertion work before the trait kills the test.
    ///
    /// Output-snapshot tests override this via
    /// `TestAccessOverrides.$hardCapNanoseconds`.
    package static var settleTotalBudgetNs: UInt64 {
        TestAccessOverrides.hardCapNanoseconds ?? 25_000_000_000 // 25 s
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
        let totalBudgetNs = Self.settleTotalBudgetNs
        let startNs = _monotonicNs()
        let budgetEndNs = startNs &+ totalBudgetNs

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
