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
/// ## Eager unpark: `noteResumeInFlight()` and the park epoch
///
/// The counter alone is a *lazy* mark: the unit leaves "parked" only when the
/// resumed task next gets a CPU slot and runs the parking scope's `defer`.
/// Between a continuation being **resumed** and that slot, the unit still reads
/// parked while model-writing work is already inbound — the
/// park→resume-in-flight window. Design §5 assumed that window was benign (the
/// yield is itself an activity signal) and that a park-generation double-check
/// would catch it; measurement killed both claims. The `AsyncStream`
/// cancellation path (`_Storage.finish()` from `next()`'s cancel handler — 62 %
/// of the observed window) emits no activity signal at all and resumes a body
/// that then runs model-writing `defer`s, and the generation never changed
/// across a check.
///
/// So the unpark is made **eager**: whoever resumes the continuation calls
/// `noteResumeInFlight()` *before* resuming, and the resumed side's `defer`
/// becomes a no-op. That requires the release to be idempotent, which is what
/// the **epoch** is for: `park()` hands back a `_ParkTicket` stamped with the
/// epoch current at park time, `noteResumeInFlight()` bumps the epoch, and a
/// ticket whose epoch is stale releases nothing. One force therefore
/// invalidates *every* open park scope on the unit — which is exactly right,
/// because a resumed task is running regardless of how many nested `park()`
/// scopes (`forEach`'s own `next()` wrapped around a stream that also parks) it
/// is unwinding through. It stays running until it *voluntarily parks again*,
/// which is the property a lazy, per-scope unpark cannot provide.
///
/// ## Why it starts running rather than at body entry
///
/// The sketch says "start 1 when the body begins". A unit is created (and
/// registered) before the cooperative pool schedules its body, and design §7
/// wants `hasPendingStartTask` to fall out of the same rule — "a task that has
/// not started is simply *running*". So the counter starts at `1` at
/// construction; the not-yet-started window is therefore running, and the
/// semantic answer needs no separate pending-start predicate.
///
/// ## The async-work audit (design §4 / §4a) — what is NOT a work unit
///
/// Semantic quiescence is only sound if every framework path that can still
/// write to a model owns a registered unit. Everything else must be in one of
/// two explicitly-justified buckets. This is the completed inventory; keep it
/// in sync when adding a `Task` to `Sources/`.
///
/// **(a) Test-drive machinery — not model work by construction.** None of it
/// runs on the per-test drain executor (`_DrainTestExecutor` is applied *only*
/// to `TaskCancellable` bodies, in the `convenience init` below), so it is
/// invisible to the scheduler-observing answer too:
///   * `TestExecutorDrive._startExecutorDrive`'s driver `Task` and its
///     `_gtsSleep`s — the thing doing the asking; counting it would make every
///     wait its own reason to keep waiting.
///   * `GlobalTickScheduler` deadline entries — a scheduled wake, not work
///     (design §4).
///   * `ModelTestingTrait`'s `group.addTask` timeout/watchdog arms.
///
/// **(d) Excluded housekeeping — framework-spawned work no test may wait for.**
/// Every entry here is a deliberate blind spot, so each carries its
/// justification at the spawn site as well:
///   * `Context.swift`'s last-seen TTL `Task` — memory reclamation on a
///     user-configured TTL, never a model reaction. Counting it would make
///     `settle()` wait out the whole TTL (design §4a).
///   * `ObservedModel.swift`'s first-activation priming `Task` — a SwiftUI
///     `objectWillChange.send()`; touches no model state.
///
/// **Counted, but not as `TaskCancellable`s.** `CallQueue`'s background-drain
/// and main-registrar pumps are real model work and *are* part of the answer —
/// `AnyContext.semanticQuiescence` folds in `backgroundCall.isIdle` and
/// `mainCallQueue.isIdle` (design §4 counts a queue item as one running unit;
/// the prototype keeps them as the two predicates they already were rather than
/// re-plumbing `CallQueue`, which gives the same answer).
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
    private var _parkGeneration: UInt64 = 0
    /// Bumped by `noteResumeInFlight()` only. A `_ParkTicket` minted under an
    /// older epoch releases nothing — see the type doc.
    private var _epoch: UInt64 = 0

    /// Bumped on every park/unpark transition. Design §5 property 2: a
    /// quiescence answer is only trustworthy if it holds across two observations
    /// with **no park-generation change between them**, because between marking
    /// parked and actually suspending — and, more importantly, between a
    /// continuation being resumed and the resumed task running its `unpark()` —
    /// the unit reads "parked" while it is about to run.
    ///
    /// Currently reported by the dual-run trace only; nothing consumes it for a
    /// verdict. It is what a verdict switch would have to gate on.
    var parkGeneration: UInt64 {
        lock.withLock { _parkGeneration }
    }

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

    /// Marks the unit parked (one level). Balanced by exactly one
    /// `_ParkTicket.release()`, which the parking scope runs from a `defer` —
    /// and which is a no-op if the unit was force-resumed in the meantime.
    func park() -> _ParkTicket {
        lock.withLock {
            _activityCount -= 1
            _parkGeneration &+= 1
            return _ParkTicket(unit: self, epoch: _epoch)
        }
    }

    /// EAGER UNPARK. Called by whoever is about to **resume** the continuation
    /// this unit is parked on: the producer immediately before
    /// `AsyncStream.Continuation.yield`, and the stream's `onTermination`
    /// handler, which the stdlib documents as running before `next()` is
    /// resumed with `nil` ("handler must be invoked before yielding nil for
    /// termination", `AsyncStream._Storage.cancel`).
    ///
    /// Makes the unit running *now* and invalidates every open park scope, so
    /// the resumed task's own `defer` adds nothing and the unit stays running
    /// until it parks again of its own accord.
    func noteResumeInFlight() {
        lock.withLock {
            if _activityCount < 1 { _activityCount = 1 }
            _epoch &+= 1
            _parkGeneration &+= 1
        }
    }

    fileprivate func release(epoch: UInt64) {
        lock.withLock {
            // Stale: a `noteResumeInFlight()` already took this unit out of the
            // park, so the scope's `defer` has nothing left to undo.
            guard epoch == _epoch else { return }
            _activityCount += 1
            _parkGeneration &+= 1
        }
    }
}

