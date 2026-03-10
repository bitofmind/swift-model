import ConcurrencyExtras

// MARK: - ModelContextStorage

/// A typed key + default value for per-context metadata storage.
///
/// Create one as a private/fileprivate constant at the declaration site of the property
/// you want to expose on `ModelContextValues`. The source location captured at `init`
/// time serves as the unique dictionary key, so no separate enum boilerplate is needed.
///
/// ```swift
/// extension ModelContextValues {
///     var isTrackingUndo: Bool {
///         get { self[_isTrackingUndo] }
///         nonmutating set { self[_isTrackingUndo] = newValue }
///     }
/// }
/// private let _isTrackingUndo = ModelContextStorage(defaultValue: false)
/// ```
///
/// You can also supply an explicit key when the source-location default is not unique enough
/// (e.g. generated code):
///
/// ```swift
/// private let _myKey = ModelContextStorage(defaultValue: 0, key: "myFeature.counter")
/// ```
struct ModelContextStorage<Value: Sendable>: Sendable {
    let defaultValue: Value
    let key: AnyHashableSendable
    let onRemoval: (@Sendable (Value) -> Void)?

    /// Default init: uses the source location as the unique storage key.
    init(
        defaultValue: Value,
        onRemoval: (@Sendable (Value) -> Void)? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        self.defaultValue = defaultValue
        self.key = AnyHashableSendable(FileAndLine(fileID: fileID, filePath: fileID, line: line, column: column))
        self.onRemoval = onRemoval
    }

    /// Explicit-key init: use when you need a stable key independent of source location.
    init<K: Hashable & Sendable>(defaultValue: Value, key: K, onRemoval: (@Sendable (Value) -> Void)? = nil) {
        self.defaultValue = defaultValue
        self.key = AnyHashableSendable(key)
        self.onRemoval = onRemoval
    }
}

// MARK: - ModelContextEntry

/// A typed get/set accessor into a context's metadata storage for a specific `ModelContextStorage`.
///
/// Returned by `ModelContextValues` subscripts. The `@dynamicMemberLookup` subscript
/// on `ModelContextValues` resolves keypaths through this type, providing clean
/// `node.metadata.someKey` read/write syntax.
struct ModelContextEntry<Value: Sendable>: Sendable {
    let get: @Sendable () -> Value
    let set: @Sendable (Value) -> Void
}

// MARK: - ModelContextValues

/// A namespace struct providing `@dynamicMemberLookup` access to a context's metadata storage.
///
/// Declare properties as extensions that return `ModelContextEntry<V>` via the storage subscript.
/// The `@dynamicMemberLookup` subscript resolves those keypaths into actual get/set calls.
///
/// Usage:
/// ```swift
/// private let _myFlag = ModelContextStorage(defaultValue: false)
///
/// extension ModelContextValues {
///     var myFlag: Bool {
///         get { self[_myFlag] }
///         nonmutating set { self[_myFlag] = newValue }
///     }
/// }
///
/// // Access via node.metadata:
/// node.metadata.myFlag        // read
/// node.metadata.myFlag = true // write
/// ```
@dynamicMemberLookup
struct ModelContextValues: Sendable {
    // Optional: nil when the node is unanchored. Reads return defaultValue, writes are no-ops.
    let context: AnyContext?

    subscript<V>(storage: ModelContextStorage<V>) -> V {
        get {
            guard let context else { return storage.defaultValue }
            return context[storage]
        }
        nonmutating set {
            guard let context else { return }
            context[storage] = newValue
        }
    }

    subscript<V>(dynamicMember path: KeyPath<ModelContextValues, V>) -> V {
        self[keyPath: path]
    }
}

// MARK: - AnyContext typed storage subscript + metadata accessor

extension AnyContext {
    /// A `ModelContextValues` accessor for this context, enabling `context.metadata.someKey` syntax.
    var metadata: ModelContextValues {
        ModelContextValues(context: self)
    }

    subscript<V>(storage: ModelContextStorage<V>) -> V {
        get {
            contextStorage[storage.key]?.value as? V ?? storage.defaultValue
        }
        set {
            let v = newValue
            let cleanup: (() -> Void)? = storage.onRemoval.map { onRemoval in { onRemoval(v) } }
            contextStorage[storage.key] = ContextStorageEntry(value: newValue, cleanup: cleanup)
        }
    }
}
