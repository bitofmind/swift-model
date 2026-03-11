import ConcurrencyExtras

// MARK: - PreferenceStorage

/// A typed key + default value + reduce function for bottom-up aggregated preference storage.
///
/// Preferences flow upward: each node writes its own contribution via `node.preference.myKey = value`,
/// and any ancestor reads the aggregate of all contributions in its subtree via `node.preference.myKey`.
///
/// Declare one as a computed property on `PreferenceKeys`. The source location captured at `init`
/// time serves as the unique dictionary key — no separate enum needed.
///
/// ```swift
/// extension PreferenceKeys {
///     var totalCount: PreferenceStorage<Int> {
///         .init(defaultValue: 0) { $0 += $1 }
///     }
/// }
///
/// // Child writes its contribution:
/// node.preference.totalCount = 5
///
/// // Any ancestor reads the aggregate:
/// let total = node.preference.totalCount  // sum of all descendants + self
/// ```
struct PreferenceStorage<Value: Sendable>: Hashable, Sendable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    let defaultValue: Value
    let key: AnyHashableSendable
    /// Combines a new contribution into the running aggregate.
    let reduce: @Sendable (inout Value, Value) -> Void
    /// When `true`, contributions from dependency model contexts are also included in the aggregate.
    let includeDependencies: Bool
    /// Optional equality check. When set, a write that doesn't change the stored value is a no-op
    /// and fires no observation notifications. Nil means always notify (non-Equatable types).
    let isEqual: (@Sendable (Value, Value) -> Bool)?

    /// Default init: uses the source location as the unique storage key.
    init(
        defaultValue: Value,
        includeDependencies: Bool = false,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column,
        reduce: @Sendable @escaping (inout Value, Value) -> Void
    ) {
        self.defaultValue = defaultValue
        self.key = AnyHashableSendable(FileAndLine(fileID: fileID, filePath: fileID, line: line, column: column))
        self.reduce = reduce
        self.includeDependencies = includeDependencies
        self.isEqual = nil
    }

    /// Explicit-key init: use when you need a stable key independent of source location.
    init<K: Hashable & Sendable>(
        defaultValue: Value,
        key: K,
        includeDependencies: Bool = false,
        reduce: @Sendable @escaping (inout Value, Value) -> Void
    ) {
        self.defaultValue = defaultValue
        self.key = AnyHashableSendable(key)
        self.reduce = reduce
        self.includeDependencies = includeDependencies
        self.isEqual = nil
    }
}

extension PreferenceStorage where Value: Equatable {
    /// Default init for Equatable values: automatically skips observation notifications
    /// when the new contribution equals the currently stored value.
    init(
        defaultValue: Value,
        includeDependencies: Bool = false,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column,
        reduce: @Sendable @escaping (inout Value, Value) -> Void
    ) {
        self.defaultValue = defaultValue
        self.key = AnyHashableSendable(FileAndLine(fileID: fileID, filePath: fileID, line: line, column: column))
        self.reduce = reduce
        self.includeDependencies = includeDependencies
        self.isEqual = { $0 == $1 }
    }

    /// Explicit-key init for Equatable values.
    init<K: Hashable & Sendable>(
        defaultValue: Value,
        key: K,
        includeDependencies: Bool = false,
        reduce: @Sendable @escaping (inout Value, Value) -> Void
    ) {
        self.defaultValue = defaultValue
        self.key = AnyHashableSendable(key)
        self.reduce = reduce
        self.includeDependencies = includeDependencies
        self.isEqual = { $0 == $1 }
    }
}

// MARK: - PreferenceKeys

/// A namespace for declaring named preference storage keys as computed properties.
///
/// ```swift
/// extension PreferenceKeys {
///     var totalCount: PreferenceStorage<Int> {
///         .init(defaultValue: 0) { $0 += $1 }
///     }
/// }
/// ```
struct PreferenceKeys: Sendable {}

// MARK: - PreferenceValues

