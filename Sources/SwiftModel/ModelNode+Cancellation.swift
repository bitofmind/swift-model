import Foundation
import AsyncAlgorithms

public extension ModelNode {
    ///  Register `perform` closure to be called when cancelled.
    /// - Returns: A cancellable to optionally allow cancelling before deactivation.
    @discardableResult
    func onCancel(perform: @Sendable @escaping () -> Void) -> Cancellable {
        guard let context = enforcedContext() else { return EmptyCancellable() }

        return AnyCancellable(context: context, onCancel: perform)
    }


    /// Cancel all cancellables that have been registered for the provided `key`
    ///
    ///     let key = UUID()
    ///
    ///     model.task {
    ///        // work...
    ///     }.cancel(for: key)
    ///
    ///     model.cancelAll(for: key)
    func cancelAll(for key: some Hashable&Sendable) {
        guard let context = enforcedContext() else { return }
        context.cancellations.cancelAll(for: key)
    }
}

public extension ModelNode {
    /// Activities created while the context is active will be cancellable via the returned `Cancellable`.
    /// Any nested tasks or forEach won't be affected
    ///
    ///     withCancellationContext {
    ///         task { }
    ///         forEach { }
    ///         onCancel { }
    ///     }.cancelInFlight()
    ///
    func cancellationContext(perform: () throws -> Void) rethrows -> Cancellable {
        guard let context = enforcedContext() else { return EmptyCancellable() }

        let key = UUID()
        try AnyCancellable.$contexts.withValue(AnyCancellable.contexts + [CancellableKey(key: key)]) {
            try perform()
        }

        return AnyCancellable(context: context) {
            cancelAll(for: key)
        }
    }

    /// Activities created while the context is active will be cancellable via the return `Cancellable`.
    /// Any nested tasks or forEach won't be affected
    ///
    ///     withCancellationContext {
    ///         task { }
    ///         forEach { }
    ///         onCancel { }
    ///     }.cancelInFlight()
    ///
    func cancellationContext(perform: () async throws -> Void) async rethrows -> Cancellable {
        guard let context = enforcedContext() else { return EmptyCancellable() }

        let key = UUID()
        try await AnyCancellable.$contexts.withValue(AnyCancellable.contexts + [CancellableKey(key: key)]) {
            try await perform()
        }

        return AnyCancellable(context: context) {
            cancelAll(for: key)
        }
    }
}
