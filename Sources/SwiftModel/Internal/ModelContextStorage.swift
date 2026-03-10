import ConcurrencyExtras

// MARK: - ModelContextStorage

/// A typed key + default value for per-context metadata storage.
///
/// Declare one as a computed property on `ModelContextKeys`. The source location
/// captured at `init` time serves as the unique dictionary key — no separate enum needed.
///
/// ```swift
/// extension ModelContextKeys {
///     var isTrackingUndo: ModelContextStorage<Bool> { .init(defaultValue: false) }
/// }
///
/// // Access via node.metadata (read/write resolved by @dynamicMemberLookup):
/// node.metadata.isTrackingUndo        // Bool
/// node.metadata.isTrackingUndo = true
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

// MARK: - ModelContextKeys

/// A namespace for declaring named context storage keys as computed properties.
///
/// Properties declared here return a `ModelContextStorage<V>` descriptor. The
/// `@dynamicMemberLookup` subscript on `ModelContextValues` resolves keypaths through
/// this type into actual get/set calls on the context's storage.
///
/// ```swift
/// extension ModelContextKeys {
///     var myFlag: ModelContextStorage<Bool> { .init(defaultValue: false) }
/// }
/// ```
struct ModelContextKeys: Sendable {}

// MARK: - ModelContextValues

/// Provides `@dynamicMemberLookup` access to a context's metadata storage via `ModelContextKeys`.
///
/// Access via `node.metadata`:
/// ```swift
/// node.metadata.myFlag        // read → Bool
/// node.metadata.myFlag = true // write
/// ```
@dynamicMemberLookup
struct ModelContextValues: Sendable {
    // Optional: nil when the node is unanchored. Reads return defaultValue, writes are no-ops.
    let context: AnyContext?

    // Direct subscript for explicit access with a storage descriptor.
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

    // @dynamicMemberLookup: KeyPath<ModelContextKeys, ModelContextStorage<V>> → V
    subscript<V>(dynamicMember path: KeyPath<ModelContextKeys, ModelContextStorage<V>>) -> V {
        get { self[ModelContextKeys()[keyPath: path]] }
        nonmutating set { self[ModelContextKeys()[keyPath: path]] = newValue }
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
