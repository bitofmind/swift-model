import Foundation

public extension ModelNode {
    /// Sends an event to this model and its ancestors.
    ///
    /// Events flow upward by default: the sender and all its ancestor models receive the event.
    /// Use the `to:` parameter to restrict or broaden the recipients.
    ///
    /// ```swift
    /// // Notify parent models that the user tapped a button:
    /// node.send(.buttonTapped)
    ///
    /// // Broadcast to all descendants instead:
    /// node.send(.reset, to: .descendants)
    /// ```
    ///
    /// Parent models receive the event via `node.event(fromType:)` or `node.forEach(node.event(...))`.
    ///
    /// - Parameters:
    ///   - event: The event value to send.
    ///   - relation: Which models receive the event. Defaults to `[.self, .ancestors]`.
    func send(_ event: M.Event, to relation: ModelRelation = [.self, .ancestors]) {
        guard let context = enforcedContext() else { return }
        context.sendEvent(event, to: relation, context: context)
        access?.didSend(event: event, from: context)
    }

    /// Sends a typed event that is not the model's own `Event` type.
    ///
    /// Use this overload to send events of an arbitrary type — for example, a shared event enum
    /// defined outside the model. Recipients use `node.event(ofType:)` to receive it.
    ///
    /// - Parameters:
    ///   - event: The event value to send.
    ///   - relation: Which models receive the event. Defaults to `[.self, .ancestors]`.
    func send<E>(_ event: E, to relation: ModelRelation = [.self, .ancestors]) {
        guard let context = enforcedContext() else { return }
        context.sendEvent(event, to: relation, context: context)
        access?.didSend(event: event, from: context)
    }
}

public extension ModelNode {
    /// Returns a stream of all events sent from this model or any of its descendants, typed as `Any`.
    ///
    /// Prefer the typed overloads (`event(ofType:)`, `event(fromType:)`) over this one.
    /// Use this only when the event type is not known at compile time.
    func event() -> AsyncStream<Any&Sendable> {
        guard let context = enforcedContext() else { return .never }
        return context.events().map(\.event).eraseToStream()
    }

    /// Returns a stream of events of type `Event` sent from this model or any of its descendants.
    ///
    /// ```swift
    /// node.forEach(node.event(ofType: AppEvent.self)) { event in
    ///     handleAppEvent(event)
    /// }
    /// ```
    func event<Event: Sendable>(ofType eventType: Event.Type) -> AsyncStream<Event> {
        guard let context = enforcedContext() else { return .never }
        return context.events().compactMap {
            guard let e = $0.event as? Event else { return nil }
            return e
        }.eraseToStream()
    }

    /// Returns a stream of events sent by models of type `FromModel` within this subtree.
    ///
    /// Each element is a tuple of the event and the model that sent it. Use this in a parent
    /// model's `onActivate()` to observe child events:
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.forEach(node.event(fromType: CounterModel.self)) { event, counter in
    ///         switch event {
    ///         case .incrementTapped: totalCount += 1
    ///         }
    ///     }
    /// }
    /// ```
    func event<FromModel: Model>(fromType modelType: FromModel.Type) -> AsyncStream<(event: FromModel.Event, model: FromModel)> where FromModel.Event: Sendable {
        guard let context = enforcedContext() else { return .never }
        return context.events().compactMap {
            guard let event = $0.event as? FromModel.Event, let context = $0.context as? Context<FromModel> else { return nil }
            return (event, context.model)
        }.eraseToStream()
    }

    /// Returns a stream of events of type `Event` sent by models of type `FromModel` within this subtree.
    ///
    /// Combines the filters of `event(ofType:)` and `event(fromType:)`: only events whose type
    /// matches `eventType` **and** whose sender matches `fromType` are emitted.
    ///
    /// Use this when a model type sends more than one event type (e.g. a shared generic event enum)
    /// and you want to narrow by both the event type and the sender type:
    ///
    /// ```swift
    /// node.forEach(node.event(ofType: NetworkEvent.self, fromType: FeedModel.self)) { event, feed in
    ///     handleNetworkEvent(event, from: feed)
    /// }
    /// ```
    func event<Event: Sendable, FromModel: Sendable>(ofType eventType: Event.Type, fromType modelType: FromModel.Type) -> AsyncStream<(event: Event, model: FromModel)> {
        guard let context = enforcedContext() else { return .never }
        return context.events().compactMap {
            guard let event = $0.event as? Event, let model = $0.context.anyModel as? FromModel else { return nil }
            return (event, model)
        }.eraseToStream()
    }
}

public extension ModelNode {
    /// Returns a stream that emits `()` each time the specified event is sent from this model.
    ///
    /// Filters to exactly this sender (not descendants). Use `event(of:)` on a parent node if
    /// you want to match from any descendant.
    ///
    /// ```swift
    /// node.forEach(node.event(of: .saveTapped)) {
    ///     await save()
    /// }
    /// ```
    func event(of event: M.Event) -> AsyncStream<()> where M.Event: Equatable&Sendable {
        guard let context = enforcedContext() else { return .never }
        return context.events().compactMap {
            guard let e = $0.event as? M.Event, e == event, $0.context === context else { return nil }
            return ()
        }.eraseToStream()
    }