/// Provides `@dynamicMemberLookup` access to a context's preference contributions via `PreferenceKeys`.
///
/// Access via `node.preference`:
/// ```swift
/// node.preference.totalCount        // reads aggregate of self + all descendants
/// node.preference.totalCount = 5    // writes this node's contribution
/// ```
@dynamicMemberLookup
struct PreferenceValues: Sendable {
    // Optional: nil when the node is unanchored. Reads return defaultValue, writes are no-ops.
    let context: AnyContext?

    init(context: AnyContext?) {
        self.context = context
    }

    // Direct subscript for explicit access with a storage descriptor.
    subscript<V>(storage: PreferenceStorage<V>) -> V {
        get {
            guard let context else { return storage.defaultValue }
            return context.preferenceValue(for: storage)
        }
        nonmutating set {
            guard let context else { return }
            context[preference: storage] = newValue
        }
    }

    // @dynamicMemberLookup: KeyPath<PreferenceKeys, PreferenceStorage<V>> → V
    subscript<V>(dynamicMember path: KeyPath<PreferenceKeys, PreferenceStorage<V>>) -> V {
        get { self[PreferenceKeys()[keyPath: path]] }
        nonmutating set { self[PreferenceKeys()[keyPath: path]] = newValue }
    }
}

// MARK: - AnyContext typed preference subscript + preference accessor

extension AnyContext {
    var preference: PreferenceValues {
        PreferenceValues(context: self)
    }

    /// Read/write a single node's preference contribution.
    /// Reading retrieves the raw stored value for this node only (not the aggregate).
    /// Use `preferenceValue(for:)` to get the aggregated value across the subtree.
    subscript<V>(preference storage: PreferenceStorage<V>) -> V {
        get {
            willAccessPreference(storage)
            return preferenceStorage[storage.key]?.value as? V ?? storage.defaultValue
        }
        set {
            let changed = lock {
                if let isEqual = storage.isEqual,
                   let existing = preferenceStorage[storage.key]?.value as? V,
                   isEqual(existing, newValue) {
                    return false
                }
                preferenceStorage[storage.key] = PreferenceStorageEntry(value: newValue, cleanup: nil)
                return true
            }
            if changed {
                didModifyPreference(storage)
            }
        }
    }

    /// Compute the aggregated preference value for a storage key by visiting self and all descendants.
    ///
    /// Each context that has stored a contribution for this key participates in the aggregate.
    /// The `reduce` function is called for each contribution, folding it into the running result.
    ///
    /// Uses `reduceHierarchy(for: [.self, .descendants])` so all descendants are visited.
    /// If `includeDependencies` is true, dependency model contexts are also included.
    func preferenceValue<V>(for storage: PreferenceStorage<V>) -> V {
        let relation: ModelRelation = storage.includeDependencies
            ? [.self, .descendants, .dependencies]
            : [.self, .descendants]
        return reduceHierarchy(for: relation, transform: \.self, into: storage.defaultValue) { result, ctx in
            ctx.willAccessPreference(storage)
            if let entry = ctx.preferenceStorage[storage.key], let value = entry.value as? V {
                storage.reduce(&result, value)
            }
        }
    }

    /// Remove this node's preference contribution, returning it to the `defaultValue` for
    /// aggregation purposes. Fires observation notifications so ancestor observers re-evaluate.
    func removePreferenceContribution<V>(for storage: PreferenceStorage<V>) {
        let hadEntry = lock {
            guard let entry = preferenceStorage[storage.key] else { return false }
            entry.cleanup?()
            preferenceStorage.removeValue(forKey: storage.key)
            return true
        }
        if hadEntry {
            didModifyPreference(storage)
        }
    }
}

// MARK: - Internal Model subscript for preference storage observation
//
// Provides a WritableKeyPath<M, V> rooted at the Model type itself, analogous to
// the `_metadata` subscript for context storage.
// This subscript is internal-only — it bridges the typed preference storage system
// and the TestAccess observation machinery. Users always use `node.preference.myKey`;
// `Context<M>` uses this subscript internally in willAccessPreference/didModifyPreference.
extension Model {
    subscript<V>(_preference storage: PreferenceStorage<V>) -> V {
        get { node.preference[storage] }
        set { node.preference[storage] = newValue }
    }
}
