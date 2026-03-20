import Foundation
import IssueReporting

// MARK: - Type-erased model test scope

/// Internal protocol that type-erases a `ModelTester<M>` so the trait and global
/// functions can hold a reference without knowing the concrete root model type.
package protocol _AnyModelTestScope: AnyObject, Sendable {
    func assert(
        timeoutNanoseconds: UInt64,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        predicates: [AssertBuilder.Predicate]
    ) async

    func unwrap<T>(
        _ expression: @escaping @Sendable () -> T?,
        timeoutNanoseconds: UInt64,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async throws -> T

    func install(_ probes: [TestProbe])
    func checkExhaustion(at fileAndLine: FileAndLine)
    func cancelAndCleanup()
    func waitForTeardown() async
    var exhaustivity: Exhaustivity { get set }
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
    package let initialExhaustivity: Exhaustivity
    package let dependencies: @Sendable (inout ModelDependencies) -> Void

    package init(exhaustivity: Exhaustivity, dependencies: @escaping @Sendable (inout ModelDependencies) -> Void) {
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

    package func assert(timeoutNanoseconds: UInt64, fileID: StaticString, filePath: StaticString, line: UInt, column: UInt, predicates: [AssertBuilder.Predicate]) async {
        guard let c = concrete else {
            reportIssue("No model was anchored in this .modelTesting test. Call withAnchor() first.", fileID: fileID, filePath: filePath, line: line, column: column)
            return
        }
        await c.assert(timeoutNanoseconds: timeoutNanoseconds, fileID: fileID, filePath: filePath, line: line, column: column, predicates: predicates)
    }

    package func unwrap<T>(_ expression: @escaping @Sendable () -> T?, timeoutNanoseconds: UInt64, fileID: StaticString, filePath: StaticString, line: UInt, column: UInt) async throws -> T {
        guard let c = concrete else {
            reportIssue("No model was anchored in this .modelTesting test. Call withAnchor() first.", fileID: fileID, filePath: filePath, line: line, column: column)
            throw UnwrapError()
        }
        return try await c.unwrap(expression, timeoutNanoseconds: timeoutNanoseconds, fileID: fileID, filePath: filePath, line: line, column: column)
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

    package func checkExhaustion(at fileAndLine: FileAndLine) {
        concrete?.checkExhaustion(at: fileAndLine)
    }

    package func cancelAndCleanup() {
        concrete?.cancelAndCleanup()
    }

    package func waitForTeardown() async {
        await concrete?.waitForTeardown()
    }

    package var exhaustivity: Exhaustivity {
        get { lock.withLock { _concrete?.exhaustivity ?? _exhaustivity } }
        set { lock.withLock {
            _exhaustivity = newValue
            _concrete?.exhaustivity = newValue
        }}
    }
    private var _exhaustivity: Exhaustivity = .full
}

// MARK: - Concrete type-erased scope

/// Concrete type-erased wrapper around `ModelTester<M>`.
package final class _ConcreteModelTestScope<M: Model>: _AnyModelTestScope, @unchecked Sendable {
    package let tester: ModelTester<M>

    package init(tester: ModelTester<M>) {
        self.tester = tester
    }

    package func assert(
        timeoutNanoseconds: UInt64,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        predicates: [AssertBuilder.Predicate]
    ) async {
        await tester.access.assert(
            timeoutNanoseconds: timeoutNanoseconds,
            at: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column),
            predicates: predicates
        )
    }

    package func unwrap<T>(
        _ expression: @escaping @Sendable () -> T?,
        timeoutNanoseconds: UInt64,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) async throws -> T {
        try await tester.access.unwrap(
            expression,
            timeoutNanoseconds: timeoutNanoseconds,
            at: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        )
    }

    package func install(_ probes: [TestProbe]) {
        for probe in probes {
            tester.access.install(probe)
        }
    }

    package func checkExhaustion(at fileAndLine: FileAndLine) {
        // Mark tester so its deinit skips cleanup — we are running it here instead.
        tester.cleanupHandledExternally = true
        tester.access.context.cancelAllRecursively(for: ContextCancellationKey.onActivate)
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
        await backgroundCall.waitUntilIdle()
    }

    package var exhaustivity: Exhaustivity {
        get { tester.exhaustivity }
        set { tester.exhaustivity = newValue }
    }
}
