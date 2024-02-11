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
            return try context.transaction(callback)
        } else {
            return try callback()
        }
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<DependencyValues, Value>) -> Value {
        if case let .reference(reference) = _$modelContext.source, reference.lastSeenValue != nil {
            // Most likely being accessed by SwiftUI shortly after being destructed, no need for runtime warning.
            return Dependency(keyPath).wrappedValue
        }

        if case let .lastSeen(id: _, timestamp: timestamp) = _$modelContext.source, -timestamp.timeIntervalSinceNow < lastSeenTimeToLive {
            // Most likely being accessed by SwiftUI shortly after being destructed, no need for runtime warning.
            return Dependency(keyPath).wrappedValue
        }

        guard let context = enforcedContext("Accessing dependency `\(String(describing: keyPath).replacingOccurrences(of: "\\DependencyValues.", with: ""))` on an unanchored model node is not allowed and will be redirected to the default dependency value") else {
            return Dependency(keyPath).wrappedValue
        }
        
        return context.dependency(for: keyPath)
    }
}

extension ModelNode {
    var modelContext: ModelContext<M> { _$modelContext }

    func enforcedContext(_ function: StaticString = #function) -> Context<M>? {
        enforcedContext("Calling \(function) on an unanchored model node is not allowed and has no effect")
    }

    func enforcedContext(_ message: @autoclosure () -> String) -> Context<M>? {
        guard let context else {
            XCTFail(message())
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
