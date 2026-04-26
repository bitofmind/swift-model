import OrderedCollections

public protocol ModelVisitor<State> {
    associatedtype State
    mutating func visit<T>(path: KeyPath<State, T>)
    mutating func visit<T>(path: WritableKeyPath<State, T>)
    mutating func visit<T: Model>(path: WritableKeyPath<State, T>)
    mutating func visit<T: ModelContainer>(path: WritableKeyPath<State, T>)
    /// Called for plain-value properties that carry a `PropertyVisibility` annotation.
    /// The default implementation delegates to `visit(path:)`, preserving backward compatibility
    /// for all existing `ModelVisitor` conformers that have no need for visibility information.
    mutating func visit<T>(path: WritableKeyPath<State, T>, visibility: PropertyVisibility)
    /// Called by `ModelContainer.visit` implementations **before** constructing a cursor for each
    /// element. When this returns `true` the container skips cursor construction entirely,
    /// eliminating the three heap allocations that `path(id:get:set:)` would otherwise produce.
    ///
    /// The default implementation returns `false`, preserving unchanged behaviour for all existing
    /// `ModelVisitor` conformers. `AnchorVisitor` overrides this to implement the fast path for
    /// already-registered container children during `updateContext` traversal.
    mutating func shouldSkipElement<T: Model>(element: T, id: AnyHashable) -> Bool
    /// Called for `MutableCollection` properties whose element type is `Model & Identifiable`
    /// but that do not necessarily conform to `ModelContainer`.
    ///
    /// The default implementation is a no-op — existing `ModelVisitor` conformers are unaffected.
    /// `AnchorVisitor`, `ModelTransformerVisitor`, and `ReduceValueVisitor` override this to
    /// handle such collections without constructing cursor key paths.
    mutating func visitCollection<C: MutableCollection>(path: WritableKeyPath<State, C>) where C: Sendable, C.Element: Model & Identifiable & Sendable, C.Index: Sendable, C.Element.ID: Sendable

    /// Called for `MutableCollection` properties whose element type is `ModelContainer & Identifiable`
    /// but that do not themselves conform to `ModelContainer`
    /// (e.g. `IdentifiedArray` whose element type is a `@ModelContainer` enum).
    ///
    /// The default implementation is a no-op — existing `ModelVisitor` conformers are unaffected.
    /// `AnchorVisitor`, `ModelTransformerVisitor`, and `ReduceValueVisitor` override this to
    /// traverse each element's model children and manage their contexts.
    mutating func visitContainerCollection<C: MutableCollection>(path: WritableKeyPath<State, C>) where C.Element: ModelContainer & Identifiable & Sendable, C: Sendable, C.Index: Sendable, C.Element.ID: Sendable
}

public extension ModelVisitor {
    mutating func visit<T>(path: KeyPath<State, T>) { }
    mutating func visit<T>(path: WritableKeyPath<State, T>) { }
    mutating func visit<T>(path: WritableKeyPath<State, T>, visibility: PropertyVisibility) {
        visit(path: path)
    }
    mutating func shouldSkipElement<T: Model>(element: T, id: AnyHashable) -> Bool { false }
    mutating func visitCollection<C: MutableCollection>(path: WritableKeyPath<State, C>) where C: Sendable, C.Element: Model & Identifiable & Sendable, C.Index: Sendable, C.Element.ID: Sendable { }
    mutating func visitContainerCollection<C: MutableCollection>(path: WritableKeyPath<State, C>) where C.Element: ModelContainer & Identifiable & Sendable, C: Sendable, C.Index: Sendable, C.Element.ID: Sendable { }
}

