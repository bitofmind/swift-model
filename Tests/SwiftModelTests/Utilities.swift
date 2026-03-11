@testable import SwiftModel
import ConcurrencyExtras
import Dependencies
import Foundation

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
    var waitUntilNil: () async -> Void {
        { [weak self] in
            while self != nil {
                await Task.yield()
            }
            // After the object is released, teardown closures dispatched during
            // onRemoval may still be held in backgroundCall's drain task queue.
            // Wait for those to finish so transitively owned objects (e.g. child
            // context References) are also released before callers assert on them.
            await backgroundCall.waitUntilIdle()
        }
    }
}

extension Model {
    var waitUntilRemoved: () async -> Void {
        context.waitUntilNil
    }
}

extension ModelNode {
    var waitUntilRemoved: () async -> Void {
        _context.waitUntilNil
    }
}

extension Context {
    var waitUntilRemoved: () async -> Void {
        reference.context.waitUntilNil
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

struct WaitTimeoutError: Error, CustomStringConvertible {
    let file: StaticString
    let line: UInt
    let timeoutSeconds: Double
    
    var description: String {
        "Timeout after \(timeoutSeconds)s waiting for condition at \(file):\(line)"
    }
}

/// Poll until a condition becomes true
/// - Parameters:
///   - condition: The condition to check (autoclosure)
///   - pollInterval: How often to check the condition in nanoseconds (default: 1ms)
///   - timeout: Maximum time to wait in nanoseconds (default: 5s)
/// - Throws: WaitTimeoutError if timeout is reached before condition becomes true
func waitUntil(
    _ condition: @autoclosure () -> Bool,
    pollInterval: UInt64 = 1_000_000,  // 1ms
    timeout: UInt64 = 5_000_000_000,   // 5s
    file: StaticString = #file,
    line: UInt = #line
) async throws {
    let start = ContinuousClock.now
    while !condition() {
        try await Task.sleep(nanoseconds: pollInterval)
        let elapsed = ContinuousClock.now - start
        let elapsedNanos = UInt64(elapsed.components.seconds) * 1_000_000_000 + UInt64(elapsed.components.attoseconds / 1_000_000_000)
        if elapsedNanos > timeout {
            throw WaitTimeoutError(
                file: file,
                line: line,
                timeoutSeconds: Double(timeout) / 1_000_000_000.0
            )
        }
    }
}

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
}
