import Foundation
import ConcurrencyExtras
import IssueReporting

/// A `ModelContainer` view of a tracked property whose declared type is an `any` existential
/// (`any P`, `(any P)?`). When the value holds a `Model`, `visit` opens it and visits it at its
/// concrete type; any other value (nil, or a non-model existential) holds no child.
///
/// It is never stored: `Model._existentialChildPath` projects it from (and writes it back into)
/// the property, and that key path is the children bucket both the anchoring traversal and the
/// write path reconcile under.
struct _ExistentialChild<Value>: ModelContainer, @unchecked Sendable {
    var value: Value

    public func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
        guard let child = value as? any Model else {
            #if DEBUG
            reportUnsupportedExistentialModels(in: value)
            #endif
            return
        }
        visitor._visitExistentialChild(child)
    }
}

#if DEBUG
private let reportedUnsupportedExistentials = LockIsolated<Set<ObjectIdentifier>>([])

/// An existential that holds models SwiftModel can't reach — a collection of them (`[any P]`,
/// `[K: any P]`) — would otherwise leave them silently unanchored. Reported once per type.
private func reportUnsupportedExistentialModels<Value>(in value: Value) {
    guard let sequence = value as? any Sequence, containsModel(sequence) else { return }
    let isNew = reportedUnsupportedExistentials.withValue { $0.insert(ObjectIdentifier(Value.self)).inserted }
    guard isNew else { return }
    reportIssue("A property of type `\(Value.self)` holds models, but collections of existential models are not supported: the models in it are not anchored. Store them as concrete model types, or one model behind `any P` / `(any P)?`.")
}

private func containsModel(_ sequence: some Sequence) -> Bool {
    sequence.contains { element in
        if element is any Model { return true }
        // Dictionary elements are (key, value) tuples.
        return Mirror(reflecting: element).children.contains { $0.value is any Model }
    }
}
#endif

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
