import Foundation
import IdentifiedCollections

/// A conforming type will allow it's members to be visited by the provided visitor.
/// For Custom types, such as nested struct or enums you would preferable used the
/// @ModelContainer instead such as:
///
///     @ModelContainer enum State {
///         case unauthorized(LoginModel)
///         case authorized(UserModel)
///     }
///
public protocol ModelContainer {
    func visit(with visitor: inout ContainerVisitor<Self>)
}

extension Optional: ModelContainer where Wrapped: ModelContainer {
    public func visit(with visitor: inout ContainerVisitor<Self>) {
        guard let value = self else { return }

        visitor.visitDynamically(with: value, at: path(value: value) {
            $0
        } set: { root, value in
            guard root != nil else { return }
            root = value
        })
    }
}

extension Array: ModelContainer where Element: ModelContainer & Identifiable { }

public extension MutableCollection where Self: ModelContainer, Element: Identifiable, Index: Sendable, Element.ID: Sendable {
    func visit(with visitor: inout ContainerVisitor<Self>) {
        for index in indices {
            let element = self[index]
            let id = threadLocals.withValue(true, at: \.forceDirectAccess) { element.id }
            let path = path(id: id) { collection in
                if index >= collection.startIndex && index < collection.endIndex {
                    let element = collection[index]
                    if element.id == id {
                        return element
                    }
                }

                return collection.first { $0.id == id }!
            } set: { collection, value in
                if index >= collection.startIndex && index < collection.endIndex {
                    let element = collection[index]
                    if element.id == id {
                        collection[index] = value
                        return
                    }
                }

                guard let index = collection.firstIndex(where: { $0.id == id }) else { return }

                collection[index] = value
            }

            visitor.visitDynamically(with: element, at: path)
        }
    }
}

extension IdentifiedArray: ModelContainer where Element: ModelContainer {
    public func visit(with visitor: inout ContainerVisitor<Self>) where ID: Sendable {
        for id in ids {
            let path = path(id: id) { collection in
                collection[id: id]!
            } set: { collection, value in
                collection[id: id] = value
            }

            visitor.visitDynamically(with: self[id: id]!, at: path)
        }
    }
}

extension Dictionary: ModelContainer where Value: ModelContainer {
    public func visit(with visitor: inout ContainerVisitor<Self>) where Key: Sendable {
        for key in keys {
            let path = path(id: key) { collection in
                collection[key]!
            } set: { collection, value in
                collection[key] = value
            }

            visitor.visitDynamically(with: self[key]!, at: path)
        }
    }
}

public extension ModelContainer {
    func path<ID: Hashable, Value>(id: ID, get: @escaping @Sendable (Self) -> Value, set: @escaping @Sendable (inout Self, Value) -> Void) -> WritableKeyPath<Self, Value> {
        let cursor = ContainerCursor(id: id, get: get, set: set)
        return \Self.[cursor: cursor]
    }

    func path<Value>(caseName: String, value: Value, get: @escaping @Sendable (Self) -> Value?, set: @escaping @Sendable (inout Self, Value) -> Void) -> WritableKeyPath<Self, Value> {
        let cursor = ContainerCursor(id: caseName, get: { get($0)! }, set: set)
        return \Self.[cursor: cursor]
    }

    func path<Value: Identifiable>(caseName: String, value: Value, get: @escaping @Sendable (Self) -> Value?, set: @escaping @Sendable (inout Self, Value) -> Void) -> WritableKeyPath<Self, Value> {
        let cursor = ContainerCursor(id: CaseAndID(caseName: caseName, id: value.id), get: { get($0)! }, set: set)
        return \Self.[cursor: cursor]
    }

    func path<Value>(value: Value, get: @escaping @Sendable (Self) -> Value?, set: @escaping @Sendable (inout Self, Value) -> Void) -> WritableKeyPath<Self, Value> {
        let cursor = ContainerCursor(id: anyHashable(from: value), get: { get($0)! }, set: set)
        return \Self.[cursor: cursor]
    }
}
