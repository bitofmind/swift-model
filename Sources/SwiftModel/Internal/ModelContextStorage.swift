import Dependencies

// Sentinel thrown by `environmentValue(for:)` to short-circuit ancestor traversal.
private struct EnvironmentValueFound: Error {
    let value: Any&Sendable
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
/// ## Accessing via `node.local` / `node.environment`
///
/// ```swift
/// // Read
/// let enabled = node.local.isFeatureEnabled
/// let current = node.environment.theme   // walks up to nearest ancestor that set it
///
/// // Write
/// node.local.isFeatureEnabled = true
/// node.environment.theme = .dark         // stores here, notifies all descendants
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

// MARK: - LocalStorage

/// A typed key + default value for node-local storage.
///
/// Declare one as a computed property on `LocalKeys`. The source location captured at `init`
/// time serves as the unique dictionary key — no separate enum or identifier is needed.
///
/// ```swift
/// extension LocalKeys {
///     var isEditing: LocalStorage<Bool> {
///         .init(defaultValue: false)
///     }
/// }
/// ```
///
/// Access values via `node.local`:
///
/// ```swift
/// node.local.isEditing = true
/// let editing = node.local.isEditing
/// ```
public struct LocalStorage<Value: Sendable>: Hashable, Sendable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage == rhs.storage }
    public func hash(into hasher: inout Hasher) { hasher.combine(storage) }
    let storage: ContextStorage<Value>

    /// Creates a local storage descriptor using the call-site source location as the unique key.
    public init(
        defaultValue: Value,
        function: StaticString = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        storage = ContextStorage(
            defaultValue: defaultValue,
            propagation: .local,
            function: function,
            fileID: fileID,
            line: line,
            column: column
        )
    }
}

extension LocalStorage where Value: Equatable {
    /// Creates a local storage descriptor for an `Equatable` value.
    ///
    /// Writes that do not change the stored value are suppressed — no observation notifications fired.
    public init(
        defaultValue: Value,
        function: StaticString = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        storage = ContextStorage(
            defaultValue: defaultValue,
            propagation: .local,
            function: function,
            fileID: fileID,
            line: line,
            column: column
        )
    }
}

// MARK: - EnvironmentStorage

/// A typed key + default value for top-down propagating storage.
///
/// Declare one as a computed property on `EnvironmentKeys`. A value written on any ancestor
/// is visible to all its descendants. Reading walks up to the nearest ancestor that has set the
/// value, returning `defaultValue` if none has.
///
/// ```swift
/// extension EnvironmentKeys {
///     var theme: EnvironmentStorage<ColorScheme> {
///         .init(defaultValue: .light)
///     }
/// }
/// ```
///
/// Access values via `node.environment`:
///
/// ```swift
/// parentNode.environment.theme = .dark        // store on parent
/// let current = childNode.environment.theme   // .dark — inherited from parent
/// childNode.environment.theme = .light        // override on child
/// ```
public struct EnvironmentStorage<Value: Sendable>: Hashable, Sendable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage == rhs.storage }
    public func hash(into hasher: inout Hasher) { hasher.combine(storage) }
    let storage: ContextStorage<Value>

    /// Creates an environment storage descriptor using the call-site source location as the unique key.
    public init(
        defaultValue: Value,
        function: StaticString = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        storage = ContextStorage(
            defaultValue: defaultValue,
            propagation: .environment,
            function: function,
            fileID: fileID,
            line: line,
            column: column
        )
    }
}

extension EnvironmentStorage where Value: Equatable {
    /// Creates an environment storage descriptor for an `Equatable` value.
    ///
    /// Writes that do not change the stored value are suppressed — no observation notifications fired.
    public init(
        defaultValue: Value,
        function: StaticString = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) {
        storage = ContextStorage(
            defaultValue: defaultValue,
            propagation: .environment,
            function: function,
            fileID: fileID,
            line: line,
            column: column
        )
    }
}

// MARK: - LocalKeys

/// A namespace for declaring named local storage keys as computed properties.
///
/// Extend `LocalKeys` with computed properties that return `LocalStorage<Value>` descriptors.
/// SwiftModel uses the source location of each property as a unique key automatically.
///
/// ```swift
/// extension LocalKeys {
///     var isEditing: LocalStorage<Bool> {
///         .init(defaultValue: false)
///     }
/// }
/// ```
///
/// Access values via `node.local`:
///
/// ```swift
/// node.local.isEditing        // read
/// node.local.isEditing = true // write
/// ```
public struct LocalKeys: Sendable {
    public init() {}
}

// MARK: - LocalValues

