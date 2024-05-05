import Dependencies

@dynamicMemberLookup
public struct ModelDependencies {
    var dependencies: DependencyValues
    var models: [AnyHashable: any Model] = [:]

    private mutating func updateWithValue<Value>(_ value: Value, forKey key: AnyHashable) {
        if let model = value as? any Model {
            models[key] = model
        }
    }

    public subscript<Key: DependencyKey>(type: Key.Type) -> Key.Value {
        get { dependencies[type] }
        set {
            dependencies[type] = newValue
            updateWithValue(newValue, forKey: ObjectIdentifier(type))
        }
    }

    public subscript<Value>(dynamicMember key: WritableKeyPath<DependencyValues, Value>) -> Value {
        get { dependencies[keyPath: key] }
        set {
            dependencies[keyPath: key] = newValue
            updateWithValue(newValue, forKey: key)
        }
    }
}
