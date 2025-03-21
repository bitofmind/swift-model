import Foundation

/// A protocol indicating that an activity or action supports cancellation.
public protocol Cancellable: Sendable {
    /// Cancel the activity.
    func cancel()

    /// Cancel the activity of a model when  when `model.cancelAll(for: key)` is called for the  provided `key`
    /// If `cancelInFlight` is true,  any previous activity set up to be cancelled for `key`
    /// is first cancelled.
    ///
    ///     model.task { ... }.cancel(for: myKey, cancelInFlight: true)
    @discardableResult
    func cancel(for key: some Hashable&Sendable, cancelInFlight: Bool) -> Self
}

public extension Cancellable {
    /// Cancel the activity of a model when  when `model.cancelAll(for: key)` is called for the  provided `key`
    ///
    ///     model.task { ... }.cancel(for: myKey)
    @discardableResult
    func cancel(for key: some Hashable&Sendable) -> Self {
        cancel(for: key, cancelInFlight: false)
    }

    /// Cancels any previously active task (using a key based of source location).
    ///
    ///     func onReload() {
    ///         task { ... }.cancelInFlight()
    ///     }
    @discardableResult
    func cancelInFlight(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) -> Self {
        cancel(for: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), cancelInFlight: true)
    }

    /// Let this cancellable inherit the the context of any containing context
    ///
    ///     func onReload() {
    ///         task {
    ///             forEach(...) { ... }
    ///                 .inheritCancellationContext() // Will be cancelled if containing task is cancelled.
    ///         }.cancelInFlight()
    ///     }
    @discardableResult
    func inheritCancellationContext() -> Self {
        for cancellableKey in AnyCancellable.inheritedContexts {
            cancel(for: cancellableKey, cancelInFlight: false)
        }
        return self
    }
}
