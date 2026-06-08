import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

/// One-shot scheduler for test-infrastructure deadlines.
///
/// Replaces per-wait `scheduleAfter` GCD callbacks with one shared GCD
/// timer source. Callers register a deadline + callback; the timer is
/// armed for the soonest pending deadline. When it fires, every entry
/// whose deadline has elapsed runs, then the timer re-arms to the next
/// soonest pending deadline (or stops if none).
///
/// **Why this exists**
///
/// 1. Eliminates GCD-timer registration churn. With many concurrent
///    waits (e.g. parallel test runs), each previously created its own
///    GCD timer that got cancelled/rescheduled on every activity. Now
///    there's one timer total.
///
/// 2. The timer fires from GCD's own thread pool, NOT the Swift
///    cooperative pool. So callbacks fire even when the cooperative
///    pool is starved — important for trait-cap timeouts under heavy
///    parallel load.
///
/// **Two priorities, one timer**: the timer source itself fires at
/// `.userInitiated` (so deadlines surface promptly regardless of pool
/// load), but each scheduled entry carries its own callback QoS:
///
/// - `.userInitiated` (default): callback runs inline on the timer's
///   GCD queue. Used for failure-case timeouts (30 s trait cap, 5 s
///   expect budget) and polling helpers (`waitUntil`) where the
///   *contract* is that the callback fires close to its requested
///   time. Without this, polling cadence becomes meaningless under
///   load and `waitUntil` slows by 10×–30×.
///
/// - `.background`: callback hops to `DispatchQueue.global(qos:
///   .background)` before executing. Used by settle's quiet-window
///   check — the timer fires on time, but the *check itself* defers
///   to runnable cooperative-pool Tasks (which run at `.medium` or
///   higher). When the .background callback finally gets a slot, any
///   task that became runnable in the meantime has already executed
///   and called `_noteActivity`, which re-armed the deadline. That's
///   the mechanism that closes the toggleExpanded class of race.
///
/// The split is deliberate: GTS itself is responsive; only consumers
/// who explicitly want load-aware deferral opt in. No scaling math,
/// no multipliers — load adaptation lives entirely in the OS
/// scheduler's QoS prioritisation.
///
/// **One-shot, not periodic**: previous iterations used a repeating
/// 10 ms ticker. That meant every deadline had up to +10 ms jitter
/// and the ticker was active any time `pending` was non-empty (modest
/// idle CPU). The one-shot design arms the timer to the soonest
/// pending `deadlineNs` and re-arms after each fire — natural
/// coalescing when multiple deadlines bunch up, zero CPU when nothing
/// is pending, and the only jitter is whatever GCD itself adds to a
/// timer source firing time.
///
/// **Coalescing**: when many deadlines cluster within tens of ms (e.g.
/// 11 parallel test-suite settles all arming 50 ms windows in the same
/// millisecond), the timer fires once at the soonest deadline and
/// `evaluateTickLocked` picks up every entry that has expired. No
/// per-entry timer churn.
///
/// **Re-arm rules**:
/// - `schedule(...)` of an entry earlier than the currently armed
///   deadline → cancel + re-arm.
/// - `schedule(...)` of an entry later than current armed → leave
///   timer alone; it will fire at the soonest, then re-arm.
/// - `cancel(...)` of the currently-soonest entry → re-arm to the
///   new soonest, or stop if pending is empty.
/// - `cancel(...)` of any other entry → leave timer alone.
///
/// **Thread-safety**: `pending`, `timerSource`, and `armedDeadlineNs`
/// are protected by `lock` (NSLock). Callbacks are invoked OUTSIDE
/// the lock to avoid re-entrant `schedule` deadlocks (callbacks
/// commonly call `schedule` again, e.g. settle's debounce re-arm).
///
/// **History**: an even earlier iteration of this scheduler tracked
/// inter-tick jitter as "congestion debt" and extended pending
/// entries' effective deadlines by debt-accrued-during-wait. Under
/// heavy load this created a self-reinforcing feedback loop — slow
/// callbacks extended deadlines, which produced queue depth, which
/// made callbacks even slower. A subsequent attempt with a *bounded*
/// `currentLoadFactor` (capped at 10×) avoided the feedback loop but
/// surfaced a separate problem: a single late tick observation could
/// pin a 200 ms window to ~2 s with no way to course-correct when
/// the load passed (the deadline was already armed at the inflated
/// time). The current design drops scaling entirely — `.background`
/// QoS is the only adaptation, and it's bounded by the OS scheduler
/// rather than by application math.
///
/// Available only when `Dispatch` is — i.e. Apple + Linux. WASM does
/// not import this file (no DispatchSource).
#if canImport(Dispatch)

