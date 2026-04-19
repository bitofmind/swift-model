/// A stream for observing changes to model properties.
///
///     let countChanges = Observed { model.count }
///     let sumChanges = Observed { model.counts.reduce(0, +) }
///
/// An observation can be to any number of properties or models, and the stream will re-calculated it's value if any of the observed values are changed.
/// Observation are typically iterated using the a model's node `forEach` helper, often set up in the `onActive()` callback:
///
///     func onActivate() {
///       node.forEach(Observed { count }) {
///         print("count did update to", $0)
///       }
///     }
public struct Observed<Element: Sendable>: AsyncSequence, Sendable {
    let stream: AsyncStream<Element>

    /// Create as Observed stream observing updates of the values provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter coalesceUpdates: Whether to batch rapid dependency changes into single updates (defaults to true).
    /// - Parameter debug: Debug options controlling trigger and change output. Only active in `DEBUG` builds.
    /// - Parameter access: closure providing the value to be observed
    @_disfavoredOverload
    public init(initial: Bool = true, coalesceUpdates: Bool = true, debug: DebugOptions? = nil, _ access: @Sendable @escaping () -> Element) {
        self.init(access: access, initial: initial, isSame: { (l: Element, r: Element) in dynamicEqual(l, r) }, coalesceUpdates: coalesceUpdates, debug: debug)
    }

    public func makeAsyncIterator() -> AsyncStream<Element>.Iterator {
        stream.makeAsyncIterator()
    }
}

public extension Observed where Element: Equatable {
    /// Create as Observed stream observing changes of the value provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter removeDuplicates: Whether to filter out duplicate values (defaults to true).
    /// - Parameter coalesceUpdates: Whether to batch rapid dependency changes into single updates (defaults to true).
    /// - Parameter debug: Debug options controlling trigger and change output. Only active in `DEBUG` builds.
    /// - Parameter access: closure providing the value to be observed
    init(initial: Bool = true, removeDuplicates: Bool = true, coalesceUpdates: Bool = true, debug: DebugOptions? = nil, _ access: @Sendable @escaping () -> Element) {
        let isSame: (@Sendable (Element, Element) -> Bool)? = removeDuplicates ? buildObservationIsSame(Element.self) : nil
        stream = Observed(access: access, initial: initial, isSame: isSame, coalesceUpdates: coalesceUpdates, debug: debug).stream
    }
}

public extension Observed {
    /// Create as Observed stream observing changes of the value provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter removeDuplicates: Whether to filter out duplicate values (defaults to true).
    /// - Parameter coalesceUpdates: Whether to batch rapid dependency changes into single updates (defaults to true).
    /// - Parameter debug: Debug options controlling trigger and change output. Only active in `DEBUG` builds.
    /// - Parameter access: closure providing the value to be observed
    init<each T: Equatable>(initial: Bool = true, removeDuplicates: Bool = true, coalesceUpdates: Bool = true, debug: DebugOptions? = nil, _ access: @Sendable @escaping () -> (repeat each T)) where Element == (repeat each T) {
        stream = Observed(access: access, initial: initial, isSame: removeDuplicates ? isSame : nil, coalesceUpdates: coalesceUpdates, debug: debug).stream
    }

    /// Create as Observed stream observing changes of the value provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter removeDuplicates: Whether to filter out duplicate values (defaults to true).
    /// - Parameter coalesceUpdates: Whether to batch rapid dependency changes into single updates (defaults to true).
    /// - Parameter debug: Debug options controlling trigger and change output. Only active in `DEBUG` builds.
    /// - Parameter access: closure providing the value to be observed
    init<each T: Equatable>(initial: Bool = true, removeDuplicates: Bool = true, coalesceUpdates: Bool = true, debug: DebugOptions? = nil, _ access: @Sendable @escaping () -> (repeat each T)?) where Element == (repeat each T)? {
        stream = Observed(access: access, initial: initial, isSame: removeDuplicates ? isSame : nil, coalesceUpdates: coalesceUpdates, debug: debug).stream
    }
}

public extension Model {
    /// Returns a stream that emits whenever any state in the model or any of its descendants changes.
    ///
    /// This is useful for cross-cutting concerns that need to react to *any* change in a subtree
    /// without caring about which specific property changed. Common use cases include:
    ///
    /// - **Dirty tracking**: detect unsaved changes to show a "modified" indicator
    /// - **Debounced autosave**: debounce rapid changes before persisting to disk
    /// - **Undo/redo stacks**: use ``ModelNode/onChange(capture:perform:)`` which skips
    ///   restore notifications automatically and provides lazy snapshot capture
    ///
    /// ```swift
    /// func onActivate() {
    ///     // Show unsaved-changes indicator whenever anything in the form changes
    ///     node.forEach(observeAnyModification()) { _ in
    ///         hasUnsavedChanges = true
    ///     }
    ///
    ///     // Debounced autosave
    ///     node.task {
    ///         for await _ in observeAnyModification().debounce(for: .seconds(2)) {
    ///             await save()
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// The stream emits once per transaction (multiple mutations inside a `node.transaction { }`
    /// produce a single emission). It finishes when the model is deactivated.
    ///
    /// > Note: This method is on `Model` directly (not `node`), so you call it as
    /// > `observeAnyModification()` from within the model, or `model.observeAnyModification()`
    /// > from a parent.
    func observeAnyModification() -> AsyncStream<()> {
        guard let context = enforcedContext() else { return .finished }

        return AsyncStream { cont in
            let cancel = context.onAnyModification { didFinish in
                if didFinish {
                    cont.finish()
                } else {
                    cont.yield(())
                }
                return nil
            }

            cont.onTermination = { _ in
                cancel()
            }
        }
    }

}