    /// Returns a stream that emits `()` each time the specified event value is sent from this model or any descendant.
    ///
    /// Unlike `event(of:)` with no type parameter (which filters to this sender only), this
    /// generic overload matches the event value anywhere in the subtree regardless of sender type.
    ///
    /// ```swift
    /// // React whenever any descendant sends .loggedOut:
    /// node.forEach(node.event(of: AppEvent.loggedOut)) {
    ///     showLoginScreen()
    /// }
    /// ```
    func event<Event: Equatable&Sendable>(of event: Event) -> AsyncStream<()> {
        guard let context = enforcedContext() else { return .never }
        return context.events().compactMap {
            guard let e = $0.event as? Event, e == event else { return nil }
            return ()
        }.eraseToStream()
    }

    /// Returns a stream that emits the sending model each time a specific event is sent by a model of type `FromModel`.
    ///
    /// Filters by both the event value and the sender's type. Each emission is the `FromModel`
    /// instance that sent the event, useful when you need to act on the specific sender:
    ///
    /// ```swift
    /// node.forEach(node.event(of: .deleteRequested, fromType: ItemModel.self)) { item in
    ///     items.removeAll { $0 === item }
    /// }
    /// ```
    func event<FromModel: Model>(of event: FromModel.Event, fromType modelType: FromModel.Type) -> AsyncStream<FromModel> where FromModel.Event: Equatable&Sendable {
        guard let context = enforcedContext() else { return .never }
        return context.events().compactMap {
            guard let e = $0.event as? FromModel.Event, e == event, let model = $0.context.anyModel as? FromModel else { return nil }
            return model
        }.eraseToStream()
    }

    /// Returns a stream that emits the sending model each time a specific event value is sent by a model of type `FromModel`.
    ///
    /// Use this when the event type is not `FromModel.Event` — for example when models send a
    /// shared event enum that is not their own associated `Event` type:
    ///
    /// ```swift
    /// node.forEach(node.event(of: SharedEvent.logout, fromType: SessionModel.self)) { session in
    ///     handleLogout(from: session)
    /// }
    /// ```
    func event<Event: Equatable&Sendable, FromModel: Sendable>(of event: Event, fromType modelType: FromModel.Type) -> AsyncStream<FromModel> {
        guard let context = enforcedContext() else { return .never }
        return context.events().compactMap {
            guard let e = $0.event as? Event, e == event, let model = $0.context.anyModel as? FromModel else { return nil }
            return model
        }.eraseToStream()
    }
}

/// Describes which models relative to a given node are visited or targeted by an operation.
///
/// `ModelRelation` is an `OptionSet`, so values can be combined:
///
/// ```swift
/// // Visit only direct children and their descendants:
/// node.reduceHierarchy(for: [.children, .descendants], ...) { ... }
///
/// // Send an event only to the sender itself (no ancestors):
/// node.send(.didReset, to: .self)
/// ```
///
/// - `.self`: The model itself.
/// - `.parent`: The model's direct parents only.
/// - `.ancestors`: All ancestor models (parents, grandparents, …).
/// - `.children`: The model's direct children only.
/// - `.descendants`: All descendants (children, grandchildren, …).
/// - `.dependencies`: Dependency models at each visited node (combined with another option).
public struct ModelRelation: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The model itself.
    public static let `self` = ModelRelation(rawValue: 1 << 0)
    /// All ancestor models, from the direct parent up to the root.
    public static let ancestors = ModelRelation(rawValue: 1 << 1)
    /// All descendant models, depth-first.
    public static let descendants = ModelRelation(rawValue: 1 << 2)
    /// The model's direct parents only (not grandparents).
    public static let parent = ModelRelation(rawValue: 1 << 3)
    /// The model's direct children only (not grandchildren).
    public static let children = ModelRelation(rawValue: 1 << 4)
    /// Also include dependency models at each visited node. Combine with another option,
    /// e.g. `[.self, .dependencies]`.
    public static let dependencies = ModelRelation(rawValue: 1 << 5)
}
