import Foundation
#if canImport(Dispatch)
import Dispatch
#endif
import CustomDump
import IssueReporting
import Dependencies

/// Returns the current monotonic time in nanoseconds.
/// Uses DispatchTime on platforms that have it; falls back to ProcessInfo.systemUptime on WASI.
private func monotonicNanoseconds() -> UInt64 {
    #if canImport(Dispatch)
    return DispatchTime.now().uptimeNanoseconds
    #else
    return UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    #endif
}

// MARK: - Settle trace logging (set SWIFT_MODEL_GTS_TRACE=1 to enable)
//
// Temporary diagnostic. Pairs with `_gtsTrace` in GlobalTickScheduler so we
// can correlate "settle armed deadline at T+50ms" with the actual GTS
// `tick fired …lateMs=…` line. Validates that `.background` QoS does what
// we think it does. Remove (or gate on a separate verbose flag) once the
// design is stable.

private let _settleTraceEnabled: Bool = {
    ProcessInfo.processInfo.environment["SWIFT_MODEL_GTS_TRACE"] == "1"
}()
private let _settleTraceLock = NSLock()
private let _settleTraceFile: FileHandle? = {
    guard _settleTraceEnabled else { return nil }
    let path = "/tmp/swift-model-settle-trace.log"
    if !FileManager.default.fileExists(atPath: path) {
        _ = FileManager.default.createFile(atPath: path, contents: nil)
    }
    return try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
}()
@inline(__always)
private func _settleTrace(_ msg: @autoclosure () -> String) {
    guard _settleTraceEnabled, let fh = _settleTraceFile else { return }
    let line = "[\(monotonicNanoseconds())] \(msg())\n"
    _settleTraceLock.withLock {
        try? fh.write(contentsOf: Data(line.utf8))
    }
}

/// Suspends briefly and resumes on the next scheduler round.
///
/// On Apple platforms, uses a GCD hop (`DispatchQueue.global().async`) which fires a
/// kernel-level callback in <1 ms regardless of Swift cooperative thread pool saturation.
/// macOS runs tests in parallel (`--parallel`), so `Task.yield()` can stall for seconds
/// under heavy concurrent load — making it unsuitable for calibration.
///
/// On Linux, tests run serially (`--no-parallel`) so the cooperative pool is not saturated,
/// and `Task.yield()` is fast. More importantly, on Linux the `@MainActor` executor is
/// backed by the cooperative pool's main thread — `Task.yield()` allows pending `@MainActor`
/// tasks (e.g. OT-path memoize recomputes queued by `MainCallQueue`) to run before we
/// evaluate predicates. A GCD hop bypasses the cooperative pool and those tasks never get
/// a scheduling opportunity within the `expect()` loop.
func yieldToScheduler() async {
    #if os(Linux) || (!canImport(Dispatch))
    await Task.yield()
    #else
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async { c.resume() }
    }
    #endif
}

// MARK: - How expect works
//
// `expect { predicate }` is a register-and-wait reactive primitive:
//
//   1. Builds a `TesterAssertContext` and a fresh `EvalSnapshot`, then calls
//      `awaitPredicate(deadlineNs:evaluate:)` with an evaluator closure that
//      runs the predicates inside `TesterAssertContextBase.$assertContext` +
//      `usingActiveAccess(self)`.
//
//   2. The evaluator runs INITIALLY on the caller's thread (inside
//      TestAccess.lock) and on every SUBSEQUENT activity from
//      `_noteActivity` (also inside the lock). Reading any @Model property
//      during evaluation fires willAccess<M,V>, which (with the assert
//      context active) appends an Access entry with the full root-relative
//      keypath, the current value, and an `apply` closure that writes that
//      value back into a Root snapshot.
//
//   3. If ALL predicates pass, the evaluator runs `isEqualIncludingIds` to
//      verify the model has actually settled at those values — not just
//      transiently true. If IDs don't match (a backgroundCall batch is still
//      in flight), the evaluator returns false and waits for the next
//      activity; the bg drain will fire didModify, which fires
//      _noteActivity, which re-invokes the evaluator.
//
//   4. On settlement, the evaluator clears each asserted path from
//      valueUpdates, advances expectedState, captures the cleaned-up
//      valueUpdates snapshot, and returns true. `awaitPredicate` resumes
//      the caller with `.passed`; `expect` then runs the exhaustion check
//      OUTSIDE the lock (diffMessage walks customMirror which re-acquires
//      the lock — deadlock-prone if held cross-thread).
//
//   5. If the deadline elapses before the evaluator returns true,
//      `awaitPredicate` resumes with `.timeout` and `expect` reports the
//      latest failure snapshot.
//
// Race elimination: predicate eval and activity bookkeeping both happen
// inside the SAME TestAccess.lock. There's no window where activity can
// fire between "we evaluated and it failed" and "we registered to be
// notified" — replaces the old poll-loop's `_activityCounter` /
// `missedActivityCheck` mechanism with structural impossibility.
//
// State lifecycle:
//   - lastState    : always up to date — updated by didModify whenever any property changes.
//   - expectedState: advances one assert at a time — updated only when an assert passes.
//   - valueUpdates : pending un-asserted changes — entries are removed when asserted.

/// Test-only overrides. Output-snapshot tests use `hardCapNanoseconds` to
/// shrink the expect/require budget so failure-message snapshots render
/// quickly. The name is preserved for API stability across the polling →
/// reactive migration even though it's no longer a "hard cap" per se.
enum TestAccessOverrides {
    @TaskLocal static var hardCapNanoseconds: UInt64? = nil
}

// Key for tracking context storage writes on dependency models (which have no root-relative keypath).
// Combines the context's identity with the per-model context path so distinct storage
// keys on distinct dependency model contexts produce distinct entries.
private struct DependencyMetadataKey: Hashable, @unchecked Sendable {
    let contextID: ObjectIdentifier
    let path: AnyKeyPath

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.contextID == rhs.contextID && lhs.path == rhs.path
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(contextID)
        hasher.combine(path)
    }
}

final class TestAccess<Root: Model>: ModelAccess, @unchecked Sendable {
    let lock = NSRecursiveLock()
    let context: Context<Root>

    // The most recent fully-settled snapshot of the root model. Updated by didModify
    // on every property write, so it always reflects the current live state.
    var lastState: Root

    // The baseline snapshot as of the last passed assert. The exhaustion check diffs
    // expectedState against lastState to catch unasserted changes.
    var expectedState: Root

    var exhaustivity: _ExhaustivityBits = .full
    var showSkippedAssertions = false

    // Pending unasserted state transitions, keyed by root-relative keypath. Populated by
    // didModify; front entries are consumed when the corresponding path is asserted. Any
    // remaining entries at exhaustion time are reported as failures.
    //
    // Each write appends a new entry to the FIFO queue for that path, preserving all
    // intermediate transitions. The front of the queue is the oldest unasserted transition.
    var valueUpdates: [PartialKeyPath<Root>: [ValueUpdate]] = [:]

    // Pending unasserted context storage writes on dependency models. Dependency models have no
    // root-relative WritableKeyPath (they live in dependencyContexts, not children), so
    // their context storage updates are tracked here rather than in valueUpdates.
    private var dependencyMetadataUpdates: [DependencyMetadataKey: ValueUpdate] = [:]

    // Same as dependencyMetadataUpdates but for preference storage writes on dependency models.
    private var dependencyPreferenceUpdates: [DependencyMetadataKey: ValueUpdate] = [:]

    // Per-(context, path) write-ordering counters. Keyed by the same DependencyMetadataKey
    // used for dependency storage so we re-use the existing struct.
    //
    // Each didModify call captures `context.modificationCount` (already post-incremented
    // before invokeDidModifyDirect is called) as `mySeqNum`. The post-lock closure then
    // checks — under the TestAccess lock — whether a later modification (higher seqNum) has
    // already written for this (context, path) pair. If so, the earlier closure's write is
    // discarded, preventing a stale value from permanently corrupting `lastState`.
    //
    // This is the fix for the following race with 10 concurrent `count += 1` calls:
    //   T1 modifies count to 1 (seqNum=1), releases lock, closure reads count=1 (before T10).
    //   T10 modifies count to 10 (seqNum=10), closure writes lastState.count=10.
    //   T1's closure acquires TestAccess lock after T10 → seqNum=1 < lastWritten=10 → rejected.
    private var lastWriteSeqNums: [DependencyMetadataKey: Int] = [:]

    var events: [Event] = []
    var probes: [TestProbe] = []
    let fileAndLine: FileAndLine

    // Per-model-type cache of private (non-exhaustively-tracked) key paths.
    // Keyed by `ObjectIdentifier(M.self)`, values are the LOCAL (non-root-relative)
    // WritableKeyPaths for properties declared `private` or `fileprivate` in that model type.
    // Built lazily on first `didModify` for each model type by traversing one instance;
    // since visibility is type-level, the result is the same for all instances of the type.
    var privatePathsByType: [ObjectIdentifier: Set<AnyKeyPath>] = [:]

    // MARK: - Wait state machine (reactive expect/settle)
    //
    // At most one wait is active at a time per TestAccess — expect/settle/require
    // are sequential within a test body. The wait state lives directly on
    // TestAccess so that `didModify`, `didSend`, and probe-call paths (which
    // all funnel through here) can update it without going through any
    // subscription layer.

    // MARK: - Pending expect/require (register-and-wait)
    //
    // Each in-flight `awaitPredicate` call registers a `PendingExpect`
    // here. On every `_noteActivity()` we iterate the list and evaluate
    // each predicate INLINE under the same lock that bumps activity —
    // no race window, no per-wait timer, no re-park loop. Predicates
    // that pass have their continuations resumed (outside the lock).
    //
    // A single in-flight expect is the common case (sequential awaits in
    // a test body). Concurrent expects (via `async let` or task groups)
    // are NOT currently supported — the code accepts a list for future
    // extension, but the first concurrent caller hits a precondition.
    // The list-based design lets us add concurrent support later without
    // changing the API.

    final class PendingExpect: @unchecked Sendable {
        /// Three modes share this entry type so `_noteActivity` can iterate
        /// one list and dispatch on `mode`.
        enum Mode {
            /// Predicate mode (`awaitPredicate` — expect / require).
            /// Evaluator runs on every `_noteActivity()` under
            /// TestAccess.lock; the entry wakes when it returns true.
            /// Contract: cheap, reentrant-safe, must not write the model.
            case predicate(@Sendable () -> Bool)

