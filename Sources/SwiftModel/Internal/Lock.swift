import Foundation

extension NSLocking {
    func callAsFunction<T>(_ operation: () throws -> T) rethrows -> T {
        try withLock(operation)
    }

    func callAsFunction<T>(_ operation: @autoclosure () throws -> T) rethrows -> T {
        try withLock(operation)
    }
}