public extension ModelVisitor where State: Model {
    /// Default implementation for `_State`-level paths: composes via `_modelStateKeyPath`
    /// and delegates to the existing `visit(path:)` overloads. This preserves backward
    /// compatibility — existing `ModelVisitor` implementations that only implement
    /// `visit(path:)` continue to work unchanged when the macro emits `visitStatically(statePath:)`.
    mutating func visit<T>(statePath: WritableKeyPath<State._ModelState, T>) {
        visit(path: State._modelStateKeyPath.appending(path: statePath))
    }
    mutating func visit<T: Model>(statePath: WritableKeyPath<State._ModelState, T>) {
        visit(path: State._modelStateKeyPath.appending(path: statePath) as WritableKeyPath<State, T>)
    }
    mutating func visit<T: ModelContainer>(statePath: WritableKeyPath<State._ModelState, T>) {
        visit(path: State._modelStateKeyPath.appending(path: statePath) as WritableKeyPath<State, T>)
    }
    mutating func visit<T>(statePath: WritableKeyPath<State._ModelState, T>, visibility: PropertyVisibility) {
        visit(path: State._modelStateKeyPath.appending(path: statePath), visibility: visibility)
    }
    mutating func visitCollection<C: MutableCollection>(statePath: WritableKeyPath<State._ModelState, C>) where C: Sendable, C.Element: Model & Identifiable & Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        visitCollection(path: State._modelStateKeyPath.appending(path: statePath) as WritableKeyPath<State, C>)
    }
    mutating func visitContainerCollection<C: MutableCollection>(statePath: WritableKeyPath<State._ModelState, C>) where C.Element: ModelContainer & Identifiable & Sendable, C: Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        visitContainerCollection(path: State._modelStateKeyPath.appending(path: statePath) as WritableKeyPath<State, C>)
    }
}

/// A non-parameterized protocol for visitors that need witness-table dispatch for
/// `_ModelState`-level paths (paths into the `_State` struct generated by `@Model`).
///
/// Unlike the extension methods on `ModelVisitor where State: Model`, the requirements here
/// appear in the witness table. `ContainerVisitor` detects conformance at runtime via
/// `modelVisitor as? any _ModelStateVisitor` (a non-parameterized existential, compatible
/// with macOS 11+) and dispatches through the witness table — without requiring changes to
/// the macro-generated `visit(with:)` signature or adding conditional conformances to every
/// `ModelVisitor` conformer.
///
/// Requirements use a generic `<M: Model, T>` pair plus a `forState: M.Type` discriminant so
/// the concrete conformer can recover the `M`-specific path type via `unsafeBitCast` (safe
/// because `ContainerVisitor` always passes `V.State.self` and `V.State == M`).
///
/// Default implementations are no-ops; conformers override only what they need.
protocol _ModelStateVisitor {
    mutating func _visitStatePath<M: Model, T>(
        _ statePath: WritableKeyPath<M._ModelState, T>,
        forState: M.Type
    )
    mutating func _visitStatePath<M: Model, T>(
        _ statePath: WritableKeyPath<M._ModelState, T>,
        forState: M.Type,
        visibility: PropertyVisibility
    )
}

extension _ModelStateVisitor {
    mutating func _visitStatePath<M: Model, T>(_ statePath: WritableKeyPath<M._ModelState, T>, forState: M.Type) { }
    mutating func _visitStatePath<M: Model, T>(_ statePath: WritableKeyPath<M._ModelState, T>, forState: M.Type, visibility: PropertyVisibility) { }
}

protocol ModelTransformer {
    func transform<M: Model>(_ model: inout M)
}

struct ModelTransformerVisitor<Root, Child, Transformer: ModelTransformer>: ModelVisitor {
    var root: Root
    let path: WritableKeyPath<Root, Child>
    let transformer: Transformer

    mutating func visit<T: Model>(path: WritableKeyPath<Child, T>) {
        let fullPath = self.path.appending(path: path)
        transformer.transform(&root[keyPath: fullPath])

        var visitor = ModelTransformerVisitor<Root, T, Transformer>(root: root, path: fullPath, transformer: transformer)
        root[keyPath: fullPath].visit(with: &visitor, includeSelf: false)
        root = visitor.root
    }

    mutating func visit<T: ModelContainer>(path: WritableKeyPath<Child, T>) {
        let fullPath = self.path.appending(path: path)
        var visitor = ModelTransformerVisitor<Root, T, Transformer>(root: root, path: fullPath, transformer: transformer)
        root[keyPath: fullPath].visit(with: &visitor, includeSelf: false)
        root = visitor.root
    }