// MARK: - Diagnostic trace logging (set SWIFT_MODEL_GTS_TRACE=1 to enable)

private let _gtsTraceEnabled: Bool = {
    ProcessInfo.processInfo.environment["SWIFT_MODEL_GTS_TRACE"] == "1"
}()
private let _gtsTraceLock = NSLock()
private let _gtsTraceFile: FileHandle? = {
    guard _gtsTraceEnabled else { return nil }
    let path = "/tmp/swift-model-gts-trace.log"
    if !FileManager.default.fileExists(atPath: path) {
        _ = FileManager.default.createFile(atPath: path, contents: nil)
    }
    return try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
}()
@inline(__always)
private func _gtsTrace(_ msg: @autoclosure () -> String) {
    guard _gtsTraceEnabled, let fh = _gtsTraceFile else { return }
    let line = "[\(DispatchTime.now().uptimeNanoseconds)] \(msg())\n"
    _gtsTraceLock.withLock {
        try? fh.write(contentsOf: Data(line.utf8))
    }
}

final class GlobalTickScheduler: @unchecked Sendable {
    static let shared = GlobalTickScheduler(manualOnly: false)

    /// When `true`, `schedule(...)` does NOT auto-start a GCD timer; the
    /// instance only fires via `_drivenTick(nowNs:)`. Used by validation
    /// tests to drive the firing logic with controlled timestamps without
    /// racing the real GCD timer. The shared production instance always
    /// uses `manualOnly: false`.
    private let manualOnly: Bool

    /// Public for back-compat with the `awaitQuietWindow_firesAfterQuietWindow`
    /// test which uses it as a slop bound; no behaviour depends on it now.
    static let tickGranularityNs: UInt64 = 10_000_000  // 10 ms

    /// Per-callback execution priority. See file header for the
    /// responsive-vs-deferential rationale.
    enum CallbackPriority {
        /// Run the callback inline on the timer's GCD queue. Used for
        /// failure-case timeouts and polling — callback fires close to
        /// the requested deadline regardless of pool load.
        case responsive
        /// Hop the callback to `.background` QoS before executing. Used
        /// for settle's quiet-window check — under contention, the
        /// callback defers to higher-priority cooperative-pool Tasks
        /// (which call `_noteActivity` first and re-arm the deadline).
        case deferential
    }

