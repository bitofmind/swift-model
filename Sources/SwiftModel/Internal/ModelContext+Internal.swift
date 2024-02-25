import Foundation
import Dependencies

extension ModelContext {
    var reference: Context<M>.Reference? {
        switch source {
        case let .reference(reference):
            return reference

        case .initial, .frozenCopy, .lastSeen:
            return nil
        }
    }

    var context: Context<M>? {
        reference?.context
    }

    var modelID: ModelID {
        switch source {
        case let .reference(reference): reference.modelID
        case let .initial(initial): initial.id
        case let .frozenCopy(id: id), let .lastSeen(id: id): id
        }
    }

    var lifetime: ModelLifetime {
        switch source {
        case let .reference(reference): reference.context?.lifetime ?? .destructed
        case .initial: .initial
        case .frozenCopy: .frozenCopy
        case .lastSeen: .destructed
        }
    }

    func enforcedContext(_ function: StaticString = #function) -> Context<M>? {
        enforcedContext("Calling \(function) on an unanchored model is not allowed and has no effect")
    }

    func enforcedContext(_ message: @autoclosure () -> String) -> Context<M>? {
        guard let context else {
            XCTFail(message())
            return nil
        }

        return context
    }

    var modifyContext: Context<M>? {
        switch source {
        case let .reference(reference):
            return reference.context
        case .initial:
            return nil
        case .frozenCopy:
            XCTFail("Modifying an frozen copy of a model is not allowed and has no effect")
            return nil
        case .lastSeen:
            XCTFail("Modifying an destructed model is not allowed and has no effect")
            return nil
        }
    }
}

extension Model {
    var lifetime: ModelLifetime {
        _$modelContext.lifetime
    }
}

extension ModelContainer {
    mutating func withContextAdded<M: Model, Container: ModelContainer>(context: Context<M>, containerPath: WritableKeyPath<M, Container>, elementPath: WritableKeyPath<Container, Self>, includeSelf: Bool) {
        var visitor = AnchorVisitor(value: self, context: context, containerPath: containerPath, elementPath: elementPath)
        visit(with: &visitor, includeSelf: includeSelf)
        self = visitor.value
    }

    func forEachContext(callback: (AnyContext) -> Void) {
        withoutActuallyEscaping(callback) { callback in
            _ = transformModel(with: ForEachTransformer(callback: callback))
        }
    }

    func activate() {
        forEachContext { _ = $0.onActivate() }
    }
}

private struct ForEachTransformer: ModelTransformer {
    let callback: (AnyContext) -> Void
    func transform<M: Model>(_ model: inout M) -> Void {
        if let context = model.context {
            callback(context)
        }
    }
}

extension ModelContext {
    init(context: Context<M>) {
        _access = nil
        source = .reference(context.reference)
    }
}

extension Model {
    var reference: Context<Self>.Reference? { _$modelContext.reference }

    var context: Context<Self>? {
        reference?.context
    }

    var isInitial: Bool {
        if case .initial = _$modelContext.source { true } else { false }
    }

    var modelID: ModelID {
        _$modelContext.modelID
    }

    mutating func withContextAdded(context: Context<Self>) {
        var visitor = AnchorVisitor(value: self, context: context, containerPath: \.self, elementPath: \.self)
        visit(with: &visitor, includeSelf: true)
        self = visitor.value
    }
}

extension ModelContext {
    func willAccess<T>(_ model: M, at path: WritableKeyPath<M, T>) -> (() -> Void)? {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), let context, let observable = model as? any Observable&Model {
            observable.access(path: path, from: context)
        }

        return access?.willAccess(model, at: path)
    }

    func willModify<T>(_ model: M, at path: WritableKeyPath<M, T>) -> (() -> Void)? {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), let context, let observable = model as? any Observable&Model {
            observable.willSet(path: path, from: context)
            defer {
                observable.didSet(path: path, from: context)
            }
            return access?.willModify(model, at: path)
        } else {
            return access?.willModify(model, at: path)
        }
    }
}

extension ModelNode {
    func access<T>(path: WritableKeyPath<M, T>, from model: M) {
        _$modelContext.willAccess(model, at: path)?()
    }

    func withMutation<Member, T>(of model: M, keyPath: WritableKeyPath<M, Member>, _ mutation: () throws -> T) rethrows -> T {

        let postModify = _$modelContext.willModify(model, at: keyPath)
        defer {
            postModify?()
        }
        return try mutation()
    }
}

extension ModelContext {
    subscript<T>(model: M, path: WritableKeyPath<M, T>) -> T {
        _read {
            if threadLocals.forceDirectAccess {
                yield model[keyPath: path]
            } else {
                switch source {
                case let .reference(reference):
                    if let context = reference.context {
                        yield context[path, willAccess(model, at: path)]
                    } else if let lastSeenValue = reference.lastSeenValue  {
                        yield lastSeenValue[keyPath: path]
                    } else {
                        yield model[keyPath: path]
                    }

                case let .initial(initial):
                    yield initial[fallback: model][keyPath: path]

                case .frozenCopy, .lastSeen:
                    yield model[keyPath: path]
                }
            }
        }

        nonmutating _modify {
            guard let context = modifyContext else {
                if case let .initial(initial) = source {
                    yield &initial[fallback: model][keyPath: path]
                } else {
                    var model = model
                    yield &model[keyPath: path]
                }
                return
            }

            yield &context[path, willModify(model, at: path)]
        }
    }

    func transaction<Value, T>(with model: M, at path: WritableKeyPath<M, Value>, modify: (inout Value) throws -> T) rethrows -> T {
        guard let context = modifyContext else {
            if case let .initial(initial) = source {
                return try modify(&initial[fallback: model][keyPath: path])
            } else {
                var value = model[keyPath: path]
                return try modify(&value)
            }
        }

        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), let observable = model as? any Observable&Model {
            observable.willSet(path: path, from: context)
            defer {
                observable.didSet(path: path, from: context)
            }
            return try context.transaction(at: path, callback: access?.willModify(model, at: path), modify: modify)
        } else {
            return try context.transaction(at: path, callback: access?.willModify(model, at: path), modify: modify)
        }
    }
}
