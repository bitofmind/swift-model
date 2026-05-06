#if canImport(Testing) && compiler(>=6)
import Testing
import IssueReporting

// MARK: - Global expect / require / settle / withExhaustivity

/// Asserts — within a `@Test(.modelTesting)` test — that all predicates in the builder
/// pass and that no unasserted side effects remain.
///
/// Mirrors the behaviour of Swift Testing's `#expect`: on failure the issue is recorded
/// but the test continues.
///
/// ```swift
/// @Test(.modelTesting) func example() async {
///     let model = CounterModel().withAnchor()
///     model.incrementTapped()
///     await expect { model.count == 1 }
/// }
/// ```
///
/// > Important: Must be called inside a `@Test(.modelTesting)` function. Calling outside
///   a model testing scope reports an issue.
public func expect(
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column,
    @AssertBuilder _ builder: @Sendable () -> AssertBuilder.Result
) async {
    guard let scope = _ModelTestingLocals.scope else {
        reportIssue("expect() must be called inside a @Test(.modelTesting) test function", fileID: fileID, filePath: filePath, line: line, column: column)
        return
    }
    await scope.assert(
        settleResetting: nil,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column,
        predicates: builder()
    )
}

/// Single-predicate convenience overload of `expect` for a plain `Bool` expression.
///
/// ```swift
/// await expect(model.count == 1)
/// ```
///
/// > Important: Must be called inside a `@Test(.modelTesting)` function.
@_disfavoredOverload
public func expect(
    _ predicate: @escaping @Sendable @autoclosure () -> Bool,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async {
    await expect(fileID: fileID, filePath: filePath, line: line, column: column) {
        predicate()
    }
}

/// Single-predicate convenience overload of `expect` for a `TestPredicate`.
/// Provides a pretty-printed diff on failure.
///
/// ```swift
/// await expect(model.count == 1)
/// ```
///
/// > Important: Must be called inside a `@Test(.modelTesting)` function.
public func expect(
    _ predicate: TestPredicate,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async {
    await expect(fileID: fileID, filePath: filePath, line: line, column: column) {
        predicate
    }
}

// MARK: - settle

/// Waits for the model to settle — all activation tasks enter their body, the model
/// becomes idle (no state changes for one scheduling round) — then resets selected
/// exhaustivity categories so subsequent `expect {}` calls start from a clean baseline.
///
/// Use `settle()` without predicates after anchoring to skip past activation side effects:
///
/// ```swift
/// @Test(.modelTesting) func example() async {
///     let model = ItemListModel().withAnchor()
///     await settle()  // activation did its thing — start fresh
///     model.selectItem(id: model.items[0].id)
///     await expect { model.selectedItem != nil }
/// }
/// ```
///
/// Pass a predicate to verify the model reached an expected state before resetting:
///
/// ```swift
/// await settle { model.items.count > 0 }
/// ```
///
/// Use `resetting:` to control which exhaustivity categories are reset. By default
/// all categories are reset. Pass a subset to keep tracking specific categories
/// across the settle boundary:
///
/// ```swift
/// await settle(resetting: .full.removing(.events)) { model.items.count > 0 }
/// // Events from activation are still tracked — assert them in the next expect.
/// await expect { model.didSend(.didLoad) }
/// ```
///
/// > Important: Must be called inside a `@Test(.modelTesting)` function.
public func settle(
    resetting: Exhaustivity = .full,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column,
    @AssertBuilder _ builder: @Sendable () -> AssertBuilder.Result
) async {
    guard let scope = _ModelTestingLocals.scope else {
        reportIssue("settle() must be called inside a @Test(.modelTesting) test function", fileID: fileID, filePath: filePath, line: line, column: column)
        return
    }
    await scope.assert(
        settleResetting: resetting.apply(to: .full),
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column,
        predicates: builder()
    )
}

/// Settles the model without any predicate — waits for activation tasks and idle cycle,
/// then resets selected exhaustivity categories.
///
/// ```swift
/// let model = MyModel().withAnchor()
/// await settle()  // skip past activation side effects
/// ```
///
/// > Important: Must be called inside a `@Test(.modelTesting)` function.
public func settle(
    resetting: Exhaustivity = .full,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async {
    guard let scope = _ModelTestingLocals.scope else {
        reportIssue("settle() must be called inside a @Test(.modelTesting) test function", fileID: fileID, filePath: filePath, line: line, column: column)
        return
    }
    await scope.assert(
        settleResetting: resetting.apply(to: .full),
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column,
        predicates: []
    )
}

/// Single-predicate settling overload for a plain `Bool` expression.
///
/// ```swift
/// await settle(model.items.count > 0)
/// ```
///
/// > Important: Must be called inside a `@Test(.modelTesting)` function.
@_disfavoredOverload
public func settle(
    _ predicate: @escaping @Sendable @autoclosure () -> Bool,
    resetting: Exhaustivity = .full,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async {
    await settle(resetting: resetting, fileID: fileID, filePath: filePath, line: line, column: column) {
        predicate()
    }
}

/// Single-predicate settling overload for a `TestPredicate`.
///
/// > Important: Must be called inside a `@Test(.modelTesting)` function.
public func settle(
    _ predicate: TestPredicate,
    resetting: Exhaustivity = .full,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async {
    await settle(resetting: resetting, fileID: fileID, filePath: filePath, line: line, column: column) {
        predicate
    }
}

// MARK: - require

/// Unwraps an optional value — within a `@Test(.modelTesting)` test — waiting for it to
/// become non-nil.
///
/// Mirrors the behaviour of Swift Testing's `#require`: on failure the issue is recorded
/// and the test stops (throws). Returns the unwrapped value on success.
///
/// ```swift
/// @Test(.modelTesting) func example() async throws {
///     let model = MyModel().withAnchor()
///     model.loadButtonTapped()
///     let item = try await require(model.selectedItem)
///     await expect { item.name == "Expected" }
/// }
/// ```
///
/// > Important: Must be called inside a `@Test(.modelTesting)` function. Calling outside
///   a model testing scope reports an issue and throws.
public func require<T>(
    _ expression: @escaping @Sendable @autoclosure () -> T?,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async throws -> T {
    guard let scope = _ModelTestingLocals.scope else {
        reportIssue("require() must be called inside a @Test(.modelTesting) test function", fileID: fileID, filePath: filePath, line: line, column: column)
        throw UnwrapError()
    }
    return try await scope.require(
        expression,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

/// Runs `body` with exhaustivity set by the given modifier for the active `.modelTesting` scope.
///
/// Any calls to `expect { }` inside `body` will use the modified exhaustivity. When `body`
/// returns the previous exhaustivity is restored.
///
/// Use absolute presets to override the current exhaustivity entirely:
/// ```swift
/// await withExhaustivity(.off) {
///     model.triggerSideEffects()  // nothing checked inside
/// }
/// ```
///
/// Use relative modifiers to adjust the current exhaustivity without replacing it:
/// ```swift
/// @Suite(.modelTesting(.removing(.events)))
/// struct MyTests {
///     @Test func example() async {
///         // Add events back temporarily for this block:
///         await withExhaustivity(.adding(.events)) {
///             model.doSomething()
///             await expect { model.didSend(.tapped) }
///         }
///     }
/// }
/// ```
///
/// > Important: Must be called inside a `@Test(.modelTesting)` function.
public func withExhaustivity(
    _ modifier: Exhaustivity,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column,
    _ body: @Sendable () async throws -> Void
) async rethrows {
    guard let scope = _ModelTestingLocals.scope else {
        reportIssue("withExhaustivity() must be called inside a @Test(.modelTesting) test function", fileID: fileID, filePath: filePath, line: line, column: column)
        try await body()
        return
    }
    let previous = scope.exhaustivity
    scope.exhaustivity = modifier.apply(to: previous)
    defer { scope.exhaustivity = previous }
    try await body()
}

// MARK: - withModelTesting scope function

/// Creates an inline model-testing scope for exhaustive testing within a single test function.
///
/// Use `withModelTesting` instead of `@Test(.modelTesting)` when you need to assert on
/// deallocation side-effects — because the scope tears the model down when the closure
/// returns, before the test function exits.
///
/// ```swift
/// @Test func testTeardown() async {
///     let testResult = TestResult()
///     await withModelTesting {
///         let model = TrackedModel().withAnchor {
///             $0.testResult = testResult
///         }
///         await expect { model.count == 0 }
///     }
///     // Model is torn down — onCancel callbacks have fired.
///     #expect(testResult.value.contains("done"))
/// }
/// ```
///
/// `withAnchor()` called inside the closure automatically connects to the scope.
/// Use the global `expect { }` and `require(_:)` functions to make assertions.
/// Exhaustion is checked when the closure returns, then all background teardown work
/// completes before `withModelTesting` itself returns.
///
/// Dependency overrides passed here are applied before any overrides in `withAnchor()`,
/// so `withAnchor`-level overrides win (same precedence as `.modelTesting(dependencies:)`).
///
/// - Parameters:
///   - exhaustivity: Exhaustivity modifier to apply. Defaults to `.full`. Pass an absolute
///     preset (`.off`, `.full`, `.state`) or a relative modifier (`.removing(.events)`).
///   - dependencies: A closure to override dependencies for all models anchored in this scope.
///   - body: The test body. Call `withAnchor()` inside to connect a model to the scope.
public func withModelTesting(
    exhaustivity: Exhaustivity = .full,
    dependencies: @escaping @Sendable (inout ModelDependencies) -> Void = { _ in },
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column,
    _ body: @Sendable () async throws -> Void
) async rethrows {
    try await _withModelTestingImpl(
        modifier: exhaustivity,
        dependencies: dependencies,
        fileID: fileID, filePath: filePath, line: line, column: column,
        body
    )
}

/// Creates an inline model-testing scope with an exhaustivity modifier.
///
/// The modifier is applied on top of the enclosing scope's exhaustivity, so nested
/// calls compose rather than reset:
///
/// ```swift
/// @Suite(.modelTesting(.removing(.events)))
/// struct MyTests {
///     @Test func example() async {
///         await withModelTesting(.removing(.tasks)) {
///             // exhaustivity = .full − .events − .tasks
///             let model = MyModel().withAnchor()
///             await expect { model.state == .ready }
///         }
///     }
/// }
/// ```
///
/// - Parameters:
///   − modifier: Applied on top of the enclosing scope's exhaustivity.
///   - dependencies: A closure to override dependencies for all models anchored in this scope.
///   - body: The test body. Call `withAnchor()` inside to connect a model.
public func withModelTesting(
    _ modifier: Exhaustivity,
    dependencies: @escaping @Sendable (inout ModelDependencies) -> Void = { _ in },
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column,
    _ body: @Sendable () async throws -> Void
) async rethrows {
    try await _withModelTestingImpl(
        modifier: modifier,
        dependencies: dependencies,
        fileID: fileID, filePath: filePath, line: line, column: column,
        body
    )
}

private func _withModelTestingImpl(
    modifier: Exhaustivity,
    dependencies: @escaping @Sendable (inout ModelDependencies) -> Void,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt,
    _ body: @Sendable () async throws -> Void
) async rethrows {
    let parentExhaustivity = _ModelTestingLocals.scope?.exhaustivity ?? .full
    let resolvedExhaustivity = modifier.apply(to: parentExhaustivity)
    // Compose with parent scope's dependencies so inner scopes inherit outer ones.
    // Inner dependencies are applied last so they win over the parent's (same precedence
    // as withAnchor-level overrides winning over scope-level overrides).
    let parentDependencies: @Sendable (inout ModelDependencies) -> Void
    if let parentScope = _ModelTestingLocals.scope as? _PendingModelTestScope {
        parentDependencies = parentScope.dependencies
    } else {
        parentDependencies = { _ in }
    }
    let mergedDependencies: @Sendable (inout ModelDependencies) -> Void = { deps in
        parentDependencies(&deps)
        dependencies(&deps)
    }
    let pending = _PendingModelTestScope(exhaustivity: resolvedExhaustivity, dependencies: mergedDependencies)
    let testQueue = BackgroundCallQueue()
    try await _BackgroundCallLocals.$queue.withValue(testQueue) {
        try await _ModelTestingLocals.$scope.withValue(pending) {
            try await body()
        }
        // After the body completes, run exhaustion checks and wait for all background
        // teardown work (onCancel callbacks, stream finalizations) to finish so that
        // post-scope assertions see the final state. Both run inside the task-local
        // scope so any backgroundCall work from onRemoval() uses the per-test queue.
        if let concrete = pending.concrete, let fl = pending.registrationFileAndLine {
            await concrete.checkExhaustion(at: fl)
            await concrete.waitForTeardown()
        }
    }
}

// MARK: - ModelTestingTrait

/// The trait that activates SwiftModel's testing infrastructure for a `@Test` or `@Suite`.
///
/// Use `.modelTesting` (or `.modelTesting(exhaustivity:)` / `.modelTesting(_:)`) as the
/// trait argument. Calling `withAnchor()` inside the test body automatically connects the
/// model and enables the global `expect { }`, `require(_:)`, and `withExhaustivity(_:_:)`
/// functions.
///
/// You do not usually reference `ModelTestingTrait` by name — use the `.modelTesting`
/// factory on `Trait` instead.
public struct ModelTestingTrait: Sendable {
    /// The exhaustivity modifier applied relative to the enclosing scope's exhaustivity.
    let modifier: Exhaustivity
    let dependencies: @Sendable (inout ModelDependencies) -> Void

    init(modifier: Exhaustivity, dependencies: @escaping @Sendable (inout ModelDependencies) -> Void) {
        self.modifier = modifier
        self.dependencies = dependencies
    }
}

#if swift(>=6.1)
extension ModelTestingTrait: TestScoping, TestTrait, SuiteTrait {
    public var isRecursive: Bool { true }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // Compose with any enclosing scope's exhaustivity so nested traits stack correctly:
        // @Suite(.modelTesting(.removing(.events)))  → .full − .events
        // @Test(.modelTesting(.removing(.tasks)))    → (.full − .events) − .tasks
        let parentExhaustivity = _ModelTestingLocals.scope?.exhaustivity ?? .full
        let resolvedExhaustivity = modifier.apply(to: parentExhaustivity)
        let pending = _PendingModelTestScope(exhaustivity: resolvedExhaustivity, dependencies: dependencies)
        // Give each test its own BackgroundCallQueue so parallel tests cannot observe
        // each other's in-flight Observed pipeline updates.
        let testQueue = BackgroundCallQueue()
        try await _BackgroundCallLocals.$queue.withValue(testQueue) {
            try await _ModelTestingLocals.$scope.withValue(pending) {
                try await function()
            }
            // After the test body completes, run exhaustion check (still inside the
            // test-local queue scope so any teardown backgroundCall work uses testQueue).
            if let concrete = pending.concrete, let fl = pending.registrationFileAndLine {
                await concrete.checkExhaustion(at: fl)
            }
        }
    }
}
#else
extension ModelTestingTrait: TestTrait, SuiteTrait {
    public var isRecursive: Bool { true }

    public func prepare(for test: Test) async throws {
        // On Swift 6.0 TestScoping.provideScope is not available.
        // The trait is registered but cannot wrap the test body.
        // Users should use withModelTesting { } for exhaustion checking on Swift 6.0.
    }
}
#endif

extension Trait where Self == ModelTestingTrait {
    /// Activates model testing infrastructure for the test function or suite.
    ///
    /// When applied to a `@Test` or `@Suite`, calling `withAnchor()` inside the test body
    /// automatically connects the model to the testing infrastructure. Use the global
    /// `expect { }` function for exhaustive assertions:
    ///
    /// ```swift
    /// @Test(.modelTesting) func example() async {
    ///     let model = CounterModel().withAnchor()
    ///     model.incrementTapped()
    ///     await expect { model.count == 1 }
    /// }
    /// ```
    ///
    /// Pass an `Exhaustivity` (from `Exhaustivity.adding(_:)` / `.removing(_:)`) as the
    /// first argument to compose with the enclosing scope's exhaustivity:
    ///
    /// ```swift
    /// @Suite(.modelTesting(.removing(.events)))   // → .full − .events
    /// struct MyTests {
    ///     @Test(.modelTesting(.removing(.tasks))) // → (.full − .events) − .tasks
    ///     func example() async { }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - modifier: An `Exhaustivity` to apply relative to the enclosing scope.
    ///   - dependencies: A closure to override dependencies for the model.
    public static func modelTesting(
        _ modifier: Exhaustivity,
        dependencies: @escaping @Sendable (inout ModelDependencies) -> Void = { _ in }
    ) -> Self {
        Self(modifier: modifier, dependencies: dependencies)
    }

    /// Activates model testing infrastructure for the test function or suite.
    ///
    /// When applied to a `@Test` or `@Suite`, calling `withAnchor()` inside the test body
    /// automatically connects the model to the testing infrastructure. Use the global
    /// `expect { }` function for exhaustive assertions:
    ///
    /// ```swift
    /// @Test(.modelTesting) func example() async {
    ///     let model = CounterModel().withAnchor()
    ///     model.incrementTapped()
    ///     await expect { model.count == 1 }
    /// }
    /// ```
    ///
    /// Apply to a base suite to share the setting across all tests:
    ///
    /// ```swift
    /// @Suite(.modelTesting) struct MyTests {
    ///     @Test func increment() async {
    ///         let model = CounterModel().withAnchor()
    ///         model.incrementTapped()
    ///         await expect { model.count == 1 }
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - exhaustivity: Exhaustivity modifier to apply. Defaults to `.full`. Pass an absolute
    ///     preset (`.off`, `.full`, `.state`) or a relative modifier (`.removing(.events)`).
    ///   - dependencies: A closure to override dependencies for the model.
    public static func modelTesting(
        exhaustivity: Exhaustivity = .full,
        dependencies: @escaping @Sendable (inout ModelDependencies) -> Void = { _ in }
    ) -> Self {
        Self(modifier: exhaustivity, dependencies: dependencies)
    }

    /// Activates model testing infrastructure with default settings.
    public static var modelTesting: Self {
        Self(modifier: Exhaustivity { _ in .full }, dependencies: { _ in })
    }
}

#endif
