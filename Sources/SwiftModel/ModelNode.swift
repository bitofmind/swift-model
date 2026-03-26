import Foundation
import AsyncAlgorithms
import Dependencies

/// The implementation interface for a model, providing access to async tasks, events,
/// cancellations, dependencies, and memoization.
///
/// `ModelNode` is the *implementor's* tool. It is available via the `node` property that the
/// `@Model` macro generates on every model, and is intended to be used from within the model's
/// own implementation — in `onActivate()`, in methods, and in extensions of the model type.
///
/// ## Why `node` exists
///
/// Rather than placing all runtime APIs directly on the model type, SwiftModel separates them
/// onto `node` for two reasons:
///
/// **Namespace clarity** — `self.count` is model state. `node.task { }` is runtime wiring.
/// The `node.` prefix makes it immediately clear when you are setting up async behavior versus
/// reading or writing data.
///
/// **Dependency access via dynamic member lookup** — Dependencies are accessed as
/// `node.myDependency` rather than `self.myDependency`, which avoids polluting the model's
/// property namespace and makes it clear the value comes from the dependency system rather
/// than the model's own state.
///
/// ## Implementor vs. consumer
///
/// `node` is public so it can be used freely in multi-file model implementations and generic
/// extensions. However, it is intended for use by the *model implementor*, not by *consumers*
/// of a model.
///
/// A consumer (a view, a parent model, a test) should interact with a model through the
/// properties and methods the model explicitly exposes. Using `node` from outside the model's
/// own implementation — to start tasks on its behalf, send events in its name, or manage its
/// cancellations — bypasses the model's intended API boundary.
///
/// There is no hard enforcement of this: Swift's access control cannot express
/// "accessible to implementors regardless of file, but not to consumers." The convention is
/// enforced by code review and understanding of the design, not by the compiler.
///
/// ## Typical usage
///
/// ```swift
/// @Model struct TimerModel {
///     var elapsed = 0
///
///     func onActivate() {
///         // Start a task tied to the model's lifetime
///         node.forEach(node.continuousClock.timer(interval: .seconds(1))) { _ in
///             elapsed += 1
///         }
///     }
///
///     func reset() {
///         // Batch mutations into a single notification
///         node.transaction {
///             elapsed = 0
///         }
///     }
/// }
/// ```
@dynamicMemberLookup
public struct ModelNode<M: Model> {
    internal let _$modelContext: ModelContext<M>

    public init(_$modelContext: ModelContext<M>) {
        self._$modelContext = _$modelContext
    }
}

extension ModelNode: @unchecked Sendable {}

public extension ModelNode {
    /// Typed access to this node's local (node-private) storage via `@dynamicMemberLookup`.
    ///
    /// Properties declared as extensions on `LocalKeys` are accessible as
    /// `node.local.myKey` (read) and `node.local.myKey = value` (write).
    /// The value is private to this node — no other node in the hierarchy sees it.
    ///
    /// ```swift
    /// extension LocalKeys {
    ///     var isEditing: LocalStorage<Bool> { .init(defaultValue: false) }
    /// }
    ///
    /// // Inside the model:
    /// node.local.isEditing = true
    /// let editing = node.local.isEditing  // true
    /// ```
    var local: LocalValues {
        LocalValues(context: _context)
    }

    /// Removes a previously stored local value from this node, resetting it to `defaultValue`.
    ///
    /// Fires observation notifications so any active observers re-evaluate.
    ///
    /// - Parameter key: A key path on `LocalKeys` identifying the storage entry to remove.
    func removeLocal<V>(_ key: KeyPath<LocalKeys, LocalStorage<V>>) {
        let storage = LocalKeys()[keyPath: key]
        _context?.removeEnvironmentValue(for: storage.storage)
    }

    /// Typed access to this node's top-down propagating storage via `@dynamicMemberLookup`.
    ///
    /// Properties declared as extensions on `EnvironmentKeys` are accessible as
    /// `node.environment.myKey` (read) and `node.environment.myKey = value` (write).
    ///
    /// Writes store the value on this node and make it visible to all descendants.
    /// Reads walk up the hierarchy to the nearest ancestor that has set the value,
    /// returning the storage's `defaultValue` if no ancestor has set it.
    ///
    /// ```swift
    /// extension EnvironmentKeys {
    ///     var theme: EnvironmentStorage<ColorScheme> {
    ///         .init(defaultValue: .light)
    ///     }
    /// }
    ///
    /// // Parent sets the theme:
    /// parentNode.environment.theme = .dark
    ///
    /// // Child reads it (returns .dark — inherited from parent):
    /// let current = childNode.environment.theme
    ///
    /// // Child overrides locally:
    /// childNode.environment.theme = .light
    /// // Now childNode and its descendants see .light; others still see .dark
    /// ```
    var environment: EnvironmentContext {
        EnvironmentContext(context: _context)
    }

