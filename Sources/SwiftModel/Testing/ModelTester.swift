import Foundation
import Dependencies
import IssueReporting
import CustomDump

/// The number of nanoseconds in one second (1,000,000,000).
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

    // Internal designated init — options are read from `ModelOption.current` (TaskLocal) by AnyContext.
    init(_ model: M, exhaustivity: _ExhaustivityBits = .full, dependencies: (inout ModelDependencies) -> Void = { _ in }, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) {
        let fl = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        fileAndLine = fl
        access = TestAccess(model: model, dependencies: dependencies, fileAndLine: fl)
        access.lock { access.exhaustivity = exhaustivity }
    }

    /// The live model being tested. Use this to read state and invoke actions.
    public var model: M {
        usingActiveAccess(access) {
            // Seed from lastState so that `let` properties (e.g. LockIsolated counters)
            // carry their correct reference values rather than zero-bytes from _zeroInit().
            // lastState is a frozen copy: tracked `var` properties are stale in the struct,
            // but after _updateContext they're always read from _stateHolder.state via the
            // .reference-source subscript, so staleness doesn't matter.
            // Using .reference source (not context.model's .live source) ensures reading
            // tracked properties triggers willAccessDirect → TestAccess.willAccess, which is
            // required for exhaustivity tracking (consuming recorded valueUpdates).
            var m = access.lock { access.lastState }
            m._updateContext(ModelContextUpdate(ModelContext(context: access.context)))
            m.modelContext.access = access
            return m
        }
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
}


public extension Model {
    /// Asserts — inside an `expect { }` block — that this model sent the given typed event.
    ///
    /// Use this inside an `expect` block to consume an expected event and verify it was sent:
    ///
    /// ```swift
    /// await expect {
    ///     model.didSend(.startMeeting)
    /// }
    /// ```
    ///
    /// > Important: Must be called inside an `expect { }` builder block. Calling it
    ///   outside will report an issue and return `false`.
    func didSend(_ event: Event, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) -> Bool {
        didSend(event as Any, filePath: filePath, line: line)
    }

    /// Asserts — inside an `expect { }` block — that this model sent an event matching
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
    ///
    /// Setting a relative modifier (e.g. `.removing(.events)`) applies against `.full` as the base.
    var exhaustivity: Exhaustivity {
        get {
            let bits = access.lock { access.exhaustivity }
            return Exhaustivity { _ in bits }
        }
        set { access.lock { access.exhaustivity = newValue.apply(to: .full) } }
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

}

// Package-internal bitmask used by TestAccess at runtime.
package struct _ExhaustivityBits: OptionSet, Equatable, Sendable {
    package let rawValue: Int

    package init(rawValue: Int) {
        self.rawValue = rawValue
    }

    package static let state = Self(rawValue: 1 << 0)
    package static let events = Self(rawValue: 1 << 1)
    package static let tasks = Self(rawValue: 1 << 2)
    package static let probes = Self(rawValue: 1 << 3)
    package static let local = Self(rawValue: 1 << 4)
    package static let preference = Self(rawValue: 1 << 5)
    package static let environment = Self(rawValue: 1 << 6)
    package static let transitions = Self(rawValue: 1 << 7)
    package static let off: Self = []
    package static let full: Self = [.state, .events, .tasks, .probes, .local, .environment, .preference]
}

/// Controls which categories of side effects the testing framework checks for exhaustion.
///
/// Pass an `Exhaustivity` value to `@Test(.modelTesting(exhaustivity:))`,
/// `@Suite(.modelTesting(exhaustivity:))`, `withModelTesting(exhaustivity:)`,
/// `withExhaustivity(_:)`, or `settle(resetting:)`.
///
/// **Absolute presets** set exhaustivity regardless of the parent scope:
/// ```swift
/// @Suite(.modelTesting(exhaustivity: .off))    // → no checks
/// @Suite(.modelTesting(exhaustivity: .full))   // → all standard checks (default)
/// @Suite(.modelTesting(exhaustivity: .state))  // → state only
/// ```
///
/// **Array literals** compose absolute presets:
/// ```swift
/// @Suite(.modelTesting(exhaustivity: [.state, .events]))  // → state + events only
/// ```
///
/// **Relative factories** compose on top of the inherited scope's exhaustivity:
/// ```swift
/// @Suite(.modelTesting(.removing(.events)))    // → inherited − .events
/// @Suite(.modelTesting(.adding(.transitions))) // → inherited + .transitions
/// ```
///
/// **Instance chaining** chains from a preset:
/// ```swift
/// @Suite(.modelTesting(exhaustivity: .full.removing(.events)))   // → .full − .events
/// @Suite(.modelTesting(exhaustivity: .off.adding(.state)))       // → .state only
/// ```
public struct Exhaustivity: Sendable, ExpressibleByArrayLiteral {
    let transform: @Sendable (_ExhaustivityBits) -> _ExhaustivityBits

