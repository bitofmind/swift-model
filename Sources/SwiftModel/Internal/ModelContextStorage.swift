import ConcurrencyExtras

// Sentinel thrown by `environmentValue(for:)` to short-circuit ancestor traversal.
private struct EnvironmentValueFound: Error {
    let value: Any
}

// MARK: - StoragePropagation

/// Controls how a `ModelContextStorage` value is read and written across the model hierarchy.
enum StoragePropagation: Sendable {
    /// Read and write only on this context. Default behavior.
    case local
    /// Read walks up to the nearest ancestor that has set the value (or returns `defaultValue`).
    /// Write stores on this context and fires observation notifications on all descendants.
    case environment
}

// MARK: - ModelContextStorage

/// A typed key + default value for per-context metadata storage.
///
/// Declare one as a computed property on `ModelContextKeys`. The source location
/// captured at `init` time serves as the unique dictionary key — no separate enum needed.
///
/// ```swift
/// extension ModelContextKeys {
///     var isTrackingUndo: ModelContextStorage<Bool> { .init(defaultValue: false) }
///     var theme: ModelContextStorage<ColorScheme> { .init(defaultValue: .light, propagation: .environment) }
/// }
///
/// // Access via node.metadata:
/// node.metadata.isTrackingUndo        // Bool (.local)
/// node.metadata.theme                 // ColorScheme (.environment — reads nearest ancestor)
/// node.metadata.theme = .dark         // stores here, notifies descendants
/// ```
struct ModelContextStorage<Value: Sendable>: Sendable {
    let defaultValue: Value
    let key: AnyHashableSendable
    let propagation: StoragePropagation
    let onRemoval: (@Sendable (Value) -> Void)?

    /// Default init: uses the source location as the unique storage key.
    init(
        defaultValue: Value,
        propagation: StoragePropagation = .local,
        onRemoval: (@Sendable (Value) -> Void)? = nil,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        self.defaultValue = defaultValue
        self.propagation = propagation
        self.key = AnyHashableSendable(FileAndLine(fileID: fileID, filePath: fileID, line: line, column: column))
        self.onRemoval = onRemoval
    }

    /// Explicit-key init: use when you need a stable key independent of source location.
    init<K: Hashable & Sendable>(
        defaultValue: Value,
        key: K,
        propagation: StoragePropagation = .local,
        onRemoval: (@Sendable (Value) -> Void)? = nil
    ) {
        self.defaultValue = defaultValue
        self.propagation = propagation
        self.key = AnyHashableSendable(key)
        self.onRemoval = onRemoval
    }
}

// MARK: - ModelContextKeys

/// A namespace for declaring named context storage keys as computed properties.
///
/// ```swift
/// extension ModelContextKeys {
///     var myFlag: ModelContextStorage<Bool> { .init(defaultValue: false) }
///     var theme: ModelContextStorage<ColorScheme> { .init(defaultValue: .light, propagation: .environment) }
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
/// node.metadata.theme         // reads nearest ancestor that set it
/// node.metadata.theme = .dark // stores here, notifies descendants
/// ```
@dynamicMemberLookup
struct ModelContextValues: Sendable {
    // Optional: nil when the node is unanchored. Reads return defaultValue, writes are no-ops.
    let context: AnyContext?

    init(context: AnyContext?) {
        self.context = context
    }

    // Direct subscript for explicit access with a storage descriptor.
    subscript<V>(storage: ModelContextStorage<V>) -> V {
        get {
            guard let context else { return storage.defaultValue }
            switch storage.propagation {
            case .local:
                return context[storage]
            case .environment:
                // Walk ancestors calling willAccessEnvironmentKey on each — this registers
                // observation dependencies at every level so any ancestor write is detected.
                return context.environmentValue(for: storage)
            }
        }
        nonmutating set {
            guard let context else { return }
            // Both local and environment writes just store on this context.
            // For environment keys the observation system fires naturally because
            // readers registered willAccess on this context during their walk.
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
            lock {
                contextStorage[storage.key] = ContextStorageEntry(value: newValue, cleanup: cleanup)
            }
            if storage.propagation == .environment {
                didModifyEnvironmentKey(storage.key)
            }
        }
    }

    /// Walk up the ancestor chain (including self) to find the nearest context that has set
    /// this key, calling `willAccessEnvironmentKey` on every visited context so that all
    /// active observation tracking registers a dependency on each level.
    ///
    /// Uses `reduceHierarchy` so that:
    /// - Multiple parents are all visited (shared-model safe).
    /// - `observedParents` is used at each level, so structural changes (re-parenting) also
    ///   trigger re-evaluation of observers.
    /// - Deduplication prevents visiting the same ancestor twice.
    func environmentValue<V>(for storage: ModelContextStorage<V>) -> V {
        do {
            try reduceHierarchy(for: [.self, .ancestors], transform: \.self, into: ()) { _, ctx in
                ctx.willAccessEnvironmentKey(storage.key)
                if let entry = ctx.contextStorage[storage.key], let value = entry.value as? V {
                    throw EnvironmentValueFound(value: value)
                }
            }
        } catch let found as EnvironmentValueFound {
            return found.value as! V
        } catch {}
        return storage.defaultValue
    }

    /// Remove a previously stored environment value from this context, returning it to
    /// inheriting from the nearest ancestor that has set it (or defaultValue if none).
    /// Fires observation notifications so observers of this context re-evaluate.
    func removeEnvironmentValue<V>(for storage: ModelContextStorage<V>) {
        let hadEntry = lock {
            guard let entry = contextStorage[storage.key] else { return false }
            entry.cleanup?()
            contextStorage.removeValue(forKey: storage.key)
            return true
        }
        if hadEntry {
            didModifyEnvironmentKey(storage.key)
        }
    }
}
