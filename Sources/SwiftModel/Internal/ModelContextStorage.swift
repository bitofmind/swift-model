import ConcurrencyExtras

// Sentinel thrown by `environmentValue(for:)` to short-circuit ancestor traversal.
private struct EnvironmentValueFound: Error {
    let value: Any
}

// MARK: - StoragePropagation

/// Controls how a `ContextStorage` value is read and written across the model hierarchy.
///
/// Use `.local` (the default) for node-private state. Use `.environment` when you want a
/// value set on an ancestor to be visible to all of its descendants without explicit passing.
public enum StoragePropagation: Sendable {
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
/// ## Declaring a context key
///
/// ```swift
/// extension ContextKeys {
///     var isFeatureEnabled: ContextStorage<Bool> {
///         .init(defaultValue: false)
///     }
///     var theme: ContextStorage<ColorScheme> {
///         .init(defaultValue: .light, propagation: .environment)
///     }
/// }
/// ```
///
/// ## Accessing via `node.context`
///
/// ```swift
/// // Read
/// let enabled = node.context.isFeatureEnabled
/// let current = node.context.theme   // walks up to nearest ancestor that set it
///
/// // Write
/// node.context.isFeatureEnabled = true
/// node.context.theme = .dark         // stores here, notifies all descendants
/// ```
///
/// ## Propagation modes
///
/// - `.local` (default): the value is read and written on this node only.
/// - `.environment`: writes store on this node; reads walk up to the nearest ancestor
///   that has set the value, returning `defaultValue` if none has.
public struct ContextStorage<Value: Sendable>: Hashable, Sendable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
    /// The value returned when no storage entry has been set for this key.
    public let defaultValue: Value
    let key: AnyHashableSendable
    /// The property name captured from the `ContextKeys` call site via `#function`.
    /// Used in test exhaustion failure messages to show `context.isDarkMode` instead of `UNKNOWN`.
    let name: String
    /// Controls whether the value propagates down the model hierarchy.
    public let propagation: StoragePropagation
    let onRemoval: (@Sendable (Value) -> Void)?
    /// When `true`, writes to this storage are not surfaced to `TestAccess` for observation
    /// or exhaustion checking. Used for system-internal storage (undo, memoize) that should
    /// not appear as unasserted state changes in user tests.
    let isSystemStorage: Bool
    /// Optional equality check. When set, a write that doesn't change the stored value is a no-op
    /// and fires no observation notifications. Nil means always notify (non-Equatable types).
    let isEqual: (@Sendable (Value, Value) -> Bool)?

    /// Creates a context storage descriptor using the call-site source location as the unique key.
    ///
    /// Because each computed property on `ContextKeys` has its own source location, distinct
    /// properties produce distinct keys automatically — no explicit key type is needed.
    ///
    /// - Parameters:
    ///   - defaultValue: The value returned when no entry has been set.
    ///   - propagation: Whether the value is node-local or inheritable from ancestors. Defaults to `.local`.
    public init(
        defaultValue: Value,
        propagation: StoragePropagation = .local,
        function: StaticString = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        self.defaultValue = defaultValue
        self.propagation = propagation
        self.key = AnyHashableSendable(FileAndLine(fileID: fileID, filePath: fileID, line: line, column: column))
        self.name = "\(function)".sanitizedPropertyName
        self.onRemoval = nil
        self.isSystemStorage = false
        self.isEqual = nil
    }

    /// Creates a context storage descriptor with an explicit stable key.
    ///
    /// Use this when you need the key to be stable across source-file renames or when you want
    /// to share a key across multiple call sites.
    ///
    /// - Parameters:
    ///   - defaultValue: The value returned when no entry has been set.
    ///   - key: An explicit stable key. Must be `Hashable` and `Sendable`.
    ///   - propagation: Whether the value is node-local or inheritable from ancestors. Defaults to `.local`.
    public init<K: Hashable & Sendable>(
        defaultValue: Value,
        key: K,
        propagation: StoragePropagation = .local,
        function: StaticString = #function
    ) {
        self.defaultValue = defaultValue
        self.propagation = propagation
        self.key = AnyHashableSendable(key)
        self.name = "\(function)".sanitizedPropertyName
        self.onRemoval = nil
        self.isSystemStorage = false
        self.isEqual = nil
    }

    /// Internal init that exposes all parameters — used by system code (undo, memoize).
    init(
        defaultValue: Value,
        propagation: StoragePropagation = .local,
        onRemoval: (@Sendable (Value) -> Void)? = nil,
        isSystemStorage: Bool,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        self.defaultValue = defaultValue
        self.propagation = propagation
        self.key = AnyHashableSendable(FileAndLine(fileID: fileID, filePath: fileID, line: line, column: column))
        self.name = ""
        self.onRemoval = onRemoval
        self.isSystemStorage = isSystemStorage
        self.isEqual = nil
    }

    /// Internal explicit-key init that exposes all parameters.
    init<K: Hashable & Sendable>(
        defaultValue: Value,
        key: K,
        propagation: StoragePropagation = .local,
        onRemoval: (@Sendable (Value) -> Void)? = nil,
        isSystemStorage: Bool
    ) {
        self.defaultValue = defaultValue
        self.propagation = propagation
        self.key = AnyHashableSendable(key)
        self.name = ""
        self.onRemoval = onRemoval
        self.isSystemStorage = isSystemStorage
        self.isEqual = nil
    }
}

