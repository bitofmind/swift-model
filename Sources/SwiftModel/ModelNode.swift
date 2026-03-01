import Foundation
import Dependencies

@dynamicMemberLookup
public struct ModelNode<M: Model> {
    public let _$modelContext: ModelContext<M>

    public init(_$modelContext: ModelContext<M>) {
        self._$modelContext = _$modelContext
    }
}

extension ModelNode: Sendable where M: Sendable {}

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
    /// ## Error Handling
    ///
    /// > Important: Transactions do **not** automatically rollback on error.
    /// Mutations made before the error are retained.
    ///
    /// ```swift
    /// model.value = 10
    ///
    /// do {
    ///     try model.node.transaction {
    ///         model.value = 20
    ///         model.value = 30
    ///         throw MyError()
    ///     }
    /// } catch {
    ///     // model.value is now 30 (not rolled back to 10)
    /// }
    /// ```
    ///
    /// To handle errors safely:
    /// ```swift
    /// // Pattern 1: Pre-validate
    /// guard isValid(newValue) else { return }
    /// model.node.transaction {
    ///     model.value = newValue
    /// }
    ///
    /// // Pattern 2: Explicit reset on error
    /// do {
    ///     try model.node.transaction {
    ///         model.update(data)
    ///     }
    /// } catch {
    ///     model.reset()  // Explicit reset
    /// }
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
    /// - Throws: Rethrows any error thrown by the callback (without rollback)
    func transaction<T>(_ callback: () throws -> T) rethrows -> T {
        if let context {
            return try ModelAccess.$isInModelTaskContext.withValue(true) {
                try context.transaction(callback)
            }
        } else {
            return try callback()
        }
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

    var isUniquelyReferenced: Bool {
        context.map { $0.parents.count <= 1 } ?? true
    }

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
        try context?.reduceHierarchy(for: relation, transform: {
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
        guard let context else {
            reportIssue(message())
            return nil
        }

        return context
    }

    var context: Context<M>? {
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
