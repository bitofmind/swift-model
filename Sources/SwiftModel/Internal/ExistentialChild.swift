import Foundation
import ConcurrencyExtras
import IssueReporting

/// A `ModelContainer` view of a value whose declared type is an `any` existential (`any P`,
/// `(any P)?`) or a collection of them (`[any P]`, `[Key: any P]`). `visit` opens every `Model`
/// the value holds and visits it at its concrete type; any other value holds no child.
///
/// It is never stored: `_existentialChildPath` projects it from (and writes it back into) the
/// property, and that key path is the children bucket both the anchoring traversal and the
/// write path reconcile under.
struct _ExistentialChild<Value>: ModelContainer, _ExistentialChildView, @unchecked Sendable {
    var value: Value

    public func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
        if let child = value as? any Model {
            visitor._visitExistentialChild(child)
        } else if let dictionary = value as? any _ExistentialKeyedStorage {
            visitor._visitExistentialEntries(of: dictionary)
        } else if let collection = value as? any MutableCollection {
            visitor._visitExistentialElements(of: collection)
        } else {
            #if DEBUG
            reportUnsupportedExistentialModels(in: value)
            #endif
        }
    }
}

/// Marks `_ExistentialChild` for visitors that special-case it without knowing its `Value`.
protocol _ExistentialChildView {}

/// Whether `value` (an existential, or a collection of them) holds at least one model.
func existentialHoldsModels<Value>(_ value: Value) -> Bool {
    if value is any Model { return true }
    if let dictionary = value as? any _ExistentialKeyedStorage { return dictionary._containsModel }
    if let sequence = value as? any Sequence { return sequence.contains { $0 is any Model } }
    return false
}

/// The keyed collections whose existential values are visited by key (`Dictionary`).
protocol _ExistentialKeyedStorage {
    associatedtype _Key: Hashable
    associatedtype _Value
    var _keys: [_Key] { get }
    subscript(_existentialEntry key: _Key) -> _Value? { get set }
}

extension _ExistentialKeyedStorage {
    var _containsModel: Bool { _keys.contains { self[_existentialEntry: $0] is any Model } }
}

extension Dictionary: _ExistentialKeyedStorage {
    var _keys: [Key] { Array(keys) }
    subscript(_existentialEntry key: Key) -> Value? {
        get { self[key] }
        set { self[key] = newValue }
    }
}

#if DEBUG
private let reportedUnsupportedExistentials = LockIsolated<Set<ObjectIdentifier>>([])

/// An existential that holds models SwiftModel can't reach — a sequence that is neither a
/// `MutableCollection` nor a `Dictionary` — would otherwise leave them silently unanchored.
/// Reported once per type.
private func reportUnsupportedExistentialModels<Value>(in value: Value) {
    guard let sequence = value as? any Sequence, sequence.contains(where: { $0 is any Model }) else { return }
    let isNew = reportedUnsupportedExistentials.withValue { $0.insert(ObjectIdentifier(Value.self)).inserted }
    guard isNew else { return }
    reportIssue("A property of type `\(Value.self)` holds models, but only `MutableCollection`s (such as `Array`) and `Dictionary`s of existential models are supported: the models in it are not anchored.")
}
#endif

/// Immutable once formed; `AnyHashable` just isn't declared `Sendable`.
nonisolated(unsafe) private let existentialSkipID = AnyHashable(0)

/// The identity of a model held in an existential collection: its concrete type and `id`
/// (different concrete types may use the same `id` values).
/// `@unchecked Sendable`: `id` is a model's `id`, immutable once formed.
struct ExistentialElementID: Hashable, @unchecked Sendable {
    var type: ObjectIdentifier
    var id: AnyHashable
}