    mutating func visitCollection<C: MutableCollection>(path: WritableKeyPath<Child, C>)
        where C: Sendable, C.Element: Model & Identifiable & Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        let fullPath = self.path.appending(path: path)
        for index in root[keyPath: fullPath].indices {
            root[keyPath: fullPath][index] = root[keyPath: fullPath][index].transformModel(with: transformer)
        }
    }

    mutating func visitContainerCollection<C: MutableCollection>(path: WritableKeyPath<Child, C>)
        where C.Element: ModelContainer & Identifiable & Sendable, C: Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        let fullPath = self.path.appending(path: path)
        for index in root[keyPath: fullPath].indices {
            let element = root[keyPath: fullPath][index]
            let id = element.id
            let cursor = ContainerCursor(id: id,
                get: { (col: C) in col.first(where: { $0.id == id }) ?? element },
                set: { (col: inout C, val: C.Element) in
                    guard let idx = col.firstIndex(where: { $0.id == id }) else { return }
                    col[idx] = val
                }
            )
            let cursorPath: WritableKeyPath<C, C.Element> = \C.[cursor: cursor]
            let elementFullPath = fullPath.appending(path: cursorPath)
            var elementVisitor = ModelTransformerVisitor<Root, C.Element, Transformer>(
                root: root, path: elementFullPath, transformer: transformer)
            root[keyPath: elementFullPath].visit(with: &elementVisitor, includeSelf: false)
            root = elementVisitor.root
        }
    }
}

protocol ValueReducer {
    associatedtype Value
    static func reduce<M: Model>(value: inout Value, model: M) -> Void
}

struct ReduceValueVisitor<Root, Child, Reducer: ValueReducer>: ModelVisitor {
    let root: Root
    let path: WritableKeyPath<Root, Child>
    let reducer: Reducer.Type
    var value: Reducer.Value

    mutating func visit<T: Model>(path: WritableKeyPath<Child, T>) {
        let fullPath = self.path.appending(path: path)
        reducer.reduce(value: &value, model: root[keyPath: fullPath])

        var visitor = ReduceValueVisitor<Root, T, Reducer>(root: root, path: fullPath, reducer: reducer, value: value)
        root[keyPath: fullPath].visit(with: &visitor, includeSelf: false)
        value = visitor.value
    }

    mutating func visit<T: ModelContainer>(path: WritableKeyPath<Child, T>) {
        let fullPath = self.path.appending(path: path)
        var visitor = ReduceValueVisitor<Root, T, Reducer>(root: root, path: fullPath, reducer: reducer, value: value)
        root[keyPath: fullPath].visit(with: &visitor, includeSelf: false)
        value = visitor.value
    }

    mutating func visitCollection<C: MutableCollection>(path: WritableKeyPath<Child, C>)
        where C: Sendable, C.Element: Model & Identifiable & Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        let fullPath = self.path.appending(path: path)
        for element in root[keyPath: fullPath] {
            value = element.reduceValue(with: reducer, initialValue: value)
        }
    }

    mutating func visitContainerCollection<C: MutableCollection>(path: WritableKeyPath<Child, C>)
        where C.Element: ModelContainer & Identifiable & Sendable, C: Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        let fullPath = self.path.appending(path: path)
        for element in root[keyPath: fullPath] {
            let id = element.id
            let cursor = ContainerCursor(id: id,
                get: { (col: C) in col.first(where: { $0.id == id }) ?? element },
                set: { (_: inout C, _: C.Element) in }
            )
            let cursorPath: WritableKeyPath<C, C.Element> = \C.[cursor: cursor]
            let elementFullPath = fullPath.appending(path: cursorPath)
            var elementVisitor = ReduceValueVisitor<Root, C.Element, Reducer>(
                root: root, path: elementFullPath, reducer: reducer, value: value)
            root[keyPath: elementFullPath].visit(with: &elementVisitor, includeSelf: false)
            value = elementVisitor.value
        }
    }
}

struct AnchorVisitor<M: Model, Container: ModelContainer, Value: ModelContainer>: ModelVisitor {
    var value: Value
    var didAttemptToReplaceWithAnchoredModel = false
    let context: Context<M>
    let containerPath: WritableKeyPath<M, Container>
    let elementPath: WritableKeyPath<Container, Value>
    /// When `true`, the hierarchy lock is known to be already held by the caller (e.g., inside
    /// `stateTransaction`). The fast path calls `findOrTrackChildLocked` instead of
    /// `findOrTrackChild`, eliminating O(N) redundant recursive lock re-entries during container
    /// traversal in `updateContext`.
    let hierarchyLockHeld: Bool

