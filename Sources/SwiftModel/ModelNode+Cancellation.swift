import Foundation
import AsyncAlgorithms

public extension ModelNode {
    ///  Register `perform` closure to be called when cancelled.
    /// - Returns: A cancellable to optionally allow cancelling before deactivation.
    @discardableResult
    func onCancel(perform: @Sendable @escaping () -> Void) -> Cancellable {
        guard let cancellations = enforcedContext()?.cancellations else { return EmptyCancellable() }

        return AnyCancellable(cancellations: cancellations, onCancel: perform)
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
    /// Activities created while the context is active will be cancellable via the provided `key`.
    /// Any nested tasks or forEach won't be affected
    ///
    ///     withCancellationContext(for: key) {
    ///         task { }
    ///         forEach { }
    ///         onCancel { }
    ///     }
    ///
    func cancellationContext<T>(for key: some Hashable&Sendable, perform: () throws -> T) rethrows -> T {
        guard let cancellations = enforcedContext()?.cancellations else { return try perform() }

        let _ = AnyCancellable(cancellations: cancellations) { [weak cancellations] in
            cancellations?.cancelAll(for: key)
        }

        return try AnyCancellable.$contexts.withValue(AnyCancellable.contexts + [CancellableKey(key: key)]) {
            try perform()
        }
    }
    
    /// Activities created while the context is active will be cancellable via the provided `key`.
    /// Any nested tasks or forEach won't be affected
    ///
    ///     withCancellationContext(for: key) {
    ///         task { }
    ///         forEach { }
    ///         onCancel { }
    ///     }
    ///
    func cancellationContext<T>(for key: some Hashable&Sendable, perform: () async throws -> T) async rethrows -> T {
        guard let cancellations = enforcedContext()?.cancellations else { return try await perform() }


        let _ = AnyCancellable(cancellations: cancellations) { [weak cancellations] in
            cancellations?.cancelAll(for: key)
        }

        return try await AnyCancellable.$contexts.withValue(AnyCancellable.contexts + [CancellableKey(key: key)]) {
            try await perform()
        }
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
        guard let cancellations = enforcedContext()?.cancellations else { return EmptyCancellable() }

        let key = UUID()
        try AnyCancellable.$contexts.withValue(AnyCancellable.contexts + [CancellableKey(key: key)]) {
            try perform()
        }

        return AnyCancellable(cancellations: cancellations) { [weak cancellations] in
            cancellations?.cancelAll(for: key)
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
        guard let cancellations = enforcedContext()?.cancellations else { return EmptyCancellable() }

        let key = UUID()
        let cancellable = AnyCancellable(cancellations: cancellations) { [weak cancellations] in
            cancellations?.cancelAll(for: key)
        }

        try await AnyCancellable.$contexts.withValue(AnyCancellable.contexts + [CancellableKey(key: key)]) {
            try await perform()
        }

        return cancellable
    }
}