            /// Debounce mode (`awaitQuietWindow` — pure quiet-window
            /// without bg-idle check). The entry does NOT wake on
            /// activity; instead each activity re-arms the deadline to
            /// `min(now + quietWindowNs, totalBudgetEndNs)`. Wakes when
            /// the (mutable) deadline finally fires.
            case debounce(quietWindowNs: UInt64)

            /// Settled mode (`awaitSettled` — settle). Wakes when BOTH
            /// of these are true simultaneously:
            ///   • no `_noteActivity` for `quietWindowNs` (quiet window)
            ///   • `bg` is idle (no pending pipeline work)
            ///
            /// Activity re-arms the GTS deadline forward like debounce.
            /// When the deadline fires, the handler checks `bg.isIdle`:
            ///   • idle → resume `.passed`
            ///   • busy → register a `bg.onIdle` observer; when that
            ///     observer fires, resume `.passed`. Activity between
            ///     "deadline fired" and "bg idle fired" cancels the
            ///     observer and re-arms the GTS deadline forward (back
            ///     to waiting-on-quiet state).
            ///
            /// `bg` is captured here (not on the outer entry) because
            /// each `.modelTesting` test has its own per-test
            /// `BackgroundCallQueue`; the queue is resolved at
            /// `awaitSettled` call-time, not when the entry runs.
            case settled(quietWindowNs: UInt64, bg: BackgroundCallQueue)
        }

        let id: UInt64
        /// Mutable in `.debounce` and `.settled` modes (re-armed by
        /// `_noteActivity`); fixed for `.predicate` mode entries.
        var deadlineNs: UInt64
        /// Absolute monotonic-ns hard cap. For `.predicate` mode, equal
        /// to `deadlineNs`. For the debounced modes, the upper bound
        /// that `deadlineNs` cannot grow past.
        let totalBudgetEndNs: UInt64
        let mode: Mode
        /// GTS callback priority for this entry's deadlines (initial
        /// arming and every re-arm). `.deferential` for in-test settle —
        /// the callback hops to `.background` so suspended cooperative-
        /// pool Tasks (which might still write to the model) get CPU
        /// first, closing the toggleExpanded class of race. `.responsive`
        /// for cleanup settle (cancelAll has already torn down the
        /// active tasks, the 200 ms cleanup window absorbs cancel-handler
        /// writes naturally, and deferring would just stall every test's
        /// teardown behind the `.background` queue's drain cadence) and
        /// for `.predicate` mode (failure-case budget — must fire close
        /// to its requested time).
        let priority: GlobalTickScheduler.CallbackPriority
        let continuation: CheckedContinuation<PredicateOutcome, Never>
        /// Cancellation handle for the GlobalTickScheduler entry that
        /// will fire if the deadline is reached. Replaced when the
        /// debounced modes re-arm. `nil` for `.settled` entries that
        /// have transitioned to waiting-on-bg-idle (GTS deadline already
        /// fired); re-engaged if activity arrives in that state.
        var deadlineCancel: (@Sendable () -> Void)?
        /// `.settled` mode only: cancel handle for the in-flight
        /// `bg.onIdle` observer, set after the GTS deadline fires and bg
        /// was still busy. Cleared on re-arm by `_noteActivity` (activity
        /// = not idle) or on resolution.
        var bgIdleCancel: (@Sendable () -> Void)?

        init(
            id: UInt64,
            deadlineNs: UInt64,
            totalBudgetEndNs: UInt64,
            mode: Mode,
            priority: GlobalTickScheduler.CallbackPriority,
            continuation: CheckedContinuation<PredicateOutcome, Never>
        ) {
            self.id = id
            self.deadlineNs = deadlineNs
            self.totalBudgetEndNs = totalBudgetEndNs
            self.mode = mode
            self.priority = priority
            self.continuation = continuation
        }
    }

    enum PredicateOutcome: Sendable {
        case passed
        case timeout
        case cancelled
    }

    var _pendingExpects: [PendingExpect] = []
    var _nextPendingExpectId: UInt64 = 0


    // Captures a single state transition: how to apply it to a Root snapshot, and how to
    // describe it for exhaustion-failure messages.
    //
    // In transitions mode, each property write creates a new ValueUpdate entry appended
    // to a FIFO queue. The queue preserves all intermediate transitions (e.g. false → true,
    // true → false) rather than collapsing them into a single last-write-wins entry.
    struct ValueUpdate {
        var apply: (inout Root) -> Void
        var debugInfo: () -> String
        /// Which exhaustivity category this update belongs to. Defaults to `.state` for
        /// regular property writes; `.local` for `node.local` writes; `.environment` for `node.environment` writes.
        var area: _ExhaustivityBits
        var fromDescription: (() -> String)?
        var toDescription: (() -> String)?
        /// The typed `to` value stored as Any, for use in willAccess during history evaluation.
        var rawValue: Any
        /// The `threadLocals.currentTransactionID` captured when this entry was written.
        /// Non-zero means the write occurred inside a `node.transaction { }`. Used to coalesce
        /// multiple writes to the same path within one transaction into a single FIFO entry.
        var transactionID: UInt = 0
    }

    struct Event {
        var event: Any
        var context: AnyContext
    }

    init(model: Root, dependencies: @escaping (inout ModelDependencies) -> Void, fileAndLine: FileAndLine) {
        expectedState = model.frozenCopy
        lastState = model.frozenCopy
        self.fileAndLine = fileAndLine
        context = Context(model: model, lock: NSRecursiveLock(), dependencies: dependencies, parent: nil)

        super.init(useWeakReference: true)

        // Register on the root context so ModelNode+Undo can find this TestAccess
        // (via `as? TestAccess<…>`) and propagate `didModify` notifications when
        // undo restores fire.
        context.modelAccess = self
        usingAccess(self) {
            // Call onActivate() directly on the context rather than traversing via activate()
            // on context.model. Context.onActivate() uses allChildren directly and invokes
            // pendingActivation for the model's own onActivate() with correct let values.
            _ = context.onActivate()
        }
        // Re-initialize snapshots from the activated model.
        //
        // Child models in containers (Array, Optional, Dictionary, @ModelContainer enums)
        // receive fresh ModelIDs during activation — they are assigned by Context.childContext
        // when the hierarchy is anchored. Cursor key paths that locate elements in these
        // containers embed those fresh IDs (via ContainerCursor.id).
        //
        // If lastState/expectedState retain the pre-activation model's frozenCopy (which has
        // the *initial* unanchored ModelIDs), then:
        //   • didModify's cursor-based write to lastState silently fails (cursor.set can't
        //     find the element because element.id != cursor.id) — lastState is never updated.
        //   • isEqualIncludingIds reads last[keyPath: cursorPath] and gets the fallback value
        //     (element captured at cursor-creation time, value == 0) instead of the current
        //     value (e.g. 99) — diff is always non-nil → loop retries until the 30 s hard cap.
        //
        // Re-initializing from model.frozenCopy gives both snapshots the same
        // ModelIDs that live cursors will use, so cursor lookups find and update elements
        // correctly. `model` has .pending source with _linkedReference = context.reference,
        // so shallowCopy reads the live state (with activated ModelIDs) from the reference.
        //
        // IMPORTANT: Wrap the activated-snapshot creation and lastState assignment inside the
        // TestAccess lock. Between onActivate() and here, async tasks (e.g. forEach with
        // initial: true) may already be running on other threads, writing to the live model
        // state and calling _writeToFrozenState, which targets self.lastState.reference (R1 —
        // the pre-activation frozen copy from line 213). Without the lock, there is a race:
        //
        //   Thread B:  writes live state → _writeToFrozenState targets R1
        //   Thread A:  model.frozenCopy → creates R2 → lastState = R2  (R1's writes lost)
        //
        // With the lock, exactly one of two interleavings occurs:
        //   (a) Thread B wins the lock first: _writeToFrozenState writes to R1, releases lock.
        //       Thread A acquires lock; model.frozenCopy reads the UPDATED live state (the
        //       TestAccess lock release→acquire provides the required happens-before barrier,
        //       making Thread B's context write visible). R2 captures the correct value. ✓
        //   (b) Thread A wins the lock first: model.frozenCopy reads current live state → R2.
        //       lastState = R2. Thread A releases lock. Thread B acquires lock; reads
        //       self.lastState = R2; _writeToFrozenState writes to R2. ✓
        lock {
            let activatedSnapshot = threadLocals.withValue(true, at: \.isApplyingSnapshot) {
                model.frozenCopy
            }
            lastState = activatedSnapshot
            expectedState = activatedSnapshot
        }
    }

    // Propagate this TestAccess to all child/dependency contexts so their property
    // reads and writes are also captured during predicate evaluation.
    override var shouldPropagateToChildren: Bool { true }

    // Called when a @Model property is read (e.g. during predicate evaluation).
    // Returns a closure that, when invoked, records an Access entry for the assert loop.
    //
    // The closure is called after the read is complete (so the value is stable). It
    // builds the full root-relative keypath by composing the context's rootPaths with
    // the per-model path, and appends the Access to the active TesterAssertContext.
    //
    // Only WritableKeyPath properties participate — read-only keypaths (e.g. computed
    // properties, synthetic environment keypaths) are silently skipped.
    //
    // For dependency model context storage (no root-relative path exists), a dummy Access is
    // returned that carries a cleanup closure to clear dependencyMetadataUpdates.
    /// See `ModelAccess.acquireWriteLock` doc-comment. Wraps the writer's
    /// `Context._modify` / `Context.stateTransaction` in our `NSRecursiveLock` so
    /// readers (predicate evaluators, also holding this lock) cannot observe a new
    /// `reference.state` value before the corresponding `valueUpdates` entry has
    /// been appended.
    override func acquireWriteLock() {
        lock.lock()
    }

    override func releaseWriteLock() {
        lock.unlock()
    }

    /// Called from the prelude of every `TaskCancellable`'s body (first CPU
    /// slot after `Task { … }` was scheduled). Fires `_noteActivity` so the
    /// quiet window re-arms — combined with the `hasPendingStartTask` gate
    /// in `_fireDeadline`, this guarantees `settle()` keeps waiting through
    /// the registration→first-execution gap of any newly-spawned task.
    /// See `ModelAccess.taskBodyStarted` for the rationale.
    override func taskBodyStarted() {
        _noteActivity()
    }

