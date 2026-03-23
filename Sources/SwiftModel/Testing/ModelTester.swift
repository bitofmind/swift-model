import Foundation
import Dispatch
import Dependencies
import IssueReporting
import CustomDump

/// The number of nanoseconds in one second (1,000,000,000).
///
/// Use this constant when specifying `timeoutNanoseconds` values:
/// ```swift
/// await expect(timeoutNanoseconds: 5 * nanosPerSecond) { ... }
/// ```
public let nanosPerSecond: UInt64 = 1_000_000_000

/// Drives a model through a test, providing exhaustive checking of state, events, tasks, and callbacks.
///
/// > Note: `ModelTester` is the lower-level testing API. Prefer `@Test(.modelTesting)` with
///   `withAnchor()` and the global `expect { }` / `require(_:)` functions — they provide the
///   same exhaustion checking with less boilerplate.
///
/// When the tester is deallocated at the end of the test, it verifies that every state change,
/// event, async task, and probe invocation has been explicitly asserted — so unexpected side
/// effects cause an immediate test failure. Use `exhaustivity` to relax individual categories
/// when needed.
public final class ModelTester<M: Model> {
    var access: TestAccess<M>
    let fileAndLine: FileAndLine
    /// Set to `true` by `_ConcreteModelTestScope` after it has run cleanup,
    /// so that `deinit` skips the duplicate work.
    var cleanupHandledExternally = false

    // Internal designated init — accepts options directly; avoids double-anchoring.
    init(_ model: M, options: ModelOption, exhaustivity: Exhaustivity = .full, dependencies: (inout ModelDependencies) -> Void = { _ in }, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) {
        let fl = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        fileAndLine = fl
        access = TestAccess(model: model, options: options, dependencies: dependencies, fileAndLine: fl)
        access.lock { access.exhaustivity = exhaustivity }
    }

    /// Creates a tester for the given model.
    ///
    /// > Deprecated: Use `@Test(.modelTesting)` with `model.withAnchor()` and the global
    ///   `expect { }` / `require(_:)` functions instead. `ModelTester` remains available for
    ///   programmatic use or advanced test scenarios.
    ///
    /// - Parameters:
    ///   - model: An un-anchored model to test.
    ///   - exhaustivity: Which side-effect categories must be explicitly asserted. Defaults to `.full`.
    ///   - dependencies: A closure for overriding dependencies that will be accessed by the model.
    @available(*, deprecated, message: "Use @Test(.modelTesting) with withAnchor() and the global expect { } / require(_:) functions instead.")
    public convenience init(_ model: M, exhaustivity: Exhaustivity = .full, dependencies: (inout ModelDependencies) -> Void = { _ in }, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) {
        self.init(model, options: [], exhaustivity: exhaustivity, dependencies: dependencies, fileID: fileID, filePath: filePath, line: line, column: column)
    }

    /// The live model being tested. Use this to read state and invoke actions.
    public var model: M {
        access.context.model
    }

    deinit {
        guard !cleanupHandledExternally else { return }
        access.context.cancelAllRecursively(for: ContextCancellationKey.onActivate)
        access.checkExhaustion(at: fileAndLine, includeUpdates: false, checkTasks: true)
        access.context.onRemoval()
    }
}

public extension Model {
    /// Anchors the model and returns it together with a `ModelTester` for exhaustive testing.
    ///
    /// > Deprecated: Use `@Test(.modelTesting)` with `model.withAnchor()`
    ///   and the global `expect { }` / `require(_:)` functions instead:
    ///
    /// ```swift
    /// @Test(.modelTesting) func example() async {
    ///     let model = AppModel().withAnchor()
    ///     model.incrementTapped()
    ///     await expect { model.count == 1 }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - exhaustivity: Which side-effect categories must be explicitly asserted. Defaults to `.full`.
    ///   - withDependencies: A closure to override dependencies injected into the model.
    @available(*, deprecated, message: "Use @Test(.modelTesting) with withAnchor() and the global expect { } / require(_:) functions instead.")
    func andTester(exhaustivity: Exhaustivity = .full, withDependencies dependencies: (inout ModelDependencies) -> Void = { _ in }, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, function: String = #function) -> (Self, ModelTester<Self>) {
        assertInitialState(function: function)
        let tester = ModelTester(self, options: [], exhaustivity: exhaustivity, dependencies: dependencies, fileID: fileID, filePath: filePath, line: line, column: column)
        return (tester.model, tester)
    }
}

