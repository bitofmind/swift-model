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