    /// Removes a previously stored environment value from this node.
    ///
    /// After removal this node will inherit the value from the nearest ancestor that has set it,
    /// or return the storage's `defaultValue` if no ancestor has set it.
    ///
    /// Fires observation notifications so any active observers re-evaluate.
    ///
    /// - Parameter key: A key path on `EnvironmentKeys` identifying the storage entry to remove.
    func removeEnvironment<V>(_ key: KeyPath<EnvironmentKeys, EnvironmentStorage<V>>) {
        let storage = EnvironmentKeys()[keyPath: key]
        _context?.removeEnvironmentValue(for: storage.storage)
    }

    /// Typed access to per-node context storage via `@dynamicMemberLookup`.
    ///
    /// - Deprecated: Use `node.local` for node-private storage or `node.environment` for
    ///   top-down propagating storage.
    @available(*, deprecated, message: "Use node.local for node-private storage or node.environment for top-down propagating storage.")
    var context: ContextValues {
        ContextValues(context: _context)
    }

    /// Removes a previously stored context value from this node.
    ///
    /// - Deprecated: Use `removeLocal(_:)` or `removeEnvironment(_:)`.
    @available(*, deprecated, message: "Use removeLocal(_:) or removeEnvironment(_:).")
    func removeContext<V>(_ key: KeyPath<ContextKeys, ContextStorage<V>>) {
        let storage = ContextKeys()[keyPath: key]
        _context?.removeEnvironmentValue(for: storage)
    }

    /// Typed access to per-node preference storage via `@dynamicMemberLookup`.
    ///
    /// Preferences aggregate **bottom-up**: each node writes its own contribution and any ancestor
    /// reads the combined aggregate of all contributions in its subtree.
    ///
    /// ```swift
    /// extension PreferenceKeys {
    ///     var totalCount: PreferenceStorage<Int> {
    ///         .init(defaultValue: 0) { $0 += $1 }
    ///     }
    /// }
    ///
    /// // Each child sets its contribution:
    /// childNode.preference.totalCount = 3
    ///
    /// // The parent reads the sum of all contributions:
    /// let total = parentNode.preference.totalCount  // 3 + contributions from other descendants
    /// ```
    var preference: PreferenceValues {
        PreferenceValues(context: _context)
    }

    /// Removes this node's contribution for a preference key.
    ///
    /// After removal this node no longer contributes to the aggregate. Ancestor observers
    /// that read the aggregate will re-evaluate.
    ///
    /// - Parameter key: A key path on `PreferenceKeys` identifying the contribution to remove.
    func removePreference<V>(_ key: KeyPath<PreferenceKeys, PreferenceStorage<V>>) {
        let storage = PreferenceKeys()[keyPath: key]
        _context?.removePreferenceContribution(for: storage)
    }
}

public extension ModelNode {
    /// Returns a `Mirror` for `model`, used by `CustomReflectable` conformance generated by the `@Model` macro.
    func mirror(of model: M, children: [(String, Any)]) -> Mirror {
        _$modelContext.mirror(of: model, children: children)
    }

    /// Returns the debug description for `model`, used by `CustomStringConvertible` conformance generated by the `@Model` macro.
    func description(of model: M) -> String {
        _$modelContext.description(of: model)
    }
}

