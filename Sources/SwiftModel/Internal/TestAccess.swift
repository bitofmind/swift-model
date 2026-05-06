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
// expect { predicate } is a polling loop that:
//
//   1. Evaluates each predicate closure. Reading any @Model property during evaluation
//      fires willAccess<M,V>, which (if a TesterAssertContext is active) appends an
//      Access entry recording the full root-relative keypath, the current value, and
//      an `apply` closure that writes that value back into a Root snapshot.
//
//   2. If ALL predicates pass, compares the read values (passedAccesses) against the
//      current lastState snapshot to verify the model has actually settled at those
//      values — not just transiently true. If IDs don't match (a backgroundCall batch
//      is still in flight), it waits and retries rather than accepting a stale read.
//
//   3. On settlement, clears each asserted path from valueUpdates (marking it as
//      handled), applies the access values into expectedState (advancing the baseline),
//      and runs the exhaustion check.
//
//   4. The exhaustion check diffs expectedState against lastState. Any remaining
//      unasserted entries in valueUpdates, any unsent events, or any un-consumed probe
//      values are reported as failures.
//
//   5. If any predicate fails and the timeout has elapsed, reports failures by
//      diffing the predicate's LHS/RHS and listing un-asserted accesses.
//
//   6. Between iterations, waitForModification suspends until the next modification
//      event fires or the timeout expires.
//
// State lifecycle:
//   - lastState    : always up to date — updated by didModify whenever any property changes.
//   - expectedState: advances one assert at a time — updated only when an assert passes.
//   - valueUpdates : pending un-asserted changes — entries are removed when asserted.
//
// Why context storage (node.local.x / node.environment.x) can't currently participate as a regular access:
//
//   willAccess<M,V> and didModify<M,V> both guard on a WritableKeyPath<M,Value> so the
//   value can be stored/applied into the typed Root snapshots (lastState/expectedState).
//   The synthetic keypath \M[environmentKey: key] used by the context storage observation system
//   is a read-only KeyPath returning AnyHashableSendable — it can never be cast to
//   WritableKeyPath, and even if it could, there is no typed Value to write back into Root.
//   Context values live in AnyContext.contextStorage (a type-erased dictionary), not in
//   the @Model struct. A parallel tracking system (contextUpdates / expectedContext /
//   lastContext) with hooks called from willAccessEnvironmentKey/didModifyEnvironmentKey
//   would be the correct fix — see the planned implementation in the tester gap investigation.

// Task-local overrides for output snapshot tests. These allow tests to trigger specific
// timeout paths quickly without waiting the normal 5-second minimum.
enum TestAccessOverrides {
    @TaskLocal static var hardCapNanoseconds: UInt64? = nil
}

/// Calibration data computed once per wait operation by measuring scheduler latency.
/// Shared by `expect`, `require`, `settle`, and end-of-test `checkExhaustion`.
package struct WaitCalibration: Sendable {
    let yieldLatencyNs: UInt64
    let yieldRoundNs: UInt64
    let scaledTimeout: UInt64
    let hardCap: UInt64
    let start: UInt64
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

final class TestAccess<Root: Model>: ModelAccess, TaskLifecycleDelegate, @unchecked Sendable {
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

    // Activation task counter (Phase 3): tracks tasks created inside onActivate() that
    // have not yet begun executing their body. Reaches 0 when all such tasks have entered.
    var _activationTasksInFlight: Int = 0

    // General task counter (Phase 5): tracks all currently-running tasks in the hierarchy.
    var _activeTaskCount: Int = 0


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

        // Register as lifecycle delegate before activation so tasks created in
        // onActivate() are counted from the first task creation.
        context.taskLifecycleDelegate = self
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
        let activatedSnapshot = threadLocals.withValue(true, at: \.isApplyingSnapshot) {
            model.frozenCopy
        }
        lastState = activatedSnapshot
        expectedState = activatedSnapshot
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
                for fullPath in fullPaths {
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
                            threadLocals.withValue(true, at: \.isApplyingSnapshot) {
                                self.lastState[keyPath: fullPath] = value
                            }
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
                        threadLocals.withValue(true, at: \.isApplyingSnapshot) {
                            self.lastState[keyPath: fullPath] = value
                        }
                    }
                }
            }
        }
    }

    override func didSend<M: Model, Event>(event: Event, from context: Context<M>) {
        lock {
            events.append(.init(event: event, context: context))
        }
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

    // Last scheduler-latency measurement (nanoseconds). Updated by calibrate().
    // Shared safely: calibrate() is only called from the test task (never from model
    // tasks), so writes are sequential within one TestAccess instance.
    // Default: 1ms — a reasonable assumption before the first measurement.
    var _lastYieldLatencyNs: UInt64 = 1_000_000

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
