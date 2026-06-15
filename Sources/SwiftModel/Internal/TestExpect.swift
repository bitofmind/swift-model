import Foundation
#if canImport(Dispatch)
import Dispatch
#endif
import CustomDump
import IssueReporting
import Dependencies
import ConcurrencyExtras

private func nowMonotonicNs() -> UInt64 {
    #if canImport(Dispatch)
    return DispatchTime.now().uptimeNanoseconds
    #else
    return UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    #endif
}

extension TestAccess {
    // Default total budget for `expect`/`require`: maximum wall-clock time
    // a single call will wait for its predicate to become true.
    //
    // Predicate re-evaluations are driven purely by reactive wake-ups —
    // `didModify`, `didSend`, and probe calls fire `_noteActivity()` on
    // TestAccess, which evaluates pending predicates INLINE (no park/wake
    // loop). See `awaitPredicate`.
    //
    // Predicates that depend on state outside the reactive system —
    // raw `LockIsolated` counters mutated from `forEach` callbacks,
    // etc. — belong in `waitUntil` (Tests/SwiftModelTests/Utilities.swift).
    //
    // 5 s gives runaway tests fast feedback. `expect` is **purely reactive**:
    // it resolves the moment the predicate is true. If your test needs to
    // wait for an async chain that a user action set in motion (e.g. a
    // `node.task(id:)` triggered by a property write whose body the next
    // assertion depends on), use `settle { … }` — `settle` waits for the
    // model to be quiet (debounce window + bg-idle) plus your predicate to
    // hold, which guarantees the chain has completed before you proceed.
    //
    // Scaled by `ModelTestingTraitOptions.timeoutScale` (env
    // `SWIFT_MODEL_TIMEOUT_SCALE`) — bump on slow CI runners. Output-
    // snapshot tests override absolutely via
    // `TestAccessOverrides.$hardCapNanoseconds`.
    static var expectDefaultBudgetNs: UInt64 {
        TestAccessOverrides.hardCapNanoseconds ?? UInt64(5_000_000_000 * ModelTestingTraitOptions.timeoutScale)
    }

    /// Snapshot of one predicate evaluation, mutated in place by the
    /// evaluator closure so the post-await code can read whether the
    /// latest eval passed and what it recorded.
    ///
    /// Class (not struct) so the evaluator can mutate it through a
    /// captured reference. `@unchecked Sendable` because synchronisation
    /// is provided externally: writes happen INSIDE `TestAccess.lock`
    /// (the evaluator is called from `_noteActivity` / `awaitPredicate`'s
    /// initial check, both holding the lock). The post-await read in
    /// `expect` happens AFTER `awaitPredicate` returns, which only
    /// happens once the last evaluator run resumed our continuation;
    /// the continuation-resume happens-before the await-return, so the
    /// final snapshot write is visible.
    fileprivate final class EvalSnapshot: @unchecked Sendable {
        var failures: [TesterAssertContext.Failure] = []
        var passedAccesses: [TesterAssertContext.Access] = []
        /// `valueUpdates` snapshot taken under TestAccess.lock at the
        /// end of a successful eval (mirrors what the old code captured
        /// before running exhaustion check).
        var capturedValueUpdates: [PartialKeyPath<Root>: [ValueUpdate]]?
    }

    func expect(settleResetting: _ExhaustivityBits? = nil, at fileAndLine: FileAndLine, predicates: [AssertBuilder.Predicate], enableExhaustionTest: Bool = true) async {
        await expect(timeoutNanoseconds: Self.expectDefaultBudgetNs, settleResetting: settleResetting, at: fileAndLine, predicates: predicates, enableExhaustionTest: enableExhaustionTest)
    }

