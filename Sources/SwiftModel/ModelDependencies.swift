import Dependencies

@dynamicMemberLookup
public struct ModelDependencies {
    var dependencies: DependencyValues
    var models: [any Model] = []

    private mutating func updateWithValue<Value>(_ value: Value) {
        if let model = value as? any Model {
            models.append(model)
        }
    }

    public subscript<Key: DependencyKey>(type: Key.Type) -> Key.Value {
        get { dependencies[type] }
        set {
            dependencies[type] = newValue
            updateWithValue(newValue)
        }
    }

    public subscript<Value>(dynamicMember key: WritableKeyPath<DependencyValues, Value>) -> Value {
        get { dependencies[keyPath: key] }
        set {
            dependencies[keyPath: key] = newValue
            updateWithValue(newValue)
        }
    }
}