public extension ModelNode {
    /// Batches multiple model mutations into a single atomic update with deferred notifications.
    ///
    /// Use transactions to maintain invariants and ensure external observers see consistent state.
    /// All property changes within the transaction block appear as a single atomic update to observers.
    ///
    /// ## Basic Usage
    ///
    /// ```swift
    /// @Model struct BankAccount {
    ///     var balance = 0
    /// }
    ///
    /// let account = BankAccount().withAnchor()
    ///
    /// // Without transaction: 3 separate notifications
    /// account.balance = 100  // Notification 1
    /// account.balance = 200  // Notification 2
    /// account.balance = 300  // Notification 3
    ///
    /// // With transaction: 1 notification with final value
    /// account.node.transaction {
    ///     account.balance = 100
    ///     account.balance = 200
    ///     account.balance = 300
    /// }  // Single notification: balance = 300
    /// ```
    ///
    /// ## Maintaining Invariants
    ///
    /// Transactions ensure external observers never see intermediate inconsistent states:
    ///
    /// ```swift
    /// @Model struct Rectangle {
    ///     var width = 0
    ///     var height = 0
    ///     var area = 0  // Invariant: area == width * height
    /// }
    ///
    /// // Without transaction: invariant can be violated
    /// rect.width = 10   // width=10, area=0 ❌ INCONSISTENT
    /// rect.height = 5   // width=10, height=5, area=0 ❌ INCONSISTENT
    /// rect.area = 50    // ✅ Consistent again
    ///
    /// // With transaction: invariant always maintained for observers
    /// rect.node.transaction {
    ///     rect.width = 10
    ///     rect.height = 5
    ///     rect.area = 50
    /// }  // Observers only see final consistent state
    /// ```
    ///
    /// ## Transaction Semantics
    ///
    /// **Atomicity**: Multiple mutations appear as a single atomic update
    /// ```swift
    /// model.node.transaction {
    ///     for i in 1...100 {
    ///         model.items.append(i)  // 100 mutations
    ///     }
    /// }
    /// // Observers receive exactly 1 notification with all 100 items
    /// ```
    ///
    /// **Consistency**: Reads within the transaction see the latest values
    /// ```swift
    /// model.node.transaction {
    ///     model.value = 10
    ///     print(model.value)  // Prints: 10 ✅
    ///
    ///     model.value = 20
    ///     print(model.value)  // Prints: 20 ✅
    /// }
    /// ```
    ///
    /// **Isolation**: Other threads block until transaction completes (lock-based)
    /// ```swift
    /// // Thread 1:
    /// model.node.transaction {
    ///     model.value = 100
    ///     Thread.sleep(0.05)
    ///     model.value = 200
    /// }
    ///
    /// // Thread 2: Reads block until transaction completes
    /// let val = model.value  // Either old value or 200, never 100
    /// ```
    ///
    /// **Nested Transactions**: Automatically coalesced into the outermost transaction
    /// ```swift
    /// model.node.transaction {
    ///     model.value = 10
    ///
    ///     model.node.transaction {
    ///         model.value = 20  // Inner transaction
    ///     }
    ///
    ///     model.value = 30
    /// }
    /// // Single notification at end of outermost transaction
    /// ```
    ///
    /// ## Best Practices
    ///
    /// **Use transactions for:**
    /// - Multi-property updates that must stay consistent
    /// - Bulk mutations (loops that modify many items)
    /// - Maintaining invariants between related properties
    ///
    /// **Don't use transactions for:**
    /// - Single property updates (unnecessary overhead)
    /// - Long-running operations (blocks other threads)
    /// - Operations with async/await (hold lock across suspension points)
    ///
    /// ## Performance Considerations
    ///
    /// Transactions use a recursive lock for thread safety, which means:
    /// - ✅ Efficient for synchronous bulk mutations
    /// - ⚠️ Blocks concurrent reads from other threads
    /// - ❌ Don't hold transaction across async boundaries
    ///
    /// ```swift
    /// // ✅ Good: Synchronous bulk update
    /// model.node.transaction {
    ///     for item in items {
    ///         model.add(item)
    ///     }
    /// }
    ///
    /// // ❌ Bad: Async work in transaction
    /// model.node.transaction {
    ///     let data = await fetchData()  // Holds lock during await!
    ///     model.data = data
    /// }
    ///
    /// // ✅ Good: Async work before transaction
    /// let data = await fetchData()
    /// model.node.transaction {
    ///     model.data = data
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - callback: The closure containing mutations to execute atomically
    /// - Returns: The value returned by the callback
    func transaction<T>(_ callback: () -> T) -> T {
        if let context = _context {
            return ModelAccess.$isInModelTaskContext.withValue(true) {
                context.transaction(callback)
            }
        } else {
            return callback()
        }
    }

    /// Batches multiple model mutations into a single atomic update with deferred notifications.
    ///
    /// - Deprecated: Transactions don't roll back on error, so a throwing closure provides no
    ///   safety guarantee. Compute your values first, then apply them inside a non-throwing
    ///   `transaction { }` closure.
    @available(*, deprecated, message: "Transactions do not roll back on error. Compute values outside the transaction and apply them in a non-throwing closure.")
    func transaction<T>(_ callback: () throws -> T) rethrows -> T {
        if let context = _context {
            return try _withBatchedUpdates {
                try ModelAccess.$isInModelTaskContext.withValue(true) {
                    try context.transaction(callback)
                }
            }
        } else {
            return try callback()
        }
    }