extension ContextStorage where Value: Equatable {
    /// Creates a context storage descriptor for an `Equatable` value, using the call-site
    /// source location as the unique key.
    ///
    /// Writes that do not change the currently stored value are suppressed — no observation
    /// notifications are fired. This is the preferred init for `Equatable` value types.
    ///
    /// - Parameters:
    ///   - defaultValue: The value returned when no entry has been set.
    ///   - propagation: Whether the value is node-local or inheritable from ancestors. Defaults to `.local`.
    public init(
        defaultValue: Value,
        propagation: StoragePropagation = .local,
        function: StaticString = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        self.defaultValue = defaultValue
        self.propagation = propagation
        self.key = AnyHashableSendable(FileAndLine(fileID: fileID, filePath: fileID, line: line, column: column))
        self.name = "\(function)".sanitizedPropertyName
        self.onRemoval = nil
        self.isSystemStorage = false
        self.isEqual = { $0 == $1 }
    }

    /// Creates a context storage descriptor for an `Equatable` value with an explicit stable key.
    ///
    /// - Parameters:
    ///   - defaultValue: The value returned when no entry has been set.
    ///   - key: An explicit stable key. Must be `Hashable` and `Sendable`.
    ///   - propagation: Whether the value is node-local or inheritable from ancestors. Defaults to `.local`.
    public init<K: Hashable & Sendable>(
        defaultValue: Value,
        key: K,
        propagation: StoragePropagation = .local,
        function: StaticString = #function
    ) {
        self.defaultValue = defaultValue
        self.propagation = propagation
        self.key = AnyHashableSendable(key)
        self.name = "\(function)".sanitizedPropertyName
        self.onRemoval = nil
        self.isSystemStorage = false
        self.isEqual = { $0 == $1 }
    }

    /// Internal Equatable init that exposes all parameters.
    init(
        defaultValue: Value,
        propagation: StoragePropagation = .local,
        onRemoval: (@Sendable (Value) -> Void)? = nil,
        isSystemStorage: Bool,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        self.defaultValue = defaultValue
        self.propagation = propagation
        self.key = AnyHashableSendable(FileAndLine(fileID: fileID, filePath: fileID, line: line, column: column))
        self.name = ""
        self.onRemoval = onRemoval
        self.isSystemStorage = isSystemStorage
        self.isEqual = { $0 == $1 }
    }

    /// Internal Equatable explicit-key init.
    init<K: Hashable & Sendable>(
        defaultValue: Value,
        key: K,
        propagation: StoragePropagation = .local,
        onRemoval: (@Sendable (Value) -> Void)? = nil,
        isSystemStorage: Bool
    ) {
        self.defaultValue = defaultValue
        self.propagation = propagation
        self.key = AnyHashableSendable(key)
        self.name = ""
        self.onRemoval = onRemoval
        self.isSystemStorage = isSystemStorage
        self.isEqual = { $0 == $1 }
    }
}

// MARK: - ContextKeys

/// A namespace for declaring named context storage keys as computed properties.
///
/// Extend `ContextKeys` with computed properties that return `ContextStorage<Value>` descriptors.
/// SwiftModel uses the source location of each property declaration as a unique key automatically,
/// so no separate enum or string identifier is required.
///
/// ```swift
/// extension ContextKeys {
///     var isFeatureEnabled: ContextStorage<Bool> {
///         .init(defaultValue: false)
///     }
///     var theme: ContextStorage<ColorScheme> {
///         .init(defaultValue: .light, propagation: .environment)
///     }
/// }
/// ```
///
/// Access values via `node.context`:
///
/// ```swift
/// node.context.isFeatureEnabled        // read
/// node.context.isFeatureEnabled = true // write
/// ```
public struct ContextKeys: Sendable {
    public init() {}
}

// MARK: - ContextValues

/// Provides `@dynamicMemberLookup` access to a model node's context storage via `ContextKeys`.
///
/// You obtain a `ContextValues` instance from `node.context` inside your model implementation.
/// Properties declared on `ContextKeys` are directly accessible as dynamic members.
///
/// ```swift
/// // Inside a model implementation (via node.context):
/// let enabled = node.context.isFeatureEnabled   // read
/// node.context.isFeatureEnabled = true           // write
/// let current = node.context.theme              // reads nearest ancestor (.environment)
/// node.context.theme = .dark                    // stores here, notifies descendants
/// ```
@dynamicMemberLookup
public struct ContextValues: Sendable {
    // Optional: nil when the node is unanchored. Reads return defaultValue, writes are no-ops.
    let context: AnyContext?

    init(context: AnyContext?) {
        self.context = context
    }

    /// Reads or writes a context value using a storage descriptor directly.
    public subscript<V>(storage: ContextStorage<V>) -> V {
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

    /// Reads or writes a context value using a key path on `ContextKeys`.
    public subscript<V>(dynamicMember path: KeyPath<ContextKeys, ContextStorage<V>>) -> V {
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
            let changed = lock {
                if let isEqual = storage.isEqual,
                   let existing = contextStorage[storage.key]?.value as? V,
                   isEqual(existing, newValue) {
                    return false
                }
                contextStorage[storage.key] = ContextStorageEntry(value: newValue, cleanup: cleanup)
                return true
            }
            // Don't notify observers for system-internal storage (undo, memoize, etc.) —
            // those writes should not surface as unasserted state in TestAccess exhaustion checks.
            if changed && !storage.isSystemStorage {
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
