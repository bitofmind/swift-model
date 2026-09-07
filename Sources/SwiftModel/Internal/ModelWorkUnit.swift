import Foundation

/// The running/parked state of one unit of framework-owned async work.
///
/// Every `TaskCancellable` — i.e. every `node.task` / `node.forEach` /
/// `node.onChange` body, including the inner per-element bodies `forEach`
/// spawns — owns exactly one `ModelWorkUnit`. The unit exists from the
/// `TaskCancellable`'s registration in `Cancellations` until its body returns
/// and the `defer` unregisters it, so "registered unit" and "unfinished work"
/// are the same set by construction.
///
/// ## Why a counter and not a `Bool`
///
/// The state we care about is *running vs parked*, which reads like a `Bool`.
/// It is stored as a signed **counter of non-parked activities** instead:
///
///   * it starts at `1` (running),
///   * `park()` decrements, `unpark()` increments,
///   * the unit is **running** iff the count is `> 0`.
///
/// This makes nesting compose. `withModelParked` can nest — a clock that wraps
/// its own `sleep` (design §6b hook 3) called from inside a `forEach` that
/// already parked around its `next()` (hook 1), or simply a `withModelParked`
/// inside a `withModelParked`. With a `Bool` the inner unpark would wrongly
/// mark the unit running while the outer park is still in scope; with a counter
/// `1 → 0 → -1 → 0` stays parked until the outermost scope exits.
///
/// **Known limitation (documented, not fixed here).** The counter is shared by
/// every task that inherits the task-local — including child tasks a library
/// spawns inside the unit. If two such children park concurrently the count
/// reaches `-1`, and the first to unpark leaves it at `0`, i.e. still parked
/// even though one child is running again. Design §6b calls this out as the
/// reason hook 1 (`forEach`'s single `next()`) is preferred over hooks that can
/// fan out. Nothing in SwiftModel itself produces that shape today.
///
/// ## Why it starts running rather than at body entry
///
/// The sketch says "start 1 when the body begins". A unit is created (and
/// registered) before the cooperative pool schedules its body, and design §7
/// wants `hasPendingStartTask` to fall out of the same rule — "a task that has
/// not started is simply *running*". So the counter starts at `1` at
/// construction; the not-yet-started window is therefore running, and the
/// semantic answer needs no separate pending-start predicate.
final class ModelWorkUnit: @unchecked Sendable {
    /// The work unit owning the current task, if any. Set once per
    /// `TaskCancellable` body (see `TaskCancellable`'s convenience init), so it
    /// propagates into every child task the body — or a library the body calls
    /// into — spawns. `nil` outside model-owned async work, which is what makes
    /// `withModelParked` a no-op passthrough there.
    @TaskLocal static var current: ModelWorkUnit?

    private let lock = NSLock()
    private var _activityCount: Int = 1
    private var _hasStartedRunning = false

    /// `true` while this unit is not parked — see the type doc for the counter
    /// rule. A unit that has been created but whose body has not run yet is
    /// running.
    var isRunning: Bool {
        lock.withLock { _activityCount > 0 }
    }

    /// `true` once the wrapped Task's body has begun executing. Backs the
    /// existing `hasPendingStartTask` verdict path, which is untouched by the
    /// semantic-quiescence work.
    var hasStartedRunning: Bool {
        lock.withLock { _hasStartedRunning }
    }

    func markBodyStarted() {
        lock.withLock { _hasStartedRunning = true }
    }

    /// Marks the unit parked (one level). Balanced by `unpark()`.
    func park() {
        lock.withLock { _activityCount -= 1 }
    }

    /// Undoes one `park()`.
    func unpark() {
        lock.withLock { _activityCount += 1 }
    }
}

/// Parks the *current* work unit for the duration of `body`, if there is one.
///
/// Internal spelling of `withModelParked`, used by the framework's own hooks
/// (`forEach` parking around its `next()`); identical semantics, no public
/// surface.
@inline(__always)
func _withCurrentWorkUnitParked<T>(_ body: () async throws -> T) async rethrows -> T {
    guard let unit = ModelWorkUnit.current else { return try await body() }
    unit.park()
    defer { unit.unpark() }
    return try await body()
}
