#if canImport(Testing) && compiler(>=6)
import Foundation
import Testing
import IssueReporting
import SwiftModel

// MARK: - Global expect / require / withExhaustivity

/// Asserts — within a `@Test(.modelTesting)` test — that all predicates in the builder
/// pass and that no unasserted side effects remain.
///
/// Mirrors the behaviour of Swift Testing's `#expect`: on failure the issue is recorded
/// but the test continues. Equivalent to `tester.assert { }` but uses the test scope set
/// up by `.modelTesting`.
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
    timeoutNanoseconds timeout: UInt64 = NSEC_PER_SEC,
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
        timeoutNanoseconds: timeout,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column,
        predicates: builder()
    )
}

/// Unwraps an optional value — within a `@Test(.modelTesting)` test — waiting for it to
/// become non-nil within the timeout.
///
/// Mirrors the behaviour of Swift Testing's `#require`: on failure the issue is recorded
/// and the test stops (throws). Returns the unwrapped value on success.
/// Equivalent to `tester.unwrap { }` but uses the test scope set up by `.modelTesting`.
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
    timeoutNanoseconds timeout: UInt64 = NSEC_PER_SEC,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async throws -> T {
    guard let scope = _ModelTestingLocals.scope else {
        reportIssue("require() must be called inside a @Test(.modelTesting) test function", fileID: fileID, filePath: filePath, line: line, column: column)
        throw UnwrapError()
    }
    return try await scope.unwrap(
        expression,
        timeoutNanoseconds: timeout,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

/// Runs `body` with exhaustivity temporarily set to `exhaustivity` for the active
/// `.modelTesting` test scope.
///
/// Any calls to `expect { }` inside `body` will use the new exhaustivity. When `body`
/// returns the previous exhaustivity is restored.
///
/// ```swift
/// @Test(.modelTesting) func example() async {
///     let model = MyModel().withAnchor()
///     model.doSomething()
///     await expect { model.state == .done }
///
///     // From here on, ignore events:
///     await withExhaustivity(.off) {
///         model.triggerSideEffects()
///     }
/// }
/// ```
///
/// > Important: Must be called inside a `@Test(.modelTesting)` function.
public func withExhaustivity(
    _ exhaustivity: Exhaustivity,
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
    scope.exhaustivity = exhaustivity
    defer { scope.exhaustivity = previous }
    try await body()
}

/// Runs `body` with exhaustivity modified relative to the current scope's exhaustivity.
///
/// The `modifier` is applied to the *current* exhaustivity — it adds or removes categories
/// without fully resetting the inherited value. When `body` returns the previous exhaustivity
/// is restored.
///
/// ```swift
/// @Suite(.modelTesting(.removing(.events)))
/// struct MyTests {
///     @Test func example() async {
///         let model = MyModel().withAnchor()
///         // Inside this block, events are added back temporarily:
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
    _ modifier: ExhaustivityModifier,
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

// MARK: - ModelTestingTrait

/// The trait struct for `@Test(.modelTesting)`.
@_documentation(visibility: private)
public struct _ModelTestingTrait: Sendable {
    /// The exhaustivity modifier applied relative to the enclosing scope's exhaustivity.
    let modifier: ExhaustivityModifier
    let dependencies: @Sendable (inout ModelDependencies) -> Void

    init(modifier: ExhaustivityModifier, dependencies: @escaping @Sendable (inout ModelDependencies) -> Void) {
        self.modifier = modifier
        self.dependencies = dependencies
    }
}

#if swift(>=6.1)
extension _ModelTestingTrait: TestScoping, TestTrait, SuiteTrait {
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
        try await _ModelTestingLocals.$scope.withValue(pending) {
            try await function()
        }
        // After the test body completes, run exhaustion check.
        if let concrete = pending.concrete, let fl = pending.registrationFileAndLine {
            concrete.checkExhaustion(at: fl)
        }
    }
}
#else
extension _ModelTestingTrait: TestTrait, SuiteTrait {
    public var isRecursive: Bool { true }

    public func prepare(for test: Test) async throws {
        // On Swift 6.0 TestScoping.provideScope is not available.
        // The trait is registered but cannot wrap the test body.
        // Users should use andTester() for exhaustion checking on Swift 6.0.
    }
}
#endif

extension Trait where Self == _ModelTestingTrait {
    /// Activates model testing infrastructure for the test function or suite.
    ///
    /// When applied to a `@Test` or `@Suite`, calling `withAnchor()` inside the test body
    /// automatically connects the model to the testing infrastructure. Use the global
    /// `expect { }` function instead of `tester.assert { }`:
    ///
    /// ```swift
    /// @Test(.modelTesting) func example() async {
    ///     let model = CounterModel().withAnchor()
    ///     model.incrementTapped()
    ///     await expect { model.count == 1 }
    /// }
    /// ```
    ///
    /// Pass an `ExhaustivityModifier` (from `Exhaustivity.adding(_:)` / `.removing(_:)`) as the
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
    ///   - modifier: An `ExhaustivityModifier` to apply relative to the enclosing scope.
    ///   - dependencies: A closure to override dependencies for the model.
    public static func modelTesting(
        _ modifier: ExhaustivityModifier,
        dependencies: @escaping @Sendable (inout ModelDependencies) -> Void = { _ in }
    ) -> Self {
        Self(modifier: modifier, dependencies: dependencies)
    }

    /// Activates model testing infrastructure for the test function or suite.
    ///
    /// When applied to a `@Test` or `@Suite`, calling `withAnchor()` inside the test body
    /// automatically connects the model to the testing infrastructure. Use the global
    /// `expect { }` function instead of `tester.assert { }`:
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
    ///   - exhaustivity: Which side-effect categories to check (absolute). Defaults to `.full`.
    ///   - dependencies: A closure to override dependencies for the model.
    public static func modelTesting(
        exhaustivity: Exhaustivity = .full,
        dependencies: @escaping @Sendable (inout ModelDependencies) -> Void = { _ in }
    ) -> Self {
        // Wrap the absolute value in a modifier that ignores the inherited exhaustivity.
        Self(modifier: ExhaustivityModifier { _ in exhaustivity }, dependencies: dependencies)
    }

    /// Activates model testing infrastructure with default settings.
    public static var modelTesting: Self {
        Self(modifier: ExhaustivityModifier { _ in .full }, dependencies: { _ in })
    }
}

#endif
