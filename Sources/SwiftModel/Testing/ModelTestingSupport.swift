import Foundation
#if canImport(Dispatch)
import Dispatch
#endif
import IssueReporting

/// Returns the current monotonic time in nanoseconds.
/// Uses DispatchTime on platforms that have it (Darwin, Linux, Android);
/// falls back to ProcessInfo.systemUptime on WASI.
private func monotonicNanoseconds() -> UInt64 {
    #if canImport(Dispatch)
    return DispatchTime.now().uptimeNanoseconds
    #else
    return UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    #endif
}

// MARK: - Type-erased model test scope

/// Internal protocol that type-erases a `ModelTester<M>` so the trait and global
/// functions can hold a reference without knowing the concrete root model type.
package protocol _AnyModelTestScope: AnyObject, Sendable {
    func assert(
        settleResetting: _ExhaustivityBits?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        predicates: [AssertBuilder.Predicate]
    ) async

    func require<T>(
        _ expression: @escaping @Sendable () -> T?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async throws -> T

    func install(_ probes: [TestProbe])
    func checkExhaustion(at fileAndLine: FileAndLine) async
    func cancelAndCleanup()
    func waitForTeardown() async
    var exhaustivity: _ExhaustivityBits { get set }
}

// MARK: - Task-local test scope

package enum _ModelTestingLocals {
    /// Set by `_ModelTestingTrait.provideScope` for the duration of the test body.
    /// `withAnchor()` reads this to detect whether a `.modelTesting` test scope is active.
    @TaskLocal package static var scope: (any _AnyModelTestScope)? = nil
}

// MARK: - Pending scope registration

/// Placeholder stored in the task-local while `provideScope` is running, before
/// `withAnchor()` has been called and the root model type is known.
package final class _PendingModelTestScope: _AnyModelTestScope, @unchecked Sendable {
    private let lock = NSLock()
    private var _concrete: (any _AnyModelTestScope)?
    private var _registrationFileAndLine: FileAndLine?
    /// Probes registered before `withAnchor()` was called (before concrete scope exists).
    /// Flushed to the concrete scope when it is registered.
    private var _pendingProbes: [TestProbe] = []

    /// Initial exhaustivity from the trait that created this scope.
    /// Passed to `withAnchor()` so the tester is configured correctly,
    /// and used as the starting value for the mutable `exhaustivity` property.
    package let initialExhaustivity: _ExhaustivityBits
    package let dependencies: @Sendable (inout ModelDependencies) -> Void

    package init(exhaustivity: _ExhaustivityBits, dependencies: @escaping @Sendable (inout ModelDependencies) -> Void) {
        self.initialExhaustivity = exhaustivity
        self._exhaustivity = exhaustivity
        self.dependencies = dependencies
    }

    func register(_ concrete: any _AnyModelTestScope, at fileAndLine: FileAndLine) {
        let probestoFlush: [TestProbe] = lock.withLock {
            if _concrete != nil {
                // Multiple withAnchor() calls in one .modelTesting test — only first is root.
                return []
            }
            _concrete = concrete
            _registrationFileAndLine = fileAndLine
            let pending = _pendingProbes
            _pendingProbes = []
            return pending
        }
        // Flush probes that were registered before withAnchor() was called.
        if !probestoFlush.isEmpty {
            concrete.install(probestoFlush)
        }
    }

    package var concrete: (any _AnyModelTestScope)? { lock.withLock { _concrete } }
    package var registrationFileAndLine: FileAndLine? { lock.withLock { _registrationFileAndLine } }

    package func assert(settleResetting: _ExhaustivityBits? = nil, fileID: StaticString, filePath: StaticString, line: UInt, column: UInt, predicates: [AssertBuilder.Predicate]) async {
        guard let c = concrete else {
            reportIssue("No model was anchored in this .modelTesting test. Call withAnchor() first.", fileID: fileID, filePath: filePath, line: line, column: column)
            return
        }
        await c.assert(settleResetting: settleResetting, fileID: fileID, filePath: filePath, line: line, column: column, predicates: predicates)
    }

    package func require<T>(_ expression: @escaping @Sendable () -> T?, fileID: StaticString, filePath: StaticString, line: UInt, column: UInt) async throws -> T {
        guard let c = concrete else {
            reportIssue("No model was anchored in this .modelTesting test. Call withAnchor() first.", fileID: fileID, filePath: filePath, line: line, column: column)
            throw UnwrapError()
        }
        return try await c.require(expression, fileID: fileID, filePath: filePath, line: line, column: column)
    }

    package func install(_ probes: [TestProbe]) {
        let forwarded: Bool = lock.withLock {
            if let c = _concrete {
                // Concrete scope already registered — forward directly (outside lock below).
                _ = c  // capture
                return true
            }
            // Buffer for later flush when withAnchor() registers the concrete scope.
            _pendingProbes.append(contentsOf: probes)
            return false
        }
        if forwarded {
            // Forward outside the lock to avoid deadlock.
            concrete?.install(probes)
        }
    }

    package func checkExhaustion(at fileAndLine: FileAndLine) async {
        await concrete?.checkExhaustion(at: fileAndLine)
    }

    package func cancelAndCleanup() {
        concrete?.cancelAndCleanup()
    }

    package func waitForTeardown() async {
        await concrete?.waitForTeardown()
    }

    package var exhaustivity: _ExhaustivityBits {
        get { lock.withLock { _concrete?.exhaustivity ?? _exhaustivity } }
        set { lock.withLock {
            _exhaustivity = newValue
            _concrete?.exhaustivity = newValue
        }}
    }
    private var _exhaustivity: _ExhaustivityBits = .full
}

// MARK: - Concrete type-erased scope

/// Concrete type-erased wrapper around `ModelTester<M>`.
package final class _ConcreteModelTestScope<M: Model>: _AnyModelTestScope, @unchecked Sendable {
    package let tester: ModelTester<M>

    package init(tester: ModelTester<M>) {
        self.tester = tester
    }

    package func assert(
        settleResetting: _ExhaustivityBits? = nil,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        predicates: [AssertBuilder.Predicate]
    ) async {
        await tester.access.expect(
            settleResetting: settleResetting,
            at: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column),
            predicates: predicates
        )
    }

    package func require<T>(
        _ expression: @escaping @Sendable () -> T?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async throws -> T {
        try await tester.access.require(
            expression,
            at: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }

    package func install(_ probes: [TestProbe]) {
        for probe in probes {
            tester.access.install(probe)
        }
    }

    package func checkExhaustion(at fileAndLine: FileAndLine) async {
        // Mark tester so its deinit skips cleanup — we are running it here instead.
        tester.cleanupHandledExternally = true

        // Reuse the latency measured during the test body (expect/settle/require all
        // update the cache). This avoids a fresh GCD hop here — which, under 500+
        // parallel tests, would flood the global queue and add ~2 s to every test.
        let cal = tester.access.calibrateWithCachedLatency()

        // Phase 1: Seal — prevent any new task registrations across the entire context
        // hierarchy. After sealing, Cancellations.register() immediately calls
        // onCancel() on incoming registrations and does NOT add them to `registered`.
        //
        // Sealing first (before any drain or cancel) closes the race where a
        // cooperatively-cancelled forEach task writes to the model AFTER cancellation,
        // causing new child-model activations: those activations call register() on the
        // already-sealed store and are immediately cancelled, so they never appear as
        // "still running" in the exhaustion check.
        //
        // Previously a waitUntilIdle() drain preceded sealing, but that required the
        // GCD backgroundCall queue to become completely empty — which under 500+
        // parallel tests can take up to hardCap seconds per test and causes CI timeouts.
        // The seal makes that drain unnecessary.
        tester.access.context.sealRecursively()

        // Phase 2: Cancel all currently-registered onActivate tasks.
        tester.access.context.cancelAllRecursively(for: ContextCancellationKey.onActivate)

        // Phase 3: Wait for naturally-completing tasks to finish and drain any remaining
        // backgroundCall writes.
        //
        // Tasks created during GCD-drain activation run in a non-async context
        // (no Swift Task active), so AnyCancellable.contexts is empty and these
        // tasks are NOT keyed with .onActivate. cancelAllRecursively(for: .onActivate)
        // does not cancel them; they must complete on their own cooperative-pool turns.
        //
        // waitUntilSettled uses GCD-backed waitForModification (not Task.yield loops)
        // so it is safe under 500+ parallel test load.
        await tester.access.waitUntilSettled(calibration: cal, reportTimeout: false, at: fileAndLine)

        tester.access.checkExhaustion(at: fileAndLine, includeUpdates: false, checkTasks: true)
        tester.access.context.onRemoval()
    }

    package func cancelAndCleanup() {
        // Mark tester so its deinit skips cleanup — we are running it here instead.
        tester.cleanupHandledExternally = true
        tester.access.context.cancelAllRecursively(for: ContextCancellationKey.onActivate)
        tester.access.context.onRemoval()
    }

    package func waitForTeardown() async {
        // Wait for the backgroundCall drain queue to finish processing any teardown
        // side-effects (onCancel callbacks, stream finalizations) that were dispatched
        // during onRemoval(). This ensures post-teardown assertions see final state.
        //
        // Use a 30-second deadline to prevent an indefinite hang.
        let deadline = monotonicNanoseconds() + 30_000_000_000
        await backgroundCall.waitUntilIdle(deadline: deadline)
    }

    package var exhaustivity: _ExhaustivityBits {
        get { tester.access.lock { tester.access.exhaustivity } }
        set { tester.access.lock { tester.access.exhaustivity = newValue } }
    }
}