    override func willAccess<M: Model, Value>(from context: Context<M>, at path: KeyPath<M._ModelState, Value>&Sendable) -> (() -> Void)? {
        guard let path = path as? WritableKeyPath<M._ModelState, Value> else { return nil }

        // Capture the modification area and storage name at the point of access (thread-locals
        // are set here but may be cleared by the time the returned closure is invoked).
        let capturedArea = threadLocals.modificationArea
        // For context/preference storage paths, storageName carries the property name
        // (e.g. "isDarkMode") captured via #function in the LocalKeys/EnvironmentKeys/PreferenceKeys declaration.
        // propertyName(from:path:) returns nil for synthetic subscript paths, so we prefer this.
        let capturedStorageName = threadLocals.storageName

        // rootPaths resolves the chain of WritableKeyPaths from Root down to this context.
        // Returns nil (empty after compactMap) only for dependency contexts not in the
        // main hierarchy — handled separately by the dependency storage branch below.
        let rootPaths = context.rootPaths.compactMap { $0 as? WritableKeyPath<Root, M> }
        let modelName = context.typeDescription

        guard let assertContext else { return nil }

        // Compose Root→M path with M._modelState→Value path to get Root→Value path.
        // Guard: _EmptyModelState models (no tracked vars) have _modelStateKeyPath defaulting to
        // fatalError() — the macro only generates it when tracked vars exist. Calling it on an
        // empty-state model (e.g. one that uses context storage but has no var properties) would
        // crash. Treat those models as if rootPaths is empty so storage/preference accesses fall
        // through to the dependency-storage early-return below.
        let mStatePath: WritableKeyPath<M, Value>?
        let fullPaths: [WritableKeyPath<Root, Value>]
        if M._ModelState.self == _EmptyModelState.self {
            mStatePath = nil
            fullPaths = []
        } else {
            let ms = M._modelStateKeyPath.appending(path: path)
            mStatePath = ms
            fullPaths = rootPaths.map { $0.appending(path: ms) }
        }

        // Build the display name for failure messages: "context.isDarkMode" / "preference.totalCount"
        // or plain "propertyName" for regular @Model state properties.
        let resolvedStorageName: String?
        if let sn = capturedStorageName {
            let pfx = capturedArea == .preference ? "preference" : capturedArea == .local ? "local" : capturedArea == .environment ? "environment" : nil
            resolvedStorageName = pfx.map { "\($0).\(sn)" } ?? sn
        } else {
            resolvedStorageName = nil  // falls back to propertyName(from:path:) below
        }

        // Dependency model context/preference storage: no root-relative path exists (the context
        // lives in dependencyContexts, not children). Return a dummy Access whose additionalCleanup
        // clears the corresponding dependency updates entry when asserted.
        if fullPaths.isEmpty, (capturedArea == .local || capturedArea == .environment || capturedArea == .preference) {
            let key = DependencyMetadataKey(contextID: ObjectIdentifier(context), path: path)
            let area = capturedArea
            return { [weak self] in
                guard let self else { return }
                let cleanup: () -> Void = { [weak self] in
                    _ = self?.lock {
                        if area == .preference {
                            self?.dependencyPreferenceUpdates.removeValue(forKey: key)
                        } else {
                            self?.dependencyMetadataUpdates.removeValue(forKey: key)  // covers .local and .environment
                        }
                    }
                }
                // Use _modelSeed directly (.live source) to read the current value and property name.
                // .live source reads from _stateHolder without triggering willAccessDirect, so
                // there is no infinite recursion risk. Storage paths have fatalError() getters;
                // use thread-local pre-computed values set by willAccessStorage/willAccessPreferenceValue.
                let capturedValue: Value
                if area == .preference, let pre = threadLocals.precomputedPreferenceValue, let typed = pre as? Value {
                    capturedValue = frozenCopy(typed)
                } else if let pre = threadLocals.precomputedStorageValue, let typed = pre as? Value {
                    capturedValue = frozenCopy(typed)
                } else {
                    capturedValue = frozenCopy(context._modelSeed[keyPath: M._modelStateKeyPath][keyPath: path])
                }
                let capturedPropertyName = resolvedStorageName ?? mStatePath.flatMap { propertyName(from: context._modelSeed, path: $0) }
                assertContext.accesses.append(.init(
                    path: \Root.self,
                    modelName: modelName,
                    propertyName: capturedPropertyName,
                    value: { String(customDumping: capturedValue) },
                    capturedValue: { capturedValue },
                    apply: { _ in },
                    additionalCleanup: cleanup,
                    skipEqualityCheck: true
                ))
            }
        }

        let isPreference = capturedArea.map { $0.contains(.preference) } ?? false
        // Context and preference storage values live in AnyContext.contextStorage, not in the @Model
        // struct fields. Writing them back to a frozen copy (no live context) is a silent no-op, so
        // the isEqualIncludingIds round-trip check would always fail. Skip it for these accesses.
        let isContextOrPreferenceStorage = capturedArea.map { $0.contains(.local) || $0.contains(.environment) || $0.contains(.preference) } ?? false
        // Model-typed properties (e.g. TestHelper.summary: SummaryFeature) carry a generation counter
        // that increments on every child write. Comparing the full struct value in isEqualIncludingIds
        // causes a false "not settled" result whenever a child property changes. Child accesses
        // (e.g. SummaryFeature.destination) are always recorded alongside and check the leaf with IDs.
        let isModelTypeValue = Value.self is any Model.Type
        // ModelContainer-typed properties (Optional<M>, @ModelContainer enum cases) use ContainerCursor
        // key paths that are only safe on the live hierarchy. Reading them on a frozenCopy snapshot
        // crashes because frozenCopy transforms model identity and the cursor's identity key no longer
        // matches. Leaf accesses within the container are recorded separately and provide the same
        // in-flight detection guarantee.
        let isContainerTypeValue = Value.self is any ModelContainer.Type

        // Transitions mode: when there are queued (unasserted) writes for this path,
        // set a thread-local override so the Context subscript yields the front-of-queue
        // historical value instead of the live model value. This ensures the predicate
        // evaluates against transitions in FIFO order rather than the latest live value.
        //
        // When the queue is empty, no override is needed — the live model value matches
        // the expected value (no unasserted writes). We must NOT fall back to reading
        // expectedState[keyPath:] because deep paths through container types (Optional<Child>,
        // array elements) use cursor keypaths whose getters force-unwrap and crash on stale
        // snapshot copies.
        //
        // Skip model-typed and container-typed values: the override yields a frozen copy,
        // and chained access through frozen model instances (e.g. .dependency.value) would
        // hit unanchored model nodes. Leaf properties within containers get their own FIFO
        // entries and overrides.
        if !isContextOrPreferenceStorage, !fullPaths.isEmpty, !isModelTypeValue, !isContainerTypeValue {
            let overrideValue: Value? = self.lock {
                guard self.exhaustivity.contains(.transitions),
                      let front = self.valueUpdates[fullPaths[0]]?.first,
                      let typed = front.rawValue as? Value else {
                    return nil
                }
                return typed
            }
            if let overrideValue {
                threadLocals.transitionOverrideValue = overrideValue
            }
        }

        return {
            // Consume the transition override from the thread-local. When called from the
            // Context subscript path, the Context already yielded this value to the predicate.
            // When called from willAccessStorage/willAccessPreference paths (which don't go
            // through the Context subscript), this clears a stale override.
            let overrideConsumed = threadLocals.transitionOverrideValue
            threadLocals.transitionOverrideValue = nil

            let value: Value
            // For preference paths, use the pre-computed aggregated value if available.
            // willAccessPreferenceValue sets threadLocals.precomputedPreferenceValue before
            // invoking this closure so we don't re-read via context[path] — which
            // re-enters preferenceValue under a lock and causes lock-ordering deadlocks.
            // For context/preference storage paths, use precomputedStorageValue since
            // the _metadata/_preference stub subscripts have fatalError() getters.
            if isPreference, let precomputed = threadLocals.precomputedPreferenceValue, let typed = precomputed as? Value {
                value = frozenCopy(typed)
            } else if isContextOrPreferenceStorage, let precomputed = threadLocals.precomputedStorageValue, let typed = precomputed as? Value {
                value = frozenCopy(typed)
            } else if overrideConsumed != nil, let typed = overrideConsumed as? Value {
                // Transitions mode: use the same override value that was yielded to the predicate.
                // Guard with != nil first to avoid the Swift gotcha where `nil as? T`
                // succeeds when T is an Optional type (producing .some(nil)).
                value = typed
            } else {
                // Use _modelSeed directly (.live source): reads from _stateHolder without
                // triggering willAccessDirect, so there is no infinite recursion risk.
                value = frozenCopy(context._modelSeed[keyPath: M._modelStateKeyPath][keyPath: path])
            }
            let resolvedPropertyName = resolvedStorageName ?? mStatePath.flatMap { propertyName(from: context._modelSeed, path: $0) }
            for fullPath in fullPaths {
                assertContext.accesses.append(.init(
                    path: fullPath,
                    modelName: modelName,
                    propertyName: resolvedPropertyName,
                    value: { String(customDumping: value) },
                    capturedValue: { value },
                    apply: { $0[keyPath: fullPath] = value },
                    skipEqualityCheck: isContextOrPreferenceStorage,
                    isModelTypeValue: isModelTypeValue,
                    isContainerTypeValue: isContainerTypeValue
                ))
            }
        }
    }