    /// Forces observation notifications for `path` without modifying the stored value.
    ///
    /// Normally, writing an `Equatable` property with the same value it already holds is a no-op —
    /// no observers are notified. This is an intentional optimisation that avoids redundant work.
    ///
    /// `touch` bypasses that optimisation. It fires all registered observation callbacks for the
    /// given property as if the value had changed, even though it hasn't. Use it when external
    /// state that a property *depends on* has changed invisibly — for example:
    ///
    /// - A reference-typed backing store was mutated in-place
    /// - A computed property's result depends on external state invisible to `==`
    ///
    /// ```swift
    /// // External backing object mutated directly — equality check would suppress notification
    /// externalDocument.unsafeReplace(newContent)
    /// node.touch(\.document)   // Force dependents of `document` to re-read
    /// ```
    ///
    /// - Parameter path: The key path of the property whose observers should be notified.
    func touch<V>(_ path: WritableKeyPath<M, V> & Sendable) {
        guard let context = _context else { return }
        context.touch(path, modelContext: _$modelContext)
    }

    private var isDestructed: Bool {
        if case let .reference(reference) = _$modelContext.source, reference.isDestructed, reference.context == nil {
            true
        } else if case .lastSeen = _$modelContext.source {
            true
        } else {
            false
        }
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<DependencyValues, Value>&Sendable) -> Value {
        if isDestructed {
            // Most likely being accessed by SwiftUI shortly after being destructed, no need for runtime warning.
            if let access = _$modelContext.access as? LastSeenAccess,
               -access.timestamp.timeIntervalSinceNow < lastSeenTimeToLive,
               let value = access.dependencyCache[keyPath] as? Value {
                return value
            }

            return Dependency(keyPath).wrappedValue
        }

        guard let context = enforcedContext("Accessing dependency `\(String(describing: keyPath).replacingOccurrences(of: "\\DependencyValues.", with: ""))` on an unanchored model node is not allowed and will be redirected to the default dependency value") else {
            return Dependency(keyPath).wrappedValue
        }

        let value = context.dependency(for: keyPath)
        if let dependencyModel = value as? any Model {
            return dependencyModel.withAccessIfPropagateToChildren(access) as! Value
        } else {
            return value
        }
    }

    subscript<Value: DependencyKey>(type: Value.Type) -> Value where Value.Value == Value {
        if isDestructed {
            // Most likely being accessed by SwiftUI shortly after being destructed, no need for runtime warning.
            let key = ObjectIdentifier(type)
            if let access = _$modelContext.access as? LastSeenAccess,
               -access.timestamp.timeIntervalSinceNow < lastSeenTimeToLive,
               let value = access.dependencyCache[key] as? Value {
                return value
            }

            return Dependency(type).wrappedValue
        }

        guard let context = enforcedContext("Accessing dependency `\(String(describing: type))` on an unanchored model node is not allowed and will be redirected to the default dependency value") else {
            return Dependency(type).wrappedValue
        }

        let value = context.dependency(for: type)
        if let dependencyModel = value as? any Model {
            return dependencyModel.withAccessIfPropagateToChildren(access) as! Value
        } else {
            return value
        }
    }

    /// Returns `true` if this model has at most one parent in the hierarchy (i.e. it is not shared).
    var isUniquelyReferenced: Bool {
        _context.map { $0.parents.count <= 1 } ?? true
    }

