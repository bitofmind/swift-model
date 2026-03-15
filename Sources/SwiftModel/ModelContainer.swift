import Foundation
import IdentifiedCollections

/// A protocol for types that hold `@Model`-typed children and expose them for hierarchy traversal.
///
/// `ModelContainer` conformance is what lets SwiftModel walk into a property and manage its
/// child models (activation, cancellation, event routing, observation, etc.).
///
/// You rarely need to implement this protocol manually. Use the `@ModelContainer` macro instead:
///
/// ```swift
/// @ModelContainer enum Destination {
///     case login(LoginModel)
///     case home(HomeModel)
/// }
/// ```
///
/// `Optional<M>`, `Array<M>`, `IdentifiedArray<M>`, and `Dictionary<Key, M>` already conform
/// for any `ModelContainer`-conforming element type `M`.
public protocol ModelContainer: Sendable {
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

public extension MutableCollection where Self: ModelContainer, Element: Identifiable&Sendable, Index: Sendable, Element.ID: Sendable {
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

                // Fall back to a linear search; if the item has been removed,
                // return the captured snapshot value so stale key paths don't crash.
                return collection.first { $0.id == id } ?? element
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

    func path<Value: Identifiable&Sendable>(caseName: String, value: Value, get: @escaping @Sendable (Self) -> Value?, set: @escaping @Sendable (inout Self, Value) -> Void) -> WritableKeyPath<Self, Value> {
        let cursor = ContainerCursor(id: CaseAndID(caseName: caseName, id: value.id), get: { get($0)! }, set: set)
        return \Self.[cursor: cursor]
    }

    /// Creates a key path into this container keyed by the value's own type identity.
    ///
    /// Use this overload inside a `@ModelContainer` `visit` implementation when there is no
    /// explicit `ID` to key on — for example, for an `Optional` whose element is not `Identifiable`.
    /// The cursor is created from the runtime identity of `value`.
    func path<Value>(value: Value, get: @escaping @Sendable (Self) -> Value?, set: @escaping @Sendable (inout Self, Value) -> Void) -> WritableKeyPath<Self, Value> {
        let cursor = ContainerCursor(id: anyHashable(from: value), get: { get($0)! }, set: set)
        return \Self.[cursor: cursor]
    }
}
