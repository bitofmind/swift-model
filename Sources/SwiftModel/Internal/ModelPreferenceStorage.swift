import ConcurrencyExtras

// MARK: - PreferenceStorage

/// A typed key + default value + reduce function for bottom-up aggregated preference storage.
///
/// Preferences flow **upward**: each node writes its own contribution via
/// `node.preference.myKey = value`, and any ancestor reads the aggregate of all contributions
/// in its subtree via `node.preference.myKey`.
///
/// ## Declaring a preference key
///
/// Extend `PreferenceKeys` with a computed property returning a `PreferenceStorage` descriptor.
/// The source location of each property serves as its unique key automatically.
///
/// ```swift
/// extension PreferenceKeys {
///     var totalCount: PreferenceStorage<Int> {
///         .init(defaultValue: 0) { $0 += $1 }
///     }
///     var hasUnsavedChanges: PreferenceStorage<Bool> {
///         .init(defaultValue: false) { $0 = $0 || $1 }
///     }
/// }
/// ```
///
/// ## Writing contributions and reading aggregates
///
/// ```swift
/// // Child writes its own contribution:
/// node.preference.totalCount = 5
///
/// // Any ancestor reads the aggregate of the whole subtree:
/// let total = node.preference.totalCount  // sum of self + all descendants
/// ```
///
/// ## Reduce function
///
/// The `reduce` closure folds each node's contribution into a running result starting from
/// `defaultValue`. It is called once per node that has set a value.
///
/// Common patterns:
/// - Sum: `{ $0 += $1 }`
/// - Union: `{ $0 = $0 || $1 }`
/// - Collection: `{ $0.append(contentsOf: $1) }`
public struct PreferenceStorage<Value: Sendable>: Hashable, Sendable {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
    /// The starting value for aggregation (used when no contributions exist).
    public let defaultValue: Value
    let key: AnyHashableSendable
    /// The property name captured from the `PreferenceKeys` call site via `#function`.
    /// Used in test exhaustion failure messages to show `preference.totalCount` instead of `UNKNOWN`.
    let name: String
    /// Combines a new contribution into the running aggregate.
    public let reduce: @Sendable (inout Value, Value) -> Void
    /// When `true`, contributions from dependency model contexts are also included in the aggregate.
    public let includeDependencies: Bool
    /// Optional equality check. When set, a write that doesn't change the stored value is a no-op
    /// and fires no observation notifications. Nil means always notify (non-Equatable types).
    let isEqual: (@Sendable (Value, Value) -> Bool)?

    /// Creates a preference storage descriptor using the call-site source location as the unique key.
    ///
    /// - Parameters:
    ///   - defaultValue: The starting value for aggregation when no contributions exist.
    ///   - includeDependencies: When `true`, dependency model contexts also contribute to the
    ///     aggregate. Defaults to `false`.
    ///   - reduce: Folds a new contribution into the running aggregate.
    public init(
        defaultValue: Value,
        includeDependencies: Bool = false,
        function: StaticString = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column,
        reduce: @Sendable @escaping (inout Value, Value) -> Void
    ) {
        self.defaultValue = defaultValue
        self.key = AnyHashableSendable(FileAndLine(fileID: fileID, filePath: fileID, line: line, column: column))
        self.name = "\(function)".sanitizedPropertyName
        self.reduce = reduce
        self.includeDependencies = includeDependencies
        self.isEqual = nil
    }

    /// Creates a preference storage descriptor with an explicit stable key.
    ///
    /// - Parameters:
    ///   - defaultValue: The starting value for aggregation when no contributions exist.
    ///   - key: An explicit stable key. Must be `Hashable` and `Sendable`.
    ///   - includeDependencies: When `true`, dependency model contexts also contribute to the
    ///     aggregate. Defaults to `false`.
    ///   - reduce: Folds a new contribution into the running aggregate.
    public init<K: Hashable & Sendable>(
        defaultValue: Value,
        key: K,
        includeDependencies: Bool = false,
        function: StaticString = #function,
        reduce: @Sendable @escaping (inout Value, Value) -> Void
    ) {
        self.defaultValue = defaultValue
        self.key = AnyHashableSendable(key)
        self.name = "\(function)".sanitizedPropertyName
        self.reduce = reduce
        self.includeDependencies = includeDependencies
        self.isEqual = nil
    }
}

extension PreferenceStorage where Value: Equatable {
    /// Creates a preference storage descriptor for an `Equatable` value, using the call-site
    /// source location as the unique key.
    ///
    /// Writes that do not change the currently stored contribution are suppressed — no observation
    /// notifications are fired.
    ///
    /// - Parameters:
    ///   - defaultValue: The starting value for aggregation when no contributions exist.
    ///   - includeDependencies: When `true`, dependency model contexts also contribute to the
    ///     aggregate. Defaults to `false`.
    ///   - reduce: Folds a new contribution into the running aggregate.
    public init(
        defaultValue: Value,
        includeDependencies: Bool = false,
        function: StaticString = #function,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column,
        reduce: @Sendable @escaping (inout Value, Value) -> Void
    ) {
        self.defaultValue = defaultValue
        self.key = AnyHashableSendable(FileAndLine(fileID: fileID, filePath: fileID, line: line, column: column))
        self.name = "\(function)".sanitizedPropertyName
        self.reduce = reduce
        self.includeDependencies = includeDependencies
        self.isEqual = { $0 == $1 }
    }

