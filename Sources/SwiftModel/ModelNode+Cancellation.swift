import Foundation

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
    /// Groups activities under a named key so they can all be cancelled at once via `cancelAll(for:)`.
    ///
    /// Every `task`, `forEach`, and `onCancel` call made *inside* the `perform` closure is
    /// registered under `key`. Calling `node.cancelAll(for: key)` later cancels all of them
    /// together, without affecting work registered outside this block:
    ///
    /// ```swift
    /// node.cancellationContext(for: "saveFlow") {
    ///     node.task { await validate() }
    ///     node.task { await upload() }
    /// }
    ///
    /// // Cancel both tasks at once:
    /// node.cancelAll(for: "saveFlow")
    /// ```
    ///
    /// Use the keyless `cancellationContext(perform:)` variant when you don't need to cancel
    /// from outside — it returns a `Cancellable` you hold directly.
    func cancellationContext<T>(for key: some Hashable&Sendable, perform: () throws -> T) rethrows -> T {
        guard let cancellations = enforcedContext()?.cancellations else { return try perform() }

        let _ = AnyCancellable(cancellations: cancellations) { [weak cancellations] in
            cancellations?.cancelAll(for: key)
        }

        return try AnyCancellable.$contexts.withValue(AnyCancellable.contexts + [CancellableKey(key: key)]) {
            try perform()
        }
    }
    
    /// Async variant of `cancellationContext(for:perform:)`.
    ///
    /// Identical semantics to the synchronous overload but accepts an `async` closure. Use this
    /// when the setup work inside the context itself is asynchronous.
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
    /// Groups activities under an anonymous key and returns a `Cancellable` that cancels all of them.
    ///
    /// Use this when you want to hold the cancellation handle directly rather than using a named key.
    /// A common pattern is to combine it with `cancelInFlight()` to ensure only one group of tasks
    /// runs at a time:
    ///
    /// ```swift
    /// func onReload() {
    ///     node.cancellationContext {
    ///         node.task { await fetchData() }
    ///         node.task { await fetchMetadata() }
    ///     }.cancelInFlight()
    /// }
    /// ```
    ///
    /// Use `cancellationContext(for:perform:)` instead when you need to trigger cancellation from
    /// a different call site (e.g. a "Cancel" button).
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

    /// Async variant of the keyless `cancellationContext(perform:)`.
    ///
    /// Identical semantics to the synchronous overload but accepts an `async` closure.
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
