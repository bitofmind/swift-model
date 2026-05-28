import Dependencies

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
    let access: ModelAccess?

    init(context: AnyContext?, access: ModelAccess?) {
        self.context = context
        self.access = access
    }

    /// Reads or writes a local value using a storage descriptor directly.
    public subscript<V>(storage: LocalStorage<V>) -> V {
        get {
            guard let context else { return storage.storage.defaultValue }
            return context[storage.storage]
        }
        nonmutating set {
            guard let context else { return }
            usingActiveAccess(access) { context[storage.storage] = newValue }
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
    let access: ModelAccess?

    init(context: AnyContext?, access: ModelAccess?) {
        self.context = context
        self.access = access
    }

    /// Reads or writes an environment value using a storage descriptor directly.
    public subscript<V>(storage: EnvironmentStorage<V>) -> V {
        get {
            guard let context else { return storage.storage.defaultValue }
            return context.environmentValue(for: storage.storage)
        }
        nonmutating set {
            guard let context else { return }
            usingActiveAccess(access) { context[storage.storage] = newValue }
        }
    }

    /// Reads or writes an environment value using a key path on `EnvironmentKeys`.
    public subscript<V>(dynamicMember path: KeyPath<EnvironmentKeys, EnvironmentStorage<V>>) -> V {
        get { self[EnvironmentKeys()[keyPath: path]] }
        nonmutating set { self[EnvironmentKeys()[keyPath: path]] = newValue }
    }
}
