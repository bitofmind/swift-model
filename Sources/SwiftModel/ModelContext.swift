import Foundation
import Dependencies

/// A read token that gives the `SwiftModel` framework access to a model's internal context.
///
/// `ModelContextAccess` can be constructed by macro-generated code (its `init` is `public`),
/// but its stored context (`_$modelContext`) is `internal` — external code cannot read the
/// context back out. This prevents consumers from bypassing the model's lifecycle management.
public struct ModelContextAccess<M: Model>: Sendable {
    /// Public so macro-generated code (in user modules) can construct the access token
    /// from the model's private stored `_$modelContext`.
    public init(_ context: ModelContext<M>) {
        self._$modelContext = context
    }

    /// Internal so only `SwiftModel` framework code can read the underlying context.
    internal let _$modelContext: ModelContext<M>
}

/// A write token that lets the `SwiftModel` framework push a new context into a model.
///
/// `ModelContextUpdate` can only be constructed inside the `SwiftModel` module (its `init` is
/// `internal`), preventing external code from forging an update. Its stored context
/// (`_$modelContext`) is `public` so macro-generated `_updateContext` (in user modules) can
/// read it and write it into the model's private stored property.
public struct ModelContextUpdate<M: Model>: Sendable {
    /// Internal so only `SwiftModel` framework code can forge an update token.
    internal init(_ context: ModelContext<M>) {
        self._$modelContext = context
    }

    /// Public so macro-generated `_updateContext` (in user modules) can read the new context.
    public let _$modelContext: ModelContext<M>
}

public struct ModelContext<M: Model> {
    /// The access reference — holds a `ModelAccess` (or its weak wrapper) for observation.
    /// Public so macro-generated `_updateContext` (in user modules) can read/write it.
    public var _access: _ModelAccessBox

    /// The unified source of truth for state, identity, and context reference.
    /// Public so macro-generated `_updateContext` (in user modules) can read/write it.
    public var _source: _ModelSourceBox<M>

    public init() {
        _access = _ModelAccessBox()
        _source = _ModelSourceBox(reference: .init(modelID: .generate(), state: _zeroInit()))
    }

    /// Public so macro-generated computed `_$modelContext` (in user modules) can construct it.
    public init(_access: _ModelAccessBox, _source: _ModelSourceBox<M>) {
        self._access = _access
        self._source = _source
    }

    var access: ModelAccess? {
        get { _access._reference?.access ?? ModelAccess.current }
        set {
            _access._reference = newValue?.reference
        }
    }

    var deepAccess: ModelAccess? {
        access.flatMap {
            $0.shouldPropagateToChildren ? $0 : nil
        }
    }

    var activeAccess: ModelAccess? {
        ModelAccess.active ?? access
    }
}

extension ModelContext: @unchecked Sendable {}

extension ModelContext: Hashable {
    public static func == (lhs: ModelContext<M>, rhs: ModelContext<M>) -> Bool {
        lhs._source.reference === rhs._source.reference
    }

    public func hash(into hasher: inout Hasher) { }
}

public extension ModelContext {
    func mirror(of model: M, children: [(String, Any)]) -> Mirror {
        if let depth = threadLocals.shallowMirrorDepth {
            if depth == 0 {
                threadLocals.shallowMirrorDepth = 1
                return Mirror(model, children: children, displayStyle: .struct)
            } else {
                return Mirror(model, children: [], displayStyle: .struct)
            }
        }
        if threadLocals.includeImplicitIDInMirror, !children.map(\.0).contains("id") {
            return Mirror(model, children: [("id", modelID)] + children, displayStyle: .struct)
        } else if threadLocals.includeImplicitIDInMirror || threadLocals.includeChildrenInMirror {
            return Mirror(model, children: children, displayStyle: .struct)
        } else {
            // Return an empty mirror so LLDB doesn't expand properties below debugDescription
            return Mirror(model, children: [], displayStyle: .struct)
        }
    }

    func description(of model: M) -> String {
        // Set includeChildrenInMirror so customDumping gets the full children via customMirror,
        // without prepending the id (which is only needed for test diffing).
        threadLocals.withValue(true, at: \.includeChildrenInMirror) {
            String(customDumping: model)
        }
    }
}

public extension ModelContext {
    func dependency<D: Model&DependencyKey>() -> D where D.Value == D {
        (_dependency() as D).withAccessIfPropagateToChildren(access)
    }

    @_disfavoredOverload
    func dependency<D: DependencyKey>() -> D where D.Value == D {
        _dependency()
    }

    func dependency<D>(for keyPath: KeyPath<DependencyValues, D> & Sendable) -> D {
        ModelNode(_$modelContext: self)[dynamicMember: keyPath]
    }

}

func containerIsSame<T: ModelContainer>(_ lhs: T, _ rhs: T) -> Bool {
    if let leftOptional = lhs as? any _Optional {
        return optionalIsSame(leftOptional, rhs)
    }

    if let leftCollection = lhs as? any Collection {
        return collectionIsSame(leftCollection, rhs)
    }

    if let leftEquatable = lhs as? any Equatable {
        return _dynamicEquatableEqual(leftEquatable, rhs as Any)
    }

    return false
}

func optionalIsSame<T: _Optional>(_ lhs: T, _ rhs: Any) -> Bool {
    let rightOptional = rhs as! T
    switch (lhs.wrappedValue, rightOptional.wrappedValue) {
    case (nil, nil):
        return true

    case (nil, _?), (_?, nil):
        return false

    case let (left?, right?):
        return modelIsSame(left, right)
    }
}

func collectionIsSame<T: Collection>(_ lhs: T, _ rhs: Any) -> Bool {
    let rightCollection = rhs as! T
    if lhs.count != rightCollection.count {
        return false
    }

    return zip(lhs, rightCollection).allSatisfy {
        modelIsSame($0, $1)
    }
}

func modelIsSame(_ lhs: Any, _ rhs: Any) -> Bool {
    if let l = lhs as? any Model {
        return _modelIsSame(l, rhs)
    } else {
        return false
    }
}

func _modelIsSame<T: Model>(_ lhs: T, _ rhs: Any) -> Bool {
    let rightOptional = rhs as! T
    return lhs.id == rightOptional.id
}