    // Called when a @Model property is written (via Context._modify / invokeDidModify).
    // Returns a closure that records the change into valueUpdates and updates lastState.
    //
    // The returned closure is run outside the model lock (post-lock callback). It
    // stores a ValueUpdate for each root-relative path so the exhaustion check can
    // later detect unasserted changes, and immediately applies the new value to lastState
    // so the assert loop can compare settled values.
    //
    // Only WritableKeyPath properties participate — the same guard as willAccess.
    //
    // For dependency model context storage (no root-relative path exists), the update is stored
    // in dependencyMetadataUpdates instead of valueUpdates.
    //
    // IMPORTANT: rootPaths is computed inside the returned closure (i.e. post-lock), NOT here
    // in the method body. Computing it here while the model's context lock is held causes a
    // lock-ordering deadlock on Linux:
    //   – rootPaths walks up to the parent, acquiring parent.lock while child.lock is held
    //     (child → parent order).
    //   – onAnyModification's withModificationActiveCount holds parent.lock and then iterates
    //     children, acquiring child.lock (parent → child order).
    // Running the closure after lock.unlock() in Context._modify/transaction breaks the cycle.
    override func didModify<M: Model, Value>(from context: Context<M>, at path: KeyPath<M._ModelState, Value>&Sendable) -> (() -> Void)? {
        guard let path = path as? WritableKeyPath<M._ModelState, Value> else { return nil }

        // Capture thread-locals here (at call time, while still inside the model lock scope).
        // They may change on other threads by the time the returned closure is invoked.
        let area = threadLocals.modificationArea ?? .state
        // For context/preference storage, storageName carries the property name captured via
        // #function in the LocalKeys/EnvironmentKeys/PreferenceKeys declaration (e.g. "isDarkMode").
        // Fall back to propertyName(from:path:) for regular @Model properties.
        let storageName = threadLocals.storageName
        // Capture the transaction ID so the post-lock closure can coalesce multiple writes
        // to the same path within a single transaction into one valueUpdates entry.
        // Zero means outside any transaction — never coalesce.
        let capturedTxID: UInt = threadLocals.postTransactions != nil ? threadLocals.currentTransactionID : 0
        // Capture thread-locals for storage value reading (set by willAccessStorage/didModifyStorage
        // before invoking this callback). The _metadata/_preference stub subscripts have fatalError()
        // getters; this pre-computed value is used instead.
        let precomputedStorage: Any? = threadLocals.precomputedStorageValue
        let precomputedPreference: Any? = threadLocals.precomputedPreferenceValue

        // Capture a monotonically-increasing sequence number for this modification.
        // AnyContext.didModify() (which increments _modificationCount) is called immediately
        // before invokeDidModifyDirect, so modificationCount already reflects this write.
        // The post-lock closure uses mySeqNum — under the TestAccess lock — to reject stale
        // writes: if a LATER modification (higher seqNum) has already written lastState for
        // this (context, path) pair, this earlier closure's write is silently discarded.
        //
        // NOTE: rootPaths CANNOT be captured here — see the deadlock comment above.
        // NOTE: context.modificationCount acquires context.lock (NSRecursiveLock); safe here
        //       because NSRecursiveLock supports re-entrant acquisition on the same thread.
        let mySeqNum = context.modificationCount
        let contextPathKey = DependencyMetadataKey(contextID: ObjectIdentifier(context), path: path)

        return { [weak self] in
            guard let self else { return }

            // rootPaths is computed here, OUTSIDE the model lock, to avoid the deadlock
            // described above. The model hierarchy is stable at this point (no lock needed
            // to safely read the parent-child structure for an active context).
            let rootPaths = context.rootPaths.compactMap { $0 as? WritableKeyPath<Root, M> }

            // Compose Root→M path with M._modelState→Value path to get Root→Value path.
            // Guard: _EmptyModelState models have _modelStateKeyPath defaulting to fatalError();
            // treat them as if rootPaths is empty (same storage early-return path as below).
            let mStatePath: WritableKeyPath<M, Value>?
            let fullPaths: [WritableKeyPath<Root, Value>]
            if M._ModelState.self == _EmptyModelState.self {
                mStatePath = nil
                fullPaths = []
            } else {
                let ms = M._modelStateKeyPath.appending(path: path)
                mStatePath = ms
                fullPaths = rootPaths.map { $0.appending(path: ms) }
            }

            // Dependency model context/preference storage: no root-relative path exists. Track the
            // update separately so checkExhaustion can report it if not asserted.
            if fullPaths.isEmpty, (area == .local || area == .environment || area == .preference) {
                let key = DependencyMetadataKey(contextID: ObjectIdentifier(context), path: path)
                let name = storageName ?? mStatePath.flatMap { propertyName(from: context._modelSeed, path: $0) }
                let prefix = area == .preference ? "preference" : area == .environment ? "environment" : "local"
                let value: Value
                if area == .preference, let pre = precomputedPreference, let typed = pre as? Value {
                    value = frozenCopy(typed)
                } else if let pre = precomputedStorage, let typed = pre as? Value {
                    value = frozenCopy(typed)
                } else {
                    value = frozenCopy(context._modelSeed[keyPath: M._modelStateKeyPath][keyPath: path])
                }
                self.lock {
                    guard (self.lastWriteSeqNums[key] ?? 0) < mySeqNum else { return }
                    self.lastWriteSeqNums[key] = mySeqNum
                    let update = ValueUpdate(
                        apply: { _ in },  // dependency storage not in Root snapshot
                        debugInfo: { "\(String(describing: M.self)).\(prefix).\(name ?? "UNKNOWN") == \(String(customDumping: value))" },
                        area: area,
                        rawValue: value as Any
                    )
                    if area == .preference {
                        self.dependencyPreferenceUpdates[key] = update
                    } else {
                        self.dependencyMetadataUpdates[key] = update  // covers .local and .environment
                    }
                }
                return
            }

            // Private properties are excluded from exhaustivity tracking: they cannot be
            // observed from test code (no public getter), so requiring tests to assert them
            // would produce false failures. We still update `lastState` so the settlement
            // check (isEqualIncludingIds) works correctly when the test reads a private
            // property via @testable import.
            //
            // fullPaths is non-empty here, which means mStatePath is non-nil (empty-state
            // models always produce empty fullPaths and are handled by the early return above).
            guard let mStatePath else { return }
            let isPrivate = self.isPrivatePath(mStatePath, in: context._modelSeed)

            let name = storageName ?? propertyName(from: context._modelSeed, path: mStatePath)
            let prefix: String? = area == .preference ? "preference" : area == .local ? "local" : area == .environment ? "environment" : nil
            let value: Value
            if area == .preference, let pre = precomputedPreference, let typed = pre as? Value {
                value = frozenCopy(typed)
            } else if area == .local || area == .environment, let pre = precomputedStorage, let typed = pre as? Value {
                value = frozenCopy(typed)
            } else {
                value = frozenCopy(context._modelSeed[keyPath: M._modelStateKeyPath][keyPath: path])
            }
            self.lock {
                guard (self.lastWriteSeqNums[contextPathKey] ?? 0) < mySeqNum else { return }
                self.lastWriteSeqNums[contextPathKey] = mySeqNum
                for (rootPath, fullPath) in zip(rootPaths, fullPaths) {
                    // Private properties are not tracked for exhaustivity: tests cannot observe
                    // them from outside the declaring type, so requiring assertions would produce
                    // false failures. We still update lastState so the settlement check
                    // (isEqualIncludingIds) works correctly when a test reads a private
                    // property via @testable import.
                    if isPrivate {
                        // Storage/preference keypaths have fatalError() getters; Swift's WritableKeyPath
                        // write ABI calls the getter first (synthesized _modify). Skip the write —
                        // the value lives in contextStorage, not in the _ModelState snapshot.
                        if area != .local && area != .environment && area != .preference {
                            // Write directly to the frozen Reference's state, bypassing the composed
                            // WritableKeyPath + nonmutating-setter chain that silently no-ops on Linux.
                            self.lastState[keyPath: rootPath]._context._$modelContext._source._writeToFrozenState(path, value)
                        }
                        continue
                    }

                    // Transaction coalescing: if the last entry for this path was written
                    // during the same transaction, replace it rather than appending. This
                    // ensures one transaction = one FIFO entry, matching Observed/memoize
                    // behaviour where a transaction also produces a single update notification.
                    let isTransactionReplacement = capturedTxID != 0
                        && self.valueUpdates[fullPath]?.last?.transactionID == capturedTxID

                    // The "from" description:
                    //   • When replacing: keep the original first-write "from" so the transition
                    //     arrow reads "original → final" rather than "intermediate → final".
                    //   • When appending after an existing entry: chain from its "to".
                    //   • First write to this path: capture current lastState.
                    let capturedFrom: (() -> String)?
                    if isTransactionReplacement {
                        capturedFrom = self.valueUpdates[fullPath]!.last!.fromDescription
                    } else if let lastEntry = self.valueUpdates[fullPath]?.last,
                              let lastTo = lastEntry.toDescription {
                        // Subsequent write: "from" is the previous entry's "to"
                        capturedFrom = lastTo
                    } else if area == .local || area == .environment || area == .preference {
                        // Storage/preference paths: values live in AnyContext.contextStorage, not in
                        // the _ModelState struct. The _metadata/_preference getter stubs call fatalError(),
                        // so reading lastState[keyPath: fullPath] would crash. Skip the "from" capture —
                        // the message will show "== newValue" instead of "oldValue → newValue".
                        capturedFrom = nil
                    } else {
                        // First write to this path since last assert: capture lastState.
                        // We use lastState rather than expectedState because deep paths through
                        // container types (Optional<Child>, array elements) use keypaths whose
                        // get closures force-unwrap — expectedState may have a nil/stale container
                        // while lastState is always kept in sync with the live model structure.
                        let capturedOriginal: Value = threadLocals.withValue(true, at: \.isApplyingSnapshot) {
                            self.lastState[keyPath: fullPath]
                        }
                        capturedFrom = {
                            threadLocals.withValue(true, at: \.includeImplicitIDInMirror) {
                                String(customDumping: capturedOriginal)
                            }
                        }
                    }

                    let toDesc: () -> String = {
                        threadLocals.withValue(true, at: \.includeImplicitIDInMirror) {
                            String(customDumping: value)
                        }
                    }

                    // Storage/preference keypaths have fatalError() getters; Swift's WritableKeyPath
                    // write ABI calls the getter first. Use a no-op apply — the value lives in
                    // contextStorage, not in the _ModelState snapshot used by isEqualIncludingIds.
                    let isStoragePath = area == .local || area == .environment || area == .preference
                    let entry = ValueUpdate(
                        apply: isStoragePath ? { _ in } : { $0[keyPath: fullPath] = value },
                        debugInfo: {
                            let prop = prefix.map { "\($0).\(name ?? "UNKNOWN")" } ?? (name ?? "UNKNOWN")
                            let label = "\(String(describing: M.self)).\(prop)"
                            if let from = capturedFrom {
                                return "\(label): \(from()) → \(toDesc())"
                            } else {
                                return "\(label) == \(toDesc())"
                            }
                        },
                        area: area,
                        fromDescription: capturedFrom,
                        toDescription: toDesc,
                        rawValue: value as Any,
                        transactionID: capturedTxID
                    )
                    if isTransactionReplacement {
                        self.valueUpdates[fullPath]![self.valueUpdates[fullPath]!.count - 1] = entry
                    } else {
                        self.valueUpdates[fullPath, default: []].append(entry)
                    }

                    // Storage/preference keypaths have fatalError() getters; Swift's WritableKeyPath
                    // write ABI calls the getter first (synthesized _modify). Skip the write —
                    // the value lives in contextStorage, not in the _ModelState snapshot.
                    if !isStoragePath {
                        // Write directly to the frozen Reference's state, bypassing the composed
                        // WritableKeyPath + nonmutating-setter chain that silently no-ops on Linux.
                        self.lastState[keyPath: rootPath]._context._$modelContext._source._writeToFrozenState(path, value)
                    }
                }
            }
            // Notify any active wait: this write counts as activity. Lives at the
            // end of the post-lock closure so the wait observer sees the fully-
            // committed lastState (matches what predicate re-evaluation will read).
            self._noteActivity()
        }
    }