    /// Returns a stream that emits `true` when the model has a single owner, `false` when it is shared.
    ///
    /// A model is *shared* when the same instance appears in more than one place in the model hierarchy
    /// (multiple parents). This stream emits the current sharing status immediately and then re-emits
    /// whenever the sharing count changes. Consecutive equal values are deduplicated.
    ///
    /// This is useful for building "exclusive editing" UX — for example, disabling an edit button
    /// when a model is referenced from multiple places:
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.forEach(node.uniquelyReferenced()) { isExclusive in
    ///         isEditable = isExclusive
    ///     }
    /// }
    /// ```
    ///
    /// The stream finishes when the model is deactivated.
    func uniquelyReferenced() -> AsyncStream<Bool> {
        guard let rootParent = enforcedContext()?.rootParent else {
            return .never
        }

        return AsyncStream { cont in
            cont.yield(isUniquelyReferenced)

            let cancel = rootParent.onAnyModification { isFinished in
                if isFinished {
                    cont.finish()
                } else {
                    cont.yield(isUniquelyReferenced)
                }

                return nil
            }

            cont.onTermination = { _ in
                cancel()
            }
        }.removeDuplicates().eraseToStream()
    }

    /// Traverses the model hierarchy and accumulates a result by applying a transform to each visited model.
    ///
    /// This is the primary API for accessing structured information across the model hierarchy.
    /// SwiftModel maintains full knowledge of parent-child relationships, and `reduceHierarchy`
    /// exposes this for custom queries such as collecting values, finding ancestors of a type,
    /// or aggregating data across a subtree.
    ///
    /// The traversal visits each model at most once, even if a model appears in multiple positions
    /// (e.g. shared models, or models reachable via multiple ancestor paths).
    ///
    /// ## Basic Usage
    ///
    /// Collect counts from all descendants:
    ///
    /// ```swift
    /// let total = node.reduceHierarchy(for: .descendants, transform: { ($0 as? CounterModel)?.count }, into: 0) { $0 += $1 }
    /// ```
    ///
    /// Find the nearest ancestor of a specific type:
    ///
    /// ```swift
    /// let appModel = node.mapHierarchy(for: .ancestors) { $0 as? AppModel }.first
    /// ```
    ///
    /// ## Relation Options
    ///
    /// The `relation` parameter is an `OptionSet` controlling which models are visited:
    ///
    /// - `.self` — visits only the model itself
    /// - `.parent` — visits the model's direct parents
    /// - `.ancestors` — visits all ancestors recursively (parents, grandparents, etc.)
    /// - `.children` — visits only direct children
    /// - `.descendants` — visits all descendants recursively
    /// - `.dependencies` — additionally includes dependency models at each visited node
    ///
    /// Options can be combined: `[.self, .ancestors]` visits the model and all of its ancestors.
    ///
    /// ## Observation
    ///
    /// When called from inside an `Observed` closure or a `withObservationTracking` block,
    /// all property accesses made inside `transform` are tracked — including properties on
    /// **ancestor models** (parents, grandparents). The stream re-evaluates whenever any tracked
    /// property on any visited model changes.
    ///
    /// **Structural changes** (adding/removing children) also trigger re-evaluation because
    /// the containing property (e.g. an array) is itself tracked. Newly added models have
    /// their properties tracked starting from the next re-evaluation.
    ///
    /// - Parameters:
    ///   - relation: Which models relative to this node to visit.
    ///   - transform: A closure applied to each visited model. Return `nil` to skip a model.
    ///   - initialResult: The starting accumulator value.
    ///   - updateAccumulatingResult: A closure that folds an element into the accumulator.
    /// - Returns: The final accumulated result.
    func reduceHierarchy<Result, Element>(for relation: ModelRelation, transform: (any Model) throws -> Element?, into initialResult: Result, _ updateAccumulatingResult: (inout Result, Element) throws -> ()) rethrows -> Result {
        try _context?.reduceHierarchy(for: relation, transform: {
            try transform($0.anyModel.withAccessIfPropagateToChildren(access))
        }, into: initialResult, updateAccumulatingResult) ?? initialResult
    }

    /// Traverses the model hierarchy and returns all non-nil transform results as an array.
    ///
    /// This is a convenience wrapper around `reduceHierarchy` that collects results into an array.
    ///
    /// ```swift
    /// // Find all active tasks across the whole hierarchy
    /// let activeModels = node.mapHierarchy(for: [.self, .descendants]) { $0 as? TaskModel }
    ///
    /// // Collect all ancestor types for debugging
    /// let ancestorNames = node.mapHierarchy(for: .ancestors) { String(describing: type(of: $0)) }
    /// ```
    ///
    /// The order of results follows the traversal order:
    /// - For `.ancestors` / `.parent`: from direct parent towards the root
    /// - For `.children` / `.descendants`: depth-first, children before their children
    ///
    /// - Parameters:
    ///   - relation: Which models relative to this node to visit.
    ///   - transform: A closure applied to each visited model. Return `nil` to exclude a model.
    /// - Returns: An array of all non-nil transformed values, in traversal order.
    func mapHierarchy<Element>(for relation: ModelRelation, transform: (any Model) throws -> Element?) rethrows -> [Element] {
        try reduceHierarchy(for: relation, transform: transform, into: []) {
            $0.append($1)
        }
    }
}

extension ModelNode {
    var modelContext: ModelContext<M> { _$modelContext }

    func enforcedContext(_ function: StaticString = #function) -> Context<M>? {
        enforcedContext("Calling \(function) on an unanchored model node is not allowed and has no effect")
    }

    func enforcedContext(_ message: @autoclosure () -> String) -> Context<M>? {
        guard let context = _context else {
            reportIssue(message())
            return nil
        }

        return context
    }

    var _context: Context<M>? {
        modelContext.context
    }

    var access: ModelAccess? {
        modelContext.access
    }

    var typeDescription: String {
        String(describing: M.self)
    }

    var modelID: ModelID {
        modelContext.modelID
    }
}