    init(value: Value, context: Context<M>, containerPath: WritableKeyPath<M, Container>, elementPath: WritableKeyPath<Container, Value>, hierarchyLockHeld: Bool = false) {
        self.value = value
        self.context = context
        self.containerPath = containerPath
        self.elementPath = elementPath
        self.hierarchyLockHeld = hierarchyLockHeld
    }

    mutating func visit<T: Model>(path: WritableKeyPath<Value, T>) {
        let childModel = value[keyPath: path]

        let isSelf = path == \Value.self && containerPath == \M.self && elementPath == \Container.self

        // For child models: bail if destructed/frozen (they were removed, don't re-anchor them).
        // For the top-level model being anchored (isSelf): allow even if destructed — this is the
        // re-anchoring case (e.g. undo restoring a deleted item, or static testValue across tests).
        if !isSelf && childModel.lifetime.isDestructedOrFrozenCopy {
            threadLocals.didReplaceModelWithDestructedOrFrozenCopy()
            return
        }

        // Skip children that are still lazily pending (have a creator but no context yet).
        // This prevents the second withContextAdded traversal in returningAnchor (and updateContext
        // re-traversals) from prematurely triggering childContext() → materializeLazyContext(),
        // which would fire onActivate() before the parent's onActivate() runs.
        if !isSelf, let childRef = childModel.modelContext.reference, childRef.hasLazyContextCreator {
            return
        }

        // Fast path: for non-self children, look up by ID only (no key-path construction).
        // Inserts the element into `modelRefs` (required for the set-subtraction diff in
        // `updateContext`) and returns the already-registered child context when found.
        // If the context is current, all remaining work is skipped — this is the common case for
        // existing elements during `append`/`remove` mutations on large arrays.
        //
        // When `hierarchyLockHeld` is true (called from within `stateTransaction`), we use
        // `findOrTrackChildLocked` to skip the redundant per-element lock re-entry, eliminating
        // O(N) recursive NSRecursiveLock acquisitions for the existing-elements fast path.
        if !isSelf {
            let existing: Context<T>? = hierarchyLockHeld
                ? context.findOrTrackChildLocked(containerPath: containerPath, childModel: childModel)
                : context.findOrTrackChild(containerPath: containerPath, childModel: childModel)
            if let existing {
                // Do NOT skip when the child is in .live (internal direct-access) mode — same as
                // visitCollection: the context check passes but writes bypass context routing.
                if existing === childModel.context, !childModel.modelContext._source._isLive {
                    return
                }
                // Context is registered but the element's modelContext points elsewhere (re-anchoring).
                // Fall through to the slow path; modelRefs was already updated by findOrTrackChild(Locked).
            }
        }

        // Lazy context: during initial anchor setup (context.reference.context == nil, i.e. before
        // setContext is called in Context.init), collection elements can be registered lazily when
        // the .lazyChildContexts option is set. Their context is created on demand (first write,
        // node use, etc.) via materializeLazyContext().
        //
        // Post-anchor updates (e.g. parent.children.append(...)) always use the eager path because
        // context.reference.context is non-nil by then — the newly added element needs its context
        // immediately so that onActivate() fires and the element participates in the hierarchy.
        //
        // Direct single-model children (e.g. `var child: Child`) are always eager regardless —
        // the MutableCollection check excludes them.
        // Construct the full element key path. Only reached for new or re-anchoring elements,
        // so the O(path-composition) cost is paid at most once per added/changed item.
        let modelElementPath = elementPath.appending(path: path)

        if !isSelf && context.options.contains(.lazyChildContexts) && (value is any MutableCollection) && context.reference.context == nil && childModel.modelContext.reference?.context == nil {
            context.registerLazyChild(containerPath: containerPath, elementPath: modelElementPath, childModel: childModel)
            return
        }

        let childContext = isSelf ? (context as! Context<T>) : context.childContext(containerPath: containerPath, elementPath: modelElementPath, childModel: childModel)

        // Also trigger re-anchoring when a non-self child is in .live mode (internal direct-access):
        // MakeInitialTransformer can leave children live even after Context.init sets the context,
        // causing subsequent user writes to bypass context routing (no lock, no observation, no undo).
        if childContext !== childModel.context || (!isSelf && childModel.modelContext._source._isLive) {
            value[keyPath: path].withContextAdded(context: childContext, containerPath: \.self, elementPath: \.self, includeSelf: false, hierarchyLockHeld: hierarchyLockHeld)
            // For non-self children: set .reference source so they can redirect through context.
            // For self (readModel in Context.init): leave .live source intact so key path access
            // reads directly from Reference._state without going through the context subscript.
            if !isSelf {
                value[keyPath: path].modelContext = ModelContext(context: childContext)
            }
        }
    }

