import Foundation
#if canImport(Dispatch)
import Dispatch
#endif
import CustomDump
import IssueReporting
import Dependencies

private func monotonicNanoseconds() -> UInt64 {
    #if canImport(Dispatch)
    return DispatchTime.now().uptimeNanoseconds
    #else
    return UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    #endif
}

extension TestAccess {
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

                // Snapshot valueUpdates entry counts before predicate evaluation.
                // Paths that gain new entries during evaluation had side-effect writes
                // (e.g. `accessCount += 1` inside a computed getter). These must be
                // skipped in isEqualIncludingIds because capturedValue is pre-write
                // but lastState is post-write.
                let prePredicateUpdateCounts: [AnyKeyPath: Int] = lock {
                    var counts: [AnyKeyPath: Int] = [:]
                    for (path, entries) in self.valueUpdates {
                        counts[path] = entries.count
                    }
                    return counts
                }

                // Step 1: Evaluate all predicates. Reading properties inside a predicate
                // fires willAccess → appends Access entries to context.accesses.
                for predicate in predicates {
                    context.predicate = predicate
                    
                    context.accesses.removeAll(keepingCapacity: true)
                    context.eventsNotSent.removeAll(keepingCapacity: true)
                    context.modelsNoLongerPartOfTester.removeAll(keepingCapacity: true)

                    let passed = usingActiveAccess(self) { predicate.predicate() }
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
                        // Snapshot all shared state under a single brief lock, then call
                        // frozenCopy and run the reduce entirely OUTSIDE the lock.
                        // frozenCopy walks Optional<M> children via _swift_getKeyPath which
                        // acquires the Swift runtime lock — holding the TestAccess lock at the
                        // same time deadlocks (lock-ordering inversion). The new conditions
                        // below also read exhaustivity/valueUpdates (shared state), so we
                        // capture those under the same brief lock.
                        let (snap, capturedExhaustivity, capturedValueUpdates) = lock { (lastState, exhaustivity, valueUpdates) }
                        let last = snap.frozenCopy
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
                                if capturedExhaustivity.contains(.transitions) && capturedValueUpdates[access.path] != nil { return result }
                                // Skip accesses whose path was WRITTEN during predicate
                                // evaluation (e.g. `accessCount += 1` inside a computed getter).
                                // capturedValue captures the pre-write value, but lastState
                                // reflects the post-write value, so they'd always diverge.
                                // Only skip paths that gained NEW entries during this predicate
                                // cycle — paths written before the predicate still need checking.
                                if let currentCount = capturedValueUpdates[access.path]?.count,
                                   currentCount > (prePredicateUpdateCounts[access.path] ?? 0) { return result }
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
                            _applyResetting(resetting)
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
}
