import ConcurrencyExtras

// Sentinel thrown by `environmentValue(for:)` to short-circuit ancestor traversal.
private struct EnvironmentValueFound: Error {
    let value: Any
}

// MARK: - StoragePropagation

/// Controls how a `ContextStorage` value is read and written across the model hierarchy.
enum StoragePropagation: Sendable {
    /// Read and write only on this context. Default behavior.
    case local
    /// Read walks up to the nearest ancestor that has set the value (or returns `defaultValue`).
    /// Write stores on this context and fires observation notifications on all descendants.
    case environment
}

// MARK: - ContextStorage

/// A typed key + default value for per-context storage.
///
/// Declare one as a computed property on `ContextKeys`. The source location
/// captured at `init` time serves as the unique dictionary key — no separate enum needed.
///
/// ```swift
/// extension ContextKeys {
///     var isTrackingUndo: ContextStorage<Bool> { .init(defaultValue: false) }
///     var theme: ContextStorage<ColorScheme> { .init(defaultValue: .light, propagation: .environment) }
/// }
///
/// // Access via node.context:
/// node.context.isTrackingUndo        // Bool (.local)
/// node.context.theme                 // ColorScheme (.environment — reads nearest ancestor)
/// node.context.theme = .dark         // stores here, notifies descendants
/// ```
struct ContextStorage<Value: Sendable>: Hashable, Sendable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    let defaultValue: Value
    let key: AnyHashableSendable
    let propagation: StoragePropagation
    let onRemoval: (@Sendable (Value) -> Void)?
    /// When `true`, writes to this storage are not surfaced to `TestAccess` for observation
    /// or exhaustion checking. Used for system-internal storage (undo, memoize) that should
    /// not appear as unasserted state changes in user tests.
    let isSystemStorage: Bool

    /// Default init: uses the source location as the unique storage key.
    init(
        defaultValue: Value,
        propagation: StoragePropagation = .local,
        onRemoval: (@Sendable (Value) -> Void)? = nil,
        isSystemStorage: Bool = false,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        self.defaultValue = defaultValue
        self.propagation = propagation
        self.key = AnyHashableSendable(FileAndLine(fileID: fileID, filePath: fileID, line: line, column: column))
        self.onRemoval = onRemoval
        self.isSystemStorage = isSystemStorage
    }

    /// Explicit-key init: use when you need a stable key independent of source location.
    init<K: Hashable & Sendable>(
        defaultValue: Value,
        key: K,
        propagation: StoragePropagation = .local,
        onRemoval: (@Sendable (Value) -> Void)? = nil,
        isSystemStorage: Bool = false
    ) {
        self.defaultValue = defaultValue
        self.propagation = propagation
        self.key = AnyHashableSendable(key)
        self.onRemoval = onRemoval
        self.isSystemStorage = isSystemStorage
    }
}

// MARK: - ContextKeys

/// A namespace for declaring named context storage keys as computed properties.
///
/// ```swift
/// extension ContextKeys {
///     var myFlag: ContextStorage<Bool> { .init(defaultValue: false) }
///     var theme: ContextStorage<ColorScheme> { .init(defaultValue: .light, propagation: .environment) }
/// }
/// ```
struct ContextKeys: Sendable {}

// MARK: - ContextValues

/// Provides `@dynamicMemberLookup` access to a context's storage via `ContextKeys`.
///
/// Access via `node.context`:
/// ```swift
/// node.context.myFlag        // read → Bool
/// node.context.myFlag = true // write
/// node.context.theme         // reads nearest ancestor that set it
/// node.context.theme = .dark // stores here, notifies descendants
/// ```
@dynamicMemberLookup
struct ContextValues: Sendable {
    // Optional: nil when the node is unanchored. Reads return defaultValue, writes are no-ops.
    let context: AnyContext?

    init(context: AnyContext?) {
        self.context = context
    }

    // Direct subscript for explicit access with a storage descriptor.
    subscript<V>(storage: ContextStorage<V>) -> V {
        get {
            guard let context else { return storage.defaultValue }
            switch storage.propagation {
            case .local:
                return context[storage]
            case .environment:
                // Walk ancestors calling willAccessStorage on each — this registers
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

    // @dynamicMemberLookup: KeyPath<ContextKeys, ContextStorage<V>> → V
    subscript<V>(dynamicMember path: KeyPath<ContextKeys, ContextStorage<V>>) -> V {
        get { self[ContextKeys()[keyPath: path]] }
        nonmutating set { self[ContextKeys()[keyPath: path]] = newValue }
    }
}

// MARK: - AnyContext typed storage subscript + context accessor

extension AnyContext {
    var context: ContextValues {
        ContextValues(context: self)
    }

    subscript<V>(storage: ContextStorage<V>) -> V {
        get {
            if !storage.isSystemStorage {
                willAccessStorage(storage)
            }
            return contextStorage[storage.key]?.value as? V ?? storage.defaultValue
        }
        set {
            let v = newValue
            let cleanup: (() -> Void)? = storage.onRemoval.map { onRemoval in { onRemoval(v) } }
            lock {
                contextStorage[storage.key] = ContextStorageEntry(value: newValue, cleanup: cleanup)
            }
            // Don't notify observers for system-internal storage (undo, memoize, etc.) —
            // those writes should not surface as unasserted state in TestAccess exhaustion checks.
            if !storage.isSystemStorage {
                didModifyStorage(storage)
            }
        }
    }

    /// Walk up the ancestor chain (including self) to find the nearest context that has set
    /// this key, calling `willAccessStorage` on every visited context so that all
    /// active observation tracking registers a dependency on each level.
    ///
    /// Uses `reduceHierarchy` so that:
    /// - Multiple parents are all visited (shared-model safe).
    /// - `observedParents` is used at each level, so structural changes (re-parenting) also
    ///   trigger re-evaluation of observers.
    /// - Deduplication prevents visiting the same ancestor twice.
    func environmentValue<V>(for storage: ContextStorage<V>) -> V {
        do {
            try reduceHierarchy(for: [.self, .ancestors], transform: \.self, into: ()) { _, ctx in
                ctx.willAccessStorage(storage)
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
    func removeEnvironmentValue<V>(for storage: ContextStorage<V>) {
        let hadEntry = lock {
            guard let entry = contextStorage[storage.key] else { return false }
            entry.cleanup?()
            contextStorage.removeValue(forKey: storage.key)
            return true
        }
        if hadEntry {
            didModifyStorage(storage)
        }
    }
}

// MARK: - Internal Model subscript for context storage observation
//
// Provides a WritableKeyPath<M, V> rooted at the Model type itself.
// Swift requires keypath subscript indices to be Hashable; AnyHashableSendable satisfies this,
// and distinct storage keys produce distinct AnyHashableSendable values, so Swift forms
// a distinct WritableKeyPath<M, V> per storage key. This path composes with rootPaths in
// TestAccess exactly like a regular @Model property keypath.
//
// This subscript is internal-only — it is the bridge between the typed storage system
// and the TestAccess observation machinery. Users always use `node.context.myKey`;
// `Context<M>` uses this subscript internally in willAccessStorage/didModifyStorage
// to produce the typed keypath needed for TestAccess snapshot tracking.
extension Model {
    subscript<V>(_metadata storage: ContextStorage<V>) -> V {
        // The subscript index must be Hashable for keypath formation. We use a wrapper
        // that hashes/equals on storage.key so distinct storages produce distinct paths.
        get { node.context[storage] }
        set { node.context[storage] = newValue }
    }
}