    mutating func visit<T: ModelContainer>(path: WritableKeyPath<Value, T>) {
        if containerPath == \.self, elementPath == \.self {
            value[keyPath: path].withContextAdded(context: context, containerPath: path as! WritableKeyPath<M, T>, elementPath: \.self, includeSelf: false, hierarchyLockHeld: hierarchyLockHeld)
        } else {
            value[keyPath: path].withContextAdded(context: context, containerPath: containerPath, elementPath: elementPath.appending(path: path), includeSelf: false, hierarchyLockHeld: hierarchyLockHeld)
        }
    }

    /// Fast-path: returns `true` when the element is already registered and up-to-date so the
    /// container can skip all cursor construction (3 heap allocations) for this element.
    ///
    /// Called from `ModelContainer.visit` before `path(id:get:set:)` cursor construction.
    /// When `hierarchyLockHeld` is `true` (the common path from `updateContext`), uses the
    /// lock-free `findOrTrackChildLocked`; otherwise acquires the lock via `findOrTrackChild`.
    mutating func shouldSkipElement<T: Model>(element: T, id: AnyHashable) -> Bool {
        // Guard: destructed/frozen copies are handled in the slow path visit<T:Model>(path:).
        guard !element.lifetime.isDestructedOrFrozenCopy else { return false }
        // Lazily-pending elements (have a creator but no context yet) must go through childContext
        // so that onActivate() fires and they participate in the hierarchy.
        if let childRef = element.modelContext.reference, childRef.hasLazyContextCreator { return false }

        let existing: Context<T>? = hierarchyLockHeld
            ? context.findOrTrackChildLocked(containerPath: containerPath, childModel: element)
            : context.findOrTrackChild(containerPath: containerPath, childModel: element)
        guard let existing else { return false }
        // Only skip when the element's modelContext still points to the registered context
        // AND the element is not in .live (internal direct-access) mode. A .live element bypasses
        // context routing even when its context reference is correct; it needs to be re-anchored
        // so that user writes route through the context (observation, locking, undo).
        return existing === element.modelContext.context && !element.modelContext._source._isLive
    }

