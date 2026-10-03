import Foundation

/// A value behind a lock, mutated in place.
///
/// Use it instead of `LockIsolated` for a collection that is mutated often.
/// `LockIsolated.withValue` copies the value out, runs the closure on the copy and writes
/// it back, so the collection is shared during the closure and every insert or append
/// copies all of it. An access collector registering each read of a 400-row scan paid
/// O(n) per read that way, which was most of an editor's main thread.
///
/// The lock is recursive, like `LockIsolated`'s, so nesting behaves the same.
/// `@unchecked Sendable`: every access to `_value` is under `lock`.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    var value: Value {
        lock { _value }
    }

    func setValue(_ newValue: Value) {
        lock { _value = newValue }
    }

    func withValue<T>(_ operation: (inout Value) throws -> T) rethrows -> T {
        try lock { try operation(&_value) }
    }
}