/// Provides `@dynamicMemberLookup` access to a model node's local storage via `LocalKeys`.
///
/// Obtained from `node.local` inside your model implementation.
///
/// ```swift
/// let editing = node.local.isEditing   // read
/// node.local.isEditing = true          // write
/// ```
@dynamicMemberLookup
public struct LocalValues: Sendable {
    let context: AnyContext?

    init(context: AnyContext?) {
        self.context = context
    }

    /// Reads or writes a local value using a storage descriptor directly.
    public subscript<V>(storage: LocalStorage<V>) -> V {
        get {
            guard let context else { return storage.storage.defaultValue }
            return context[storage.storage]
        }
        nonmutating set {
            guard let context else { return }
            context[storage.storage] = newValue
        }
    }

    /// Reads or writes a local value using a key path on `LocalKeys`.
    public subscript<V>(dynamicMember path: KeyPath<LocalKeys, LocalStorage<V>>) -> V {
        get { self[LocalKeys()[keyPath: path]] }
        nonmutating set { self[LocalKeys()[keyPath: path]] = newValue }
    }
}

// MARK: - EnvironmentKeys

/// A namespace for declaring named environment storage keys as computed properties.
///
/// Extend `EnvironmentKeys` with computed properties that return `EnvironmentStorage<Value>` descriptors.
///
/// ```swift
/// extension EnvironmentKeys {
///     var theme: EnvironmentStorage<ColorScheme> {
///         .init(defaultValue: .light)
///     }
/// }
/// ```
///
/// Access values via `node.environment`:
///
/// ```swift
/// node.environment.theme         // read (walks up hierarchy to nearest setter)
/// node.environment.theme = .dark // write (stores here, visible to descendants)
/// ```
public struct EnvironmentKeys: Sendable {
    public init() {}
}

// MARK: - EnvironmentContext

/// Provides `@dynamicMemberLookup` access to a model node's environment storage via `EnvironmentKeys`.
///
/// Obtained from `node.environment` inside your model implementation. Reads walk up the hierarchy
/// to the nearest ancestor that has set the value; writes store on this node and are inherited
/// by all descendants.
///
/// ```swift
/// let current = node.environment.theme    // read — walks up hierarchy
/// node.environment.theme = .dark          // write — visible to all descendants
/// ```
@dynamicMemberLookup
public struct EnvironmentContext: Sendable {
    let context: AnyContext?

    init(context: AnyContext?) {
        self.context = context
    }

    /// Reads or writes an environment value using a storage descriptor directly.
    public subscript<V>(storage: EnvironmentStorage<V>) -> V {
        get {
            guard let context else { return storage.storage.defaultValue }
            return context.environmentValue(for: storage.storage)
        }
        nonmutating set {
            guard let context else { return }
            context[storage.storage] = newValue
        }
    }

    /// Reads or writes an environment value using a key path on `EnvironmentKeys`.
    public subscript<V>(dynamicMember path: KeyPath<EnvironmentKeys, EnvironmentStorage<V>>) -> V {
        get { self[EnvironmentKeys()[keyPath: path]] }
        nonmutating set { self[EnvironmentKeys()[keyPath: path]] = newValue }
    }
}

// MARK: - ContextKeys (deprecated)

/// A namespace for declaring named context storage keys as computed properties.
///
/// - Important: Deprecated. Use ``LocalKeys`` for node-private storage or ``EnvironmentKeys``
///   for top-down propagating storage.
@available(*, deprecated, message: "Use LocalKeys for node-private storage or EnvironmentKeys for top-down propagating storage.")
public struct ContextKeys: Sendable {
    public init() {}
}

// MARK: - ContextValues (deprecated)

/// Provides `@dynamicMemberLookup` access to a model node's context storage via `ContextKeys`.
///
/// - Important: Deprecated. Use `node.local` for node-private storage or `node.environment`
///   for top-down propagating storage.
@available(*, deprecated, message: "Use node.local for node-private storage or node.environment for top-down propagating storage.")
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
    subscript<V>(storage: ContextStorage<V>) -> V {
        get {
            if !storage.isSystemStorage {
                willAccessStorage(storage)
            }
            return lock { contextStorage[storage.key]?.value as? V } ?? storage.defaultValue
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
                // Read under ctx's lock to avoid a data race with concurrent writes on that context.
                let entry = ctx.lock { ctx.contextStorage[storage.key] }
                if let entry, let value = entry.value as? V {
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
        get {
            guard let context = node._context else { return storage.defaultValue }
            switch storage.propagation {
            case .local: return context[storage]
            case .environment: return context.environmentValue(for: storage)
            }
        }
        set { node._context?[storage] = newValue }
    }
}
