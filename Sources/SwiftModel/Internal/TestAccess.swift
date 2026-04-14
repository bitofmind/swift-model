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
    private var _activationTasksInFlight: Int = 0

    // General task counter (Phase 5): tracks all currently-running tasks in the hierarchy.
    private var _activeTaskCount: Int = 0


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

    init(model: Root, dependencies: (inout ModelDependencies) -> Void, fileAndLine: FileAndLine) {
        expectedState = model.frozenCopy
        lastState = model.frozenCopy
        self.fileAndLine = fileAndLine
        context = Context(model: model, lock: NSRecursiveLock(), dependencies: dependencies, parent: nil)

        super.init(useWeakReference: true)

        context.readModel.modelContext.access = self
        context.modifyModel.modelContext.access = self
        // Register as lifecycle delegate before activation so tasks created in
        // onActivate() are counted from the first task creation.
        context.taskLifecycleDelegate = self
        usingAccess(self) {
            context.model.activate()
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
        // Re-initializing from context.readModel.frozenCopy gives both snapshots the same
        // ModelIDs that live cursors will use, so cursor lookups find and update elements
        // correctly.
        let activatedSnapshot = threadLocals.withValue(true, at: \.isApplyingSnapshot) {
            context.readModel.frozenCopy
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
    override func willAccess<M: Model, Value>(_ model: M, at path: KeyPath<M, Value>&Sendable) -> (() -> Void)? {
        guard let path = path as? WritableKeyPath<M, Value> else { return nil }

        // Capture the modification area and storage name at the point of access (thread-locals
        // are set here but may be cleared by the time the returned closure is invoked).
        let capturedArea = threadLocals.modificationArea
        // For context/preference storage paths, storageName carries the property name
        // (e.g. "isDarkMode") captured via #function in the LocalKeys/EnvironmentKeys/PreferenceKeys declaration.
        // propertyName(from:path:) returns nil for synthetic subscript paths, so we prefer this.
        let capturedStorageName = threadLocals.storageName

        // rootPaths resolves the chain of WritableKeyPaths from Root down to this model.
        // It is nil only if the model has been detached from the hierarchy.
        let rootPaths = model.context?.rootPaths.compactMap { $0 as? WritableKeyPath<Root, M> }
        guard let rootPaths else {
            if let assertContext {
                assertContext.modelsNoLongerPartOfTester.append(model.typeDescription)
            } else {
                fail("Model \(model.typeDescription) is no longer part of this tester", at: fileAndLine)
            }
            return nil
        }

        guard let assertContext else { return nil }

        let fullPaths = rootPaths.map { $0.appending(path: path) }

        // Build the display name for failure messages: "context.isDarkMode" / "preference.totalCount"
        // or plain "propertyName" for regular @Model state properties.
        let resolvedStorageName: String?
        if let sn = capturedStorageName {
            let pfx = capturedArea == .preference ? "preference" : capturedArea == .local ? "local" : capturedArea == .environment ? "environment" : nil
            resolvedStorageName = pfx.map { "\($0).\(sn)" } ?? sn
        } else {
            resolvedStorageName = nil  // falls back to propertyName(from:path:) below
        }

        // Dependency model context/preference storage: no root-relative path exists (the model
        // lives in dependencyContexts, not children). Return a dummy Access whose additionalCleanup
        // clears the corresponding dependency updates entry when asserted.
        if fullPaths.isEmpty, (capturedArea == .local || capturedArea == .environment || capturedArea == .preference), let modelContext = model.context {
            let key = DependencyMetadataKey(contextID: ObjectIdentifier(modelContext), path: path)
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
                let capturedValue = frozenCopy(modelContext[path])
                assertContext.accesses.append(.init(
                    path: \Root.self,
                    modelName: model.typeDescription,
                    propertyName: resolvedStorageName ?? propertyName(from: model, path: path),
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
            // invoking this closure so we don't re-read via model.context![path] — which
            // re-enters preferenceValue under a lock and causes lock-ordering deadlocks.
            if isPreference, let precomputed = threadLocals.precomputedPreferenceValue, let typed = precomputed as? Value {
                value = frozenCopy(typed)
            } else if overrideConsumed != nil, let typed = overrideConsumed as? Value {
                // Transitions mode: use the same override value that was yielded to the predicate.
                // Guard with != nil first to avoid the Swift gotcha where `nil as? T`
                // succeeds when T is an Optional type (producing .some(nil)).
                value = typed
            } else {
                value = frozenCopy(model.context![path])
            }
            for fullPath in fullPaths {
                assertContext.accesses.append(.init(
                    path: fullPath,
                    modelName: model.typeDescription,
                    propertyName: resolvedStorageName ?? propertyName(from: model, path: path),
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
    override func didModify<M: Model, Value>(_ model: M, at path: KeyPath<M, Value>&Sendable) -> (() -> Void)? {
        guard let path = path as? WritableKeyPath<M, Value> else { return nil }

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

        return { [weak self] in
            guard let self else { return }

            // rootPaths is computed here, OUTSIDE the model lock, to avoid the deadlock
            // described above. The model hierarchy is stable at this point (no lock needed
            // to safely read the parent-child structure for an active model).
            let rootPaths = model.context?.rootPaths.compactMap { $0 as? WritableKeyPath<Root, M> }
            guard let rootPaths else {
                fatalError()
            }

            let fullPaths = rootPaths.map { $0.appending(path: path) }

            // Dependency model context/preference storage: no root-relative path exists. Track the
            // update separately so checkExhaustion can report it if not asserted.
            if fullPaths.isEmpty, (area == .local || area == .environment || area == .preference), let modelContext = model.context {
                let key = DependencyMetadataKey(contextID: ObjectIdentifier(modelContext), path: path)
                let name = storageName ?? propertyName(from: model, path: path)
                let prefix = area == .preference ? "preference" : area == .environment ? "environment" : "local"
                let value = frozenCopy(modelContext[path])
                self.lock {
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
            let isPrivate = self.isPrivatePath(path, in: model)

            let name = storageName ?? propertyName(from: model, path: path)
            let prefix: String? = area == .preference ? "preference" : area == .local ? "local" : area == .environment ? "environment" : nil
            let value = frozenCopy(model.context![path])
            self.lock {
                for fullPath in fullPaths {
                    // Private properties are not tracked for exhaustivity: tests cannot observe
                    // them from outside the declaring type, so requiring assertions would produce
                    // false failures. We still update lastState so the settlement check
                    // (isEqualIncludingIds) works correctly when a test reads a private
                    // property via @testable import.
                    if isPrivate {
                        self.lastState[keyPath: fullPath] = value
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

                    let entry = ValueUpdate(
                        apply: { $0[keyPath: fullPath] = value },
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

                    self.lastState[keyPath: fullPath] = value
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

    func expect(settleResetting: _ExhaustivityBits? = nil, at fileAndLine: FileAndLine, predicates: [AssertBuilder.Predicate], enableExhaustionTest: Bool = true) async {
        await expect(timeoutNanoseconds: 1_000_000_000, settleResetting: settleResetting, at: fileAndLine, predicates: predicates, enableExhaustionTest: enableExhaustionTest)
    }

    func expect(timeoutNanoseconds timeout: UInt64, settleResetting: _ExhaustivityBits? = nil, at fileAndLine: FileAndLine, predicates: [AssertBuilder.Predicate], enableExhaustionTest: Bool = true) async {
        let cal = await calibrate(timeout: timeout)
        let scaledTimeout = cal.scaledTimeout
        let yieldRoundNs = cal.yieldRoundNs
        let hardCap = cal.hardCap
        let context = TesterAssertContext(events: { self.lock { self.events } }, fileAndLine: fileAndLine)

        await TesterAssertContextBase.$assertContext.withValue(context) {

            let start = cal.start
            var lastProgressTime = start  // reset whenever a state modification arrives
            var retryCount = 0
            var failures: [TesterAssertContext.Failure] = []
            var passedAccesses: [TesterAssertContext.Access] = []
            while true {
                // Defensive: clear any stale transition override that might linger on this
                // pthread thread from a previous iteration. The willAccess callback normally
                // clears it, but skipped-callback paths (e.g. destructed model branch in
                // Context._read) can leave it set. Clearing here ensures each predicate
                // evaluation starts from a known-clean state.
                threadLocals.transitionOverrideValue = nil

                failures = []
                passedAccesses = []

                context.eventsSent.removeAll()
                context.probes.removeAll()

                // Step 1: Evaluate all predicates. Reading properties inside a predicate
                // fires willAccess → appends Access entries to context.accesses.
                for predicate in predicates {
                    context.predicate = predicate
                    
                    context.accesses.removeAll(keepingCapacity: true)
                    context.eventsNotSent.removeAll(keepingCapacity: true)
                    context.modelsNoLongerPartOfTester.removeAll(keepingCapacity: true)

                    let passed = predicate.predicate()
                    let accesses = context.accesses
                    if passed {
                        passedAccesses += accesses
                    } else {
                        failures.append(.init(
                            predicate: predicate,
                            accesses: accesses,
                            events: context.eventsNotSent,
                            modelsNoLongerPartOfTester: context.modelsNoLongerPartOfTester,
                            probes: context.probes
                        ))

                        break
                    }
                }

                if failures.isEmpty {
                    // Step 2: All predicates passed. Verify that the predicate's read values
                    // match lastState (the live model). This guards against the predicate
                    // passing transiently while a backgroundCall batch is still committing
                    // changes (IDs would diverge because frozenCopy includes generation IDs).
                    //
                    // In transitions mode, accesses that read from the FIFO queue (historical
                    // values) are skipped here — they don't correspond to live model values
                    // and comparing them against lastState would always fail.
                    //
                    // frozenCopy walks Optional<M> children which calls _swift_getKeyPath to
                    // create dynamic ContainerCursor key paths. _swift_getKeyPath needs the Swift
                    // runtime lock — calling it while holding NSRecursiveLock deadlocks when the
                    // runtime lock is contended. Compute frozenCopy outside the lock; expectedState
                    // and lastState are value-type copies so this is safe.
                    // isApplyingSnapshot suppresses willAccessPreference/willAccessStorage callbacks
                    // and re-entrant observation triggered by releasing live child models during
                    // the transform.
                    // Read lastState under the lock (brief), then compute frozenCopy and
                    // evaluate key paths OUTSIDE the lock. Evaluating container cursor key
                    // paths (e.g. items[0].value) can call _swift_getKeyPath which acquires
                    // the Swift runtime lock. Holding TestAccess lock while needing the
                    // runtime lock deadlocks when another thread holds the runtime lock and
                    // needs TestAccess lock (lock-ordering inversion). Since `last` is a
                    // local frozen copy and `passedAccesses` is a local array, no lock is
                    // needed for the comparison itself.
                    let isEqualIncludingIds = threadLocals.withValue(true, at: \.isApplyingSnapshot) {
                        let last = lock { lastState }.frozenCopy
                        return threadLocals.withValue(true, at: \.includeImplicitIDInMirror) {
                            return passedAccesses.reduce(true) { result, access in
                                // Context/preference storage values live in AnyContext.contextStorage,
                                // not in the @Model struct fields. Writing them back to a frozen copy
                                // (which has no live context) is a silent no-op, so the round-trip
                                // read would return defaultValue instead of the asserted value —
                                // making isEqualIncludingIds always false and causing a hang.
                                // The predicate already verified these values on the live model,
                                // so we skip the frozen-copy equality check for them.
                                if access.skipEqualityCheck { return result }
                                // Skip container-level model accesses. When a model property (e.g.
                                // TestHelper.summary of type SummaryFeature) is accessed, its full
                                // struct value is captured including the generation counter. But the
                                // generation counter advances on every child write, so comparing the
                                // whole struct causes a false "not settled yet" when the child property
                                // we actually asserted has already settled. Child-level accesses
                                // (e.g. SummaryFeature.destination) are always recorded alongside the
                                // parent, and they check the actual leaf value with IDs — sufficient
                                // to detect genuine backgroundCall in-flight conditions.
                                if access.isModelTypeValue { return result }
                                // Skip ModelContainer-typed values (Optional<M>, @ModelContainer enums).
                                // These use ContainerCursor key paths whose getter does `get($0)!`.
                                // ContainerCursor paths are safe to traverse only on the live model
                                // hierarchy — reading them on a frozenCopy snapshot crashes because
                                // frozenCopy transforms model identity and the cursor no longer matches.
                                // Leaf accesses recorded within the container are checked independently.
                                if access.isContainerTypeValue { return result }
                                // Transitions mode: skip settlement check for accesses that read
                                // from the FIFO queue. Their captured value is historical (the
                                // front-of-queue value) and will not match lastState (the live value).
                                if self.exhaustivity.contains(.transitions) && self.valueUpdates[access.path] != nil { return result }
                                // Compare the predicate-time captured value against lastState directly.
                                // Using only `last` (which reflects the current live state) and comparing
                                // against the captured value is safe and sufficient: if the IDs match,
                                // the model has settled.
                                let a = last[keyPath: access.path]
                                return result && (diff(access.capturedValue(), a) == nil)
                            }
                        }
                    }

                    // Predicate passed but IDs don't match yet: there is a pending
                    // backgroundCall batch in flight. Wait for items currently queued to
                    // drain (FIFO sentinel), then retry. We use waitForCurrentItems rather
                    // than waitUntilIdle so we don't block on other tests' work under 100x load.
                    // If the timeout has elapsed even here, fall through to the failure path so
                    // the assert doesn't spin forever when isEqualIncludingIds is permanently false.
                    if !isEqualIncludingIds {
                        if start.distance(to: monotonicNanoseconds()) > hardCap {
                            // Hard cap hit: the model has been continuously producing changes
                            // and IDs never converged. Report as failure.
                            fail("State did not settle: model IDs kept diverging after the predicate passed. This may indicate a backgroundCallQueue loop or an unresolvable ID mismatch.", at: fileAndLine)
                            return
                        }
                        await backgroundCall.waitForCurrentItems(deadline: start + hardCap)
                        await yieldToScheduler()
                        // Count as progress — backgroundCall draining counts as activity.
                        lastProgressTime = monotonicNanoseconds()
                        continue
                    }

                    if isEqualIncludingIds {
                        // Settling mode: after the predicate passes and IDs converge,
                        // wait for all activation tasks to enter their body, then run
                        // one idle cycle to catch trailing mutations (e.g. forEach first
                        // fires). Finally, reset selected exhaustivity categories so
                        // subsequent expect {} calls only see changes made after settling.
                        if let resetting = settleResetting {
                            let settled = await waitUntilSettled(calibration: cal, at: fileAndLine)
                            if !settled { return }

                            // Reset selected exhaustivity categories.
                            lock {
                                if resetting.contains(.state) {
                                    expectedState = lastState
                                    valueUpdates.removeAll()
                                }
                                if resetting.contains(.local) {
                                    dependencyMetadataUpdates.removeAll()
                                }
                                if resetting.contains(.environment) || resetting.contains(.preference) {
                                    dependencyPreferenceUpdates.removeAll()
                                }
                                if resetting.contains(.events) {
                                    events.removeAll()
                                }
                                if resetting.contains(.probes) {
                                    for probe in probes {
                                        probe.resetValues()
                                    }
                                }
                            }
                            return
                        }

                        // Step 3: Model has settled. Mark all asserted paths as handled,
                        // advance expectedState, and run the exhaustion check.
                        //
                        // Capture valueUpdates inside the same lock that clears it.
                        // checkExhaustion would otherwise re-read valueUpdates under a
                        // separate lock acquisition, creating a race window where a concurrent
                        // thread running an activeAccessCallback can write a new entry between
                        // the clearing block's unlock and checkExhaustion's lock — producing
                        // a spurious "State not exhausted" failure.
                        var capturedValueUpdates: [PartialKeyPath<Root>: [ValueUpdate]]? = nil
                        lock {
                            // Sync expectedState to lastState for structural consistency.
                            // Individual consumed.apply(&expectedState) is unsafe because deep
                            // paths through container types (Optional<Child>, array elements)
                            // use cursor keypaths whose setters force-unwrap — expectedState may
                            // have a nil/stale container. Assigning lastState directly keeps all
                            // container structures and IDs in sync. Remaining FIFO entries in
                            // valueUpdates are caught by Layer 3 of the exhaustion check.
                            expectedState = lastState

                            let isTransitions = exhaustivity.contains(.transitions)
                            for access in passedAccesses {
                                if valueUpdates[access.path] != nil {
                                    if isTransitions {
                                        // Transitions mode: pop only the front (oldest unasserted) entry.
                                        // Subsequent writes remain for the next assertion to consume.
                                        valueUpdates[access.path]!.removeFirst()
                                        if valueUpdates[access.path]!.isEmpty {
                                            valueUpdates[access.path] = nil
                                        }
                                    } else {
                                        // Non-transitions mode (last-write-wins): clear all entries.
                                        // The assertion consumed the final value; intermediate writes
                                        // do not need to be individually asserted.
                                        valueUpdates[access.path] = nil
                                    }
                                }
                                // For dependency context storage, run the additional cleanup (clears
                                // dependencyMetadataUpdates for this storage key+context).
                                access.additionalCleanup?()
                            }

                            for index in context.eventsSent.reversed() { events.remove(at: index) }

                            for (probe, value) in context.probes {
                                probe.consume(value)
                            }

                            // Capture valueUpdates after clearing so checkExhaustion uses
                            // this consistent snapshot rather than re-reading under a new lock.
                            capturedValueUpdates = valueUpdates
                        }

                        if enableExhaustionTest && !exhaustivity.contains(.transitions) {
                            // Step 4: Check that no other state changed without being
                            // asserted. Diffs expectedState against lastState.
                            // IMPORTANT: Must be called outside the lock. checkExhaustion calls
                            // diffMessage/customDump which triggers customMirror on @Model types,
                            // which reads @ModelTracked properties, which calls willAccess, which
                            // acquires context.rootPaths — also guarded by the same lock. If we
                            // are suspended via an async withValue and resume on a different thread,
                            // the NSRecursiveLock is not re-entrant across threads and deadlocks.
                            checkExhaustion(at: fileAndLine, includeUpdates: true, capturedUpdates: capturedValueUpdates)
                        }

                        return
                    }
                }

                // Step 5 (timeout): Report failures.
                // IMPORTANT: All reporting (diffMessage, customDump, fail) happens outside the lock.
                // diffMessage/customDump triggers customMirror on @Model types, which reads
                // @ModelTracked properties, which calls willAccess → rootPaths → tries to acquire
                // this same lock from the continuation's thread — deadlock if already held.
                //
                // Activity-relative timeout: fail only when the model has made no progress for
                // `scaledTimeout` (no state changes), or when the absolute hard cap fires.
                let now = monotonicNanoseconds()
                if lastProgressTime.distance(to: now) > scaledTimeout || start.distance(to: now) > hardCap {
                    // Build all failure messages outside the lock so that diffMessage/customDump
                    // cannot re-enter it via willAccess → rootPaths.
                    var reports: [[(String, FileAndLine)]] = []
                    for failure in failures {
                        var messages: [(String, FileAndLine)] = []
                        if let (lhs, rhs) = failure.predicate.values() {
                            let propertyNames = failure.accesses.compactMap { access in
                                access.propertyName.map { "\(access.modelName).\($0)" }
                            }.joined(separator: ", ")

                            let title = "Expectation not met: \(propertyNames)"
                            let message = threadLocals.withValue(true, at: \.includeChildrenInMirror) {
                                diffMessage(expected: rhs, actual: lhs, title: title)
                            }
                            messages.append((message ?? title, failure.predicate.fileAndLine))
                        } else {
                            for access in failure.accesses {
                                let pred = access.propertyName.map {
                                    "\(access.modelName).\($0) == \(access.value())"
                                } ?? access.value()
                                messages.append(("Expectation not met: \(pred)", failure.predicate.fileAndLine))
                            }
                        }

                        for event in failure.events {
                            messages.append(("Expected event not sent: \(String(customDumping: event.event)) from \(event.context.typeDescription)", failure.predicate.fileAndLine))
                        }

                        for modelName in failure.modelsNoLongerPartOfTester {
                            messages.append(("Model \(modelName) is no longer part of this tester", fileAndLine))
                        }

                        for (probe, value) in failure.probes {
                            let preTitle = "Expected probe not called" + (probe.name.map { " \"\($0)\":" } ?? ":")
                            let title = value is NoArgs ? preTitle :
                                """
                                \(preTitle)
                                    \(String(customDumping: value))
                                """

                            if probe.isEmpty {
                                messages.append((
                                    """
                                    \(title)

                                    No available probe values
                                    """, fileAndLine))
                            } else if probe.count == 1, let message = threadLocals.withValue(true, at: \.includeChildrenInMirror, perform: { diffMessage(expected: value, actual: probe.values[0], title: "Probe does not match") }) {
                                messages.append((message, fileAndLine))
                            } else {
                                messages.append((
                                    """
                                    \(title)

                                    \(probe.count) Available probe values to assert:
                                        \(probe.values.map { String(customDumping: $0) }.joined(separator: "\n    "))
                                    """, fileAndLine))
                            }
                        }

                        if failure.accesses.isEmpty, failure.events.isEmpty, failure.modelsNoLongerPartOfTester.isEmpty, failure.probes.isEmpty {
                            messages.append(("Assertion failed", failure.predicate.fileAndLine))
                        }
                        reports.append(messages)
                    }

                    // Now apply state mutations under the lock (no diffMessage/customDump here).
                    lock {
                        // Sync expectedState for structural consistency (see Step 3 comment).
                        expectedState = lastState

                        for access in passedAccesses {
                            // Pop front entry from FIFO queue if present.
                            if valueUpdates[access.path] != nil {
                                valueUpdates[access.path]!.removeFirst()
                                if valueUpdates[access.path]!.isEmpty {
                                    valueUpdates[access.path] = nil
                                }
                            }
                            access.additionalCleanup?()
                        }

                        for index in context.eventsSent.reversed() { events.remove(at: index) }

                        for (probe, value) in context.probes {
                            probe.consume(value)
                        }
                    }

                    // Emit failure reports outside the lock.
                    for messages in reports {
                        for (message, location) in messages {
                            fail(message, at: location)
                        }
                    }


                    if enableExhaustionTest {
                        checkExhaustion(at: fileAndLine, includeUpdates: false)
                    }
                    return
                }

                // Step 6: Wait for the next modification event before re-checking.
                // Pass the remaining no-progress budget as the wait timeout (how long to sleep
                // if no modification arrives). The hard cap is checked at Step 5 next iteration.
                let elapsed = lastProgressTime.distance(to: monotonicNanoseconds())
                let remaining = elapsed < scaledTimeout ? scaledTimeout - UInt64(elapsed) : 0
                retryCount += 1

                let didProgress = await waitForModification(timeoutNanoseconds: remaining, yieldRoundNs: yieldRoundNs, retryCount: retryCount)
                if didProgress { lastProgressTime = monotonicNanoseconds() }
            }

            // Step 5 (timeout): Report failures.
            // IMPORTANT: All reporting (diffMessage, customDump, fail) happens outside the lock.
            // diffMessage/customDump triggers customMirror on @Model types, which reads
            // @ModelTracked properties, which calls willAccess → rootPaths → tries to acquire
            // this same lock from the continuation's thread — deadlock if already held.
            // Build all failure messages outside the lock so that diffMessage/customDump
            // cannot re-enter it via willAccess → rootPaths.
            var reports: [[(String, FileAndLine)]] = []
            for failure in failures {
                var messages: [(String, FileAndLine)] = []
                if let (lhs, rhs) = failure.predicate.values() {
                    let propertyNames = failure.accesses.compactMap { access in
                        access.propertyName.map { "\(access.modelName).\($0)" }
                    }.joined(separator: ", ")

                    let title = "Expectation not met: \(propertyNames)"
                    let message = threadLocals.withValue(true, at: \.includeChildrenInMirror) {
                        diffMessage(expected: rhs, actual: lhs, title: title)
                    }
                    messages.append((message ?? title, failure.predicate.fileAndLine))
                } else {
                    for access in failure.accesses {
                        let pred = access.propertyName.map {
                            "\(access.modelName).\($0) == \(access.value())"
                        } ?? access.value()
                        messages.append(("Expectation not met: \(pred)", failure.predicate.fileAndLine))
                    }
                }

                for event in failure.events {
                    messages.append(("Expected event not sent: \(String(customDumping: event.event)) from \(event.context.typeDescription)", failure.predicate.fileAndLine))
                }

                for modelName in failure.modelsNoLongerPartOfTester {
                    messages.append(("Model \(modelName) is no longer part of this tester", fileAndLine))
                }

                for (probe, value) in failure.probes {
                    let preTitle = "Expected probe not called" + (probe.name.map { "\"\($0)\":" } ?? ":")
                    let title = value is NoArgs ? preTitle :
                        """
                        \(preTitle)
                            \(String(customDumping: value))
                        """

                    if probe.isEmpty {
                        messages.append((
                            """
                            \(title)

                            No available probe values
                            """, fileAndLine))
                    } else if probe.count == 1, let message = threadLocals.withValue(true, at: \.includeChildrenInMirror, perform: { diffMessage(expected: value, actual: probe.values[0], title: "Probe does not match") }) {
                        messages.append((message, fileAndLine))
                    } else {
                        messages.append((
                            """
                            \(title)

                            \(probe.count) Available probe values to assert:
                                \(probe.values.map { String(customDumping: $0) }.joined(separator: "\n\t"))
                            """, fileAndLine))
                    }
                }

                if failure.accesses.isEmpty, failure.events.isEmpty, failure.modelsNoLongerPartOfTester.isEmpty, failure.probes.isEmpty {
                    messages.append(("Expectation not met", failure.predicate.fileAndLine))
                }
                reports.append(messages)
            }

            // Now apply state mutations under the lock (no diffMessage/customDump here).
            lock {
                // Sync expectedState for structural consistency (see Step 3 comment).
                expectedState = lastState

                for access in passedAccesses {
                    // Pop front entry from FIFO queue if present.
                    if valueUpdates[access.path] != nil {
                        valueUpdates[access.path]!.removeFirst()
                        if valueUpdates[access.path]!.isEmpty {
                            valueUpdates[access.path] = nil
                        }
                    }
                    access.additionalCleanup?()
                }

                for index in context.eventsSent.reversed() { events.remove(at: index) }

                for (probe, value) in context.probes {
                    probe.consume(value)
                }
            }

            // Emit failure reports outside the lock.
            for messages in reports {
                for (message, location) in messages {
                    fail(message, at: location)
                }
            }

            if enableExhaustionTest {
                checkExhaustion(at: fileAndLine, includeUpdates: false)
            }
        }
    }

    /// Polls `expression` until it returns a non-nil value, then returns the unwrapped result.
    /// Uses the same activity-relative idle detection as `expect`: the timeout resets on every
    /// model state change, so a healthy model never hits it. The hard cap is the absolute
    /// safety net (default 5 s, overridable via `TestAccessOverrides.hardCapNanoseconds`).
    func require<T>(_ expression: @escaping @Sendable () -> T?, at fileAndLine: FileAndLine) async throws -> T {
        let cal = await calibrate()
        let scaledTimeout = cal.scaledTimeout
        let yieldRoundNs = cal.yieldRoundNs
        let hardCap = cal.hardCap
        let start = cal.start
        var lastProgressTime = start
        var retryCount = 0

        while true {
            if let value = expression() {
                // Expression is non-nil. Drive the same settled-state stability check as expect.
                let predicate = AssertBuilder.Predicate(predicate: { expression() != nil }, fileAndLine: fileAndLine)
                await expect(timeoutNanoseconds: nanosPerSecond, at: fileAndLine, predicates: [predicate], enableExhaustionTest: false)
                return value
            }

            let now = monotonicNanoseconds()
            if lastProgressTime.distance(to: now) > scaledTimeout || start.distance(to: now) > hardCap {
                fail("Failed to unwrap value of type \(T.self)", at: fileAndLine)
                throw UnwrapError()
            }

            let elapsed = start.distance(to: now)
            let remaining = elapsed < hardCap ? hardCap - UInt64(elapsed) : 0
            let didProgress = await waitForModification(
                timeoutNanoseconds: min(remaining, yieldRoundNs),
                yieldRoundNs: yieldRoundNs,
                retryCount: retryCount
            )
            if didProgress { lastProgressTime = monotonicNanoseconds() }
            retryCount += 1
        }
    }

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
        while activationTasksInFlight > 0 {
            await waitForModification(timeoutNanoseconds: cal.scaledTimeout, yieldRoundNs: cal.yieldRoundNs, retryCount: 0)
            if cal.start.distance(to: monotonicNanoseconds()) > cal.hardCap {
                if reportTimeout {
                    let taskInfo = settleTimeoutDiagnostics()
                    fail("settle() timed out: model still has active tasks.\n\(taskInfo)", at: fileAndLine)
                }
                return false
            }
        }

        // Phase 2: Idle cycle — wait until one full scheduling round passes
        // with no state changes. Uses modificationCount on the root context as
        // a version number.
        var lastChangeVersion = context.modificationCount
        while true {
            await backgroundCall.waitForCurrentItems(deadline: cal.start + cal.hardCap)
            await yieldToScheduler()

            // Re-check activation tasks: backgroundCall drain or yieldToScheduler
            // may have triggered child model activations (e.g. SearchResultItem
            // activated when results is set), creating new tasks that haven't entered
            // their body yet. Wait for them before evaluating idle state.
            while activationTasksInFlight > 0 {
                await waitForModification(timeoutNanoseconds: cal.scaledTimeout, yieldRoundNs: cal.yieldRoundNs, retryCount: 0)
                if cal.start.distance(to: monotonicNanoseconds()) > cal.hardCap {
                    if reportTimeout {
                        let taskInfo = settleTimeoutDiagnostics()
                        fail("settle() timed out: model still has active tasks.\n\(taskInfo)", at: fileAndLine)
                    }
                    return false
                }
            }

            let currentVersion = context.modificationCount
            if currentVersion == lastChangeVersion {
                if lock({ _activeTaskCount }) == 0 {
                    break // no active tasks and no changes → settled
                }
                // Tasks are still running but no state changed yet. The task body
                // may be waiting for a cooperative pool turn (e.g. ImmediateClock
                // task entered but hasn't written detailLine yet).
                //
                // Yield to the cooperative pool repeatedly to give blocked tasks
                // scheduling opportunities, then drain the backgroundCall queue
                // (where model writes are batched). Under 100× parallel load the
                // pool is saturated so a single yield is insufficient — the loop
                // gives ~20 scheduling rounds. For observation loops (node.forEach
                // suspended in `for await`) this loop completes quickly since
                // Task.yield() is nearly free when no cooperative tasks are ready.
                var progressed = false
                for _ in 0..<20 {
                    await Task.yield()
                    await backgroundCall.waitForCurrentItems(deadline: cal.start + cal.hardCap)
                    if context.modificationCount != currentVersion || lock({ _activeTaskCount }) == 0 {
                        progressed = true
                        break
                    }
                }
                if !progressed {
                    // Still no modifications after cooperative yields + queue drains.
                    // The task body may be suspended across multiple `try await`
                    // points (nested withValue calls in TaskCancellable) waiting
                    // for cooperative pool turns on a different thread — yields on
                    // our thread don't help. Use onAnyModification callback (via
                    // waitForModification) which fires immediately when the write
                    // happens regardless of thread. The extended timeout (yieldRoundNs
                    // × 30: ~30ms normal, ~300ms under 100× saturation) is only
                    // consumed for observation loops; real modifications wake us early.
                    let patience = cal.yieldRoundNs * 30
                    await waitForModification(timeoutNanoseconds: patience, yieldRoundNs: patience, retryCount: 2)
                    if context.modificationCount == currentVersion {
                        break // No progress — remaining tasks are observation loops
                    }
                }
                lastChangeVersion = context.modificationCount
            } else {
                lastChangeVersion = currentVersion
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