    fileprivate struct Entry {
        let id: UInt64
        let deadlineNs: UInt64
        let armedAtNs: UInt64
        let priority: CallbackPriority
        let callback: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var nextId: UInt64 = 0
    /// Kept sorted by `deadlineNs` ascending so the soonest entry is
    /// `pending[0]` and `evaluateTickLocked` can prefix-scan for
    /// expired entries.
    private var pending: [Entry] = []
    private var timerSource: DispatchSourceTimer?

    /// The absolute monotonic deadline the current `timerSource` is
    /// armed for. `0` when no timer is alive. Compared against new
    /// entries' deadlines to decide whether to re-arm.
    private var armedDeadlineNs: UInt64 = 0

    init(manualOnly: Bool = false) {
        self.manualOnly = manualOnly
    }

    /// Register a callback to fire at `deadlineNs` (absolute monotonic
    /// nanoseconds; see `monotonicNanoseconds()`). Returns a cancel
    /// closure that is idempotent (no-op if the callback has already
    /// fired or been cancelled).
    ///
    /// Thread-safety: callable from any thread.
    @discardableResult
    func schedule(
        deadlineNs: UInt64,
        priority: CallbackPriority = .responsive,
        callback: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
        let armedAtNs = monotonicNanoseconds()
        // Pre-compute the trace delta as signed Int64 so a deadline in
        // the past (e.g., a trait-cap or expect-budget that has already
        // elapsed by the time we re-arm it) doesn't trap when the
        // unsigned wrap-around is later cast to Int64. The signed
        // subtraction handles the past-deadline case naturally.
        let traceDeltaMs = (Int64(bitPattern: deadlineNs) &- Int64(bitPattern: armedAtNs)) / 1_000_000
        let id: UInt64 = lock.withLock {
            nextId &+= 1
            let id = nextId
            let entry = Entry(id: id, deadlineNs: deadlineNs, armedAtNs: armedAtNs, priority: priority, callback: callback)
            // Insert sorted by deadlineNs ascending (linear scan).
            let insertIdx = pending.firstIndex(where: { $0.deadlineNs > deadlineNs }) ?? pending.endIndex
            pending.insert(entry, at: insertIdx)
            if !manualOnly {
                rearmIfNeededLocked()
            }
            _gtsTrace("schedule id=\(id) deadlineInMs=\(traceDeltaMs) priority=\(priority) pending=\(pending.count)")
            return id
        }
        return { [weak self] in
            self?.cancel(id: id)
        }
    }

    private func cancel(id: UInt64) {
        lock.withLock {
            let before = pending.count
            pending.removeAll { $0.id == id }
            if !manualOnly {
                rearmIfNeededLocked()
            }
            _gtsTrace("cancel id=\(id) before=\(before) after=\(pending.count) armed=\(armedDeadlineNs != 0)")
        }
    }

    /// Re-arm the timer if pending state has diverged from what the
    /// timer is currently armed for. Must be called while holding
    /// `lock`.
    ///
    /// Cases:
    ///   1. `pending` is empty → cancel any armed timer.
    ///   2. Soonest pending deadline differs from `armedDeadlineNs` →
    ///      cancel + re-arm to the new soonest.
    ///   3. Soonest pending deadline == armed → no-op (timer is already
    ///      where it needs to be).
    private func rearmIfNeededLocked() {
        guard let soonest = pending.first else {
            // Nothing pending → drop the timer entirely.
            if timerSource != nil {
                timerSource?.cancel()
                timerSource = nil
                armedDeadlineNs = 0
                _gtsTrace("stopTimer")
            }
            return
        }
        if armedDeadlineNs == soonest.deadlineNs {
            // Already armed for this exact deadline — nothing to do.
            return
        }
        // Re-arm. Cancel any existing timer and create a new one.
        timerSource?.cancel()
        let now = monotonicNanoseconds()
        let delayNs: Int64 = soonest.deadlineNs > now
            ? Int64(soonest.deadlineNs - now)
            : 0
        // Timer source itself fires at `.userInitiated` so deadlines
        // surface promptly regardless of pool load. Per-callback
        // execution priority is handled in `fire()` — deferential
        // callbacks hop to `.background` from there.
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        source.schedule(
            deadline: .now() + DispatchTimeInterval.nanoseconds(Int(delayNs)),
            // One-shot: leeway is "best effort" — the OS may fire up
            // to this much later. With `.background` QoS the actual
            // delay under load far exceeds this anyway; setting it
            // generously lets GCD coalesce with other system work.
            leeway: .nanoseconds(Int(Self.tickGranularityNs))
        )
        source.setEventHandler { [weak self] in
            self?.fire()
        }
        timerSource = source
        armedDeadlineNs = soonest.deadlineNs
        source.resume()
        let traceDeadlineMs = (Int64(bitPattern: soonest.deadlineNs) &- Int64(bitPattern: now)) / 1_000_000
        _gtsTrace("armTimer delayInMs=\(delayNs / 1_000_000) deadlineInMs=\(traceDeadlineMs) pending=\(pending.count)")
    }

    /// Timer fired. Fire every expired entry, then re-arm to next
    /// soonest (or stop if empty).
    private func fire() {
        let now = monotonicNanoseconds()
        let (toFire, remainingCount): ([Entry], Int) = lock.withLock {
            // The timer just fired; clear armedDeadlineNs so
            // `rearmIfNeededLocked` will arm a fresh timer.
            armedDeadlineNs = 0
            timerSource = nil
            let fired = evaluateTickLocked(nowNs: now)
            // Re-arm if there's still pending work.
            if !manualOnly {
                rearmIfNeededLocked()
            }
            return (fired, pending.count)
        }
        if !toFire.isEmpty || remainingCount > 0 {
            // Report fire-latency: how late the timer arrived relative
            // to each fired entry's nominal deadline. Under `.background`
            // QoS this is often non-trivial — that IS the load
            // adaptation.
            var lateLog = ""
            for e in toFire {
                let lateMs = (Int64(bitPattern: now) &- Int64(bitPattern: e.deadlineNs)) / 1_000_000
                lateLog += " id=\(e.id)lateMs=\(lateMs)"
            }
            _gtsTrace("fire fired=\(toFire.count) remaining=\(remainingCount)\(lateLog)")
        }
        // Fire callbacks OUTSIDE the lock so they can call back into
        // `schedule(...)` (common pattern: re-arm on activity) without
        // re-entering.
        //
        // Per-callback priority dispatch:
        //   - `.responsive`: run inline on the timer's `.userInitiated`
        //     GCD queue. Used for failure-case timeouts and polling —
        //     the deadline is meant to fire close to its requested time.
        //   - `.deferential`: hop to `.background` QoS. The callback
        //     waits for higher-priority cooperative-pool work to drain
        //     before running. Used by settle's quiet-window check.
        for entry in toFire {
            switch entry.priority {
            case .responsive:
                entry.callback()
            case .deferential:
                let cb = entry.callback
                DispatchQueue.global(qos: .background).async {
                    cb()
                }
            }
        }
    }

    /// Pure firing evaluation. Returns the entries whose deadline is
    /// `<= nowNs`. Must be called while holding `lock`. Used by both
    /// the real timer's `fire()` and by `_drivenTick` for tests.
    fileprivate func evaluateTickLocked(nowNs: UInt64) -> [Entry] {
        // Pending is sorted ascending — collect the prefix of expired.
        var fireCount = 0
        for entry in pending {
            if entry.deadlineNs <= nowNs { fireCount += 1 } else { break }
        }
        guard fireCount > 0 else { return [] }
        let expired = Array(pending.prefix(fireCount))
        pending.removeFirst(fireCount)
        return expired
    }

    /// Like `evaluateTickLocked`, but fires only the expired `.responsive`
    /// entries; expired `.deferential` entries are LEFT pending. Must be
    /// called while holding `lock`.
    ///
    /// This models the production starvation case faithfully: when a
    /// `.deferential` callback's `.background` slot never runs, the entry's
    /// deadline has elapsed but its callback is never delivered — exactly
    /// "expired, still pending, never fired." Test-only, via
    /// `_drivenTick(nowNs:fireDeferential:)`.
    fileprivate func evaluateTickResponsiveOnlyLocked(nowNs: UInt64) -> [Entry] {
        var fired: [Entry] = []
        var remaining: [Entry] = []
        // `pending` is sorted ascending; iterating in order and rebuilding
        // `remaining` preserves that invariant for the entries we keep.
        for entry in pending {
            if entry.deadlineNs <= nowNs, entry.priority == .responsive {
                fired.append(entry)
            } else {
                remaining.append(entry)
            }
        }
        pending = remaining
        return fired
    }

    // MARK: - Test introspection

    /// Number of currently-pending callbacks. Test-only.
    var _pendingCount: Int {
        lock.withLock { pending.count }
    }

    /// Drive a fire manually for tests — same code path as the GCD
    /// callback but with caller-controlled "now". Returns the count of
    /// callbacks that fired and ALSO invokes each callback (outside
    /// the lock) so side-effects observable to the test happen as in
    /// production. Pair with `init(manualOnly: true)` so no real GCD
    /// timer races your driven ticks.
    ///
    /// Pass `fireDeferential: false` to deliver only the expired
    /// `.responsive` callbacks and leave expired `.deferential` entries
    /// pending — simulating an infinitely-starved `.background` queue
    /// where the `.deferential` slot never runs. Used to test that
    /// settle's `.responsive` budget-cap backstop resolves a wait even
    /// when its primary `.deferential` deadline is starved.
    @discardableResult
    func _drivenTick(nowNs: UInt64, fireDeferential: Bool = true) -> Int {
        let toFire: [Entry] = lock.withLock {
            fireDeferential
                ? evaluateTickLocked(nowNs: nowNs)
                : evaluateTickResponsiveOnlyLocked(nowNs: nowNs)
        }
        for entry in toFire {
            entry.callback()
        }
        return toFire.count
    }
}

private func monotonicNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

#else

// MARK: - WASM stub
//
// `TestAccess` uses `GlobalTickScheduler` to register deadlines for
// `expect` / `settle`. WASM (WASI SDK) doesn't ship `Dispatch`, so
// there's no GCD timer source to back the real scheduler. Providing a
// no-op stub keeps the call sites in `TestAccess.swift` compiling for
// WASM without platform-guarding each reference; tests are not
// executed on WASM today (the `IssueReportingTestSupport` dynamic-
// library product blocks linking any test target), so the no-op
// never runs.

final class GlobalTickScheduler: @unchecked Sendable {
    static let shared = GlobalTickScheduler()

    static let tickGranularityNs: UInt64 = 10_000_000

    enum CallbackPriority {
        case responsive, deferential
    }

    @discardableResult
    func schedule(
        deadlineNs _: UInt64,
        priority _: CallbackPriority = .responsive,
        callback _: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
        // No-op: WASM never fires the callback. Callers must not depend on
        // the deadline firing for correctness on this platform.
        return {}
    }

    var _pendingCount: Int { 0 }

    @discardableResult
    func _drivenTick(nowNs _: UInt64, fireDeferential _: Bool = true) -> Int { 0 }
}

#endif