extension ContainerVisitor {
    mutating func _visitExistentialChild<C: Model, Value>(_ child: C) where V.State == _ExistentialChild<Value> {
        let fallback = child
        // `Model.id` is `Hashable` but not necessarily `Sendable`; the cursor compares through
        // `fallback` (a `Sendable` model) instead of capturing the id itself.
        let cursor = ContainerCursor<AnyHashable, _ExistentialChild<Value>, C>(id: AnyHashable(child.id), get: { box in
            // A stale path (the property now holds another child, or nil) reads the captured
            // child, like the other container cursors' fallbacks.
            guard let current = box.value as? C, current.id == fallback.id else { return fallback }
            return current
        }, set: { box, newValue in
            guard let current = box.value as? C, current.id == fallback.id else { return }
            box.value = newValue as! Value
        })
        modelVisitor.visit(path: \_ExistentialChild<Value>.[cursor: cursor])
    }
}

extension ContainerVisitor {
    mutating func _visitExistentialElements<C: MutableCollection, Value>(of collection: C) where V.State == _ExistentialChild<Value> {
        for index in collection.indices {
            guard let child = collection[index] as? any Model else { continue }
            _visitExistentialElement(child, at: index, in: C.self)
        }
    }

    mutating func _visitExistentialElement<M: Model, C: MutableCollection, Value>(_ child: M, at index: C.Index, in _: C.Type) where V.State == _ExistentialChild<Value> {
        // Fast path: already registered with a current context — no cursor needed. (The `id`
        // argument is not consulted by the visitors that skip; a constant avoids an
        // `AnyHashable` conversion per element.)
        if shouldSkipElement(element: child, id: existentialSkipID) { return }

        let slot = ExistentialElementSlot<C, M, Value>(index: index, fallback: child)
        let cursor = ContainerCursor<ExistentialElementID, _ExistentialChild<Value>, M>(
            id: ExistentialElementID(type: ObjectIdentifier(M.self), id: AnyHashable(child.id)),
            get: { slot.get($0) }, set: { slot.set(&$0, $1) })
        modelVisitor.visit(path: \_ExistentialChild<Value>.[cursor: cursor])
    }

    mutating func _visitExistentialEntries<D: _ExistentialKeyedStorage, Value>(of dictionary: D) where V.State == _ExistentialChild<Value> {
        for key in dictionary._keys {
            guard let child = dictionary[_existentialEntry: key] as? any Model else { continue }
            _visitExistentialEntry(child, key: key, in: D.self)
        }
    }

    mutating func _visitExistentialEntry<M: Model, D: _ExistentialKeyedStorage, Value>(_ child: M, key: D._Key, in _: D.Type) where V.State == _ExistentialChild<Value> {
        if shouldSkipElement(element: child, id: existentialSkipID) { return }

        let slot = ExistentialEntrySlot<D, M, Value>(key: key, fallback: child)
        let cursor = ContainerCursor<ExistentialElementID, _ExistentialChild<Value>, M>(
            id: ExistentialElementID(type: ObjectIdentifier(M.self), id: AnyHashable(child.id)),
            get: { slot.get($0) }, set: { slot.set(&$0, $1) })
        modelVisitor.visit(path: \_ExistentialChild<Value>.[cursor: cursor])
    }
}

// The cursor logic for one element of an existential collection lives in these slots, so the
// cursor's `@Sendable` closures capture an instance, not the collection's generic metatypes.
// `@unchecked Sendable`: immutable once formed (the index or key, and a captured model value).

/// One element of an existential `MutableCollection`, found by its last known index and then by
/// identity (it may have moved).
private final class ExistentialElementSlot<C: MutableCollection, M: Model, Value>: @unchecked Sendable {
    let index: C.Index
    let fallback: M

    init(index: C.Index, fallback: M) {
        self.index = index
        self.fallback = fallback
    }

    func position(in collection: C) -> C.Index? {
        if collection.indices.contains(index), let current = collection[index] as? M, current.id == fallback.id {
            return index
        }
        return collection.firstIndex { ($0 as? M)?.id == fallback.id }
    }

    /// A stale path (the element was removed) reads the captured model, like the other
    /// container cursors' fallbacks.
    func get(_ box: _ExistentialChild<Value>) -> M {
        guard let collection = box.value as? C, let at = position(in: collection) else { return fallback }
        return collection[at] as! M
    }

