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

// MARK: - Hashable synthesis helpers

/// Returns `true` if `lhs == rhs`, using value equality for `Equatable` types.
///
/// This overload is preferred by Swift's overload resolution when `T` conforms to `Equatable`,
/// and is used by the `@ModelContainer` macro's synthesised `==` operator.
public func _modelEqual<T: Equatable>(_ lhs: T, _ rhs: T) -> Bool {
    lhs == rhs
}

/// Returns `true` if `lhs.id == rhs.id`, for `Identifiable` types that are not `Equatable`.
///
/// This is the fallback overload used by the `@ModelContainer` macro's synthesised `==` operator
/// when the associated value type is not `Equatable` (e.g. a plain `@Model` struct).
/// Marked disfavored so the `Equatable` overload wins when `T` conforms to both.
@_disfavoredOverload
public func _modelEqual<T: Identifiable>(_ lhs: T, _ rhs: T) -> Bool {
    lhs.id == rhs.id
}

/// Returns `true` if all elements compare equal by id, for arrays of `Identifiable` types
/// that are not `Equatable` (e.g. `[@Model]` arrays).
/// Marked disfavored so the `Equatable` overload wins when `T` conforms to both.
@_disfavoredOverload
public func _modelEqual<T: Identifiable>(_ lhs: [T], _ rhs: [T]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { _modelEqual($0, $1) }
}

/// Feeds `value` into `hasher` using its full `Hashable` conformance.
///
/// This overload is preferred by Swift's overload resolution when `T` conforms to `Hashable`,
/// and is used by the `@ModelContainer` macro's synthesised `hash(into:)`.
public func _modelCombine<T: Hashable>(into hasher: inout Hasher, _ value: T) {
    hasher.combine(value)
}

/// Feeds `value.id` into `hasher` for `Identifiable` types that are not `Hashable`.
///
/// This is the fallback overload used by the `@ModelContainer` macro's synthesised `hash(into:)`
/// when the associated value type is not `Hashable` (e.g. a plain `@Model` struct).
/// Marked disfavored so the `Hashable` overload wins when `T` conforms to both.
@_disfavoredOverload
public func _modelCombine<T: Identifiable>(into hasher: inout Hasher, _ value: T) {
    hasher.combine(value.id)
}

/// Feeds each element's id into `hasher` for arrays of `Identifiable` types that are not `Hashable`
/// (e.g. `[@Model]` arrays).
/// Marked disfavored so the `Hashable` overload wins when `T` conforms to both.
@_disfavoredOverload
public func _modelCombine<T: Identifiable>(into hasher: inout Hasher, _ value: [T]) {
    for element in value { _modelCombine(into: &hasher, element) }
}

/// Fallback for types that are neither `Equatable` nor `Identifiable` (e.g. closure/function types).
/// Such values can never be meaningfully compared for equality, so this always returns `false`.
public func _modelEqual<T>(_ lhs: T, _ rhs: T) -> Bool {
    false
}

/// Fallback for types that are neither `Hashable` nor `Identifiable` (e.g. closure/function types).
/// Combines a stable zero value; closures cannot be hashed in any meaningful way.
public func _modelCombine<T>(into hasher: inout Hasher, _ value: T) {
    hasher.combine(0)
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
