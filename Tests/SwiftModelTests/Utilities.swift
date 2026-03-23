@testable import SwiftModel
import ConcurrencyExtras
import Dependencies
import Foundation
import IssueReporting

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
    // Fast path: if the condition is already satisfied, skip the calibration yield entirely.
    // On iOS simulator under heavy parallel-test load a single Task.yield() can take
    // hundreds of milliseconds, so avoiding it when possible keeps tests fast.
    if condition() { return }

    // Scale the timeout by current scheduler latency so that under heavy parallel
    // test load (e.g. 100x repetitions) we wait proportionally longer.
    let calibrationStart = DispatchTime.now().uptimeNanoseconds
    await Task.yield()
    let yieldLatencyNs = DispatchTime.now().uptimeNanoseconds - calibrationStart
    let scaledTimeout = max(timeout, yieldLatencyNs * 100)

    let start = DispatchTime.now().uptimeNanoseconds
    while !condition() {
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        if elapsed > scaledTimeout {
            throw WaitTimeoutError(
                file: file,
                line: line,
                timeoutSeconds: Double(timeout) / 1_000_000_000.0
            )
        }

        // Yield cooperatively so the backgroundCall drain task (which drives Observed
        // stream updates) gets scheduler turns. Under heavy parallel test load
        // backgroundCall is almost always busy, so yielding interleaves with it
        // naturally. We sleep the poll interval only when it's idle to avoid spinning.
        if !backgroundCall.isIdle {
            await Task.yield()
        } else {
            await Task.yield()
            if condition() { return }
            try await Task.sleep(nanoseconds: pollInterval)
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