    /// Creates a preference storage descriptor for an `Equatable` value with an explicit stable key.
    ///
    /// - Parameters:
    ///   - defaultValue: The starting value for aggregation when no contributions exist.
    ///   - key: An explicit stable key. Must be `Hashable` and `Sendable`.
    ///   - includeDependencies: When `true`, dependency model contexts also contribute to the
    ///     aggregate. Defaults to `false`.
    ///   - reduce: Folds a new contribution into the running aggregate.
    public init<K: Hashable & Sendable>(
        defaultValue: Value,
        key: K,
        includeDependencies: Bool = false,
        function: StaticString = #function,
        reduce: @Sendable @escaping (inout Value, Value) -> Void
    ) {
        self.defaultValue = defaultValue
        self.key = AnyHashableSendable(key)
        self.name = "\(function)".sanitizedPropertyName
        self.reduce = reduce
        self.includeDependencies = includeDependencies
        self.isEqual = { $0 == $1 }
    }
}

// MARK: - PreferenceKeys

/// A namespace for declaring named preference storage keys as computed properties.
///
/// Extend `PreferenceKeys` with computed properties that return `PreferenceStorage<Value>`
/// descriptors. SwiftModel uses the source location of each property as its unique key
/// automatically — no explicit identifier is needed.
///
/// ```swift
/// extension PreferenceKeys {
///     var totalCount: PreferenceStorage<Int> {
///         .init(defaultValue: 0) { $0 += $1 }
///     }
///     var hasUnsavedChanges: PreferenceStorage<Bool> {
///         .init(defaultValue: false) { $0 = $0 || $1 }
///     }
/// }
/// ```
///
/// Access values via `node.preference`:
///
/// ```swift
/// node.preference.totalCount = 3          // write this node's contribution
/// let total = node.preference.totalCount  // read aggregate of self + descendants
/// ```
public struct PreferenceKeys: Sendable {
    public init() {}
}

// MARK: - PreferenceValues

/// Provides `@dynamicMemberLookup` access to a model node's preference storage via `PreferenceKeys`.
///
/// You obtain a `PreferenceValues` instance from `node.preference` inside your model implementation.
/// Properties declared on `PreferenceKeys` are directly accessible as dynamic members.
///
/// Reading a preference aggregates contributions from the current node **and all descendants**.
/// Writing stores this node's own contribution, which is then included in any ancestor's read.
///
/// ```swift
/// // Inside a model implementation (via node.preference):
/// node.preference.totalCount = 3           // write this node's contribution
/// let total = node.preference.totalCount   // aggregate: self + all descendants
/// ```
@dynamicMemberLookup
public struct PreferenceValues: Sendable {
    // Optional: nil when the node is unanchored. Reads return defaultValue, writes are no-ops.
    let context: AnyContext?

    init(context: AnyContext?) {
        self.context = context
    }

    /// Reads the aggregated preference value (self + all descendants) or writes this node's contribution.
    public subscript<V>(storage: PreferenceStorage<V>) -> V {
        get {
            guard let context else { return storage.defaultValue }
            return context.preferenceValue(for: storage)
        }
        nonmutating set {
            guard let context else { return }
            context[preference: storage] = newValue
        }
    }

    /// Reads or writes a preference value using a key path on `PreferenceKeys`.
    public subscript<V>(dynamicMember path: KeyPath<PreferenceKeys, PreferenceStorage<V>>) -> V {
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
            return lock { preferenceStorage[storage.key]?.value as? V ?? storage.defaultValue }
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
        // During snapshot comparison inside TestAccess, avoid walking the live context hierarchy.
        // The hierarchy walk acquires the context lock, which can deadlock when called from a
        // concurrent task while the TestAccess NSRecursiveLock is already held on another thread.
        // Instead, return just this node's local stored contribution — sufficient for comparison.
        if threadLocals.isApplyingSnapshot {
            return lock { preferenceStorage[storage.key]?.value as? V ?? storage.defaultValue }
        }
        let relation: ModelRelation = storage.includeDependencies
            ? [.self, .descendants, .dependencies]
            : [.self, .descendants]
        let result = reduceHierarchy(for: relation, transform: \.self, into: storage.defaultValue) { result, ctx in
            ctx.willAccessPreference(storage)
            let entry = ctx.lock { ctx.preferenceStorage[storage.key] }
            if let entry, let value = entry.value as? V {
                storage.reduce(&result, value)
            }
        }
        // Register the aggregated value with TestAccess after the full traversal is done.
        // This avoids re-entering preferenceValue inside willAccessPreference callbacks,
        // which would acquire child locks while the parent lock is held — a deadlock risk.
        willAccessPreferenceValue(storage, value: result)
        return result
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