    func expect(timeoutNanoseconds timeout: UInt64, settleResetting: _ExhaustivityBits? = nil, at fileAndLine: FileAndLine, predicates: [AssertBuilder.Predicate], enableExhaustionTest: Bool = true) async {
        let context = TesterAssertContext(events: { self.lock { self.events } }, fileAndLine: fileAndLine)
        // Mutable across evaluations. Read after `awaitPredicate` returns
        // (success → use passedAccesses + capturedValueUpdates; timeout →
        // use failures). See `EvalSnapshot` doc-comment for the
        // synchronisation argument.
        let snapshot = EvalSnapshot()

        let startNs = nowMonotonicNs()
        let deadlineNs = startNs &+ timeout

        // The evaluator runs both initially (caller's thread) and on every
        // subsequent activity (writer thread, inside _noteActivity, under
        // TestAccess.lock). Returns true when the predicate is satisfied
        // AND the lastState IDs match (isEqualIncludingIds).
        //
        // `weak self` would force `self` Optional everywhere inside; we
        // hold a strong reference instead since the evaluator's lifetime
        // is bounded by the awaitPredicate await on this task.
        // EXPERIMENTAL (executor-drain quiescence): if model tasks are running on
        // a per-test harness executor, drive them to a fixpoint concurrently with
        // the reactive wait. Additive — the predicate still resolves reactively
        // the instant it's true (transients caught); this just guarantees forward
        // progress without depending on the wall clock, so a passing test resolves
        // deterministically under load. `nil` (no executor / pre-macOS-15) leaves
        // behaviour exactly as before.
        let executorDriver = _startExecutorDrive()
        let outcome = await self.awaitPredicate(deadlineNs: deadlineNs) { @Sendable [self] in
            TesterAssertContextBase.$assertContext.withValue(context) {
                usingActiveAccess(self) {
                    self._evaluateExpect(predicates: predicates, context: context, snapshot: snapshot)
                }
            }
        }
        executorDriver?.cancel()

        switch outcome {
        case .passed:
            // Latest eval succeeded. Snapshot's passedAccesses +
            // capturedValueUpdates were stored under TestAccess.lock by
            // the evaluator at that moment, so they're consistent.
            let capturedUpdates = snapshot.capturedValueUpdates

            if let resetting = settleResetting {
                // Settling mode: predicate passed; now wait for the model
                // to quiet down before resetting exhaustivity.
                let settled = await waitUntilSettled(at: fileAndLine)
                if !settled { return }
                _applyResetting(resetting)
                return
            }

            if enableExhaustionTest && !exhaustivity.contains(.transitions) {
                // Run exhaustion check OUTSIDE the lock — diffMessage walks
                // model state via customMirror → willAccess → lock, which
                // would deadlock cross-thread (NSRecursiveLock not
                // reentrant across threads).
                checkExhaustion(at: fileAndLine, includeUpdates: true, capturedUpdates: capturedUpdates)
            }
            return

        case .timeout:
            // Latest eval failed. Snapshot.failures is what to report.
            // Fall through to common failure-reporting block below.
            break

        case .cancelled:
            // Per-test trait cap fired (or external cancel). The trait
            // already recorded `[TRAIT timeout]`. Just unwind.
            return
        }

        // ----- Failure reporting (timeout case only) -----
        // All reporting (diffMessage, customDump, fail) happens outside
        // the lock. diffMessage triggers customMirror on @Model types,
        // which reads @ModelTracked properties, which calls willAccess →
        // rootPaths → acquires the same lock — deadlock if held.
        var reports: [[(String, FileAndLine)]] = []
        for failure in snapshot.failures {
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

        // Apply state mutations under the lock (no diffMessage here).
        lock {
            expectedState = lastState

            for access in snapshot.passedAccesses {
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

    /// The actual predicate-evaluation logic, factored out so `expect`'s
    /// `awaitPredicate` evaluator stays small. Must be called with the
    /// caller having set up `TesterAssertContextBase.$assertContext` and
    /// `usingActiveAccess(self)`. Returns true when:
    ///   1. All predicates returned true
    ///   2. `isEqualIncludingIds` succeeded (lastState matches the read
    ///      values — guards against backgroundCall-in-flight stale reads)
    ///
    /// Writes the latest eval's state into `snapshot` so the caller can
    /// report success/failure details.
    ///
    /// This runs INSIDE `TestAccess.lock` (the evaluator is called from
    /// `_noteActivity` and `awaitPredicate`'s initial check, both holding
    /// the lock). NSRecursiveLock allows re-entry on the same thread, so
    /// predicate reads that fire `willAccess → self.lock` are fine.
    fileprivate func _evaluateExpect(
        predicates: [AssertBuilder.Predicate],
        context: TesterAssertContext,
        snapshot: EvalSnapshot
    ) -> Bool {
        // Defensive: clear any stale transition override from prior eval.
        threadLocals.transitionOverrideValue = nil

        // Snapshot valueUpdates entry counts before predicate evaluation.
        // Paths that gain new entries during evaluation had side-effect
        // writes (e.g. `accessCount += 1` inside a computed getter). These
        // must be skipped in isEqualIncludingIds because capturedValue is
        // pre-write but lastState is post-write.
        let prePredicateUpdateCounts: [AnyKeyPath: Int] = {
            var counts: [AnyKeyPath: Int] = [:]
            for (path, entries) in self.valueUpdates {
                counts[path] = entries.count
            }
            return counts
        }()

        // Fresh per-eval bookkeeping.
        context.eventsSent.removeAll()
        context.probes.removeAll(keepingCapacity: true)

        // Reset snapshot for this eval — previous eval may have left
        // stale failures/passedAccesses that no longer apply.
        snapshot.failures.removeAll(keepingCapacity: true)
        snapshot.passedAccesses.removeAll(keepingCapacity: true)
        snapshot.capturedValueUpdates = nil

        // Step 1: Evaluate all predicates.
        for predicate in predicates {
            context.predicate = predicate
            context.accesses.removeAll(keepingCapacity: true)
            context.eventsNotSent.removeAll(keepingCapacity: true)
            context.modelsNoLongerPartOfTester.removeAll(keepingCapacity: true)

            let passed = predicate.predicate()
            let accesses = context.accesses
            if passed {
                snapshot.passedAccesses += accesses
            } else {
                snapshot.failures.append(.init(
                    predicate: predicate,
                    accesses: accesses,
                    events: context.eventsNotSent,
                    modelsNoLongerPartOfTester: context.modelsNoLongerPartOfTester,
                    probes: context.probes
                ))
                break
            }
        }

        if !snapshot.failures.isEmpty {
            return false
        }

        // Step 2: isEqualIncludingIds — verify lastState matches the
        // captured values. Detects transient passes where the
        // backgroundCall pipeline hasn't yet committed.
        let isEqualIncludingIds: Bool = {
            guard !snapshot.passedAccesses.isEmpty else { return true }
            return threadLocals.withValue(true, at: \.isApplyingSnapshot) {
                threadLocals.withValue(true, at: \.forceDirectAccess) {
                    threadLocals.withValue(true, at: \.includeImplicitIDInMirror) {
                        snapshot.passedAccesses.reduce(true) { result, access in
                            if access.skipEqualityCheck { return result }
                            if access.isModelTypeValue { return result }
                            if access.isContainerTypeValue { return result }
                            if exhaustivity.contains(.transitions) && valueUpdates[access.path] != nil { return result }
                            if let currentCount = valueUpdates[access.path]?.count,
                               currentCount > (prePredicateUpdateCounts[access.path] ?? 0) { return result }
                            let a = lastState[keyPath: access.path]
                            let d = diff(access.capturedValue(), a)
                            return result && d == nil
                        }
                    }
                }
            }
        }()

        if !isEqualIncludingIds {
            // Predicate passed but pending bg drain hasn't committed.
            // Wait for next activity — the bg drain will fire didModify,
            // which fires _noteActivity, which re-invokes us. Keep
            // passedAccesses in the snapshot so timeout-time reporting
            // has the latest captured state.
            return false
        }


        // Step 3: Success! Clear asserted paths from valueUpdates,
        // advance expectedState, consume events and probes — exactly
        // what the old success path did under TestAccess.lock (we ARE
        // under the lock).
        expectedState = lastState
        let isTransitions = exhaustivity.contains(.transitions)
        for access in snapshot.passedAccesses {
            if valueUpdates[access.path] != nil {
                if isTransitions {
                    valueUpdates[access.path]!.removeFirst()
                    if valueUpdates[access.path]!.isEmpty {
                        valueUpdates[access.path] = nil
                    }
                } else {
                    valueUpdates[access.path] = nil
                }
            }
            access.additionalCleanup?()
        }
        for index in context.eventsSent.reversed() { events.remove(at: index) }
        for (probe, value) in context.probes {
            probe.consume(value)
        }

        // Capture valueUpdates after clearing so the exhaustion check
        // (which runs OUTSIDE the lock after we return) sees a stable
        // snapshot.
        snapshot.capturedValueUpdates = valueUpdates
        return true
    }

    /// Tries `expression` until it returns a non-nil value, then returns
    /// the unwrapped result. Reactive wake-up on each model write / event
    /// / probe call via `awaitPredicate`. After `expectDefaultBudgetNs`
    /// of no successful evaluation, fails with `UnwrapError`.
    /// Predicates that depend on external state (non-tracked values)
    /// should use `waitUntil` instead.
    ///
    /// **Note**: the evaluator returns `Bool` (not `T?`) to avoid
    /// requiring `T: Sendable`. After `awaitPredicate` resolves with
    /// `.passed`, we re-evaluate `expression` on the caller's task to
    /// obtain the value. Costs one extra evaluation but keeps the
    /// public API T-agnostic.
    func require<T>(_ expression: @escaping @Sendable () -> T?, at fileAndLine: FileAndLine) async throws -> T {
        let startNs = nowMonotonicNs()
        let deadlineNs = startNs &+ Self.expectDefaultBudgetNs

        let outcome = await self.awaitPredicate(deadlineNs: deadlineNs) { @Sendable in
            expression() != nil
        }

        switch outcome {
        case .passed:
            // Re-evaluate on this task to get the value. The expression
            // passed at least once during awaitPredicate so it should
            // still pass here; if it doesn't (unusual race where state
            // briefly toggled), we fall through to defensive failure.
            guard let value = expression() else {
                fail("require: predicate passed during await but value is now nil", at: fileAndLine)
                throw UnwrapError()
            }
            // Drive the same settled-state stability check as expect
            // (uses isEqualIncludingIds + exhaustion-free expect plumbing).
            let predicate = AssertBuilder.Predicate(predicate: { expression() != nil }, fileAndLine: fileAndLine)
            await expect(timeoutNanoseconds: Self.expectDefaultBudgetNs, at: fileAndLine, predicates: [predicate], enableExhaustionTest: false)
            return value

        case .timeout:
            fail("Failed to unwrap value of type \(T.self)", at: fileAndLine)
            throw UnwrapError()

        case .cancelled:
            // Trait cap fired; unwind without recording another issue.
            throw UnwrapError()
        }
    }
}