/// One open park scope, handed out by `ModelWorkUnit.park()`.
///
/// A value type on purpose: `park()` sits on the per-element path of every
/// SwiftModel-owned stream, so the ticket must not allocate. Idempotence
/// against an eager unpark comes from the epoch stamp, not from a per-ticket
/// flag.
struct _ParkTicket {
    fileprivate let unit: ModelWorkUnit
    fileprivate let epoch: UInt64

    /// Ends the scope. A no-op if `ModelWorkUnit.noteResumeInFlight()` ran
    /// while the scope was open — which is what makes it safe to call from a
    /// `defer` that runs after an eager unpark.
    func release() {
        unit.release(epoch: epoch)
    }
}

/// Parks the *current* work unit for the duration of `body`, if there is one.
///
/// Internal spelling of `withModelParked`, used by the framework's own hooks
/// (`forEach` parking around its `next()`); identical semantics, no public
/// surface.
///
/// ## The cancellation handler
///
/// This is the generic half of the eager unpark, and the only half available
/// for a **foreign** suspension — `node.forEach` over a third-party
/// `AsyncSequence` (design §6b hook 1), or a clock that adopted
/// `withModelParked` (hook 3). SwiftModel produces neither, so it cannot mark
/// the resume the way `_ParkSource` does for its own streams. But it *does*
/// own the cancellation: `Cancellations.cancelAll` → `TaskCancellable.onCancel`
/// → `Task.cancel()` runs this handler synchronously, before the cancelled task
/// is resumed — and cancellation is the resume that matters most, because it is
/// the one with no activity signal behind it and the one that goes straight
/// into model-writing `defer`s.
///
/// The residual is a foreign source *delivering a value*: `swift-clocks`'
/// `ImmediateClock` timer resuming its consumer is not a cancellation and not
/// our continuation, so the unit reads parked until the resumed task runs. That
/// is inherent to hook 1 — the price of parking any `AsyncSequence` with no
/// adoption at all — and design §6b hook 2 (`parkedInModelTasks()`) is the
/// opt-in that would close it.
@inline(__always)
func _withCurrentWorkUnitParked<T>(_ body: () async throws -> T) async rethrows -> T {
    guard let unit = ModelWorkUnit.current else { return try await body() }
    let ticket = unit.park()
    defer { ticket.release() }
    return try await withTaskCancellationHandler {
        try await body()
    } onCancel: {
        unit.noteResumeInFlight()
    }
}
