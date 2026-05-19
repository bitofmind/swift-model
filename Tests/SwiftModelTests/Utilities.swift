@testable import SwiftModel
import ConcurrencyExtras
import Dependencies
import Foundation
import IssueReporting
import Testing

@propertyWrapper
final class Locked<Value> {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    init(wrappedValue: Value) {
        _value = wrappedValue
    }

    var value: Value {
        get { lock { _value } }
        set { lock { _value = newValue } }
    }

    var wrappedValue: Value {
        get { value }
        set { value = newValue }
    }
    
    var projectedValue: Locked {
        self
    }

    func callAsFunction<T>(_ operation: (inout Value) -> T) -> T {
        lock {
            operation(&_value)
        }
    }
}

extension Locked: @unchecked Sendable where Value: Sendable {}

extension NSLock {
    func callAsFunction<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

extension Optional where Wrapped: AnyObject {
    // Returns a closure with a weak capture so the strong reference doesn't prevent deallocation.
    var waitUntilNil: () async -> Void {
        { [weak self] in
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            while self != nil {
                if DispatchTime.now().uptimeNanoseconds > deadline {
                    reportIssue("waitUntilRemoved timed out after 5s — model was not released. Check for retain cycles.")
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000) // poll every 10ms
            }
            // After the object is released, teardown closures dispatched during
            // onRemoval may still be held in backgroundCall's drain task queue.
            // Wait for those to finish so transitively owned objects (e.g. child
            // context References) are also released before callers assert on them.
            let idleDeadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
            await backgroundCall.waitUntilIdle(deadline: idleDeadline)
        }
    }
}

extension Model {
    func waitUntilRemoved() async {
        await context.waitUntilNil()
    }
}

extension ModelNode {
    func waitUntilRemoved() async {
        await _context.waitUntilNil()
    }
}

extension Context {
    func waitUntilRemoved() async {
        await reference.context.waitUntilNil()
    }
}

func waitUntilRemoved<M: Model>(_ model: () async throws -> M) async rethrows {
    try await model().context.waitUntilNil()
}

class TestResult: @unchecked Sendable {
    let values = LockIsolated<[String]>([])
    var value: String {
        values.value.joined()
    }

    func add(_ value: String) {
        values.withValue {
            $0.append(value)
        }
    }
}

extension DependencyValues {
    var testResult: TestResult {
        get { self[Key.self] }
        set { self[Key.self] = newValue }
    }

    enum Key: DependencyKey {
        static let liveValue = TestResult()
    }
}

// `waitUntil` and its timeout error live in SwiftModel as
// `Sources/SwiftModel/Internal/WaitUntilCallback.swift` and are picked
// up here via `@testable import SwiftModel`. That implementation
// re-evaluates the predicate on `GlobalTickScheduler`'s shared GCD
// ticker — callbacks fire off the cooperative pool, and all concurrent
// `waitUntil` calls across parallel tests share one ticker instead of
// each spinning its own `Task.sleep`.

/// Test parameter for validating both observation mechanisms
enum ObservationPath: String, CaseIterable {
    case observationRegistrar
    case accessCollector

    var options: ModelOption {
        switch self {
        case .observationRegistrar:
            return []
        case .accessCollector:
            return [.disableObservationRegistrar]
        }
    }

    func withOptions<T>(_ body: () throws -> T) rethrows -> T {
        try ModelOption.$current.withValue(options, operation: body)
    }
}

/// Test parameter for validating both observation mechanisms (AccessCollector vs withObservationTracking)
///
/// IMPORTANT: withObservationTracking path ONLY works with coalescing enabled.
/// Tests using `Observed(coalesceUpdates: false)` inside models will NOT work correctly
/// with UpdatePath.withObservationTracking - they will fall back to AccessCollector.
///
/// If you need to test non-coalescing behavior, use AccessCollector directly:
/// - `[.disableObservationRegistrar, .disableMemoizeCoalescing]`
enum UpdatePath: String, CaseIterable {
    case accessCollector
    case withObservationTracking

    var options: ModelOption {
        switch self {
        case .accessCollector:
            // Disable ObservationRegistrar to force AccessCollector path
            // Note: Coalescing can still be controlled via .disableMemoizeCoalescing
            return [.disableObservationRegistrar]
        case .withObservationTracking:
            // Use ObservationRegistrar (default)
            // WARNING: Tests using Observed(coalesceUpdates: false) will NOT use this path!
            // They will fall back to AccessCollector because coalesceUpdates: false forces that path.
            return []
        }
    }

    func withOptions<T>(_ body: () throws -> T) rethrows -> T {
        try ModelOption.$current.withValue(options, operation: body)
    }
}

func withModelOptions<T>(_ options: ModelOption, _ body: () throws -> T) rethrows -> T {
    try ModelOption.$current.withValue(options, operation: body)
}

// MARK: - Background call isolation test trait

/// A test trait that gives each test its own isolated `BackgroundCallQueue`,
/// preventing parallel tests from observing each other's in-flight `Observed`
/// pipeline updates.
///
/// Use on suites that explicitly call `await backgroundCall.waitUntilIdle()` or
/// `await backgroundCall.waitForCurrentItems()` — those that don't use `.modelTesting`
/// (which already provides per-test isolation automatically).
struct BackgroundCallIsolationTrait: TestTrait, SuiteTrait {
    var isRecursive: Bool { true }
}

#if swift(>=6.1)
extension BackgroundCallIsolationTrait: TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await _BackgroundCallLocals.$queue.withValue(BackgroundCallQueue()) {
            try await function()
        }
    }
}
#endif

extension Trait where Self == BackgroundCallIsolationTrait {
    /// Gives each test its own `BackgroundCallQueue`, preventing parallel tests from
    /// observing each other's in-flight `Observed` pipeline updates.
    static var backgroundCallIsolation: Self { Self() }
}

// MARK: - CapturingIssueReporter
//
// Used by `CancellationTests` to assert that specific code paths emit
// `reportIssue` calls. Duplicated in `Tests/SwiftModelSnapshotTests/` as well
// (the snapshot target's `AssertIssueSnapshot.swift` defines its own copy)
// because SwiftPM test targets can't import each other.

/// Collects failure messages from `reportIssue` calls without emitting them as test failures.
final class CapturingIssueReporter: IssueReporter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var messages: [String] = []

    func reportIssue(
        _ message: @autoclosure () -> String?,
        severity: IssueSeverity,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) {
        let m = message() ?? ""
        lock.withLock { messages.append(m) }
    }
}