    /// Cursor-free traversal for `MutableCollection` properties.
    ///
    /// Iterates the collection directly by index, bypassing `ModelContainer.visit(with:)` and
    /// the associated cursor key path allocations. Uses `findOrTrackChildForCollection` /
    /// `childContextForCollection` which key elements by `(containerPath, ModelRef(\C.self, id))`.
    mutating func visitCollection<C: MutableCollection>(path: WritableKeyPath<Value, C>)
        where C: Sendable, C.Element: Model & Identifiable & Sendable, C.Index: Sendable, C.Element.ID: Sendable {

        // Compute the full path from M to C.
        // In the top-level case (containerPath == \.self, elementPath == \.self), this is `path`.
        // In nested cases it composes all three segments.
        let collectionPath: WritableKeyPath<M, C> = containerPath
            .appending(path: elementPath)
            .appending(path: path)

        // Lazily register an element-path maker for this collection property the first time it is
        // visited. The maker is consulted by rootPathTree() only when rootPaths is queried
        // (TestAccess / undo observation) — never in production. One closure per property.
        if context.collectionElementPathMakersStore?[collectionPath] == nil {
            context.lock {
                context.registerCollectionElementPathMaker(for: collectionPath) { anyID in
                    guard let typedID = anyID.base as? C.Element.ID else { return \C.self }
                    let cursor = ContainerCursor<C.Element.ID, C, C.Element>(
                        id: typedID,
                        get: { $0.first(where: { $0.id == typedID })! },
                        set: { coll, val in
                            guard let idx = coll.firstIndex(where: { $0.id == typedID }) else { return }
                            coll[idx] = val
                        }
                    )
                    return \C.[cursor: cursor]
                }
            }
        }

        for index in value[keyPath: path].indices {
            let element = value[keyPath: path][index]

            guard !element.lifetime.isDestructedOrFrozenCopy else {
                threadLocals.didReplaceModelWithDestructedOrFrozenCopy()
                continue
            }
            if let childRef = element.modelContext.reference, childRef.hasLazyContextCreator {
                continue
            }

            // O(1) fast path: element already registered and context is current.
            let existing: Context<C.Element>? = hierarchyLockHeld
                ? context.findOrTrackChildLockedForCollection(containerPath: collectionPath, childModel: element)
                : context.findOrTrackChildForCollection(containerPath: collectionPath, childModel: element)
            // Do NOT skip when the element is in .live (internal direct-access) mode: it needs its
            // modelContext transitioned to .regular so that user writes route through the context.
            // This case arises when MakeInitialTransformer transitions pre-anchor elements to .live
            // before Context.init sets the child context — the context check then passes, but the
            // element is still bypassing context routing.
            if let existing, existing === element.modelContext.context, !element.modelContext._source._isLive { continue }

            // Lazy context: during initial anchor setup, register lazily when option is set.
            if context.options.contains(.lazyChildContexts) && context.reference.context == nil && element.modelContext.reference?.context == nil {
                context.registerLazyChildForCollection(containerPath: collectionPath, childModel: element)
                continue
            }

            let childContext = context.childContextForCollection(containerPath: collectionPath, childModel: element)
            if childContext !== element.modelContext.context || element.modelContext._source._isLive {
                value[keyPath: path][index].withContextAdded(context: childContext, containerPath: \.self, elementPath: \.self, includeSelf: false, hierarchyLockHeld: hierarchyLockHeld)
                value[keyPath: path][index].modelContext = ModelContext(context: childContext)
            }
        }
    }

    /// Cursor-free traversal for `MutableCollection` properties whose element type is
    /// `ModelContainer & Identifiable` but that do not conform to `ModelContainer` themselves
    /// (e.g. `IdentifiedArray<Path>` where `Path` is a `@ModelContainer` enum).
    ///
    /// Unlike the old cursor-based approach, no `ContainerCursor` is allocated per element.
    /// Child contexts are stored under `children[collectionPath]` keyed by
    /// `ModelRef(\C.self, childModel.id)` — the same sentinel strategy as `visitCollection`.
    /// A cursor is only built lazily inside `AnchorVisitorForContainerElement` if a nested
    /// `ModelContainer` child property is encountered (the uncommon path).
    mutating func visitContainerCollection<C: MutableCollection>(path: WritableKeyPath<Value, C>)
        where C.Element: ModelContainer & Identifiable & Sendable, C: Sendable, C.Index: Sendable, C.Element.ID: Sendable {

        let collectionPath: WritableKeyPath<M, C> = containerPath
            .appending(path: elementPath)
            .appending(path: path)

        for index in value[keyPath: path].indices {
            let element = value[keyPath: path][index]
            let id = threadLocals.withValue(true, at: \.forceDirectAccess) { element.id }

            var elementVisitor = AnchorVisitorForContainerElement(
                value: element,
                context: context,
                collectionPath: collectionPath,
                elementID: id,
                capturedElement: element,
                hierarchyLockHeld: hierarchyLockHeld
            )
            element.visit(with: &elementVisitor, includeSelf: false)
            value[keyPath: path][index] = elementVisitor.value
        }
    }
}

