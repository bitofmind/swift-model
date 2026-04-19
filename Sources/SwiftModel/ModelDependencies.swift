import Dependencies

/// A mutable container of dependency overrides passed to `andTester`, `withDependencies`, or `withAnchor`.
///
/// `ModelDependencies` wraps `swift-dependencies`' `DependencyValues` and adds tracking of
/// any model-typed dependencies so they can be managed as part of the model hierarchy.
///
/// You interact with `ModelDependencies` through its `@dynamicMemberLookup` subscript, which
/// mirrors the `DependencyValues` key path syntax:
///
/// ```swift
/// let (model, tester) = AppModel().andTester {
///     $0.uuid = .incrementing
///     $0.continuousClock = ImmediateClock()
///     $0.apiClient = .mock
/// }
/// ```
@dynamicMemberLookup
public struct ModelDependencies: Sendable {
    var dependencies: DependencyValues
    var models: [AnyHashableSendable: any Model] = [:]

    private mutating func updateWithValue<Value>(_ value: Value, forKey key: some Hashable&Sendable) {
        if let model = value as? any Model {
            models[AnyHashableSendable(key)] = model
        }
    }

    public subscript<Key: DependencyKey>(type: Key.Type) -> Key.Value {
        get { dependencies[type] }
        set {
            dependencies[type] = newValue
            updateWithValue(newValue, forKey: ObjectIdentifier(type))
        }
    }

    public subscript<Value>(dynamicMember key: WritableKeyPath<DependencyValues, Value>&Sendable) -> Value {
        get { dependencies[keyPath: key] }
        set {
            dependencies[keyPath: key] = newValue
            updateWithValue(newValue, forKey: key)
        }
    }
}
