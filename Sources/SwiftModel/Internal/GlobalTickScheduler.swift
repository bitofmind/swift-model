import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

/// Single-ticker scheduler for test-infrastructure deadlines.
///
/// Replaces per-wait `scheduleAfter` GCD callbacks with one shared GCD
/// timer ticking at `tickGranularityNs` (10 ms). Callers register a
/// deadline + callback; on each tick the scheduler fires every callback
/// whose deadline has elapsed.
///
/// **Why this exists**
///
/// 1. Eliminates GCD-timer registration churn. With many concurrent
///    waits (e.g. parallel test runs), each previously created its own
///    GCD timer that got cancelled/rescheduled on every activity. Now
///    there's one ticker total.
///
/// 2. The ticker fires from GCD's own thread pool, NOT the Swift
///    cooperative pool. So callbacks fire even when the cooperative
///    pool is starved — the suspected cause of trait-cap timeouts not
///    firing under heavy parallel load.
///
/// **Trade-off**: deadlines have +tick-granularity jitter (up to 10 ms)
/// plus any extra delay from a slow tick callback. Acceptable for all
/// current users (settle 50 ms / expect 5 s / trait cap 30 s).
///
/// **Adaptive ticking**: the ticker is only running while `pending` is
/// non-empty. Cancelled / fired entries that drain the queue stop the
/// ticker; the next `schedule(...)` starts it again. No idle CPU cost.
///
/// **Thread-safety**: `pending` and `timerSource` are protected by
/// `lock` (NSLock). Callbacks are invoked OUTSIDE the lock to avoid
/// re-entrant `schedule` deadlocks (callbacks commonly call `schedule`
/// again, e.g. settle's debounce re-arm).
///
/// **History**: an earlier iteration of this scheduler tracked
/// inter-tick jitter as "congestion debt" and extended pending entries'
/// effective deadlines by debt-accrued-during-wait, so that under heavy
/// load entries would get a budget proportional to *healthy* wall-clock
/// time rather than *nominal* wall-clock time. In practice this
/// created a self-reinforcing feedback loop under x100 parallel stress
/// — slow tick callbacks extended all pending deadlines, which
/// produced more queue depth, which made ticks even slower, which
/// extended deadlines further. Tests appeared to hang for an hour or
/// more (they were actually progressing, just at ~1/50 wall-clock
/// rate). The simple monotonic-deadline behaviour below was restored.
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

    /// When `true`, `schedule(...)` does NOT auto-start a GCD ticker; the
    /// instance only fires via `_drivenTick(nowNs:)`. Used by validation
    /// tests to drive the tick logic with controlled timestamps without
    /// racing the real GCD ticker. The shared production instance always
    /// uses `manualOnly: false`.
    private let manualOnly: Bool

    /// Tick granularity. Deadlines fire on the next tick at-or-after.
    static let tickGranularityNs: UInt64 = 10_000_000  // 10 ms

    fileprivate struct Entry {
        let id: UInt64
        let deadlineNs: UInt64
        let callback: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var nextId: UInt64 = 0
    /// Kept sorted by `deadlineNs` ascending so `tick()` can prefix-scan.
    /// Insertion is O(n) via linear scan + insert; cancel removes by id
    /// (O(n)). N is small in practice — at most one entry per in-flight
    /// test wait per concurrent test.
    private var pending: [Entry] = []
    private var timerSource: DispatchSourceTimer?

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
    func schedule(deadlineNs: UInt64, callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id: UInt64 = lock.withLock {
            nextId &+= 1
            let id = nextId
            let entry = Entry(id: id, deadlineNs: deadlineNs, callback: callback)
            // Insert sorted by deadlineNs ascending (linear scan).
            let insertIdx = pending.firstIndex(where: { $0.deadlineNs > deadlineNs }) ?? pending.endIndex
            pending.insert(entry, at: insertIdx)
            let starting = timerSource == nil && !manualOnly
            if starting {
                startTickerLocked()
            }
            _gtsTrace("schedule id=\(id) deadline=\(deadlineNs) pending=\(pending.count) starting=\(starting)")
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
            let stopping = pending.isEmpty && timerSource != nil
            if pending.isEmpty {
                stopTickerLocked()
            }
            _gtsTrace("cancel id=\(id) before=\(before) after=\(pending.count) stopping=\(stopping)")
        }
    }

    /// Must be called while holding `lock`. Idempotent — caller checks `timerSource == nil`.
    private func startTickerLocked() {
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        let granularity = DispatchTimeInterval.nanoseconds(Int(Self.tickGranularityNs))
        source.schedule(deadline: .now() + granularity, repeating: granularity, leeway: granularity)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        timerSource = source
        source.resume()
        _gtsTrace("startTicker pending=\(pending.count)")
    }

    /// Must be called while holding `lock`.
    private func stopTickerLocked() {
        timerSource?.cancel()
        timerSource = nil
        _gtsTrace("stopTicker pending=\(pending.count)")
    }

    private func tick() {
        let now = monotonicNanoseconds()
        let (toFire, remainingCount, tickerAlive): ([Entry], Int, Bool) = lock.withLock {
            let fired = evaluateTickLocked(nowNs: now)
            return (fired, pending.count, timerSource != nil)
        }
        if !toFire.isEmpty || remainingCount > 0 {
            _gtsTrace("tick fired=\(toFire.count) remaining=\(remainingCount) tickerAlive=\(tickerAlive)")
        }
        // Fire callbacks OUTSIDE the lock so they can call back into
        // `schedule(...)` (common pattern: re-arm on activity) without
        // re-entering.
        for entry in toFire {
            entry.callback()
        }
    }

    /// Pure tick evaluation. Returns the entries that should fire NOW.
    /// Stops the ticker if `pending` drains.
    ///
    /// Factored out so tests can drive it with controlled `nowNs`
    /// values without depending on real GCD scheduling.
    ///
    /// Must be called while holding `lock`.
    fileprivate func evaluateTickLocked(nowNs: UInt64) -> [Entry] {
        // Pending is sorted ascending — collect the prefix of expired.
        var fireCount = 0
        for entry in pending {
            if entry.deadlineNs <= nowNs { fireCount += 1 } else { break }
        }
        guard fireCount > 0 else { return [] }
        let expired = Array(pending.prefix(fireCount))
        pending.removeFirst(fireCount)
        if pending.isEmpty {
            stopTickerLocked()
        }
        return expired
    }

    // MARK: - Test introspection

    /// Number of currently-pending callbacks. Test-only.
    var _pendingCount: Int {
        lock.withLock { pending.count }
    }

    /// Drive a tick manually for tests — same code path as the GCD
    /// callback but with caller-controlled "now". Returns the count of
    /// callbacks that fired and ALSO invokes each callback (outside the
    /// lock) so side-effects observable to the test happen as in
    /// production. Pair with `init(manualOnly: true)` so no real GCD
    /// ticker races your driven ticks.
    @discardableResult
    func _drivenTick(nowNs: UInt64) -> Int {
        let toFire: [Entry] = lock.withLock {
            evaluateTickLocked(nowNs: nowNs)
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
// `expect` / `settle`. WASM (WASI SDK) doesn't ship `Dispatch`, so there's
// no GCD timer source to back the real scheduler. Providing a no-op stub
// keeps the call sites in `TestAccess.swift` compiling for WASM without
// platform-guarding each reference; tests are not executed on WASM today
// (the `IssueReportingTestSupport` dynamic-library product blocks linking
// any test target), so the no-op never runs.
//
// If we ever do enable WASM test execution, this stub will need replacing
// with a real cooperative-task-pool-backed implementation — or callers
// will need explicit `#if canImport(Dispatch)` fallbacks.

final class GlobalTickScheduler: @unchecked Sendable {
    static let shared = GlobalTickScheduler()

    static let tickGranularityNs: UInt64 = 10_000_000

    @discardableResult
    func schedule(deadlineNs _: UInt64, callback _: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        // No-op: WASM never fires the callback. Callers must not depend on
        // the deadline firing for correctness on this platform.
        return {}
    }

    var _pendingCount: Int { 0 }

    @discardableResult
    func _drivenTick(nowNs _: UInt64) -> Int { 0 }
}

#endif
