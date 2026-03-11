import Foundation
import CustomDump
import IssueReporting
import Dependencies

// MARK: - How tester.assert works
//
// tester.assert { predicate } is a polling loop that:
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
// Why context storage (node.context.x) can't currently participate as a regular access:
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

    var events: [Event] = []
    var probes: [TestProbe] = []
    let fileAndLine: FileAndLine

    // Captures a pending state change: how to apply it to a Root snapshot, and how to
    // describe it for exhaustion-failure messages.
    struct ValueUpdate {
        var apply: (inout Root) -> Void
        var debugInfo: () -> String
        /// Which exhaustivity category this update belongs to. Defaults to `.state` for
        /// regular property writes; `.context` for `node.context` writes.
        var area: Exhaustivity
    }

    struct Event {
        var event: Any
        var context: AnyContext
    }

    init(model: Root, options: ModelOption = [], dependencies: (inout ModelDependencies) -> Void, fileAndLine: FileAndLine) {
        expectedState = model.frozenCopy
        lastState = model.frozenCopy
        self.fileAndLine = fileAndLine
        context = Context(model: model, lock: NSRecursiveLock(), options: options, dependencies: dependencies, parent: nil)

        super.init(useWeakReference: true)

        context.readModel.modelContext.access = self
        context.modifyModel.modelContext.access = self
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

        // Capture the modification area at the point of access (thread-local is set here
        // but may be cleared by the time the returned closure is invoked).
        let capturedArea = threadLocals.modificationArea

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

        // Dependency model context storage: no root-relative path exists (the model lives in
        // dependencyContexts, not children). Return a dummy Access whose additionalCleanup
        // clears the corresponding dependencyMetadataUpdates entry when asserted.
        if fullPaths.isEmpty, capturedArea == .context, let modelContext = model.context {
            let key = DependencyMetadataKey(contextID: ObjectIdentifier(modelContext), path: path)
            return { [weak self] in
                guard let self else { return }
                let cleanup: () -> Void = { [weak self] in
                    self?.lock { self?.dependencyMetadataUpdates.removeValue(forKey: key) }
                }
                assertContext.accesses.append(.init(
                    path: \Root.self,
                    modelName: model.typeDescription,
                    propertyName: propertyName(from: model, path: path),
                    value: String(customDumping: frozenCopy(modelContext[path])),
                    apply: { _ in },
                    additionalCleanup: cleanup
                ))
            }
        }

        return {
            let value = frozenCopy(model.context![path])
            for fullPath in fullPaths {
                assertContext.accesses.append(.init(
                    path: fullPath,
                    modelName: model.typeDescription,
                    propertyName: propertyName(from: model, path: path),
                    value: String(customDumping: value)
                ) {
                    $0[keyPath: fullPath] = value
                })
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
    override func didModify<M: Model, Value>(_ model: M, at path: KeyPath<M, Value>&Sendable) -> (() -> Void)? {
        guard let path = path as? WritableKeyPath<M, Value> else { return nil }

        let rootPaths = model.context?.rootPaths.compactMap { $0 as? WritableKeyPath<Root, M> }
        guard let rootPaths else {
            fatalError()
        }

        let fullPaths = rootPaths.map { $0.appending(path: path) }
        let area = threadLocals.modificationArea ?? .state

        // Dependency model context storage: no root-relative path exists. Track the update
        // separately so checkExhaustion can report it if not asserted.
        if fullPaths.isEmpty, area == .context, let modelContext = model.context {
            let key = DependencyMetadataKey(contextID: ObjectIdentifier(modelContext), path: path)
            return { [weak self] in
                guard let self else { return }
                let value = frozenCopy(modelContext[path])
                self.lock {
                    self.dependencyMetadataUpdates[key] = ValueUpdate(
                        apply: { _ in },  // dependency context storage not in Root snapshot
                        debugInfo: { "\(String(describing: M.self)).\(propertyName(from: model, path: path) ?? "UNKNOWN") == \(String(customDumping: value))" },
                        area: .context
                    )
                }
            }
        }

        return {
            let value = frozenCopy(model.context![path])
            self.lock {
                for fullPath in fullPaths {
                    self.valueUpdates[fullPath] = ValueUpdate(
                        apply: { $0[keyPath: fullPath] = value },
                        debugInfo: { "\(String(describing: M.self)).\(propertyName(from: model, path: path) ?? "UNKOWN") == \(String(customDumping: value))" },
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
            _XCTExpectFailure {
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
        let calibrationStart = DispatchTime.now().uptimeNanoseconds
        await Task.yield()
        let yieldLatencyNs = DispatchTime.now().uptimeNanoseconds - calibrationStart
        // Give the condition ~100 scheduler rounds at the current pace.
        return max(floor, yieldLatencyNs * 100)
    }

    func assert(timeoutNanoseconds timeout: UInt64, at fileAndLine: FileAndLine, predicates: [AssertBuilder.Predicate], enableExhaustionTest: Bool = true) async {
        let calibrationStart = DispatchTime.now().uptimeNanoseconds
        await Task.yield()
        let yieldLatencyNs = DispatchTime.now().uptimeNanoseconds - calibrationStart
        let scaledTimeout = max(timeout, yieldLatencyNs * 100)
        // One scheduler round at the current pace. Used as the minimum poll interval so
        // for-await loop bodies always get at least one full cooperative-pool turn per
        // waitForModification call, even under heavy parallel test load.
        let yieldRoundNs = max(1_000_000, yieldLatencyNs) // floor at 1ms for lightly loaded runs
        let context = TesterAssertContext(events: { self.lock { self.events } }, fileAndLine: fileAndLine)
        await TesterAssertContextBase.$assertContext.withValue(context) {

            let start = DispatchTime.now().uptimeNanoseconds
            while true {
                var failures: [TesterAssertContext.Failure] = []
                var passedAccesses: [TesterAssertContext.Access] = []

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
                    let isEqualIncludingIds = lock {
                        var expected = expectedState.frozenCopy
                        var last = lastState.frozenCopy
                        return threadLocals.withValue(true, at: \.includeInMirror) {
                            passedAccesses.reduce(true) { result, access in
                                access.apply(&expected)
                                access.apply(&last)
                                let e = expected[keyPath: access.path]
                                let a = last[keyPath: access.path]

                                return result && (diff(e, a) == nil)
                            }
                        }
                    }

                    // Predicate passed but IDs don't match yet: there is a pending
                    // backgroundCall batch in flight. Wait for it to settle and retry —
                    // do NOT call waitForModification (which blocks on the *next* modification
                    // event and would miss the modification that already happened).
                    if !isEqualIncludingIds {
                        await backgroundCall.waitUntilIdle()
                        await Task.yield()
                        continue
                    }

                    if isEqualIncludingIds {
                        // Step 3: Model has settled. Mark all asserted paths as handled,
                        // advance expectedState, and run the exhaustion check.
                        lock {
                            for access in passedAccesses {
                                // Clear the pending update — this path has been asserted.
                                valueUpdates[access.path] = nil
                                // For dependency context storage, run the additional cleanup (clears
                                // dependencyMetadataUpdates for this storage key+context).
                                access.additionalCleanup?()
                                // Advance the baseline to include this asserted value.
                                access.apply(&expectedState)
                            }

                            events.remove(atOffsets: context.eventsSent)

                            for (probe, value) in context.probes {
                                probe.consume(value)
                            }

                            if enableExhaustionTest {
                                // Step 4: Check that no other state changed without being
                                // asserted. Diffs expectedState against lastState.
                                checkExhaustion(at: fileAndLine, includeUpdates: true)
                            }
                        }

                        return
                    }
                }

                // Step 5 (timeout): Report failures.
                if start.distance(to: DispatchTime.now().uptimeNanoseconds) > scaledTimeout {
                    lock {
                        for failure in failures {
                            if let (lhs, rhs) = failure.predicate.values() {
                                let propertyNames = failure.accesses.compactMap { access in
                                    access.propertyName.map { "\(access.modelName).\($0)" }
                                }.joined(separator: ", ")

                                for access in failure.accesses {
                                    access.apply(&expectedState)
                                }

                                let title = "Failed to assert: \(propertyNames)"
                                let message = threadLocals.withValue(true, at: \.includeChildrenInMirror) {
                                    diffMessage(expected: rhs, actual: lhs, title: title)
                                }
                                if let message {
                                    fail(message, at: failure.predicate.fileAndLine)
                                } else {
                                    fail(title, at: failure.predicate.fileAndLine)
                                }
                            } else {
                                for access in failure.accesses {
                                    let predicate = access.propertyName.map {
                                        "\(access.modelName).\($0) == \(access.value)"
                                    } ?? access.value

                                    fail("Failed to assert: \(predicate)", at: failure.predicate.fileAndLine)

                                    access.apply(&expectedState)
                                }
                            }

                            for event in failure.events {
                                fail("Failed to assert sending of: \(String(customDumping: event.event)) from \(event.context.typeDescription)", at: failure.predicate.fileAndLine)
                            }

                            for modelName in failure.modelsNoLongerPartOfTester {
                                fail("Model \(modelName) is no longer part of this tester", at: fileAndLine)
                            }

                            for (probe, value) in failure.probes {
                                let preTitle = "Failed to assert calling of probe" + (probe.name.map { "\"\($0)\":" } ?? ":")
                                let title = value is NoArgs ? preTitle :
                                    """
                                    \(preTitle)
                                        \(String(customDumping: value))
                                    """

                                if probe.isEmpty {
                                    fail(
                                        """
                                        \(title)

                                        No available probe values
                                        """, at: fileAndLine)
                                } else if probe.count == 1, let message = threadLocals.withValue(true, at: \.includeChildrenInMirror, perform: { diffMessage(expected: value, actual: probe.values[0], title: "Probe does not match") }) {
                                    fail(message, at: fileAndLine)
                                } else {
                                    fail(
                                    """
                                    \(title)

                                    \(probe.count) Available probe values to assert:
                                        \(probe.values.map { String(customDumping: $0) }.joined(separator: "\n\t"))
                                    """, at: fileAndLine)
                                }
                            }

                            if failure.accesses.isEmpty, failure.events.isEmpty, failure.modelsNoLongerPartOfTester.isEmpty, failure.probes.isEmpty {
                                fail("Failed to assert: ", at: failure.predicate.fileAndLine)
                            }
                        }

                        for access in passedAccesses {
                            valueUpdates[access.path] = nil
                            access.additionalCleanup?()
                            access.apply(&expectedState)
                        }
                        
                        events.remove(atOffsets: context.eventsSent)

                        for (probe, value) in context.probes {
                            probe.consume(value)
                        }
                    }

                    if enableExhaustionTest {
                        checkExhaustion(at: fileAndLine, includeUpdates: false)
                    }
                    return
                }

                // Step 6: Wait for the next modification event before re-checking.
                let elapsed = start.distance(to: DispatchTime.now().uptimeNanoseconds)
                let remaining = elapsed < scaledTimeout ? scaledTimeout - UInt64(elapsed) : 0
                await waitForModification(timeoutNanoseconds: remaining, yieldRoundNs: yieldRoundNs)
            }
        }
    }

    func unwrap<T>(_ expression: @escaping @Sendable () -> T?, timeoutNanoseconds timeout: UInt64, at fileAndLine: FileAndLine) async throws -> T {
        let scaledTimeout = await Self.adaptiveTimeout(floor: timeout)
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            if let value = expression() {
                let predicate = AssertBuilder.Predicate(predicate: { expression() != nil }, fileAndLine: fileAndLine)
                await assert(timeoutNanoseconds: timeout, at: fileAndLine, predicates: [predicate], enableExhaustionTest: false)
                return value
            }

            if start.distance(to: DispatchTime.now().uptimeNanoseconds) > scaledTimeout {
                fail("Failed to unwrap value", at: fileAndLine)
                throw UnwrapError()
            }

            let elapsed = start.distance(to: DispatchTime.now().uptimeNanoseconds)
            let remaining = elapsed < scaledTimeout ? scaledTimeout - UInt64(elapsed) : 0
            await waitForModification(timeoutNanoseconds: remaining, yieldRoundNs: 1_000_000)
        }
    }

    /// Suspends briefly so the async pipeline can settle, then returns so the outer
    /// assert loop can re-check its predicate.
    ///
    /// `yieldRoundNs` is the measured yield latency at the start of `assert()` — it
    /// represents one full cooperative-pool round at the current load level. The function
    /// sleeps for at least this long so that `for await` loop bodies (which consume values
    /// yielded by `backgroundCall.performUpdate` and write to external `LockIsolated`
    /// state) always get at least one scheduler turn per call, regardless of pool load.
    private func waitForModification(timeoutNanoseconds remaining: UInt64, yieldRoundNs: UInt64) async {
        guard remaining > 0 else { return }

        // Fast path: a modification is currently being processed by backgroundCall.
        // Wait for it to finish, then sleep one scheduler round so for-await consumers
        // of the yielded stream values get to run.
        if !backgroundCall.isIdle {
            await backgroundCall.waitUntilIdle()
            try? await Task.sleep(nanoseconds: yieldRoundNs)
            return
        }

        // backgroundCall is idle. Two cases:
        //
        // A) The update pipeline already ran before we arrived (e.g. backgroundCall
        //    processed the undo change while we were in adaptiveTimeout's yield).
        //    The for-await body may not have run yet. We register onAnyModification
        //    to catch future changes, then sleep one full scheduler round so the
        //    for-await body gets a turn.
        //
        // B) We are genuinely waiting for a future modification. onAnyModification
        //    fires as soon as it arrives, cutting the sleep short.
        //
        // The outer assert() loop re-checks the predicate after each return and
        // accumulates elapsed time against the scaled timeout.
        let didModify = LockIsolated(false)
        let cancelModification = context.onAnyModification { _ in
            return { didModify.setValue(true) }
        }
        defer { cancelModification() }

        // Sleep one scheduler round. Under light load this is ~1ms; under heavy parallel
        // test load it scales up to match the actual cooperative-pool round-trip time,
        // ensuring the for-await body gets at least one scheduling opportunity.
        if !didModify.value {
            try? await Task.sleep(nanoseconds: yieldRoundNs)
        }

        // If a modification arrived (either before we registered or during the sleep),
        // wait for backgroundCall to finish and sleep another round for the consumer.
        if didModify.value || !backgroundCall.isIdle {
            await backgroundCall.waitUntilIdle()
            try? await Task.sleep(nanoseconds: yieldRoundNs)
        }
    }

    // Checks that no state changed without being asserted (exhaustion check).
    //
    // Three layers of checking:
    //   1. Diff expectedState vs lastState by value (without IDs) — catches structural changes.
    //   2. Diff with IDs included — catches identity changes (e.g. child model replacements).
    //   3. If states match by value, check valueUpdates for un-asserted paths not yet
    //      visible in the struct diff (e.g. multiple writes to the same property that
    //      ended up back at the same value, or writes to hidden/non-mirrored properties).
    //
    // At the end, resets expectedState = lastState so the next assert starts from a
    // clean baseline.
    func checkExhaustion(at fileAndLine: FileAndLine, includeUpdates: Bool, checkTasks: Bool = false) {
        if checkTasks {
            for info in context.activeTasks {
                fail("Models of type `\(info.modelName)` have \(info.fileAndLines.count) active tasks still running", for: .tasks, at: fileAndLine)

                for fileAndLine in info.fileAndLines {
                    fail("Models of type `\(info.modelName)` have an active task still running", for: .tasks, at: fileAndLine)
                }
            }
        }

        let events = lock { self.events }
        for event in events {
            fail("Event `\(String(customDumping: event.event))` sent from `\(event.context.typeDescription)` was not handled", for: .events, at: fileAndLine)
        }

        let probes = lock { self.probes }
        for probe in probes {
            let name = probe.name.map { "\"\($0)\":" } ?? ""
            for value in probe.values {
                let valueString = value is NoArgs ? "" : " with: \(String(customDumping: value))"
                fail("Failed to assert calling of probe \(name)\(valueString)", for: .probes, at: fileAndLine)
            }
        }

        let (lastAsserted, actual) = lock { (expectedState, lastState) }

        let title = "State not exhausted"
        // Layer 1: structural diff without IDs.
        let message = threadLocals.withValue(true, at: \.includeChildrenInMirror) {
            diffMessage(expected: lastAsserted, actual: actual, title: title)
        }
        if let message {
            fail(message, for: .state, at: fileAndLine)
        } else {
            // Layer 2: diff with IDs included (catches identity/generation changes).
            let message = threadLocals.withValue(true, at: \.includeInMirror) {
                diffMessage(expected: lastAsserted, actual: actual, title: title)
            }

            if let message {
                fail(message, for: .state, at: fileAndLine)
            } else if includeUpdates {
                // Layer 3: check for pending valueUpdates not visible in the struct diff.
                // Partition by area so state and context storage are reported independently and
                // respect their respective exhaustivity flags.
                // Report state and context updates separately so each respects its own flag.
                for area: Exhaustivity in [.state, .context] {
                    let updates = valueUpdates.values.filter { $0.area == area }
                    if !updates.isEmpty {
                        let descriptions = updates.map { $0.debugInfo() }
                        let areaTitle = area == .context ? "Context not exhausted" : "State not exhausted"
                        fail("""
                            \(areaTitle): …

                            Modifications not asserted:

                            \(descriptions.map { $0.indent(by: 4) }.joined(separator: "\n\n"))
                            """, for: area, at: fileAndLine)
                    }
                }

                // Layer 3b: check for unasserted context storage on dependency models.
                // These are tracked separately because dependency models have no
                // root-relative WritableKeyPath and cannot be put in valueUpdates.
                let depUpdates = lock { dependencyMetadataUpdates }
                if !depUpdates.isEmpty {
                    let descriptions = depUpdates.values.map { $0.debugInfo() }
                    fail("""
                        Context not exhausted: …

                        Modifications not asserted:

                        \(descriptions.map { $0.indent(by: 4) }.joined(separator: "\n\n"))
                        """, for: .context, at: fileAndLine)
                }
            }
        }

        // Reset the baseline so the next assert call starts from the current live state.
        lock {
            self.expectedState = self.lastState
            self.valueUpdates.removeAll()
            self.dependencyMetadataUpdates.removeAll()
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
            var value: String

            var apply: (inout Root) -> Void
            // Called during assertion clearing for accesses that need side-effect cleanup
            // beyond the standard valueUpdates path-based removal (e.g. dependency context storage).
            var additionalCleanup: (() -> Void)?

            init(path: PartialKeyPath<Root>, modelName: String, propertyName: String?, value: String, apply: @escaping (inout Root) -> Void, additionalCleanup: (() -> Void)? = nil) {
                self.path = path
                self.modelName = modelName
                self.propertyName = propertyName
                self.value = value
                self.apply = apply
                self.additionalCleanup = additionalCleanup
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

struct UnwrapError: Error { }

class TesterAssertContextBase: @unchecked Sendable {
    func didSend<M: Model, Event>(event: Event, from context: Context<M>) -> Bool { fatalError() }
    func probe(_ probe: TestProbe, wasCalledWith value: Any) -> Void { fatalError() }

    @TaskLocal static var assertContext: TesterAssertContextBase?
}