// Internal overloads used by tests (via @testable import) to exercise specific option combinations.
extension Model {
    func andTester(options: ModelOption, exhaustivity: Exhaustivity = .full, withDependencies dependencies: (inout ModelDependencies) -> Void = { _ in }, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, function: String = #function) -> (Self, ModelTester<Self>) {
        assertInitialState(function: function)
        let tester = ModelTester(self, options: options, exhaustivity: exhaustivity, dependencies: dependencies, fileID: fileID, filePath: filePath, line: line, column: column)
        return (tester.model, tester)
    }
}


public extension Model {
    /// Asserts — inside a `tester.assert { }` block — that this model sent the given typed event.
    ///
    /// Use this inside an `assert` block to consume an expected event and verify it was sent:
    ///
    /// ```swift
    /// await tester.assert {
    ///     model.didSend(.startMeeting)
    /// }
    /// ```
    ///
    /// > Important: Must be called inside a `ModelTester.assert` builder block. Calling it
    ///   outside will report an issue and return `false`.
    func didSend(_ event: Event, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) -> Bool {
        didSend(event as Any, filePath: filePath, line: line)
    }

    /// Asserts — inside a `tester.assert { }` block — that this model sent an event matching
    /// the given value. Use the typed overload (`didSend(_ event: Event)`) when the model has
    /// an associated `Event` type.
    func didSend(_ event: Any, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) -> Bool {
        guard let assertContext = TesterAssertContextBase.assertContext else {
            reportIssue("Can only call didSend inside a ModelTester assert", filePath: filePath, line: line)
            return false
        }

        guard lifetime >= .active else {
            reportIssue("Can only call didSend on a model that is part of a ModelTester", filePath: filePath, line: line)
            return false
        }

        guard let context = enforcedContext() else { return false }
        return assertContext.didSend(event: event, from: context)
    }
}

public extension ModelTester {
    /// Controls which categories of side effects must be explicitly asserted before the tester
    /// is deallocated.
    ///
    /// By default `exhaustivity` is `.full`, meaning any state change, sent event, completed task,
    /// or probe value that has not been asserted causes a test failure. Lower it to skip categories
    /// you don't care about in a particular test:
    ///
    /// ```swift
    /// tester.exhaustivity = [.state, .events] // ignore tasks and probes
    /// tester.exhaustivity = .off              // skip all exhaustion checks
    /// ```
    var exhaustivity: Exhaustivity {
        get { access.lock { access.exhaustivity } }
        set { access.lock { access.exhaustivity = newValue } }
    }

    /// When `true`, prints each assertion that was skipped due to `exhaustivity` settings rather
    /// than silently discarding it.
    ///
    /// Useful when debugging flaky tests or tightening exhaustivity on an existing test suite:
    ///
    /// ```swift
    /// tester.showSkippedAssertions = true
    /// tester.exhaustivity = [.state]  // state is checked; events/tasks/probes are skipped but printed
    /// ```
    var showSkippedAssertions: Bool {
        get { access.lock { access.showSkippedAssertions } }
        set { access.lock { access.showSkippedAssertions = newValue } }
    }

