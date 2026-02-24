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
        context.waitUntilNil
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

/// Test parameter for validating both update() implementation paths
enum UpdatePath: String, CaseIterable {
    case accessCollector
    case withObservationTracking

    var options: ModelOption {
        switch self {
        case .accessCollector:
            return []  // Default behavior
        case .withObservationTracking:
            return [.useWithObservationTracking]  // Opt-in
        }
    }
}