/// A visitor that traverses a single `ModelContainer` element inside a `MutableCollection`
/// that does not itself conform to `ModelContainer`.
///
/// Stores child contexts under `children[collectionPath]` using
/// `ModelRef(elementPath: \C.self, id: childModel.id)` as the registry key — the same sentinel
/// strategy as `childContextForCollection`. No cursor is needed for `visit<Child: Model>`.
///
/// A `ContainerCursor` is built lazily (stored in `_cursorPath`) only when
/// `visit<U: ModelContainer>` is called — the uncommon path of nested `ModelContainer` inside
/// a collection element. For the common case (`@Model` children inside a `@ModelContainer` enum)
/// the cursor is never constructed, saving 3 heap allocations per element.
struct AnchorVisitorForContainerElement<M: Model, C: MutableCollection, T: ModelContainer & Identifiable>: ModelVisitor
    where C: Sendable, C.Element == T, T.ID: Sendable, C.Index: Sendable {
    typealias State = T
    var value: T
    let context: Context<M>
    /// Path to the collection in the root model (`M → C`). Used as the outer key in `children`.
    let collectionPath: WritableKeyPath<M, C>
    /// The element's identity, used only if a cursor is needed for `visit<U: ModelContainer>`.
    let elementID: T.ID
    /// A copy of the element at traversal time, used as the cursor's fallback `get` value.
    let capturedElement: T
    let hierarchyLockHeld: Bool
    /// Lazily-constructed cursor path (`C → T`). Built at most once per element traversal,
    /// only if `visit<U: ModelContainer>` is called.
    private var _cursorPath: WritableKeyPath<C, T>?

    init(value: T, context: Context<M>, collectionPath: WritableKeyPath<M, C>, elementID: T.ID, capturedElement: T, hierarchyLockHeld: Bool) {
        self.value = value
        self.context = context
        self.collectionPath = collectionPath
        self.elementID = elementID
        self.capturedElement = capturedElement
        self.hierarchyLockHeld = hierarchyLockHeld
        self._cursorPath = nil
    }

    mutating func visit<Child: Model>(path: WritableKeyPath<T, Child>) {
        let childModel = value[keyPath: path]

        if childModel.lifetime.isDestructedOrFrozenCopy {
            threadLocals.didReplaceModelWithDestructedOrFrozenCopy()
            return
        }
        if let childRef = childModel.modelContext.reference, childRef.hasLazyContextCreator { return }

        // Fast path: element already registered and context is current — no cursor needed.
        let existing: Context<Child>? = hierarchyLockHeld
            ? context.findOrTrackChildLockedForContainerCollectionModel(
                collectionPath: collectionPath, childModel: childModel)
            : context.findOrTrackChildForContainerCollectionModel(
                collectionPath: collectionPath, childModel: childModel)
        if let existing, existing === childModel.modelContext.context { return }

        // Slow path: create or update child context. No cursor path required — uses \C.self sentinel.
        let childCtx = context.childContextForContainerCollectionModel(
            collectionPath: collectionPath,
            childModel: childModel
        )
        if childCtx !== childModel.modelContext.context {
            value[keyPath: path].withContextAdded(
                context: childCtx, containerPath: \.self, elementPath: \.self,
                includeSelf: false, hierarchyLockHeld: hierarchyLockHeld)
            value[keyPath: path].modelContext = ModelContext(context: childCtx)
        }
    }

    mutating func visit<U: ModelContainer>(path: WritableKeyPath<T, U>) {
        // Nested ModelContainer inside a ModelContainer collection element.
        // Build the cursor lazily — only this uncommon path requires it.
        // NOTE: these children are NOT included in children[collectionPath], so the removal
        // diff in updateContextForContainerCollection will not clean them up when the element
        // is removed. This limitation only affects nested-ModelContainer-in-ModelContainer cases;
        // the common path (Model children inside a @ModelContainer enum) is handled above.
        let cp = cursorPath()
        let composedPath = cp.appending(path: path)
        let fullPath = collectionPath.appending(path: composedPath)
        value[keyPath: path].withContextAdded(
            context: context,
            containerPath: fullPath,
            elementPath: \.self,
            includeSelf: false,
            hierarchyLockHeld: hierarchyLockHeld
        )
    }

    /// Returns the cursor path for this element, constructing it lazily on first call.
    private mutating func cursorPath() -> WritableKeyPath<C, T> {
        if let existing = _cursorPath { return existing }
        let id = elementID
        let cap = capturedElement
        let cursor = ContainerCursor(id: id,
            get: { (col: C) in col.first(where: { $0.id == id }) ?? cap },
            set: { (col: inout C, val: C.Element) in
                guard let idx = col.firstIndex(where: { $0.id == id }) else { return }
                col[idx] = val
            }
        )
        let p: WritableKeyPath<C, T> = \C.[cursor: cursor]
        _cursorPath = p
        return p
    }
}