    /// Registers `TestProbe` instances for exhaustion checking.
    ///
    /// > Deprecated: Probes created inside a `@Test(.modelTesting)` test auto-register with the
    ///   active scope on creation and on every call. Explicit `install()` is no longer needed.
    @available(*, deprecated, message: "TestProbe auto-installs on creation and on every call. Explicit install() is no longer needed.")
    func install(_ probes: TestProbe...) {
        for probe in probes {
            access.install(probe)
        }
    }
}

/// An option set that controls which categories of side effects the `ModelTester` checks for exhaustion.
///
/// The tester fails a test if any effect in an enabled category is not consumed by an `assert` call
/// before the tester is deallocated (or before the next `assert`).
///
/// - `state`: model state changes must be asserted.
/// - `events`: events sent via `node.send()` must be asserted with `model.didSend(_:)`.
/// - `tasks`: async tasks launched by the model must complete or be cancelled within the test.
/// - `probes`: values emitted by installed `TestProbe` instances must be asserted.
/// - `local`: writes to node-private storage via `node.local` must be asserted.
/// - `environment`: writes to top-down propagating storage via `node.environment` must be asserted.
/// - `preference`: writes to preference storage via `node.preference` must be asserted.
///
/// Use `.off` to disable all checks, or compose individual members:
///
/// ```swift
/// tester.exhaustivity = [.state, .events]  // only check state and events
/// tester.exhaustivity = .off               // don't check anything
/// ```
public struct Exhaustivity: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public extension Exhaustivity {
    /// Require all model state changes to be consumed by `assert` blocks.
    static let state = Self(rawValue: 1 << 0)
    /// Require all events sent via `node.send()` to be observed inside `assert` blocks.
    static let events = Self(rawValue: 1 << 1)
    /// Require all async tasks started by the model to complete or be cancelled before the tester deallocates.
    static let tasks = Self(rawValue: 1 << 2)
    /// Require all values emitted by installed `TestProbe` instances to be consumed.
    static let probes = Self(rawValue: 1 << 3)
    /// Require all node-private storage changes (via `node.local`) to be consumed by `assert` blocks.
    static let local = Self(rawValue: 1 << 4)
    /// Require all preference storage changes (via `node.preference`) to be consumed by `assert` blocks.
    static let preference = Self(rawValue: 1 << 5)
    /// Require all top-down propagating storage changes (via `node.environment`) to be consumed by `assert` blocks.
    static let environment = Self(rawValue: 1 << 6)

    /// Exhaustivity is completely disabled — no side effects need to be asserted.
    static let off: Self = []
    /// All categories are checked. This is the default.
    static let full: Self = [.state, .events, .tasks, .probes, .local, .environment, .preference]

    /// Require all context storage changes to be consumed by `assert` blocks.
    ///
    /// - Deprecated: Use `[.local, .environment]` to cover both storage kinds, or just
    ///   `.local` / `.environment` to target one specifically.
    @available(*, deprecated, message: "Use [.local, .environment] to cover both storage kinds, or .local/.environment to target one specifically.")
    static var context: Self { [.local, .environment] }
}

public extension Exhaustivity {
    /// Returns exhaustivity with the given categories added.
    ///
    /// ```swift
    /// @Test(.modelTesting(exhaustivity: .off.adding(.state)))
    /// ```
    func adding(_ other: Self) -> Self { self.union(other) }

    /// Returns exhaustivity with the given categories removed.
    ///
    /// ```swift
    /// @Test(.modelTesting(exhaustivity: .full.removing(.events)))
    /// ```
    func removing(_ other: Self) -> Self { self.subtracting(other) }

