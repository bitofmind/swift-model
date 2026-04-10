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
                // Use Task.sleep (kernel timer) instead of Task.yield() to poll.
                // Task.yield() on a saturated cooperative pool (200+ parallel tests
                // on 2-vCPU CI) can suspend for minutes, making the deadline check
                // above unreachable until long after the 5s deadline has elapsed.
                // Task.sleep fires after exactly ~10ms regardless of pool saturation.
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            // After the object is released, teardown closures dispatched during
            // onRemoval may still be held in backgroundCall's drain task queue.
            // Wait for those to finish so transitively owned objects (e.g. child
            // context References) are also released before callers assert on them.
            //
            // Use a 10-second deadline to prevent an indefinite hang when the global
            // queue is perpetually busy with other parallel tests' work on 2-vCPU CI.
            // Teardown callbacks execute in microseconds; 10s is orders of magnitude
            // more than enough for the GCD drain to process them.
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
    // test load (e.g. 100x repetitions or 600+ concurrent tests on 2-vCPU CI)
    // we wait proportionally longer for cooperative consumer tasks to be scheduled.
    // Use Task.yield() (not a GCD hop) so we measure cooperative-pool latency:
    // on a saturated pool, Task.yield() takes 50 ms+ which scales the timeout up
    // to 5s+ (giving consumer tasks time to be scheduled). A GCD hop fires in
    // <1ms regardless of pool saturation and would give no useful scaling.
    let calibrationStart = DispatchTime.now().uptimeNanoseconds
    await Task.yield()
    let yieldLatencyNs = DispatchTime.now().uptimeNanoseconds - calibrationStart
    // Cap yieldLatencyNs at 100ms to prevent scaledTimeout from becoming
    // enormous (e.g., 500s) when Task.yield() takes seconds during mass-concurrent
    // test startup (511 tests all starting simultaneously floods the cooperative pool).
    // max scale: 100ms * 100 = 10s — enough for consumer tasks without risking infinite waits.
    let cappedLatencyNs = min(yieldLatencyNs, 100_000_000)  // cap at 100ms
    let scaledTimeout = max(timeout, cappedLatencyNs * 100)

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

        // Kernel-level dispatch hop instead of Task.yield() — same rationale as the
        // calibration above. After the hop, re-check the condition and sleep one poll
        // interval only when backgroundCall is idle (avoids busy-spinning while the
        // drain task is actively delivering updates).
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { c.resume() }
        }
        if condition() { return }
        if backgroundCall.isIdle {
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