    override func didSend<M: Model, Event>(event: Event, from context: Context<M>) {
        lock {
            events.append(.init(event: event, context: context))
        }
        // Notify any active wait: event arrival counts as activity (a predicate
        // waiting on `model.didSend(...)` can now re-evaluate).
        _noteActivity()
    }

    // MARK: - Wait state machine implementation

    /// Notify any active wait that activity has occurred (model write, event
    /// send, probe call). Evaluates every pending predicate INLINE under the
    /// same lock that ordered the activity; predicates that now pass have
    /// their continuations resumed (outside the lock).
    ///
    /// Thread-safety: callable from any thread. Wakes continuations OUTSIDE
    /// the lock so resumed Tasks can call back into `awaitPredicate` /
    /// `awaitQuietWindow` without re-entering.
    func _noteActivity() {
        var wakes: [CheckedContinuation<PredicateOutcome, Never>] = []
        lock {
            let now = monotonicNanoseconds()
            // Iterate in reverse so removals don't shift indices we haven't
            // visited yet.
            for i in (0..<_pendingExpects.count).reversed() {
                let pending = _pendingExpects[i]
                switch pending.mode {
                case .predicate(let evaluate):
                    let passed = evaluate()
                    if passed {
                        pending.deadlineCancel?()
                        wakes.append(pending.continuation)
                        _pendingExpects.remove(at: i)
                    }
                case .debounce(let quietWindowNs):
                    // Re-arm deadline to `min(now + quietWindow, budgetCap)`.
                    // Skip the re-schedule when it wouldn't push the
                    // deadline further out (already at the cap).
                    //
                    // GlobalTickScheduler.schedule/cancel acquire a
                    // separate lock, so re-arming while holding
                    // TestAccess.lock is deadlock-free. The cancel handle
                    // is replaced atomically before the new one is
                    // scheduled; a stale fire of the OLD scheduler entry
                    // would call `_fireDeadline(pendingId:)`, but by then
                    // either the entry has been re-armed (cancel happened)
                    // or it has actually fired (no-op on the second
                    // attempt — `_pendingExpects` no longer contains it).
                    let newDeadline = Self._quietDeadline(nowNs: now, quietWindowNs: quietWindowNs, budgetEndNs: pending.totalBudgetEndNs)
                    if newDeadline > pending.deadlineNs {
                        pending.deadlineCancel?()
                        pending.deadlineNs = newDeadline
                        let entryId = pending.id
                        pending.deadlineCancel = GlobalTickScheduler.shared.schedule(deadlineNs: newDeadline, priority: pending.priority) { [weak self] in
                            self?._fireDeadline(pendingId: entryId)
                        }
                        _settleTrace("rearm:debounce id=\(pending.id) newDeadlineInMs=\((Int64(bitPattern: newDeadline) &- Int64(bitPattern: now)) / 1_000_000)")
                    }
                case .settled(let quietWindowNs, _):
                    // Same re-arm rule as `.debounce`, plus: if we're in
                    // the "waiting on bg-idle" sub-state (deadline already
                    // fired, bgIdleCancel set), cancel the bg-idle
                    // observer (this activity proves bg is not idle right
                    // now) and re-schedule the GTS deadline to push the
                    // quiet window forward.
                    let newDeadline = Self._quietDeadline(nowNs: now, quietWindowNs: quietWindowNs, budgetEndNs: pending.totalBudgetEndNs)
                    _settleTrace("rearm:settled id=\(pending.id) newDeadlineInMs=\((Int64(bitPattern: newDeadline) &- Int64(bitPattern: now)) / 1_000_000) hadBgCancel=\(pending.bgIdleCancel != nil)")

                    // If a bg-idle observer is in flight, cancel it.
                    // Activity = not idle, so any pending idle-fire is
                    // semantically stale. The wrapper-with-fired-flag in
                    // `BackgroundCallQueue.onIdle` makes a racing fire
                    // observe the cancel and no-op.
                    if let bgCancel = pending.bgIdleCancel {
                        bgCancel()
                        pending.bgIdleCancel = nil
                    }

                    // Re-engage the GTS deadline. Two cases:
                    //   1. deadlineCancel != nil → still in waiting-on-GTS
                    //      state; cancel old entry and re-schedule forward.
                    //   2. deadlineCancel == nil → GTS deadline already
                    //      fired earlier; we were in waiting-on-bg-idle.
                    //      Activity returns us to waiting-on-GTS — schedule
                    //      a fresh GTS entry.
                    if pending.deadlineCancel != nil && newDeadline <= pending.deadlineNs {
                        // No forward movement and still in GTS-waiting
                        // state → nothing to do.
                        continue
                    }
                    pending.deadlineCancel?()
                    pending.deadlineNs = newDeadline
                    let entryId = pending.id
                    pending.deadlineCancel = GlobalTickScheduler.shared.schedule(deadlineNs: newDeadline, priority: pending.priority) { [weak self] in
                        self?._fireDeadline(pendingId: entryId)
                    }
                }
            }
        }
        // Resume outside the lock — resumed Tasks may synchronously call
        // back into `awaitPredicate`, which would re-acquire the lock.
        // Order doesn't matter — each continuation is unique.
        for cont in wakes {
            cont.resume(returning: .passed)
        }
    }

    // MARK: - awaitPredicate

    /// Register a predicate and wait until it passes, the deadline
    /// elapses, or the Task is cancelled.
    ///
    /// `evaluate` is called:
    /// - **Initially** on the caller's thread, INSIDE TestAccess.lock,
    ///   before parking. If it returns true, we resolve immediately
    ///   without parking — same eval cost as the OLD design's first
    ///   loop iteration.
    /// - **Subsequently** on writer threads from `_noteActivity`, INSIDE
    ///   TestAccess.lock. Predicates that now pass have their callers
    ///   resumed with `.passed`.
    ///
    /// **Race elimination**: because eval and the pending-list updates
    /// are both inside the same lock that `_noteActivity` holds, there's
    /// no window where activity can fire between "we evaluated and it
    /// failed" and "we registered to be notified."
    ///
    /// **Evaluator contract**: must be cheap (called per activity),
    /// reentrant-safe (NSRecursiveLock), and MUST NOT write to the
    /// model (would trigger recursive `_noteActivity` while we hold the
    /// lock). TaskLocals like `assertContext` must be wrapped inside
    /// `evaluate` by the caller — they don't propagate from caller to
    /// writer thread automatically. Pattern:
    ///
    /// ```swift
    /// await access.awaitPredicate(deadlineNs: ...) {
    ///     TesterAssertContextBase.$assertContext.withValue(context) {
    ///         usingActiveAccess(access) {
    ///             // ... evaluate predicates, return true if all pass ...
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// Returns `.passed` / `.timeout` / `.cancelled`. The deadline
    /// callback is registered with `GlobalTickScheduler`, so it fires
    /// from GCD's pool — not subject to cooperative-pool starvation.
    func awaitPredicate(
        deadlineNs: UInt64,
        evaluate: @escaping @Sendable () -> Bool
    ) async -> PredicateOutcome {
        await _awaitPending(
            initialDeadlineNs: deadlineNs,
            totalBudgetEndNs: deadlineNs,
            mode: .predicate(evaluate),
            // `.deferential` — same rationale as settle (see
            // `waitUntilSettled` and `settleTotalBudgetNs`'s comment).
            // expect's predicate becomes true only when some
            // cooperative-pool Task writes/sends/probes; on a loaded
            // box that Task may not get CPU within wall-clock budget.
            // Routing the budget-end callback through `.background`
            // QoS ensures the timeout only fires after the scheduler
            // has actually drained higher-priority work — so we don't
            // declare failure on a load symptom. The 30 s trait cap
            // remains the true safety net for genuine hangs.
            //
            // Predicate evaluation itself is still INLINE on every
            // `_noteActivity`, so the happy-path latency is unchanged
            // (resolves the instant the predicate becomes true).
            priority: .deferential
        )
    }

    /// Compute the deadline for a settle quiet-window arming. Returns
    /// `min(now + quietWindowNs, budgetEndNs)` — **literal**, no scaling.
    ///
    /// **Used by**: every site in this file that arms a `.debounce` or
    /// `.settled` quiet window — `awaitQuietWindow`, `awaitSettled`, the
    /// `_noteActivity` re-arm paths, and the pending-start retry paths
    /// in `_fireDeadline` / `_fireBgIdle`.
    ///
    /// **No load-aware extension**. The natural load adaptation lives
    /// one layer down: `GlobalTickScheduler` runs at `.background` QoS,
    /// so its tick callback is itself deferred until higher-priority
    /// work has drained. A 50 ms nominal deadline armed during heavy
    /// contention naturally fires at ~50 ms + scheduling latency, which
    /// is exactly the "wait until the system has settled" semantic we
    /// want. Multiplying the window on top of that was double-counting
    /// — and worse, fragile: a single late tick observation could pin
    /// a 200 ms window to 2 s with no mechanism to recover when the
    /// load passed.
    static func _quietDeadline(nowNs now: UInt64, quietWindowNs: UInt64, budgetEndNs: UInt64) -> UInt64 {
        let candidate = now &+ quietWindowNs
        let deadline = candidate < budgetEndNs ? candidate : budgetEndNs
        // Signed wrap-safe trace: `deadline` may be ≤ `now` when
        // `budgetEndNs` has already elapsed.
        let traceDeltaMs = (Int64(bitPattern: deadline) &- Int64(bitPattern: now)) / 1_000_000
        _settleTrace("_quietDeadline quietMs=\(quietWindowNs / 1_000_000) deadlineInMs=\(traceDeltaMs)")
        return deadline
    }