    /// Creates an exhaustivity value from an explicit transform closure.
    package init(_ transform: @escaping @Sendable (_ExhaustivityBits) -> _ExhaustivityBits) {
        self.transform = transform
    }

    /// Creates an exhaustivity that is the union of all elements (absolute preset).
    ///
    /// Each element is interpreted as an absolute preset. Relative modifiers (`.adding`, `.removing`)
    /// are unusual in array literals; use explicit preset names (`.state`, `.events`, etc.) instead.
    ///
    /// ```swift
    /// @Suite(.modelTesting(exhaustivity: [.state, .events]))
    /// await settle(resetting: [.state, .events])
    /// ```
    public init(arrayLiteral elements: Exhaustivity...) {
        let bits = elements.reduce(_ExhaustivityBits.off) { $0.union($1.apply(to: .off)) }
        self.init { _ in bits }
    }

    /// Applies this exhaustivity value against a base and returns the resolved bits.
    package func apply(to base: _ExhaustivityBits) -> _ExhaustivityBits {
        transform(base)
    }

    // MARK: - Absolute presets (ignore the inherited exhaustivity)

    /// All standard exhaustivity checks. This is the default.
    public static var full: Self { Self { _ in .full } }

    /// No exhaustivity checks.
    public static var off: Self { Self { _ in .off } }

    /// State changes only.
    public static var state: Self { Self { _ in .state } }

    /// Sent events only.
    public static var events: Self { Self { _ in .events } }

    /// Async tasks only.
    public static var tasks: Self { Self { _ in .tasks } }

    /// `TestProbe` values only.
    public static var probes: Self { Self { _ in .probes } }

    /// Node-private storage (`node.local`) only.
    public static var local: Self { Self { _ in .local } }

    /// Preference storage (`node.preference`) only.
    public static var preference: Self { Self { _ in .preference } }

    /// Top-down propagating storage (`node.environment`) only.
    public static var environment: Self { Self { _ in .environment } }

    /// FIFO transition-order exhaustivity.
    ///
    /// When `.transitions` is included, `expect` evaluates predicates against recorded history
    /// in FIFO order rather than the live model value. Each property write creates a separate
    /// entry; entries are consumed one at a time as assertions pass. This eliminates races where
    /// `expect { !model.isLoading }` could fire on the *initial* `false` before the loading
    /// task even starts.
    ///
    /// Not included in `.full` by default — opt in explicitly when you want strict ordering:
    /// ```swift
    /// @Suite(.modelTesting(exhaustivity: .adding(.transitions)))
    /// ```
    public static var transitions: Self { Self { _ in .transitions } }

    // MARK: - Relative factories (compose with the inherited exhaustivity)

    /// Returns an exhaustivity that adds the given categories to the inherited exhaustivity.
    ///
    /// ```swift
    /// @Suite(.modelTesting(.adding(.transitions)))  // → inherited + .transitions
    /// ```
    ///
    /// In free-context positions (e.g. `settle(resetting:)`) the implicit base is `.off`,
    /// so `.adding(.transitions)` resets only the transitions category.
    public static func adding(_ other: Self) -> Self {
        let bitsToAdd = other.apply(to: .off)
        return Self { $0.union(bitsToAdd) }
    }

    /// Returns an exhaustivity that removes the given categories from the inherited exhaustivity.
    ///
    /// ```swift
    /// @Suite(.modelTesting(.removing(.events)))  // → inherited − .events
    /// ```
    ///
    /// In free-context positions (e.g. `settle(resetting:)`) the implicit base is `.full`,
    /// so `.removing(.events)` resets everything except events.
    public static func removing(_ other: Self) -> Self {
        let bitsToRemove = other.apply(to: .off)
        return Self { $0.subtracting(bitsToRemove) }
    }

    // MARK: - Instance chaining

    /// Returns a new exhaustivity that adds the given categories to the result of this one.
    ///
    /// ```swift
    /// .off.adding(.state)                 // → .state only
    /// .off.adding([.state, .events])      // → .state + .events
    /// ```
    public func adding(_ other: Self) -> Self {
        let bitsToAdd = other.apply(to: .off)
        return Self { self.apply(to: $0).union(bitsToAdd) }
    }

    /// Returns a new exhaustivity that removes the given categories from the result of this one.
    ///
    /// ```swift
    /// .full.removing(.events)             // → .full − .events
    /// .full.removing([.state, .events])   // → .full − .state − .events
    /// ```
    public func removing(_ other: Self) -> Self {
        let bitsToRemove = other.apply(to: .off)
        return Self { self.apply(to: $0).subtracting(bitsToRemove) }
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


