import Foundation
import Dependencies

@dynamicMemberLookup
public struct ModelNode<M: Model> {
    public let _$modelContext: ModelContext<M>

    public init(_$modelContext: ModelContext<M>) {
        self._$modelContext = _$modelContext
    }
}

extension ModelNode: Sendable where M: Sendable {}

public extension ModelNode {
    func transaction<T>(_ callback: () throws -> T) rethrows -> T {
        if let context {
            return try ModelAccess.$isInModelTaskContext.withValue(true) {
                try context.transaction(callback)
            }
        } else {
            return try callback()
        }
    }

    private var isDestructed: Bool {
        if case let .reference(reference) = _$modelContext.source, reference.isDestructed, reference.context == nil {
            true
        } else if case .lastSeen = _$modelContext.source {
            true
        } else {
            false
        }
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<DependencyValues, Value>&Sendable) -> Value {
        if isDestructed {
            // Most likely being accessed by SwiftUI shortly after being destructed, no need for runtime warning.
            if let access = _$modelContext.access as? LastSeenAccess,
               -access.timestamp.timeIntervalSinceNow < lastSeenTimeToLive,
               let value = access.dependencyCache[keyPath] as? Value {
                return value
            }

            return Dependency(keyPath).wrappedValue
        }

        guard let context = enforcedContext("Accessing dependency `\(String(describing: keyPath).replacingOccurrences(of: "\\DependencyValues.", with: ""))` on an unanchored model node is not allowed and will be redirected to the default dependency value") else {
            return Dependency(keyPath).wrappedValue
        }

        let value = context.dependency(for: keyPath)
        if let dependencyModel = value as? any Model {
            return dependencyModel.withAccessIfPropagateToChildren(access) as! Value
        } else {
            return value
        }
    }

    subscript<Value: DependencyKey>(type: Value.Type) -> Value where Value.Value == Value {
        if isDestructed {
            // Most likely being accessed by SwiftUI shortly after being destructed, no need for runtime warning.
            let key = ObjectIdentifier(type)
            if let access = _$modelContext.access as? LastSeenAccess,
               -access.timestamp.timeIntervalSinceNow < lastSeenTimeToLive,
               let value = access.dependencyCache[key] as? Value {
                return value
            }

            return Dependency(type).wrappedValue
        }

        guard let context = enforcedContext("Accessing dependency `\(String(describing: type))` on an unanchored model node is not allowed and will be redirected to the default dependency value") else {
            return Dependency(type).wrappedValue
        }

        let value = context.dependency(for: type)
        if let dependencyModel = value as? any Model {
            return dependencyModel.withAccessIfPropagateToChildren(access) as! Value
        } else {
            return value
        }
    }

    var isUniquelyReferenced: Bool {
        context.map { $0.parents.count <= 1 } ?? true
    }

    func uniquelyReferenced() -> AsyncStream<Bool> {
        guard let rootParent = enforcedContext()?.rootParent else {
            return .never
        }

        return AsyncStream { cont in
            cont.yield(isUniquelyReferenced)

            let cancel = rootParent.onAnyModification { isFinished in
                if isFinished {
                    cont.finish()
                } else {
                    cont.yield(isUniquelyReferenced)
                }

                return nil
            }

            cont.onTermination = { _ in
                cancel()
            }
        }.removeDuplicates().eraseToStream()
    }

    func reduceHierarchy<Result, Element>(for relation: ModelRelation, transform: (any Model) throws -> Element?, into initialResult: Result, _ updateAccumulatingResult: (inout Result, Element) throws -> ()) rethrows -> Result {
        try context?.reduceHierarchy(for: relation, transform: {
            try transform($0.anyModel.withAccessIfPropagateToChildren(access))
        }, into: initialResult, updateAccumulatingResult) ?? initialResult
    }

    func mapHierarchy<Element>(for relation: ModelRelation, transform: (any Model) throws -> Element?) rethrows -> [Element] {
        try reduceHierarchy(for: relation, transform: transform, into: []) {
            $0.append($1)
        }
    }
}

extension ModelNode {
    var modelContext: ModelContext<M> { _$modelContext }

    func enforcedContext(_ function: StaticString = #function) -> Context<M>? {
        enforcedContext("Calling \(function) on an unanchored model node is not allowed and has no effect")
    }

    func enforcedContext(_ message: @autoclosure () -> String) -> Context<M>? {
        guard let context else {
            reportIssue(message())
            return nil
        }

        return context
    }

    var context: Context<M>? {
        modelContext.context
    }

    var access: ModelAccess? {
        modelContext.access
    }

    var typeDescription: String {
        String(describing: M.self)
    }

    var modelID: ModelID {
        modelContext.modelID
    }
}