    /// Park the calling Task until the model has been silent (no
    /// `_noteActivity`) for `quietWindowNs`, or until `totalBudgetNs`
    /// elapses overall, or the Task is cancelled.
    ///
    /// **Single-await debounce**: unlike a loop of "wake on activity,
    /// recompute, re-park", this primitive uses **one** `withCheckedContinuation`.
    /// On every activity, `_noteActivity` (under TestAccess.lock) re-arms
    /// the entry's GlobalTickScheduler deadline to `min(now +
    /// quietWindowNs, totalBudgetEndNs)`. The continuation only wakes
    /// when the (mutable) deadline finally fires — exactly once per
    /// `awaitQuietWindow` call.
    ///
    /// On wake, the caller compares `monotonicNanoseconds()` to the
    /// budget end to distinguish "quiet window elapsed (settled)" from
    /// "budget exhausted." Returns `.passed` in both cases — the
    /// distinction is the caller's; see `waitUntilSettled`.
    func awaitQuietWindow(
        quietWindowNs: UInt64,
        totalBudgetNs: UInt64
    ) async -> PredicateOutcome {
        let now = monotonicNanoseconds()
        let budgetEnd = now &+ totalBudgetNs
        // Initial deadline is `min(now + quiet, budgetEnd)` — if no
        // activity ever arrives we wake when the quiet window first
        // elapses.
        let initialDeadline = Self._quietDeadline(nowNs: now, quietWindowNs: quietWindowNs, budgetEndNs: budgetEnd)
        _settleTrace("awaitQuietWindow:arm quietMs=\(quietWindowNs / 1_000_000) budgetMs=\(totalBudgetNs / 1_000_000)")
        let outcome = await _awaitPending(
            initialDeadlineNs: initialDeadline,
            totalBudgetEndNs: budgetEnd,
            mode: .debounce(quietWindowNs: quietWindowNs),
            // Same rationale as in-test `awaitSettled`: this is a
            // race-protection wait, defer the quiet check so suspended
            // Tasks land first.
            priority: .deferential
        )
        let elapsedMs = (monotonicNanoseconds() &- now) / 1_000_000
        _settleTrace("awaitQuietWindow:resume outcome=\(outcome) elapsedMs=\(elapsedMs)")
        return outcome
    }

    /// Park the calling Task until BOTH:
    ///   • no `_noteActivity` (model write / event send / probe call)
    ///     has arrived for `quietWindowNs`, AND
    ///   • `bg` is idle (no in-flight pipeline work)
    ///
    /// are simultaneously true — or `totalBudgetNs` elapses overall, or
    /// the Task is cancelled.
    ///
    /// **Single-await design**: this primitive replaces the previous
    /// "loop: `awaitQuietWindow` + `bg.waitForCurrentItems` + check
    /// `modificationCount`" structure in `waitUntilSettled`. The state
    /// machine — re-arm on activity, transition to waiting-on-bg-idle
    /// when the quiet window expires while bg is busy, transition back
    /// to waiting-on-quiet on new activity — runs inside
    /// `_noteActivity`, `_fireDeadline`, and `_fireBgIdle` under the
    /// same `TestAccess.lock`. The continuation suspends exactly once;
    /// the resume happens from whichever path resolves it.
    ///
    /// **Why this matters for silent memoize recomputes**: when a
    /// memoize `performUpdate` re-evaluates and its produced value
    /// matches the cached one, `update(with:)` skips the `onUpdate`
    /// callback (`isSame` returns true). No `didModify` fires, so no
    /// `_noteActivity` wake. `awaitQuietWindow` alone cannot observe
    /// that bg work; `awaitSettled` does, via the `bg.onIdle`
    /// observer that fires when the drain completes.
    ///
    /// Returns `.passed` whenever the entry resolves (caller compares
    /// `now` to the budget end to distinguish "fully settled" from
    /// "budget exhausted") or `.cancelled` on Task cancellation.
    /// - Parameter priority: GTS callback priority for the deadline.
    ///   `.deferential` (default) defers the quiet-check callback to
    ///   `.background` QoS so suspended cooperative-pool Tasks land
    ///   their writes first — needed by in-test settle to close the
    ///   toggleExpanded race. Cleanup settle passes `.responsive`
    ///   because by then `cancelAllRecursively` has torn down tasks,
    ///   the 200 ms cleanup window absorbs cancel-handler writes
    ///   naturally, and deferring would stall every test's teardown
    ///   behind the `.background` queue's drain cadence (the
    ///   "all-tests-finish-at-the-same-instant clusters" pattern).
    func awaitSettled(
        quietWindowNs: UInt64,
        totalBudgetNs: UInt64,
        bg: BackgroundCallQueue,
        priority: GlobalTickScheduler.CallbackPriority = .deferential
    ) async -> PredicateOutcome {
        let now = monotonicNanoseconds()
        let budgetEnd = now &+ totalBudgetNs
        let initialDeadline = Self._quietDeadline(nowNs: now, quietWindowNs: quietWindowNs, budgetEndNs: budgetEnd)
        _settleTrace("awaitSettled:arm quietMs=\(quietWindowNs / 1_000_000) budgetMs=\(totalBudgetNs / 1_000_000) priority=\(priority)")
        let outcome = await _awaitPending(
            initialDeadlineNs: initialDeadline,
            totalBudgetEndNs: budgetEnd,
            mode: .settled(quietWindowNs: quietWindowNs, bg: bg),
            priority: priority
        )
        let elapsedMs = (monotonicNanoseconds() &- now) / 1_000_000
        _settleTrace("awaitSettled:resume outcome=\(outcome) elapsedMs=\(elapsedMs)")
        return outcome
    }