    /// Returns a modifier that adds the given categories to the inherited exhaustivity.
    ///
    /// When used in `@Test(.modelTesting(...))`, `@Suite(.modelTesting(...))`, or
    /// `withExhaustivity(_:)`, the modifier is applied on top of the enclosing scope's
    /// exhaustivity, composing rather than resetting it:
    ///
    /// ```swift
    /// @Suite(.modelTesting(.removing(.events)))   // → .full − .events
    /// struct MyTests {
    ///     @Test(.modelTesting(.removing(.tasks))) // → (.full − .events) − .tasks
    ///     func example() async {
    ///         await withExhaustivity(.adding(.events)) { // → adds .events back
    ///             ...
    ///         }
    ///     }
    /// }
    /// ```
    static func adding(_ other: Self) -> ExhaustivityModifier {
        ExhaustivityModifier { $0.union(other) }
    }

    /// Returns a modifier that removes the given categories from the inherited exhaustivity.
    ///
    /// When used in `@Test(.modelTesting(...))`, `@Suite(.modelTesting(...))`, or
    /// `withExhaustivity(_:)`, the modifier is applied on top of the enclosing scope's
    /// exhaustivity, composing rather than resetting it:
    ///
    /// ```swift
    /// @Suite(.modelTesting(.removing(.events)))   // → .full − .events
    /// struct MyTests {
    ///     @Test(.modelTesting(.removing(.tasks))) // → (.full − .events) − .tasks
    ///     func example() async { }
    /// }
    /// ```
    static func removing(_ other: Self) -> ExhaustivityModifier {
        ExhaustivityModifier { $0.subtracting(other) }
    }
}

/// A relative modification to an `Exhaustivity` value.
///
/// Use `Exhaustivity.adding(_:)` or `Exhaustivity.removing(_:)` to create a modifier. Pass it
/// directly to `@Test(.modelTesting(...))`, `@Suite(.modelTesting(...))`, or `withExhaustivity(_:)`
/// and it will be applied on top of the inherited exhaustivity rather than replacing it:
///
/// ```swift
/// @Suite(.modelTesting(.removing(.events))) // removes events from .full
/// struct MyTests {
///     @Test(.modelTesting(.removing(.tasks))) // also removes tasks (composed)
///     func example() async {
///         await withExhaustivity(.adding(.events)) { // adds events back for this block
///             ...
///         }
///     }
/// }
/// ```
public struct ExhaustivityModifier: Sendable {
    let transform: @Sendable (Exhaustivity) -> Exhaustivity

    /// Creates a modifier from an explicit transform closure.
    public init(_ transform: @escaping @Sendable (Exhaustivity) -> Exhaustivity) {
        self.transform = transform
    }

    /// Applies this modifier to a base exhaustivity and returns the result.
    public func apply(to base: Exhaustivity) -> Exhaustivity {
        transform(base)
    }

    /// Returns a modifier that adds the given categories to the inherited exhaustivity.
    ///
    /// Equivalent to `Exhaustivity.adding(_:)`. Available as a static member so
    /// leading-dot syntax works in any context that expects `ExhaustivityModifier`:
    ///
    /// ```swift
    /// @Suite(.modelTesting(.adding(.events)))
    /// ```
    public static func adding(_ other: Exhaustivity) -> Self {
        Self { $0.union(other) }
    }

    /// Returns a modifier that removes the given categories from the inherited exhaustivity.
    ///
    /// Equivalent to `Exhaustivity.removing(_:)`. Available as a static member so
    /// leading-dot syntax works in any context that expects `ExhaustivityModifier`:
    ///
    /// ```swift
    /// @Suite(.modelTesting(.removing(.events)))
    /// ```
    public static func removing(_ other: Exhaustivity) -> Self {
        Self { $0.subtracting(other) }
    }
}

@resultBuilder
public enum AssertBuilder { }

public extension AssertBuilder {
    struct Predicate: @unchecked Sendable {
        var predicate: @Sendable () -> Bool
        var values: @Sendable () -> (Any, Any)? = { nil }
        var fileAndLine: FileAndLine
    }
    typealias Result = [Predicate]

    static func buildBlock(_ layers: Result...) -> Result {
        layers.flatMap { $0 }
    }

