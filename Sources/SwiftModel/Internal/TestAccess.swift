import Foundation
import Dispatch
import CustomDump
import IssueReporting
import Dependencies

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

    var exhaustivity: Exhaustivity = .full
    var showSkippedAssertions = false

    // Pending unasserted state changes, keyed by root-relative keypath. Populated by
    // didModify; entries are cleared when the corresponding path is asserted. Any
    // remaining entries at exhaustion time are reported as failures.
    var valueUpdates: [PartialKeyPath<Root>: ValueUpdate] = [:]

    // Pending unasserted context storage writes on dependency models. Dependency models have no
    // root-relative WritableKeyPath (they live in dependencyContexts, not children), so
    // their context storage updates are tracked here rather than in valueUpdates.
    private var dependencyMetadataUpdates: [DependencyMetadataKey: ValueUpdate] = [:]

    // Same as dependencyMetadataUpdates but for preference storage writes on dependency models.
    private var dependencyPreferenceUpdates: [DependencyMetadataKey: ValueUpdate] = [:]

    var events: [Event] = []
    var probes: [TestProbe] = []
    let fileAndLine: FileAndLine

    // Activation task counter (Phase 3): tracks tasks created inside onActivate() that
    // have not yet begun executing their body. Reaches 0 when all such tasks have entered.
    private var _activationTasksInFlight: Int = 0

    // General task counter (Phase 5): tracks all currently-running tasks in the hierarchy.
    private var _activeTaskCount: Int = 0

    // Captures a pending state change: how to apply it to a Root snapshot, and how to
    // describe it for exhaustion-failure messages.
    struct ValueUpdate {
        var apply: (inout Root) -> Void
        var debugInfo: () -> String
        /// Which exhaustivity category this update belongs to. Defaults to `.state` for
        /// regular property writes; `.local` for `node.local` writes; `.environment` for `node.environment` writes.
        var area: Exhaustivity
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

        return {
            // For preference paths, use the pre-computed aggregated value if available.
            // willAccessPreferenceValue sets threadLocals.precomputedPreferenceValue before
            // invoking this closure so we don't re-read via model.context![path] — which
            // re-enters preferenceValue under a lock and causes lock-ordering deadlocks.
            let value: Value
            if isPreference, let precomputed = threadLocals.precomputedPreferenceValue, let typed = precomputed as? Value {
                value = frozenCopy(typed)
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
                        area: area
                    )
                    if area == .preference {
                        self.dependencyPreferenceUpdates[key] = update
                    } else {
                        self.dependencyMetadataUpdates[key] = update  // covers .local and .environment
                    }
                }
                return
            }

            let name = storageName ?? propertyName(from: model, path: path)
            let prefix: String? = area == .preference ? "preference" : area == .local ? "local" : area == .environment ? "environment" : nil
            let value = frozenCopy(model.context![path])
            self.lock {
                for fullPath in fullPaths {
                    self.valueUpdates[fullPath] = ValueUpdate(
                        apply: { $0[keyPath: fullPath] = value },
                        debugInfo: {
                            let prop = prefix.map { "\($0).\(name ?? "UNKNOWN")" } ?? (name ?? "UNKNOWN")
                            // Use includeInMirror so @Model child values show their fields and ModelID.
                            // This makes it clear which instance was assigned (important when a child
                            // model is replaced with a new instance that has the same field values).
                            let valueDescription = threadLocals.withValue(true, at: \.includeImplicitIDInMirror) {
                                String(customDumping: value)
                            }
                            return "\(String(describing: M.self)).\(prop) == \(valueDescription)"
                        },
                        area: area
                    )

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

    func fail(_ message: String, for area: Exhaustivity, at fileAndLine: FileAndLine) {
        if lock({ exhaustivity.contains(area) }) {
            fail(message, at: fileAndLine)
        } else if lock({ showSkippedAssertions }) {
            withExpectedIssue {
                fail(message, at: fileAndLine)
            }
        }
    }

    /// Measures current scheduler latency and returns an effective timeout that scales
    /// with system load, using `floor` as the minimum.
    ///
    /// Under parallel test load the cooperative thread pool is saturated, so `Task.yield()`
    /// takes much longer than usual — and model tasks waiting for a thread are delayed by
    /// exactly the same factor. Scaling the timeout by yield latency keeps the effective
    /// "number of scheduler rounds" constant regardless of how many tests run in parallel.
    /// Under no load a yield takes ~microseconds, so the multiplier stays near 1× and
    /// `floor` is returned as-is.
    static func adaptiveTimeout(floor: UInt64) async -> UInt64 {
        // Only scale when the caller passes the default (1 s) or larger timeout. Short explicit
        // timeouts must be respected as-is so tests probing failure messages don't wait
        // unexpectedly long under heavy parallel load.
        guard floor >= nanosPerSecond else { return floor }
        let calibrationStart = DispatchTime.now().uptimeNanoseconds
        await Task.yield()
        let yieldLatencyNs = DispatchTime.now().uptimeNanoseconds - calibrationStart
        // Give the condition ~100 scheduler rounds at the current pace.
        return max(floor, yieldLatencyNs * 100)
    }

    func expect(settleResetting: Exhaustivity? = nil, at fileAndLine: FileAndLine, predicates: [AssertBuilder.Predicate], enableExhaustionTest: Bool = true) async {
        await expect(timeoutNanoseconds: 1_000_000_000, settleResetting: settleResetting, at: fileAndLine, predicates: predicates, enableExhaustionTest: enableExhaustionTest)
    }

    func expect(timeoutNanoseconds timeout: UInt64, settleResetting: Exhaustivity? = nil, at fileAndLine: FileAndLine, predicates: [AssertBuilder.Predicate], enableExhaustionTest: Bool = true) async {
        let calibrationStart = DispatchTime.now().uptimeNanoseconds
        await Task.yield()
        let yieldLatencyNs = DispatchTime.now().uptimeNanoseconds - calibrationStart
        // Only apply adaptive scaling for the default (1 s) timeout or larger. Short explicit
        // timeouts (e.g. 1 ms passed by output-snapshot tests) must be respected as-is so
        // tests that intentionally probe failure messages don't wait unexpectedly long under
        // heavy parallel load.
        //
        // Cap at 10 s: on a heavily loaded CI (500 ms yield latency), the uncapped formula
        // (yieldLatency × 100 = 50 s) would make genuinely failing tests wait ~50 s before
        // reporting. 10 s gives ~20 scheduler rounds at 500 ms — enough for any legitimate
        // condition while keeping failure feedback fast.
        let scaledTimeout = timeout >= nanosPerSecond ? min(10 * nanosPerSecond, max(timeout, yieldLatencyNs * 100)) : timeout
        // One scheduler round at the current pace. Used as the minimum poll interval so
        // for-await loop bodies always get at least one full cooperative-pool turn per
        // waitForModification call, even under heavy parallel test load.
        let yieldRoundNs = max(1_000_000, yieldLatencyNs) // floor at 1ms for lightly loaded runs
        let context = TesterAssertContext(events: { self.lock { self.events } }, fileAndLine: fileAndLine)
        // Hard cap: absolute maximum even when the model IS making progress (e.g. infinite
        // mutation loop). Capped at 30 s — triple the scaledTimeout cap so legitimately busy
        // models have headroom, while runaway loops get caught well within CI job timeouts.
        // TestAccessOverrides.hardCapNanoseconds allows output snapshot tests to override.
        let hardCap = TestAccessOverrides.hardCapNanoseconds ?? min(30 * nanosPerSecond, max(5 * nanosPerSecond, scaledTimeout * 10))

        await TesterAssertContextBase.$assertContext.withValue(context) {

            let start = DispatchTime.now().uptimeNanoseconds
            var lastProgressTime = start  // reset whenever a state modification arrives
            var retryCount = 0
            var failures: [TesterAssertContext.Failure] = []
            var passedAccesses: [TesterAssertContext.Access] = []
            while true {
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
                    // frozenCopy walks Optional<M> children which calls _swift_getKeyPath to
                    // create dynamic ContainerCursor key paths. _swift_getKeyPath needs the Swift
                    // runtime lock — calling it while holding NSRecursiveLock deadlocks when the
                    // runtime lock is contended. Compute frozenCopy outside the lock; expectedState
                    // and lastState are value-type copies so this is safe.
                    // isApplyingSnapshot suppresses willAccessPreference/willAccessStorage callbacks
                    // and re-entrant observation triggered by releasing live child models during
                    // the transform.
                    let isEqualIncludingIds = threadLocals.withValue(true, at: \.isApplyingSnapshot) {
                        let last = lastState.frozenCopy
                        return lock {
                            threadLocals.withValue(true, at: \.includeImplicitIDInMirror) {
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
                                    // Compare the predicate-time captured value against lastState directly.
                                    // Using only `last` (which reflects the current live state) and comparing
                                    // against the captured value is safe and sufficient: if the IDs match,
                                    // the model has settled.
                                    let a = last[keyPath: access.path]
                                    return result && (diff(access.capturedValue(), a) == nil)
                                }
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
                        if start.distance(to: DispatchTime.now().uptimeNanoseconds) > hardCap {
                            // Hard cap hit: the model has been continuously producing changes
                            // and IDs never converged. Report as failure.
                            fail("State did not settle: model IDs kept diverging after the predicate passed. This may indicate a backgroundCallQueue loop or an unresolvable ID mismatch.", at: fileAndLine)
                            return
                        }
                        await backgroundCall.waitForCurrentItems(deadline: start + hardCap)
                        await Task.yield()
                        // Count as progress — backgroundCall draining counts as activity.
                        lastProgressTime = DispatchTime.now().uptimeNanoseconds
                        continue
                    }

                    if isEqualIncludingIds {
                        // Settling mode: after the predicate passes and IDs converge,
                        // wait for all activation tasks to enter their body, then run
                        // one idle cycle to catch trailing mutations (e.g. forEach first
                        // fires). Finally, reset selected exhaustivity categories so
                        // subsequent expect {} calls only see changes made after settling.
                        if let resetting = settleResetting {
                            // Wait for all onActivate()-born tasks to begin executing.
                            // In practice this completes almost immediately because
                            // activationTaskEntered() fires at the start of the task body.
                            while self.activationTasksInFlight > 0 {
                                let didProgress = await waitForModification(timeoutNanoseconds: scaledTimeout, yieldRoundNs: yieldRoundNs, retryCount: retryCount)
                                if didProgress { lastProgressTime = DispatchTime.now().uptimeNanoseconds }
                                retryCount += 1
                                if start.distance(to: DispatchTime.now().uptimeNanoseconds) > hardCap {
                                    let taskInfo = self.settleTimeoutDiagnostics()
                                    fail("settle() timed out: model still has active tasks.\n\(taskInfo)", at: fileAndLine)
                                    return
                                }
                            }

                            // Idle cycle: wait until one full scheduling round passes
                            // with no state changes. Uses modificationCount on the root
                            // context as a version number.
                            var lastChangeVersion = self.context.modificationCount
                            while true {
                                await backgroundCall.waitForCurrentItems(deadline: start + hardCap)
                                await Task.yield()
                                let currentVersion = self.context.modificationCount
                                if currentVersion == lastChangeVersion {
                                    // No changes this round. If tasks are still running,
                                    // wait one more round to handle scheduling jitter —
                                    // the task might just be between yield suspension and
                                    // its next mutation.
                                    if !self.isCompletelyIdle {
                                        await waitForModification(timeoutNanoseconds: yieldRoundNs, yieldRoundNs: yieldRoundNs, retryCount: 2)
                                        let afterWait = self.context.modificationCount
                                        if afterWait == currentVersion {
                                            break // genuinely idle: no changes even after waiting
                                        }
                                        lastChangeVersion = afterWait
                                    } else {
                                        break // no active tasks → idle
                                    }
                                } else {
                                    lastChangeVersion = currentVersion
                                }
                                lastProgressTime = DispatchTime.now().uptimeNanoseconds
                                if start.distance(to: DispatchTime.now().uptimeNanoseconds) > hardCap {
                                    let taskInfo = self.settleTimeoutDiagnostics()
                                    fail("settle() timed out: model still has active tasks.\n\(taskInfo)", at: fileAndLine)
                                    return
                                }
                            }

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
                        lock {
                            // Sync expectedState to lastState for the asserted changes.
                            // Applying access values (predicate-time frozen copies) would write
                            // stale ModelContext.frozenCopy IDs into expectedState. Since
                            // ModelContext.== compares by frozenCopy.id, any child write after
                            // the predicate ran would cause expectedState != lastState in the
                            // structural diff, producing a false "not equal but no diff detected"
                            // failure. Assigning lastState directly keeps all IDs in sync.
                            // The exhaustion check relies on valueUpdates (layer-3) to catch
                            // any unasserted changes, which is comprehensive: every property
                            // write via @Model fires didModify and adds a valueUpdates entry.
                            expectedState = lastState

                            for access in passedAccesses {
                                // Clear the pending update — this path has been asserted.
                                valueUpdates[access.path] = nil
                                // For dependency context storage, run the additional cleanup (clears
                                // dependencyMetadataUpdates for this storage key+context).
                                access.additionalCleanup?()
                            }

                            for index in context.eventsSent.reversed() { events.remove(at: index) }

                            for (probe, value) in context.probes {
                                probe.consume(value)
                            }
                        }

                        if enableExhaustionTest {
                            // Step 4: Check that no other state changed without being
                            // asserted. Diffs expectedState against lastState.
                            // IMPORTANT: Must be called outside the lock. checkExhaustion calls
                            // diffMessage/customDump which triggers customMirror on @Model types,
                            // which reads @ModelTracked properties, which calls willAccess, which
                            // acquires context.rootPaths — also guarded by the same lock. If we
                            // are suspended via an async withValue and resume on a different thread,
                            // the NSRecursiveLock is not re-entrant across threads and deadlocks.
                            checkExhaustion(at: fileAndLine, includeUpdates: true)
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
                let now = DispatchTime.now().uptimeNanoseconds
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
                        for failure in failures {
                            for access in failure.accesses {
                                access.apply(&expectedState)
                            }
                        }

                        for access in passedAccesses {
                            access.apply(&expectedState)
                            valueUpdates[access.path] = nil
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
                let elapsed = lastProgressTime.distance(to: DispatchTime.now().uptimeNanoseconds)
                let remaining = elapsed < scaledTimeout ? scaledTimeout - UInt64(elapsed) : 0
                retryCount += 1

                let didProgress = await waitForModification(timeoutNanoseconds: remaining, yieldRoundNs: yieldRoundNs, retryCount: retryCount)
                if didProgress { lastProgressTime = DispatchTime.now().uptimeNanoseconds }
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
                for failure in failures {
                    for access in failure.accesses {
                        access.apply(&expectedState)
                    }
                }

                for access in passedAccesses {
                    valueUpdates[access.path] = nil
                    access.additionalCleanup?()
                    access.apply(&expectedState)
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
        let calibrationStart = DispatchTime.now().uptimeNanoseconds
        await Task.yield()
        let yieldLatencyNs = DispatchTime.now().uptimeNanoseconds - calibrationStart
        let scaledTimeout = min(10 * nanosPerSecond, max(nanosPerSecond, yieldLatencyNs * 100))
        let yieldRoundNs = max(1_000_000, yieldLatencyNs)
        let hardCap = TestAccessOverrides.hardCapNanoseconds ?? min(30 * nanosPerSecond, max(5 * nanosPerSecond, scaledTimeout * 10))

        let start = DispatchTime.now().uptimeNanoseconds
        var lastProgressTime = start
        var retryCount = 0

        while true {
            if let value = expression() {
                // Expression is non-nil. Drive the same settled-state stability check as expect.
                let predicate = AssertBuilder.Predicate(predicate: { expression() != nil }, fileAndLine: fileAndLine)
                await expect(timeoutNanoseconds: nanosPerSecond, at: fileAndLine, predicates: [predicate], enableExhaustionTest: false)
                return value
            }

            let now = DispatchTime.now().uptimeNanoseconds
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
            if didProgress { lastProgressTime = DispatchTime.now().uptimeNanoseconds }
            retryCount += 1
        }
    }

    /// Suspends briefly so the async pipeline can settle, then returns so the outer
    /// assert loop can re-check its predicate.
    ///
    /// Uses an escalation strategy based on `retryCount` to balance two competing needs:
    ///
    /// - **Fast conditions** (e.g. a model property set by a cancellation handler):
    ///   The value is written directly to `lastState` synchronously. A `Task.yield()`
    ///   is sufficient — no need to wait for `backgroundCall` at all.
    ///
    /// - **Async conditions** (memoized properties, `Observed` streams):
    ///   Both go through `backgroundCall` — memoize's performUpdate and Observed stream
    ///   updates all use the same per-test task-local queue. A FIFO sentinel via
    ///   `waitForCurrentItems` ensures the update has run before re-checking.
    ///
    /// Escalation by retry count:
    ///   0-1: Just yield — free and instant. Covers fast conditions on the first retry.
    ///   2+:  Use `waitForCurrentItems(deadline: ...)` then `waitUntilIdle()`. Ensures
    ///        the drain loop's post-batch yield has run so stream consumers have run.
    /// Returns `true` if a state modification was observed during the wait (progress was made).
    @discardableResult
    private func waitForModification(timeoutNanoseconds remaining: UInt64, yieldRoundNs: UInt64, retryCount: Int = 0) async -> Bool {
        guard remaining > 0 else { return false }

        // After two quick-yield retries, escalate to a sentinel wait when the pipeline
        // queue has pending work. This gives fast conditions a free early-exit while
        // ensuring memoized and Observed-stream conditions get enough time to settle.
        let bgQueue = backgroundCall
        if retryCount >= 2 && !bgQueue.isIdle {
            // FIFO sentinel: suspend until all items currently in the queue have been
            // processed. When it fires, any pending performUpdate has already run.
            //
            // Deadline: use the full remaining timeout. By retry 2, fast conditions
            // (e.g. testCancelInFlight) have already passed on an earlier quick-yield
            // retry, so we know this is a genuinely async condition. Waiting up to
            // `remaining` ensures deep queues under heavy parallel load are covered.
            let deadline = DispatchTime.now().uptimeNanoseconds + remaining
            await bgQueue.waitForCurrentItems(deadline: deadline)
            // waitUntilIdle() ensures the drain loop's post-batch Task.yield() has run
            // so stream consumers have had a scheduler turn before we re-check.
            // Use the same deadline so a starved drain loop doesn't cause an indefinite hang.
            if !bgQueue.isIdle {
                await bgQueue.waitUntilIdle(deadline: deadline)
            }
            await Task.yield()
            // Draining the queue counts as progress — it may have delivered an update.
            return true
        }

        // Early retries (0-1) or backgroundCallQueue already idle.
        //
        // backgroundCallQueue idle means either:
        // A) performUpdate already ran — memoize cache is fresh, predicate will pass.
        // B) No modification yet — register onAnyModification and sleep one round.
        let didModify = LockIsolated(false)
        let cancelModification = context.onAnyModification { _ in
            return { didModify.setValue(true) }
        }
        defer { cancelModification() }

        if !didModify.value {
            // No modification yet. On early retries just yield (fast path for conditions
            // that are already satisfied); on later retries sleep a full round to avoid
            // busy-spinning while genuinely waiting for a future modification.
            if retryCount < 2 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: yieldRoundNs)
            }
        }

        // If a modification arrived (or the pipeline queue is still busy), yield once so
        // it gets a scheduler turn to process any resulting updates before re-checking.
        if didModify.value || !backgroundCall.isIdle {
            await Task.yield()
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

    // Checks that no state changed without being asserted (exhaustion check).
    //
    // At the end, resets expectedState = lastState so the next assert starts from a
    // clean baseline.
    func checkExhaustion(at fileAndLine: FileAndLine, includeUpdates: Bool, checkTasks: Bool = false) {
        if checkTasks {
            for info in context.activeTasks {
                let taskWord = info.tasks.count == 1 ? "task" : "tasks"
                fail("Models of type `\(info.modelName)` have \(info.tasks.count) active \(taskWord) still running", for: .tasks, at: fileAndLine)

                for (taskName, taskFileAndLine) in info.tasks {
                    fail("Active task '\(taskName)' of `\(info.modelName)` still running (registered here)", for: .tasks, at: taskFileAndLine)
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

        let (lastAsserted, actual, snapshotUpdates) = lock { (expectedState, lastState, valueUpdates) }

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
        if !reportedStateFailure {
            // Partition by area so state, local, environment, and preference storage are each reported
            // independently and respect their respective exhaustivity flags.
            for area: Exhaustivity in [.state, .local, .environment, .preference] {
                let updates = snapshotUpdates.values.filter { $0.area == area }
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
                for area: Exhaustivity in [.local, .environment] {
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

package struct UnwrapError: Error { package init() {} }

class TesterAssertContextBase: @unchecked Sendable {
    func didSend<M: Model, Event>(event: Event, from context: Context<M>) -> Bool { fatalError() }
    func probe(_ probe: TestProbe, wasCalledWith value: Any) -> Void { fatalError() }

    @TaskLocal static var assertContext: TesterAssertContextBase?
}
