import Dependencies
import ConcurrencyExtras

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
