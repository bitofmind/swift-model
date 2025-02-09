import Foundation

public extension ModelNode {
    /// Sends an event.
    /// - Parameter event: even to send.
    /// - Parameter receivers: Receivers of the event, default to self and ancestors.
    func send(_ event: M.Event, to relation: ModelRelation = [.self, .ancestors]) {
        guard let context = enforcedContext() else { return }
        context.sendEvent(event, to: relation, context: context)
        access?.didSend(event: event, from: context)
    }

    /// Sends an event.
    /// - Parameter event: even to send.
    /// - Parameter receivers: Receivers of the event, default to self and ancestors.
    func send<E>(_ event: E, to relation: ModelRelation = [.self, .ancestors]) {
        guard let context = enforcedContext() else { return }
        context.sendEvent(event, to: relation, context: context)
        access?.didSend(event: event, from: context)
    }
}

public extension ModelNode {
    func event() -> AsyncStream<Any&Sendable> {
        guard let context = enforcedContext() else { return .never }
        return context.events().map(\.event).eraseToStream()
    }

    /// Returns a sequence that emits when events of type `eventType` is sent from this model or any of its descendants.
    func event<Event: Sendable>(ofType eventType: Event.Type) -> AsyncStream<Event> {
        guard let context = enforcedContext() else { return .never }
        return context.events().compactMap {
            guard let e = $0.event as? Event else { return nil }
            return e
        }.eraseToStream()
    }

    /// Returns a sequence of events sent from this model or any of its descendants.
    ///
    ///     forEach(events(fromType: ChildModel.self)) { event, model in ... }
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