    private func _awaitPending(
        initialDeadlineNs: UInt64,
        totalBudgetEndNs: UInt64,
        mode: PendingExpect.Mode,
        priority: GlobalTickScheduler.CallbackPriority
    ) async -> PredicateOutcome {
        let id: UInt64 = lock {
            _nextPendingExpectId &+= 1
            return _nextPendingExpectId
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<PredicateOutcome, Never>) in
                let immediate: PredicateOutcome? = lock {
                    if Task.isCancelled { return .cancelled }

                    // Initial eval inside the same lock that activity uses.
                    // For debounce mode we never short-circuit — settle
                    // wants to wait for the quiet window to elapse.
                    if case .predicate(let evaluate) = mode, evaluate() {
                        return .passed
                    }

                    // Register for future activity / deadline. The
                    // priority chosen by the caller (and stored on the
                    // entry) is reused by every subsequent re-arm in
                    // `_noteActivity` / `_fireDeadline` / `_fireBgIdle`.
                    let pending = PendingExpect(
                        id: id,
                        deadlineNs: initialDeadlineNs,
                        totalBudgetEndNs: totalBudgetEndNs,
                        mode: mode,
                        priority: priority,
                        continuation: cont
                    )
                    pending.deadlineCancel = GlobalTickScheduler.shared.schedule(deadlineNs: initialDeadlineNs, priority: priority) { [weak self] in
                        self?._fireDeadline(pendingId: id)
                    }
                    _pendingExpects.append(pending)
                    return nil
                }
                if let immediate {
                    cont.resume(returning: immediate)
                }
            }
        } onCancel: {
            // Task cancellation arrived while we may be parked. Remove
            // our pending entry (if still present) and resume.
            let toWake: CheckedContinuation<PredicateOutcome, Never>? = lock {
                guard let idx = _pendingExpects.firstIndex(where: { $0.id == id }) else { return nil }
                let pending = _pendingExpects.remove(at: idx)
                pending.deadlineCancel?()
                pending.bgIdleCancel?()
                return pending.continuation
            }
            toWake?.resume(returning: .cancelled)
        }
    }

    /// Called by GlobalTickScheduler when a pending expect's deadline
    /// is reached.
    ///
    /// Behaviour by mode:
    ///   • `.predicate` — resume `.timeout`, remove entry.
    ///   • `.debounce`  — resume `.timeout` (callers of
    ///     `awaitQuietWindow` treat that as "quiet window expired"),
    ///     remove entry.
    ///   • `.settled`   — check `bg.isIdle`. If idle OR the deadline is
    ///     at/past the total-budget cap (no point waiting further),
    ///     resume `.timeout` and remove entry. Otherwise register a
    ///     `bg.onIdle` observer that will fire when bg drains;
    ///     `bgIdleCancel` is stored on the entry so a racing
    ///     `_noteActivity` can cancel the in-flight observer and
    ///     re-arm the GTS deadline forward. The entry stays in
    ///     `_pendingExpects` while we wait.
    private func _fireDeadline(pendingId: UInt64) {
        // Returns the continuation to resume (with .timeout), or nil if
        // this fire didn't result in a resolution (entry already gone,
        // or transitioned to waiting-on-bg-idle for `.settled` mode).
        let toWake: CheckedContinuation<PredicateOutcome, Never>? = lock {
            guard let idx = _pendingExpects.firstIndex(where: { $0.id == pendingId }) else {
                _settleTrace("fireDeadline:gone id=\(pendingId)")
                return nil
            }
            let pending = _pendingExpects[idx]
            // GTS just fired — clear the cancel handle so the
            // re-engagement path in `_noteActivity` treats this entry as
            // having no in-flight GTS entry.
            pending.deadlineCancel = nil

            switch pending.mode {
            case .predicate, .debounce:
                _settleTrace("fireDeadline:resolve id=\(pendingId) mode=\(pending.mode)")
                _pendingExpects.remove(at: idx)
                return pending.continuation
            case .settled(let quietWindowNs, let bg):
                let now = monotonicNanoseconds()
                let pastBudget = now >= pending.totalBudgetEndNs

                // Pending-start gate: if any registered TaskCancellable's
                // body hasn't begun executing yet, do NOT declare quiet —
                // an `onActivate` task still queued in the cooperative pool
                // would write a property after settle returned, surviving
                // to the exhaustivity check as an unasserted modification
                // (see `ModelAccess.taskBodyStarted` for the full rationale).
                //
                // We can't observe "task body started" as a discrete event
                // here, but `taskBodyStarted` on the same TestAccess fires
                // `_noteActivity`, which re-arms the GTS deadline — so when
                // the body finally runs we'll re-fire this deadline and
                // re-check. As a belt-and-suspenders, if no
                // `_noteActivity` arrives, we still re-arm with one quiet
                // window so we keep polling rather than hang forever on a
                // task that never schedules (the total budget catches that
                // case as a normal settle timeout).
                if !pastBudget && context.hasPendingStartTask {
                    let newDeadline = Self._quietDeadline(nowNs: now, quietWindowNs: quietWindowNs, budgetEndNs: pending.totalBudgetEndNs)
                    pending.deadlineNs = newDeadline
                    let entryId = pending.id
                    pending.deadlineCancel = GlobalTickScheduler.shared.schedule(deadlineNs: newDeadline, priority: pending.priority) { [weak self] in
                        self?._fireDeadline(pendingId: entryId)
                    }
                    _settleTrace("fireDeadline:retryPendingStart id=\(pendingId)")
                    return nil
                }

                if pastBudget || bg.isIdle {
                    _settleTrace("fireDeadline:resolve id=\(pendingId) mode=settled pastBudget=\(pastBudget) bgIdle=\(bg.isIdle)")
                    _pendingExpects.remove(at: idx)
                    return pending.continuation
                }
                // bg is busy — register an idle observer. The wrapper-
                // with-fired-flag inside `onIdle` guarantees at-most-once
                // delivery, so a race with `_noteActivity` cancelling us
                // is safe.
                let entryId = pending.id
                pending.bgIdleCancel = bg.onIdle { [weak self] in
                    self?._fireBgIdle(pendingId: entryId)
                }
                _settleTrace("fireDeadline:waitBgIdle id=\(pendingId)")
                return nil
            }
        }
        toWake?.resume(returning: .timeout)
    }

    /// Called by `BackgroundCallQueue.onIdle` when bg drains while a
    /// `.settled` entry is waiting on it (the GTS deadline already
    /// fired, bg was busy at the time, we registered a one-shot idle
    /// observer). Resumes `.timeout` so the caller can compare its
    /// `now` to `budgetEndNs` and treat it as either "settled" or
    /// "budget exhausted" — same convention as the deadline path.
    ///
    /// **Stale-fire race**: between the bg-idle wrapper firing (on the
    /// GCD pool) and this method acquiring `TestAccess.lock`, an activity
    /// can arrive on a writer thread and call `_noteActivity`, which
    /// will cancel `bgIdleCancel` (no-op now — wrapper already fired)
    /// AND re-arm the GTS deadline. In that case we observe
    /// `pending.deadlineCancel != nil` and abandon this fire — the
    /// activity took precedence and we must continue waiting for the
    /// re-armed quiet window.
    private func _fireBgIdle(pendingId: UInt64) {
        let toWake: CheckedContinuation<PredicateOutcome, Never>? = lock {
            guard let idx = _pendingExpects.firstIndex(where: { $0.id == pendingId }) else {
                _settleTrace("fireBgIdle:gone id=\(pendingId)")
                return nil
            }
            let pending = _pendingExpects[idx]
            // Activity re-armed the GTS deadline after the bg-idle
            // wrapper fired — this fire is stale; keep waiting.
            if pending.deadlineCancel != nil {
                _settleTrace("fireBgIdle:stale id=\(pendingId) (activity re-armed)")
                return nil
            }
            // Pending-start gate (same rationale as `_fireDeadline`'s
            // `.settled` branch): even with bg idle, if a registered
            // `TaskCancellable` body hasn't executed once yet, we must
            // keep waiting. Re-arm GTS and abandon this fire.
            if case .settled(let quietWindowNs, _) = pending.mode, context.hasPendingStartTask {
                let now = monotonicNanoseconds()
                let newDeadline = Self._quietDeadline(nowNs: now, quietWindowNs: quietWindowNs, budgetEndNs: pending.totalBudgetEndNs)
                pending.deadlineNs = newDeadline
                let entryId = pending.id
                pending.deadlineCancel = GlobalTickScheduler.shared.schedule(deadlineNs: newDeadline, priority: pending.priority) { [weak self] in
                    self?._fireDeadline(pendingId: entryId)
                }
                pending.bgIdleCancel = nil
                _settleTrace("fireBgIdle:retryPendingStart id=\(pendingId)")
                return nil
            }
            pending.bgIdleCancel = nil
            _settleTrace("fireBgIdle:resolve id=\(pendingId)")
            _pendingExpects.remove(at: idx)
            return pending.continuation
        }
        toWake?.resume(returning: .timeout)
    }

    func fail(_ message: String, at fileAndLine: FileAndLine) {
        reportIssue(message, fileID: fileAndLine.fileID, filePath: fileAndLine.filePath, line: fileAndLine.line, column: fileAndLine.column)
    }

    func fail(_ message: String, for area: _ExhaustivityBits, at fileAndLine: FileAndLine) {
        if lock({ exhaustivity.contains(area) }) {
            fail(message, at: fileAndLine)
        } else if lock({ showSkippedAssertions }) {
            withExpectedIssue {
                fail(message, at: fileAndLine)
            }
        }
    }

    /// Resets exhaustivity categories within the lock. Called from settle(resetting:) settle paths in expect().
    func _applyResetting(_ bits: _ExhaustivityBits) {
        lock {
            if bits.contains(.state) {
                expectedState = lastState
                valueUpdates.removeAll()
            }
            if bits.contains(.local) {
                dependencyMetadataUpdates.removeAll()
            }
            if bits.contains(.environment) || bits.contains(.preference) {
                dependencyPreferenceUpdates.removeAll()
            }
            if bits.contains(.events) {
                events.removeAll()
            }
            if bits.contains(.probes) {
                for probe in probes {
                    probe.resetValues()
                }
            }
        }
    }

    func checkExhaustion(at fileAndLine: FileAndLine, includeUpdates: Bool, checkTasks: Bool = false, capturedUpdates: [PartialKeyPath<Root>: [ValueUpdate]]? = nil) {
        if checkTasks {
            for info in context.activeTasks {
                let taskWord = info.tasks.count == 1 ? "task" : "tasks"
                fail("Models of type `\(info.modelName)` have \(info.tasks.count) active \(taskWord) still running", for: .tasks, at: fileAndLine)

                for (taskName, taskFileAndLine) in info.tasks {
                    fail("Active task '\(taskName)' of `\(info.modelName)` still running", for: .tasks, at: taskFileAndLine)
                }
            }
        }

        let events = lock { self.events }
        for event in events {
            fail("Event `\(String(customDumping: event.event))` sent from `\(event.context.typeDescription)` was not handled", for: .events, at: fileAndLine)
        }

        let probes = lock { self.probes }
        for probe in probes {
            let preTitle = "Expected probe not called" + (probe.name.map { " \"\($0)\":" } ?? ":")
            for value in probe.values {
                let message = value is NoArgs ? preTitle :
                    """
                    \(preTitle)
                        \(String(customDumping: value))
                    """
                fail(message, for: .probes, at: fileAndLine)
            }
        }

        // Read expectedState and lastState under a fresh lock so layers 1/2 detect any
        // concurrent writes to lastState that occurred after the clearing block. For layer 3
        // (valueUpdates), use the pre-captured snapshot when provided: it was captured inside
        // the same lock as the clearing block, eliminating the race window where a concurrent
        // activeAccessCallback could write a new entry between clearing and this read.
        let snap = lock { (expectedState, lastState, valueUpdates) }
        let lastAsserted = snap.0
        let actual = snap.1
        let snapshotUpdates = capturedUpdates ?? snap.2

        let title = "State not exhausted"

        // Three layers of exhaustion checking.
        //
        // On the success path (includeUpdates = true), expectedState was just set to lastState
        // so layers 1 and 2 would always produce identical values — skip straight to layer 3.
        //
        // On the timeout/deinit path (includeUpdates = false), run the layers in order and
        // stop at the first one that produces output. This mirrors the original behavior
        // and avoids duplicate messages for the same change.
        //
        // Layer 1: structural diff without IDs (data fields only). Catches data changes cleanly
        // without ModelID noise.
        //
        // Layer 2: structural diff with IDs included. Only runs if layer 1 produced nothing —
        // meaning all data fields are identical. In that case the only possible difference is
        // the implicit ModelID, which indicates a child model was replaced with a new instance
        // that has the same field values.
        //
        // Layer 3: valueUpdates — per-property unasserted changes. Runs on the success path
        // always; on the timeout/deinit path only when layers 1 and 2 both produced nothing.
        // (On success path it catches writes that happened after the last asserted predicate;
        // on timeout path it catches changes invisible to the struct diff, e.g. multiple writes
        // that returned to the same value.)
        //
        // We use diffMessage() for layers 1 and 2. It uses Equatable.== as a pre-check before
        // running the structural diff, which filters out enum cases with function-typed associated
        // values (where == always returns false but customDump shows no difference).

        var reportedStateFailure = false

        // Layer 1: diff without IDs (data fields only).
        let layer1 = threadLocals.withValue(true, at: \.includeChildrenInMirror) {
            diffMessage(expected: lastAsserted, actual: actual, title: title)
        }
        // Suppress "Not equal but no difference detected" from layer-1 too.
        // Enum cases with function-typed associated values cause Equatable.== to return
        // false (functions can't be compared) but customDump shows no visible difference.
        if let message = layer1, !message.contains("Not equal but no difference detected") {
            fail(message, for: .state, at: fileAndLine)
            reportedStateFailure = true
        } else {
            // Layer 2: diff with IDs — only runs if layer 1 found nothing.
            // Catches identity-only changes: child model replaced with a new instance
            // that has the same field values, so only the implicit ModelID differs.
            let layer2 = threadLocals.withValue(true, at: \.includeImplicitIDInMirror) {
                diffMessage(expected: lastAsserted, actual: actual, title: title)
            }
            // Suppress "Not equal but no difference detected" results from layer-2.
            // This happens with enum cases that have function-typed associated values:
            // Equatable.== returns false (functions can't be compared) but customDump
            // shows no visible difference. These are false positives for the id-only diff.
            if let message = layer2, !message.contains("Not equal but no difference detected") {
                fail(message, for: .state, at: fileAndLine)
                reportedStateFailure = true
            }
        }

        // Layer 3: valueUpdates — only when layers 1/2 didn't fire.
        // On the success path, layers 1/2 produce no output because expectedState was
        // just set to lastState. Layer 3 catches any writes that fired after that reset.
        // On the timeout/deinit path, layer 3 catches changes invisible to the struct
        // diff (e.g. multiple writes to the same property that ended at the same value).
        //
        // With FIFO queues, each remaining entry in each queue is an unasserted transition.
        if !reportedStateFailure {
            // Flatten all queue entries into a single list for reporting.
            let allUpdates = snapshotUpdates.values.flatMap { $0 }
            // Partition by area so state, local, environment, and preference storage are each reported
            // independently and respect their respective exhaustivity flags.
            for area: _ExhaustivityBits in [.state, .local, .environment, .preference] {
                let updates = allUpdates.filter { $0.area == area }
                if !updates.isEmpty {
                    let descriptions = updates.map { $0.debugInfo() }
                    let areaTitle: String
                    switch area {
                    case .local: areaTitle = "Local not exhausted"
                    case .environment: areaTitle = "Environment not exhausted"
                    case .preference: areaTitle = "Preference not exhausted"
                    default: areaTitle = "State not exhausted"
                    }
                    fail("""
                        \(areaTitle): …

                        Modifications not asserted:

                        \(descriptions.map { $0.indent(by: 4) }.joined(separator: "\n\n"))
                        """, for: area, at: fileAndLine)
                }
            }

            // Layer 3b: unasserted local/environment/preference storage on dependency models.
            // These are tracked separately because dependency models have no
            // root-relative WritableKeyPath and cannot be put in valueUpdates.
            let depMetaUpdates = lock { dependencyMetadataUpdates }
            if !depMetaUpdates.isEmpty {
                for area: _ExhaustivityBits in [.local, .environment] {
                    let updates = depMetaUpdates.values.filter { $0.area == area }
                    if !updates.isEmpty {
                        let descriptions = updates.map { $0.debugInfo() }
                        let areaTitle = area == .local ? "Local not exhausted" : "Environment not exhausted"
                        fail("""
                            \(areaTitle): …

                            Modifications not asserted:

                            \(descriptions.map { $0.indent(by: 4) }.joined(separator: "\n\n"))
                            """, for: area, at: fileAndLine)
                    }
                }
            }

            let depPrefUpdates = lock { dependencyPreferenceUpdates }
            if !depPrefUpdates.isEmpty {
                let descriptions = depPrefUpdates.values.map { $0.debugInfo() }
                fail("""
                    Preference not exhausted: …

                    Modifications not asserted:

                    \(descriptions.map { $0.indent(by: 4) }.joined(separator: "\n\n"))
                    """, for: .preference, at: fileAndLine)
            }
        }

        // Reset the baseline so the next assert call starts from the current live state.
        lock {
            self.expectedState = self.lastState
            self.valueUpdates.removeAll()
            self.dependencyMetadataUpdates.removeAll()
            self.dependencyPreferenceUpdates.removeAll()
        }

    }

    func install(_ probe: TestProbe) {
        // Set the activity notifier BEFORE adding the probe to the
        // tracking array. Order matters: a `probe.call()` racing with
        // install must either see `notifier == nil` (in which case the
        // probe isn't yet known to this TestAccess and the test isn't
        // yet waiting on it) or a fully-wired notifier. The reverse
        // order would let a probe call slip through with the probe
        // installed but no wake-up — exactly the race that lost activity
        // signals to parked `expect` calls.
        probe._setActivityNotifier { [weak self] in
            self?._noteActivity()
        }
        lock {
            if probes.contains(where: { $0 === probe }) { return }
            probes.append(probe)
        }
    }

    /// Returns `true` when `path` is declared `private`/`fileprivate` in model type `M`.
    ///
    /// Results are cached per model type: the first call for a given `M` traverses one
    /// model instance to discover its private key paths (visibility is type-level, so
    /// any instance gives the same result). Subsequent calls hit the cache directly.
    ///
    /// Must be called OUTSIDE `self.lock` because it acquires `self.lock` internally.
    func isPrivatePath<M: Model, Value>(_ path: WritableKeyPath<M, Value>, in model: M) -> Bool {
        let typeKey = ObjectIdentifier(M.self)
        return lock {
            if let cached = privatePathsByType[typeKey] {
                return cached.contains(path)
            }
            // Build the set of private paths for M by traversing one instance.
            // `visit(with:includeSelf:false)` calls the macro-generated `visit(with:)`
            // body which emits `visitStatically(at: ..., visibility: .private)` for
            // each private property. Our collector intercepts those calls.
            var collector = LocalPrivatePathsCollector<M>()
            model.visit(with: &collector, includeSelf: false)
            let paths = collector.privatePaths
            privatePathsByType[typeKey] = paths
            return paths.contains(path)
        }
    }

    final class TesterAssertContext: TesterAssertContextBase, @unchecked Sendable {
        let events: () -> [Event]
        let fileAndLine: FileAndLine
        var predicate: AssertBuilder.Predicate?

        struct Access {
            var path: PartialKeyPath<Root>
            var modelName: String
            var propertyName: String?
            // Lazy: evaluated only when building error messages (outside the model lock).
            // Eagerly calling String(customDumping:) while holding NSRecursiveLock can hang
            // due to Swift runtime conformance-cache contention.
            var value: () -> String
            // The raw captured value from predicate evaluation time (type-erased).
            // Used by isEqualIncludingIds to compare against lastState without round-tripping
            // through `expected` (which may have stale/nil containers that crash on write).
            var capturedValue: () -> Any

            var apply: (inout Root) -> Void
            // Called during assertion clearing for accesses that need side-effect cleanup
            // beyond the standard valueUpdates path-based removal (e.g. dependency context storage).
            var additionalCleanup: (() -> Void)?
            // True for context/preference storage accesses: their values live in AnyContext.contextStorage,
            // not in the @Model struct fields. Writing them back to a frozen copy (which has no live context)
            // is a silent no-op, so they cannot participate in the isEqualIncludingIds round-trip check.
            // The predicate itself already verified the value is correct on the live model.
            var skipEqualityCheck: Bool
            // True when the Value type is itself a Model (e.g. TestHelper.summary: SummaryFeature).
            // Container-model accesses include a generation counter that increments on every child write,
            // so comparing the full struct value causes a false "not settled" result in isEqualIncludingIds
            // whenever a child property changes. Child-property accesses (e.g. SummaryFeature.destination)
            // are always recorded alongside the parent and check the actual leaf values with IDs — that is
            // sufficient to detect genuine in-flight backgroundCall batches.
            var isModelTypeValue: Bool
            // True when the Value type conforms to ModelContainer (Optional<M>, @ModelContainer enum cases).
            // These properties are accessed via ContainerCursor key paths — dynamic paths whose getter does
            // `get($0)!` (force-unwrap). ContainerCursor paths are only safe to read on the live model
            // hierarchy; reading them on a frozenCopy snapshot crashes because frozenCopy transforms
            // model identity and the cursor's identity key no longer matches.
            // Child-level accesses (e.g. SummaryFeature.destination.personalInfo leaf values) are always
            // recorded alongside and are sufficient to detect in-flight backgroundCall batches.
            var isContainerTypeValue: Bool

            init(path: PartialKeyPath<Root>, modelName: String, propertyName: String?, value: @escaping () -> String, capturedValue: @escaping () -> Any, apply: @escaping (inout Root) -> Void, additionalCleanup: (() -> Void)? = nil, skipEqualityCheck: Bool = false, isModelTypeValue: Bool = false, isContainerTypeValue: Bool = false) {
                self.path = path
                self.modelName = modelName
                self.propertyName = propertyName
                self.value = value
                self.capturedValue = capturedValue
                self.apply = apply
                self.additionalCleanup = additionalCleanup
                self.skipEqualityCheck = skipEqualityCheck
                self.isModelTypeValue = isModelTypeValue
                self.isContainerTypeValue = isContainerTypeValue
            }
        }

        var accesses: [Access] = []
        var eventsSent: IndexSet = []
        var eventsNotSent: [Event] = []
        var modelsNoLongerPartOfTester: [String] = []
        var probes: [(probe: TestProbe, value: Any)] = []

        init(events: @escaping () -> [Event], fileAndLine: FileAndLine) {
            self.events = events
            self.fileAndLine = fileAndLine
        }

        var predicateFileAndLine: FileAndLine { predicate?.fileAndLine ?? fileAndLine }

        struct Failure {
            var predicate: AssertBuilder.Predicate
            var accesses: [Access] = []
            var events: [Event] = []
            var modelsNoLongerPartOfTester: [String] = []
            var probes: [(TestProbe, Any)]
        }

        override func didSend<M: Model, E>(event: E, from context: Context<M>) -> Bool {
            let events = self.events()
            let index = events.indices.firstIndex { i in
                !eventsSent.contains(i) &&
                events[i].context === context &&
                (isEqual(events[i].event, event) ?? threadLocals.withValue(true, at: \.includeChildrenInMirror) { diff(events[i].event, event) == nil })
            }

            guard let index else {
                eventsNotSent.append(Event(event: event, context: context))
                return false
            }

            eventsSent.insert(index)
            return true
        }

        override func probe(_ probe: TestProbe, wasCalledWith value: Any) -> Void {
            probes.append((probe, value))
        }
    }

    var assertContext: TesterAssertContext? {
        TesterAssertContextBase.assertContext as? TesterAssertContext
    }
}