    func set(_ box: inout _ExistentialChild<Value>, _ newValue: M) {
        if Value.self == C.self {
            // Mutate in place: a cast-out copy would share the buffer and copy it on write,
            // once per element of a traversal.
            withUnsafeMutablePointer(to: &box.value) { pointer in
                pointer.withMemoryRebound(to: C.self, capacity: 1) { collection in
                    guard let at = position(in: collection.pointee) else { return }
                    collection.pointee[at] = newValue as! C.Element
                }
            }
            return
        }
        // `Value` is an optional collection (`[any P]?`).
        guard var collection = box.value as? C, let at = position(in: collection) else { return }
        collection[at] = newValue as! C.Element
        box.value = collection as! Value
    }
}

/// One value of an existential `Dictionary`, found by key and identity.
private final class ExistentialEntrySlot<D: _ExistentialKeyedStorage, M: Model, Value>: @unchecked Sendable {
    let key: D._Key
    let fallback: M

    init(key: D._Key, fallback: M) {
        self.key = key
        self.fallback = fallback
    }

    func get(_ box: _ExistentialChild<Value>) -> M {
        guard let dictionary = box.value as? D, let current = dictionary[_existentialEntry: key] as? M, current.id == fallback.id else { return fallback }
        return current
    }

    func set(_ box: inout _ExistentialChild<Value>, _ newValue: M) {
        if Value.self == D.self {
            withUnsafeMutablePointer(to: &box.value) { pointer in
                pointer.withMemoryRebound(to: D.self, capacity: 1) { dictionary in
                    guard let current = dictionary.pointee[_existentialEntry: key] as? M, current.id == fallback.id else { return }
                    dictionary.pointee[_existentialEntry: key] = (newValue as! D._Value)
                }
            }
            return
        }
        guard var dictionary = box.value as? D, let current = dictionary[_existentialEntry: key] as? M, current.id == fallback.id else { return }
        dictionary[_existentialEntry: key] = (newValue as! D._Value)
        box.value = dictionary as! Value
    }
}

/// The hashable index of `Model[_existentialChild:]`: the property's model-level key path.
struct _ExistentialChildKey<Root, Value>: Hashable, @unchecked Sendable {
    let path: WritableKeyPath<Root, Value>
}

extension ModelContainer {
    subscript<Value>(_existentialChild key: _ExistentialChildKey<Self, Value>) -> _ExistentialChild<Value> {
        get { _ExistentialChild(value: self[keyPath: key.path]) }
        set { self[keyPath: key.path] = newValue.value }
    }

    /// The key path to the `_ExistentialChild` view of the value at `path` (a `@ModelContainer`
    /// struct property or enum case payload).
    static func _existentialChildPath<Value>(_ path: WritableKeyPath<Self, Value>) -> WritableKeyPath<Self, _ExistentialChild<Value>> {
        \Self.[_existentialChild: _ExistentialChildKey(path: path)]
    }
}

extension Model {
    /// The model-level key path to the `_ExistentialChild` view of the tracked property at `statePath`.
    static func _existentialChildPath<Value>(_ statePath: WritableKeyPath<_ModelState, Value>) -> WritableKeyPath<Self, _ExistentialChild<Value>> {
        _existentialChildPath(_modelStateKeyPath.appending(path: statePath))
    }
}

/// Whether two existential values hold the same child (same concrete model, same `id`). Used as
/// the `isSame` of an existential property's write transaction. Values that hold no model can't
/// be compared, so — as for any other non-`Equatable` property — every write counts as a change.
func existentialChildIsSame<Value>(_ lhs: Value, _ rhs: Value) -> Bool {
    guard let l = lhs as? any Model, let r = rhs as? any Model else { return false }
    return modelIsSame(l, r)
}

private func modelIsSame<L: Model>(_ lhs: L, _ rhs: any Model) -> Bool {
    guard let rhs = rhs as? L else { return false }
    return lhs.id == rhs.id
}
