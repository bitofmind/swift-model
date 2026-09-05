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
    /// Provenance appended to this scope's exhaustion failures — see
    /// `_PendingModelTestScope.exhaustionNote`.
    func setExhaustionNote(_ note: String?)
    func cancelAndCleanup()
    func waitForTeardown() async
    var exhaustivity: _ExhaustivityBits { get set }
    /// Monotonic-ns of this test's most recent non-executor progress (model
    /// activity, main/background observation drains — `TestAccess._progressNs`).
    /// Feeds the trait cap's inactivity watchdog; `0` when unknown.
    var progressNs: UInt64 { get }
    /// The root model type this scope is bound to. Used only to name the models in
    /// the duplicate-`withAnchor()` diagnostic, so it is never computed on a hot path.
    var rootModelTypeName: String { get }
}

// MARK: - Task-local test scope

package enum _ModelTestingLocals {
    /// Set by `ModelTestingTrait.provideScope` for the duration of the test body.
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

    /// Appended to every exhaustion failure raised in this scope, naming the scope that
    /// set the exhaustivity policy. Set only when the scope *overrode* what it inherited:
    /// without it a failure points at the `withAnchor()` line and says nothing about the
    /// policy or where it came from, which reads as "the enclosing trait didn't apply".
    package let exhaustionNote: String?

    package init(
        exhaustivity: _ExhaustivityBits,
        dependencies: @escaping @Sendable (inout ModelDependencies) -> Void,
        exhaustionNote: String? = nil
    ) {
        self.initialExhaustivity = exhaustivity
        self._exhaustivity = exhaustivity
        self.dependencies = dependencies
        self.exhaustionNote = exhaustionNote
    }

    /// Connects the first `withAnchor()` of a scope as its root, and reports the second.
    ///
    /// A test scope tracks exactly one root: `expect`/`require` wake on that root's
    /// `TestAccess` activity, and exhaustion is checked against its tree. A second
    /// `withAnchor()` therefore cannot be adopted — and because nothing retains the tester
    /// built for it, it is deallocated on return from `withAnchor()`, which tears its
    /// context down. Undiagnosed, that surfaces as a live-looking model whose writes
    /// vanish, so the rejection names both call sites and the ways out.
    func register(_ concrete: any _AnyModelTestScope, at fileAndLine: FileAndLine) {
        enum Outcome {
            case adopted([TestProbe])
            case rejected(first: any _AnyModelTestScope, at: FileAndLine?)
        }
        let outcome: Outcome = lock.withLock {
            if let existing = _concrete {
                return .rejected(first: existing, at: _registrationFileAndLine)
            }
            _concrete = concrete
            _registrationFileAndLine = fileAndLine
            let pending = _pendingProbes
            _pendingProbes = []
            return .adopted(pending)
        }
        switch outcome {
        case let .rejected(first, firstFileAndLine):
            reportDuplicateAnchor(
                first: first,
                firstFileAndLine: firstFileAndLine,
                second: concrete,
                secondFileAndLine: fileAndLine
            )
            // Tear the rejected root down here rather than leaving it to the tester's
            // deinit, which would also run an exhaustion check on a model the scope never
            // tracked — a second, misleading failure on top of the one above.
            concrete.cancelAndCleanup()

        case let .adopted(probesToFlush):
            // Only the root registration adopts the scope's probes and exhaustion note.
            // Flush probes that were registered before withAnchor() was called.
            if !probesToFlush.isEmpty {
                concrete.install(probesToFlush)
            }
            if let exhaustionNote {
                concrete.setExhaustionNote(exhaustionNote)
            }
        }
    }

    private func reportDuplicateAnchor(
        first: any _AnyModelTestScope,
        firstFileAndLine: FileAndLine?,
        second: any _AnyModelTestScope,
        secondFileAndLine: FileAndLine
    ) {
        let firstName = first.rootModelTypeName
        let secondName = second.rootModelTypeName
        let firstSite = firstFileAndLine.map { " at \($0.fileID):\($0.line)" } ?? ""
        reportIssue(
            """
            withAnchor() was already called in this test scope, by \(firstName)\(firstSite). \
            A scope tracks exactly one anchored root, so this \(secondName) is not connected to \
            it: it is torn down as withAnchor() returns, and its writes, events and tasks are \
            dropped — expect { } and exhaustivity never see them.

            Ways out, in order of preference:
            • Make \(secondName) a child of the anchored \(firstName). One tree per scope is the \
            supported shape, and expect { } then covers both models.
            • Keep \(secondName) live but untracked: let (model, anchor) = \
            \(secondName)().returningAnchor(), holding the anchor for as long as the test needs \
            the model. This is the fit for peers that must run at the same time — wired to each \
            other, but with the test asserting only through \(firstName). expect { } will not \
            wake on \(secondName)'s activity; that is the whole trade.
            • Give it a scope of its own: await withModelTesting { \(secondName)().withAnchor() … }. \
            Scopes nest sequentially, so this fits phases that follow one another — snapshot from \
            one root, restore into a fresh one — rather than roots that must be live together. The \
            inner model is torn down when its closure returns, and expect { } inside it sees only \
            that model.
            """,
            fileID: secondFileAndLine.fileID,
            filePath: secondFileAndLine.filePath,
            line: secondFileAndLine.line,
            column: secondFileAndLine.column
        )
    }

    package var concrete: (any _AnyModelTestScope)? { lock.withLock { _concrete } }
    package var registrationFileAndLine: FileAndLine? { lock.withLock { _registrationFileAndLine } }

    /// Forwards to the concrete scope once `withAnchor()` has registered one;
    /// `0` before that (the trait cap's window then rests on executor activity
    /// alone, exactly as before this signal existed).
    package var progressNs: UInt64 { concrete?.progressNs ?? 0 }

    package var rootModelTypeName: String { concrete?.rootModelTypeName ?? "an unregistered model" }

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

    package func setExhaustionNote(_ note: String?) {
        concrete?.setExhaustionNote(note)
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

    package var progressNs: UInt64 { tester.access._progressNs }

    package var rootModelTypeName: String { String(describing: M.self) }

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

    package func setExhaustionNote(_ note: String?) {
        tester.access.setExhaustionNote(note)
    }

    package func checkExhaustion(at fileAndLine: FileAndLine) async {
        // Mark tester so its deinit skips cleanup — we are running it here instead.
        tester.cleanupHandledExternally = true

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

        // Phase 3: Wait for naturally-completing tasks to commit any final
        // writes, then verify nothing's still arriving. Debounce on model
        // writes / events with the cleanup window (longer than in-test
        // settle, to absorb cancel-handler writes that may take time).
        await tester.access.waitUntilSettled(cleanup: true, at: fileAndLine)

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
