import XCTest
@testable import SwiftModel

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
