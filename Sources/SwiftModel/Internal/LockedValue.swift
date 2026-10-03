import Foundation

/// A value behind a recursive lock: SwiftModel's replacement for ConcurrencyExtras'
/// `LockIsolated`, with an in-place mutation for hot paths.
///
/// `withValue` has `LockIsolated`'s semantics: it copies the value out, runs the closure
/// on the copy and writes it back. That tolerates re-entry (a nested `withValue` on the
/// same box from inside the closure, which the recursive lock allows and some paths do,
/// e.g. a synchronous observer update re-entering its own update). But a collection is
/// shared during the closure, so every insert or append copies all of it.
///
/// `withValueInPlace` mutates the stored value directly, with no copy. Use it for a
/// collection that grows on a hot path, and only where the closure cannot reach this box
/// again: re-entry would be overlapping access to the stored value, which Swift traps on
/// in Release as well as Debug. An access collector registering each read of a 4,000-row
/// scan through `withValue` spent 192 ms copying; in place it takes 13 ms.
///
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

    /// Runs `operation` on a copy and stores the result; safe to re-enter.
    func withValue<T>(_ operation: (inout Value) throws -> T) rethrows -> T {
        try lock {
            var value = _value
            defer { _value = value }
            return try operation(&value)
        }
    }

    /// Runs `operation` on the stored value itself. `operation` must not reach this box
    /// again (no callbacks into code that might).
    func withValueInPlace<T>(_ operation: (inout Value) throws -> T) rethrows -> T {
        try lock { try operation(&_value) }
    }
}