    @_disfavoredOverload
    static func buildExpression(_ predicate: @autoclosure @escaping @Sendable () -> Bool, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) -> Result {
        [Predicate(predicate: predicate, fileAndLine: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column))]
    }

    @_disfavoredOverload
    static func buildExpression(_ predicate: @autoclosure @escaping @Sendable () -> Bool?, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) -> Result {
        [Predicate(predicate: { predicate() == true }, fileAndLine: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column))]
    }

    static func buildExpression(_ predicate: TestPredicate, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) -> Result {
        [Predicate(predicate: predicate.predicate, values: predicate.values, fileAndLine: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column))]
    }
}

func predicate(@AssertBuilder _ builder: @Sendable () -> AssertBuilder.Result) -> Bool {
    let result = builder()

    return result.allSatisfy { $0.predicate() }
}

public struct TestPredicate: Sendable {
    var predicate: @Sendable () -> Bool
    var values: @Sendable () -> (Any, Any)? = { nil }
}

public func == <T: Equatable&Sendable>(lhs: @escaping @Sendable @autoclosure () -> T, rhs: @escaping @Sendable @autoclosure () -> T) -> TestPredicate {
    TestPredicate(predicate: { lhs() == rhs() }, values: { (lhs(), rhs()) })
}

public func == <T: Equatable&Sendable>(lhs: @escaping @Sendable @autoclosure () -> T?, rhs: @escaping @Sendable @autoclosure () -> T) -> TestPredicate {
    TestPredicate(predicate: { lhs() == rhs() }, values: { (lhs() as Any, rhs() as Any) })
}

public extension ModelTester {
    /// Waits for all pending model updates to propagate, then verifies that every predicate in
    /// the builder body is `true` and that no unasserted side-effects remain (subject to `exhaustivity`).
    ///
    /// > Deprecated: Use the global `expect { }` function inside a `@Test(.modelTesting)` test instead.
    ///
    /// - Parameter timeout: Maximum nanoseconds to wait for the predicates to become true (default 1 s).
    /// - Parameter builder: A result-builder block of Boolean predicates. Use the `==` operator for
    ///   pretty-printed diff output on failure.
    @available(*, deprecated, message: "Use the global expect { } function inside a @Test(.modelTesting) test instead.")
    func assert(timeoutNanoseconds timeout: UInt64 = nanosPerSecond, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, @AssertBuilder _ builder: @Sendable () -> AssertBuilder.Result) async {
        await access.assert(timeoutNanoseconds: timeout, at: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), predicates: builder())
    }

    /// Single-predicate convenience overload. Equivalent to `assert { predicate }` for a plain `Bool` expression.
    ///
    /// > Deprecated: Use the global `expect { }` function inside a `@Test(.modelTesting)` test instead.
    @_disfavoredOverload
    @available(*, deprecated, message: "Use the global expect { } function inside a @Test(.modelTesting) test instead.")
    func assert(_ predicate: @escaping @Sendable @autoclosure () -> Bool, timeoutNanoseconds timeout: UInt64 = nanosPerSecond, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) async {
        let fileAndLine = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        let predicate = AssertBuilder.Predicate(predicate: predicate, fileAndLine: fileAndLine)
        await access.assert(timeoutNanoseconds: timeout, at: fileAndLine, predicates: [predicate])
    }

    /// Single-predicate convenience overload for a `TestPredicate` (the result of `==` between two `Equatable` values).
    /// Provides a pretty-printed diff on failure.
    ///
    /// > Deprecated: Use the global `expect { }` function inside a `@Test(.modelTesting)` test instead.
    @available(*, deprecated, message: "Use the global expect { } function inside a @Test(.modelTesting) test instead.")
    func assert(_ predicate: TestPredicate, timeoutNanoseconds timeout: UInt64 = nanosPerSecond, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) async {
        let fileAndLine = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        let predicate = AssertBuilder.Predicate(predicate: predicate.predicate, values: predicate.values, fileAndLine: fileAndLine)
        await access.assert(timeoutNanoseconds: timeout, at: fileAndLine, predicates: [predicate])
    }

    /// Waits for an optional expression to become non-`nil`, then returns the unwrapped value.
    ///
    /// > Deprecated: Use the global `require(_:)` function inside a `@Test(.modelTesting)` test instead.
    @available(*, deprecated, message: "Use the global require(_:) function inside a @Test(.modelTesting) test instead.")
    func unwrap<T>(_ unwrap: @escaping @Sendable @autoclosure () -> T?, timeoutNanoseconds timeout: UInt64 = nanosPerSecond, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) async throws -> T  {
        try await access.unwrap(unwrap, timeoutNanoseconds: timeout, at: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column))
    }
}