// MARK: - LocalPrivatePathsCollector

/// A `ModelVisitor` that collects the LOCAL (non-root-relative) key paths of all
/// `private`/`fileprivate` properties declared on a single `@Model` type.
///
/// Plain-value private properties are recorded in `privatePaths`; model-typed and
/// container-typed properties are skipped (their child hierarchies are still tracked).
private struct LocalPrivatePathsCollector<State: Model>: ModelVisitor {
    var privatePaths: Set<AnyKeyPath> = []

    mutating func visit<T>(path: WritableKeyPath<State, T>, visibility: PropertyVisibility) {
        if visibility == .private {
            privatePaths.insert(path)
        }
    }

    // Model- and container-typed properties are traversed normally (not treated as private
    // even if the parent property itself is private). No-op to skip recursion here.
    mutating func visit<T: Model>(path: WritableKeyPath<State, T>) { }
    mutating func visit<T: ModelContainer>(path: WritableKeyPath<State, T>) { }
}

package struct UnwrapError: Error { package init() {} }

class TesterAssertContextBase: @unchecked Sendable {
    func didSend<M: Model, Event>(event: Event, from context: Context<M>) -> Bool { fatalError() }
    func probe(_ probe: TestProbe, wasCalledWith value: Any) -> Void { fatalError() }

    @TaskLocal static var assertContext: TesterAssertContextBase?
}
