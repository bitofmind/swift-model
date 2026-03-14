import Foundation
import AsyncAlgorithms

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

    /// Returns a sequence that emits when events of type `eventType` is sent from model or any of its descendants of the type `fromType`.
    func event<Event: Sendable, FromModel: Sendable>(ofType eventType: Event.Type, fromType modelType: FromModel.Type) -> AsyncStream<(event: Event, model: FromModel)> {
        guard let context = enforcedContext() else { return .never }
        return context.events().compactMap {
            guard let event = $0.event as? Event, let model = $0.context.anyModel as? FromModel else { return nil }
            return (event, model)
        }.eraseToStream()
    }
}

public extension ModelNode {
    /// Returns a sequence that emits when events equal to the provided `event` is sent from this model.
    func event(of event: M.Event) -> AsyncStream<()> where M.Event: Equatable&Sendable {
        guard let context = enforcedContext() else { return .never }
        return context.events().compactMap {
            guard let e = $0.event as? M.Event, e == event, $0.context === context else { return nil }
            return ()
        }.eraseToStream()
    }

    /// Returns a sequence that emits when events equal to the provided `event` is sent from this model or any of its descendants.
    func event<Event: Equatable&Sendable>(of event: Event) -> AsyncStream<()> {
        guard let context = enforcedContext() else { return .never }
        return context.events().compactMap {
            guard let e = $0.event as? Event, e == event else { return nil }
            return ()
        }.eraseToStream()
    }

    /// Returns a sequence that emits when events equal to the provided `event` is sent from this model or any of its descendants.
    ///
    ///     forEach(events(of: .someEvent, fromType: ChildModel.self)) { model in ... }
    func event<FromModel: Model>(of event: FromModel.Event, fromType modelType: FromModel.Type) -> AsyncStream<FromModel> where FromModel.Event: Equatable&Sendable {
        guard let context = enforcedContext() else { return .never }
        return context.events().compactMap {
            guard let e = $0.event as? FromModel.Event, e == event, let model = $0.context.anyModel as? FromModel else { return nil }
            return model
        }.eraseToStream()
    }

    /// Returns a sequence that emits when events equal to the provided `event` is sent from this model or any of its descendants of type `fromType`.
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

    public static let `self` = ModelRelation(rawValue: 1 << 0)
    public static let ancestors = ModelRelation(rawValue: 1 << 1)
    public static let descendants = ModelRelation(rawValue: 1 << 2)
    public static let parent = ModelRelation(rawValue: 1 << 3)
    public static let children = ModelRelation(rawValue: 1 << 4)
    public static let dependencies = ModelRelation(rawValue: 1 << 5)
}
