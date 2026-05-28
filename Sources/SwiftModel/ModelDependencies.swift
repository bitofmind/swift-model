import Dependencies

/// A mutable container of dependency overrides passed to `withDependencies` or `withAnchor`.
///
/// `ModelDependencies` wraps `swift-dependencies`' `DependencyValues` and adds tracking of
/// any model-typed dependencies so they can be managed as part of the model hierarchy.
///
/// You interact with `ModelDependencies` through its `@dynamicMemberLookup` subscript, which
/// mirrors the `DependencyValues` key path syntax:
///
/// ```swift
/// let model = AppModel().withAnchor {
///     $0.uuid = .incrementing
///     $0.continuousClock = ImmediateClock()
///     $0.apiClient = .mock
/// }
/// ```
@dynamicMemberLookup
public struct ModelDependencies: Sendable {
    var dependencies: DependencyValues
    /// Tracked model-typed dependency entries. Each entry carries both the model value and a
    /// closure that knows how to write a new value (e.g. an `initialDependencyCopy`) back into
    /// a `DependencyValues` snapshot — used by `Context.init` to keep `capturedDependencies`
    /// in sync with the cloned `dependencyModels` entries before `withContextAdded` runs.
    var models: [AnyHashableSendable: DepModelEntry] = [:]

    struct DepModelEntry: @unchecked Sendable {
        var model: any Model
        /// `_stateVersion` of the model's Reference at the time this entry was written.
        /// Used by `Context.init` to detect whether a stored child's dep closure performed
        /// a read-modify-write on this dep after it was captured (incrementing `_stateVersion`
        /// without going through `ModelDependencies.subscript`).
        var capturedVersion: Int
        /// Writes `model` (or a replacement) back into a `DependencyValues` under the same key.
        let restoreInto: (inout DependencyValues, any Model) -> Void
    }

    private mutating func updateWithValue<Value>(
        _ value: Value,
        forKey key: some Hashable & Sendable,
        restoreInto: @escaping (inout DependencyValues, Value) -> Void
    ) {
        if let model = value as? any Model {
            func captureVer<D: Model>(_ m: D) -> Int { m.modelContext._source.reference._stateVersion }
            models[AnyHashableSendable(key)] = DepModelEntry(model: model, capturedVersion: captureVer(model)) { deps, m in
                if let typed = m as? Value { restoreInto(&deps, typed) }
            }
        }
    }

    public subscript<Key: DependencyKey>(type: Key.Type) -> Key.Value {
        get { dependencies[type] }
        set {
            dependencies[type] = newValue
            updateWithValue(newValue, forKey: ObjectIdentifier(type)) { deps, v in
                deps[Key.self] = v
            }
        }
    }

    public subscript<Value>(dynamicMember key: WritableKeyPath<DependencyValues, Value> & Sendable) -> Value {
        get { dependencies[keyPath: key] }
        set {
            dependencies[keyPath: key] = newValue
            updateWithValue(newValue, forKey: key) { deps, v in
                deps[keyPath: key] = v
            }
        }
    }
}