@available(macOS 13, iOS 16, watchOS 9, tvOS 16, *)
public extension ModelTester {
    /// Waits for all pending model updates to propagate, then verifies predicates with a `Duration` timeout.
    ///
    /// > Deprecated: Use the global `expect(timeout:)` function inside a `@Test(.modelTesting)` test instead.
    @available(*, deprecated, message: "Use the global expect(timeout:) function inside a @Test(.modelTesting) test instead.")
    func assert(timeout: Duration, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, @AssertBuilder _ builder: @Sendable () -> AssertBuilder.Result) async {
        await access.assert(timeoutNanoseconds: timeout.toNanoseconds, at: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), predicates: builder())
    }

    /// Single-predicate `Bool` overload with a `Duration` timeout.
    ///
    /// > Deprecated: Use the global `expect(timeout:)` function inside a `@Test(.modelTesting)` test instead.
    @_disfavoredOverload
    @available(*, deprecated, message: "Use the global expect(timeout:) function inside a @Test(.modelTesting) test instead.")
    func assert(_ predicate: @escaping @Sendable @autoclosure () -> Bool, timeout: Duration, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) async {
        let fileAndLine = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        let predicate = AssertBuilder.Predicate(predicate: predicate, fileAndLine: fileAndLine)
        await access.assert(timeoutNanoseconds: timeout.toNanoseconds, at: fileAndLine, predicates: [predicate])
    }

    /// Single-predicate `TestPredicate` overload with a `Duration` timeout.
    ///
    /// > Deprecated: Use the global `expect(timeout:)` function inside a `@Test(.modelTesting)` test instead.
    @available(*, deprecated, message: "Use the global expect(timeout:) function inside a @Test(.modelTesting) test instead.")
    func assert(_ predicate: TestPredicate, timeout: Duration, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) async {
        let fileAndLine = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        let predicate = AssertBuilder.Predicate(predicate: predicate.predicate, values: predicate.values, fileAndLine: fileAndLine)
        await access.assert(timeoutNanoseconds: timeout.toNanoseconds, at: fileAndLine, predicates: [predicate])
    }

    /// Waits for an optional to become non-`nil` with a `Duration` timeout.
    ///
    /// > Deprecated: Use the global `require(_:timeout:)` function inside a `@Test(.modelTesting)` test instead.
    @available(*, deprecated, message: "Use the global require(_:timeout:) function inside a @Test(.modelTesting) test instead.")
    func unwrap<T>(_ unwrap: @escaping @Sendable @autoclosure () -> T?, timeout: Duration, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) async throws -> T {
        try await access.unwrap(unwrap, timeoutNanoseconds: timeout.toNanoseconds, at: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column))
    }
}

@available(macOS 13, iOS 16, watchOS 9, tvOS 16, *)
private extension Duration {
    /// Converts a `Duration` to nanoseconds as `UInt64`, clamped to zero for negative values.
    var toNanoseconds: UInt64 {
        let (seconds, attoseconds) = components
        return UInt64(max(seconds, 0)) * nanosPerSecond + UInt64(max(attoseconds, 0)) / nanosPerSecond
    }
}


