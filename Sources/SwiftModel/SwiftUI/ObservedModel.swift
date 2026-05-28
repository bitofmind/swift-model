#if canImport(SwiftUI)
import SwiftUI
import Observation

/// Sets up a model for observation to invalidate the view when state changes.
///
/// Use the projectedValue to access a binding of a property such as `$model.count`.
///
/// >`@ObservedModel` has been carefully crafted to only trigger view updates when properties you are accessing from your view is updated.
///
///   struct CounterView: View {
///     @ObservedModel var model: CounterModel
///
///     var body: some View {
///       Stepper(value: $model.count) {
///         Text("\(model.count)")
///       }
///     }
///   }
///
/// # Debug
///
/// Call `$model.debug(_:)` inside `body` to log which keypath of `wrappedValue`
/// (or any descendant model the view reads) caused SwiftUI to invalidate this
/// view:
///
///     var body: some View {
///         $editor.debug()                                  // auto-label "<ModelType> at file:line"
///         $editor.debug(.init(name: "EditorMidBar"))       // custom label
///         $editor.debug(.triggers(.withValue))             // include old → new
///         $editor.debug(.init(printer: signposts))         // route to Instruments
///         return content
///     }
///
/// `triggers`, `name`, `printer`, `accessObserver`, and `captureAccessStack`
/// from `DebugOptions` are honoured; `changes` is ignored (covered by
/// `node.debug(.changes)` on the model itself). Active only in `DEBUG` builds;
/// the call is compiled out in release.
@propertyWrapper @dynamicMemberLookup
@MainActor
public struct ObservedModel<M: Model>: DynamicProperty, Equatable {
    @StateObject private var access = ViewAccess()

    // Read in DEBUG inside `update()`. When the enclosing subtree has been
    // marked via `.swiftModelDebugScope()`, this is `true` and we install
    // `ViewAccess` even on the iOS 17+ registrar path so descendant reads
    // are scoped to this view's access (which is what gives `$model.debug(...)`
    // accurate attribution).
    //
    // SwiftUI calls `update()` on every nested `DynamicProperty` member before
    // calling it on the wrapper itself, so by the time `update()` runs the env
    // value reflects whatever the closest ancestor set.
#if DEBUG
    @Environment(\.swiftModelDebugActive) private var swiftModelDebugActive
#endif

    public init(wrappedValue: M) {
        self.wrappedValue = wrappedValue
    }

    public init(projectedValue: Self) {
        self.wrappedValue = projectedValue.wrappedValue
    }

    public var wrappedValue: M
    public var projectedValue: Self { self }

    public nonisolated mutating func update() {
        // On iOS 17+ / macOS 14+ with `ObservationRegistrar` enabled, SwiftUI wraps
        // `body` in `withObservationTracking` and handles invalidation itself, so
        // installing `ViewAccess` would be wasted work. We bail out entirely in
        // release, and lazily-install in DEBUG only after a body-side
        // `$model.debug(...)` has flipped a sticky flag on the `@StateObject`
        // access (Option B: zero cost on the registrar path until debug is in use).
        //
        // Once the sticky flag is set the access is re-installed on every render
        // for the lifetime of the `@StateObject` — even if the user later removes
        // the `$model.debug(...)` line. Rebuilding the view (Cmd-R) resets it. On
        // the registrar path the access runs purely for debug emission and passes
        // `suppressObjectWillChange: true` so the registrar's invalidation isn't
        // doubled by a redundant `objectWillChange.send()`.
        let usesObservationRegistrar: Bool
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *),
            wrappedValue.context?.hasObservationRegistrar == true {
            usesObservationRegistrar = true
        } else {
            usesObservationRegistrar = false
        }

#if !DEBUG
        if usesObservationRegistrar {
            return
        }
#endif

        MainActor.assumeIsolated {
#if DEBUG
            // Sticky-lazy gate: skip install on the registrar path until either
            //   (a) a body-side `$model.debug(...)` has flipped `debugRequested`, or
            //   (b) the enclosing subtree has been marked via
            //       `.swiftModelDebugScope()` (env value `swiftModelDebugActive`).
            //
            // (b) is the "force-install" path that breaks debug attribution leaks
            // — when an ancestor view has `$model.debug(...)` attached, its
            // `ViewAccess` would otherwise see transitive reads from descendant
            // views that skip their own `ViewAccess` install on iOS 17+. With
            // env-active here, every descendant `@ObservedModel` installs its own
            // access, re-stamping the model so reads register on the descendant.
            if usesObservationRegistrar && !access.debugRequested && !swiftModelDebugActive {
                return
            }
#endif
            wrappedValue = wrappedValue.withAccess(access)
            access.updateObserved(
                wrappedValue,
                suppressObjectWillChange: usesObservationRegistrar
            )
        }
    }

    /// Attach debug logging for the duration of this view's body window.
    ///
    /// Call from inside `body`. One line is emitted per tracked-property mutation
    /// that invalidates this view, naming the model and key path that fired:
    ///
    /// ```swift
    /// var body: some View {
    ///     $editor.debug()                          // auto-label: "EditorModel at TodoList.swift:42"
    ///     $editor.debug(.init(name: "EditorMidBar"))
    ///     $editor.debug(.triggers(.withValue))     // include old → new
    ///     return content
    /// }
    /// ```
    ///
    /// `triggers`, `name`, `printer`, `accessObserver`, and `captureAccessStack`
    /// from `DebugOptions` are honoured; `changes` is ignored (covered by
    /// `node.debug(.changes)` on the model itself). When `name` is `nil`, the
    /// default label is `"<ModelType> at fileID:line"` — `<ModelType>` from
    /// `String(describing: M.self)` and the call site captured via `#fileID`/`#line`.
    /// Pass a custom `name` (e.g. the View's type name) when you want a stable,
    /// human-readable identifier.
    ///
    /// The debug state is cleared at the start of each render — removing this
    /// line from `body` automatically disables emission on the next render. Set
    /// once-and-forget is not supported; this matches the lifetime of a SwiftUI
    /// view body.
    ///
    /// In release builds the call compiles to nothing — leave it in place when
    /// shipping, no `#if DEBUG` wrapping required at call sites.
    public func debug(
        _ options: DebugOptions = .triggers(),
        fileID: StaticString = #fileID,
        line: UInt = #line
    ) {
#if DEBUG
        // Apply the auto-label only when the user didn't supply one. `withDefaultName`
        // preserves *all* other fields — crucial: rebuilding the struct field-by-field
        // historically dropped `accessObserver` and `captureAccessStack`, silently
        // breaking users who set those without also setting `name`.
        let resolved = options.withDefaultName("\(String(describing: M.self)) at \(debugFileLocation(fileID, line))")
        access.attachDebug(resolved)
#endif
    }

    public subscript<T>(dynamicMember path: WritableKeyPath<M, T>) -> Binding<T> {
        Binding {
            wrappedValue[keyPath: path]
        } set: { newValue in
            var model = wrappedValue
            model[keyPath: path] = newValue
        }
    }

    public subscript<T: Model>(dynamicMember path: KeyPath<M, T>) -> Binding<T> {
        Binding {
            wrappedValue[keyPath: path]
        } set: { _ in }
    }

    public var binding: Binding<M> {
        Binding {
            wrappedValue
        } set: { _ in }
    }

    public nonisolated static func == (lhs: ObservedModel, rhs: ObservedModel) -> Bool {
        lhs.wrappedValue.modelID == rhs.wrappedValue.modelID
    }
}

public extension Binding {
    subscript<Subject: Model>(dynamicMember keyPath: KeyPath<Value, Subject>&Sendable) -> Binding<Subject> where Value: Model {
        Binding<Subject> {
            wrappedValue[keyPath: keyPath]
        } set: { _ in }
    }
}

/// A view that scopes observation to its content, preventing unnecessary
/// re-renders of the containing view.
///
/// When a parent view accesses a model property, SwiftUI re-renders the
/// *entire* parent whenever that property changes — even if the property is
/// only used in a small part of the view hierarchy. Wrapping that part in
/// `ModelScope` confines observation to the scope itself: only `ModelScope`
/// re-renders when its accessed properties change, leaving the parent unaffected.
///
/// ```swift
/// struct TrackView: View {
///     var segment: SegmentModel  // no @ObservedModel — view is stable
///
///     var body: some View {
///         baseTrackView
///             .overlay {
///                 // Only this scope re-renders when isHovering changes.
///                 // Without ModelScope the overlay has no observation at all
///                 // (no @ObservedModel in TrackView), or with @ObservedModel
///                 // the entire TrackView re-renders for every hover change.
///                 ModelScope {
///                     if segment.isHovering { HoverOverlay() }
///                 }
///             }
///     }
/// }
/// ```
///
/// `ModelScope` observes *all* models accessed inside the closure — not just
/// one — so mixed-model content is naturally handled:
///
/// ```swift
/// ModelScope {
///     if segment.isHovering || editor.isExternalPaneActive { ... }
/// }
/// ```
///
/// ## iOS 16 lazy-closure fix
///
/// `ModelScope` also fixes a secondary iOS 16 issue: certain SwiftUI APIs
/// evaluate their `@ViewBuilder` content in a separate rendering context,
/// breaking the observation chain if no scope boundary is present. Affected
/// APIs include `ModalContext`, `GeometryReader`, `.sheet`, `.popover`,
/// `.fullScreenCover`, and `NavigationStack` destination closures. On iOS 17
/// and later, SwiftUI's `withObservationTracking` handles these automatically.
///
/// ```swift
/// ModalContext {
///     ModelScope {
///         switch model.step { ... }
///     }
/// }
/// ```
///
/// ## `debug:` attribution coverage — synchronous vs. captured-closure reads
///
/// `ModelScope.body` wraps `content` in `usingActiveAccess(access)`. The
/// access dispatch in `Context.willAccessDirect` resolves to
/// `ModelAccess.active ?? stampedAccess` — so the thread-local active
/// access **takes precedence** over the model's stamped access. On both
/// the iOS 16 (`AccessCollector`) path and the iOS 17+ (`ObservationRegistrar`)
/// path, every **synchronous read** that happens during `content()` rendering
/// dispatches `willAccess` to this scope's access, so `debug:` attributes
/// it to this scope.
///
/// The limitation is **closure lifetime, not platform**. A read that fires
/// asynchronously through a captured closure (e.g. `.onHover { editor.x = ... }`,
/// `.task { ... editor.foo ... }`, `Observed { ... }` callbacks) runs *after*
/// `usingActiveAccess` has returned. At that point `ModelAccess.active` is
/// `nil`, so the dispatch falls back to whatever stamp the captured model
/// carries — typically the enclosing `@ObservedModel`'s access, not this
/// scope's. Its `debug:` therefore attributes to the enclosing view, not
/// to the scope.
///
/// If you need attribution for closure-captured reads — e.g. a hover handler
/// inside a pane should attribute to that pane, not to the editor root —
/// introduce a small wrapper view with its own `@ObservedModel`. The
/// wrapper's `update()` re-stamps the model with the wrapper's access, and
/// since the stamp is what closure-captured reads dispatch through, this
/// gives stable per-section attribution regardless of timing:
///
/// ```swift
/// struct TracksPaneScope<Content: View>: View {
///     @ObservedModel var editor: EditorModel
///     @ViewBuilder var content: Content
///
///     var body: some View {
///         let _ = $editor.debug(.init(name: "TracksPane", captureAccessStack: 20))
///         content
///     }
/// }
/// ```
public struct ModelScope<Content: View>: View {
    @StateObject private var access = ViewAccess()
    private let content: () -> Content
    // `debug`, `fileID`, and `line` are read only inside `#if DEBUG` paths
    // (`attachDebug` + the default-label construction). Gating their storage on
    // `#if DEBUG` keeps the release-build struct stride down — no `Optional`
    // overhead, no `StaticString` payload, no `UInt`. The init signatures still
    // accept the params on both builds so user code compiles either way; release
    // builds discard them.
#if DEBUG
    private let debug: DebugOptions?
    private let fileID: StaticString
    private let line: UInt

    // See `@ObservedModel.swiftModelDebugActive` for rationale. When the
    // enclosing subtree has been marked via `.swiftModelDebugScope()`, the
    // scope installs `ViewAccess` even on iOS 17+ so descendant reads
    // register on this scope's access (giving accurate `$model.debug(...)`
    // attribution).
    @Environment(\.swiftModelDebugActive) private var swiftModelDebugActive
#endif

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
#if DEBUG
        self.debug = nil
        self.fileID = #fileID
        self.line = #line
#endif
    }

    /// Variant that attaches a `DebugOptions` value for the lifetime of this scope.
    ///
    /// Use to log which model properties accessed inside the scope are invalidating
    /// just this scope (rather than the parent view). Equivalent in spirit to
    /// `$model.debug(_:)` on `@ObservedModel`, but configured at construction
    /// because `ModelScope` has no `body`-side projection.
    ///
    /// ```swift
    /// ModelScope(debug: .init(name: "EditorView.toolbar",
    ///                         accessObserver: .firstAccessCallStack())) {
    ///     EditorMidBar(editor: editor)
    /// }
    /// ```
    ///
    /// On iOS 17+ / macOS 14+ the scope normally lets SwiftUI's
    /// `withObservationTracking` drive invalidation directly. When `debug` is non-nil
    /// the scope's `ViewAccess` is installed too, but with `suppressObjectWillChange`
    /// set so the registrar's invalidation isn't doubled — the access exists solely
    /// to emit debug output / fire `accessObserver`. The `#fileID:#line` is captured
    /// at construction and used as the default label when `debug.name` is `nil`.
    ///
    /// Compiled out in release builds beyond the wrapping: the debug install path is
    /// gated on `#if DEBUG`, and in release the scope behaves identically to the
    /// no-`debug` initialiser.
    public init(
        debug: DebugOptions?,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.content = content
#if DEBUG
        self.debug = debug
        self.fileID = fileID
        self.line = line
#else
        _ = debug      // discard — used only in DEBUG
        _ = fileID
        _ = line
#endif
    }

    public var body: some View {
        let usesRegistrar: Bool
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            usesRegistrar = true
        } else {
            usesRegistrar = false
        }

#if DEBUG
        if let debug {
            // Prepare the access for this render. On the registrar path we also
            // suppress `ViewAccess.objectWillChange.send()` so the access doesn't
            // double-invalidate alongside `withObservationTracking`.
            access.prepareForRender(suppressObjectWillChange: usesRegistrar)

            // Attach (or reattach) debug for the current render. Default the label
            // to `"ModelScope at file:line"` when none was supplied, matching the
            // `$model.debug(...)` auto-label convention. `withDefaultName` preserves
            // all other fields including `accessObserver` and `captureAccessStack` —
            // important when users set those without also overriding `name`.
            let resolved = debug.withDefaultName("ModelScope at \(debugFileLocation(fileID, line))")
            access.attachDebug(resolved)
        }
#endif

        return _renderedContent(usesRegistrar: usesRegistrar)
    }

    // Split the install + env-propagation decision out of `body` so DEBUG can
    // use `@ViewBuilder` (yielding a concrete `_ConditionalContent<…>`) while
    // release returns the original `Content` directly. Previously a uniform
    // `AnyView` wrap was used to unify the two compilation modes — release
    // builds paid an `AnyView` cost for a DEBUG-only feature, breaking
    // SwiftUI's structural-identity reuse for every `ModelScope` consumer.
#if DEBUG
    @ViewBuilder
    private func _renderedContent(usesRegistrar: Bool) -> some View {
        let debugActive = (debug != nil)
        // Force-install also when the enclosing subtree has been marked
        // `.swiftModelDebugScope()` — gives descendant attribution scoping
        // even when this scope has no `debug` itself.
        let forceInstall = swiftModelDebugActive
        // `debugActive` always implies `shouldInstall`, so the
        // `!shouldInstall && debugActive` cell is impossible — three real cases.
        let shouldInstall = !usesRegistrar || debugActive || forceInstall

        if debugActive {
            // Has its own debug — install and propagate
            // `\.swiftModelDebugActive` so every nested `@ObservedModel` /
            // `ModelScope` also installs its own `ViewAccess`. The re-stamping
            // chain is what prevents descendant reads from leaking onto this
            // scope's `ViewAccess`.
            usingActiveAccess(access) { content() }
                .environment(\.swiftModelDebugActive, true)
        } else if shouldInstall {
            // iOS 16 (always installs) OR ancestor `.swiftModelDebugScope()`
            // asked for force-install. Either way, no env propagation from
            // here — either it's already set by the ancestor, or we're on
            // the iOS 16 path where the env is irrelevant.
            usingActiveAccess(access) { content() }
        } else {
            // iOS 17+, no debug on this scope, no ancestor force-install.
            // SwiftUI's `withObservationTracking` drives invalidation and our
            // access would be pure overhead. Zero-cost path.
            content()
        }
    }
#else
    // Release: no debug surface, no env value to consult. iOS 16 installs,
    // iOS 17+ doesn't — single branch, returns `Content` directly so the
    // opaque `body` type stays structural (no `AnyView`).
    private func _renderedContent(usesRegistrar: Bool) -> Content {
        if !usesRegistrar {
            return usingActiveAccess(access) { content() }
        } else {
            return content()
        }
    }
#endif
}

internal final class Observer<M: Model>: @unchecked Sendable {
    // Protected by ViewAccess's lock
    weak var context: Context<M>?
    weak var viewAccess: ViewAccess?
    var accesses: [PartialKeyPath<M._ModelState>: () -> Void] = [:]
    /// Last-seen rendered value per accessed path, populated only when debug is enabled
    /// with `.withValue` or `.withDiff` formats. Used to produce `old → new` lines on
    /// each trigger. Reads and writes happen under `ViewAccess.lock`.
    var debugLastValues: [PartialKeyPath<M._ModelState>: String] = [:]
    /// Captured raw return-address stack per accessed path (as `UInt` bit patterns
    /// so the storage stays trivially `Sendable`), populated only when debug has
    /// `captureAccessStack` set. Symbolicated lazily inside `emitDebugTrigger` so
    /// the cost is paid only for paths that actually invalidate the view.
    /// Reads and writes happen under `ViewAccess.lock`.
    var debugAccessStacks: [PartialKeyPath<M._ModelState>: [UInt]] = [:]

    init(context: Context<M>, viewAccess: ViewAccess) {
        self.context = context
        self.viewAccess = viewAccess
    }

    deinit {
        for cancellable in accesses.values {
            cancellable()
        }
    }
}

/// Debug state captured on a `ViewAccess`. Holds the user-supplied options resolved
/// into the values the `onModify` callback needs — a thread-safe printer, the format
/// to use, the view's label, and the optional diff style. `nil` everywhere outside
/// `#if DEBUG` so release builds pay no cost.
#if DEBUG
private struct ViewAccessDebug: Sendable {
    let printer: PrinterBox
    /// `nil` when the view is only using debug for the `accessObserver` hook —
    /// no trigger emission, but property reads still register so the observer fires.
    let triggers: TriggerFormat?
    let label: String
    /// Optional read-side hook. Fired by `ViewAccess.willAccess` on every access
    /// while debug is attached (outside locks). See ``AccessObserver``.
    let accessObserver: (any AccessObserver)?
    /// When non-nil, `willAccess` captures a raw return-address stack of this depth
    /// at first registration; `emitDebugTrigger` symbolicates and appends it.
    let captureAccessStack: Int?

    /// `true` when we need to capture and compare values across mutations
    /// (i.e. `.withValue` or `.withDiff`).
    var needsValueCapture: Bool {
        switch triggers {
        case .name, nil:             return false
        case .withValue, .withDiff:  return true
        }
    }
}
#endif

internal final class ViewAccess: ModelAccess, ObservableObject, @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [ModelID: AnyObject] = [:]
    private var root: AnyContext?
    /// True when SwiftUI's `withObservationTracking` is handling view invalidation for
    /// this access (iOS 17+ / macOS 14+ with `useObservationRegistrar`). The
    /// `onModify` callback then skips its own `objectWillChange.send()` to avoid a
    /// redundant invalidation signal. Debug emission, if enabled, still fires —
    /// that's the whole reason we install `ViewAccess` on the registrar path.
    private var suppressObjectWillChange: Bool = false
#if DEBUG
    /// Set by `attachDebug(_:)` during a body render and read at `willAccess` time.
    /// `nil` when the user has not called `$model.debug(...)` in the current render.
    /// Cleared at the start of each `updateObserved` call so that removing the
    /// `$model.debug(...)` line auto-disables emission on the next render.
    private var debug: ViewAccessDebug?
    /// Sticky flag — set the first time `attachDebug(_:)` activates debug. Lives
    /// for the lifetime of the `@StateObject` and is never reset. On the iOS 17+
    /// `ObservationRegistrar` path this gates `ObservedModel.update()`'s install:
    /// zero cost until the first `$model.debug(...)` call, then access is
    /// re-installed every render so debug emission survives toggling the line on
    /// and off. Rebuilding the view (Cmd-R) resets the `@StateObject` and the flag.
    private(set) var debugRequested: Bool = false
#endif

    init() {
        super.init(useWeakReference: true)
    }

    func updateObserved<M: Model>(
        _ model: M,
        suppressObjectWillChange: Bool = false
    ) {
        lock.withLock {
            if let root, root !== model.context {
                observers.removeAll(keepingCapacity: true)
            }
            self.root = model.context
            self.suppressObjectWillChange = suppressObjectWillChange

#if DEBUG
            // Clear debug state at the start of each render. Body re-attaches via
            // `$model.debug(...)`; removing the line therefore auto-disables emission
            // on the next render with no stale state hanging around.
            self.debug = nil
#endif
        }
    }

#if DEBUG
    /// Attach or replace debug options. Called by `$model.debug(...)` inside body.
    /// Idempotent — call multiple times if needed; the most recent options win for
    /// the current render. The per-render `debug` state is cleared automatically
    /// by the next `updateObserved` call; the sticky `debugRequested` flag
    /// persists for the `@StateObject`'s lifetime so subsequent renders keep
    /// installing the access (needed on the iOS 17+ registrar path where install
    /// is otherwise skipped).
    ///
    /// On the very first activation we schedule an extra invalidation via
    /// `Task { @MainActor in objectWillChange.send() }`. On the registrar path
    /// the current render's reads went straight through `withObservationTracking`
    /// without registering on `ViewAccess`, so we'd have no observers to fire on
    /// the next mutation. The priming render runs `update()` again — this time
    /// with the sticky flag set — which installs the access, body re-runs and
    /// registers reads, and subsequent mutations emit normally. The task defers
    /// to the next runloop tick to avoid the SwiftUI "Publishing changes from
    /// within view updates" warning, since `attachDebug` is called from `body`.
    func attachDebug(_ options: DebugOptions) {
        let needsPriming: Bool = lock.withLock {
            // Activate when either trigger output, an access observer, or
            // access-stack capture is requested. (Stack capture without `triggers`
            // is degenerate — there's no place to emit the stack — but allow it
            // so attaching purely for `accessObserver` still works.)
            let wantsStackCapture = (options.captureAccessStack ?? 0) > 0
            guard options.triggers != nil || options.accessObserver != nil || wantsStackCapture else {
                self.debug = nil
                return false
            }
            self.debug = ViewAccessDebug(
                printer: PrinterBox(options.effectivePrinter),
                triggers: options.triggers,
                label: options.name ?? "?",
                accessObserver: options.accessObserver,
                captureAccessStack: options.captureAccessStack
            )
            let firstActivation = !self.debugRequested
            self.debugRequested = true
            return firstActivation
        }
        if needsPriming {
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
    }
#endif

#if DEBUG
    /// Per-render prep for `ModelScope`, which has no single root model. Sets the
    /// `suppressObjectWillChange` flag and clears the per-render `debug` state
    /// (which the body's `attachDebug` call will repopulate). Observers persist for
    /// the `@StateObject`'s lifetime.
    func prepareForRender(suppressObjectWillChange: Bool) {
        lock.withLock {
            self.suppressObjectWillChange = suppressObjectWillChange
            self.debug = nil
        }
    }
#endif

    override func willAccess<M: Model, Value>(from context: Context<M>, at path: KeyPath<M._ModelState, Value>&Sendable) -> (() -> Void)? {
        guard !ModelAccess.isInModelTaskContext else {
            return nil
        }

#if DEBUG
        // Skip registration entirely when the read originates from a debug-side
        // `customDump` walk (initial-value capture in this method, or
        // `dumpForDebug` inside `emitDebugTrigger`). Without this guard every
        // `.withValue` emit registers every walked field as a tracked dependency
        // *and* captures the dump's own call stack instead of the user-code stack
        // — both of which pollute subsequent investigations.
        if threadLocals.isInsideDebugDump {
            return nil
        }
#endif

        // Skip registration when this read is inside a memoize's async `observe()`
        // body. The memoize's own dependency tracking runs upstream via Apple's
        // `withObservationTracking` (in `ObservationTracking.observe()`); the
        // calling view's `ViewAccess` must not also accumulate deps for whatever
        // the memoize body internally touches — otherwise the memoize provides
        // freshness dedup but not observation isolation, and the parent's
        // `$model.debug(...)` attributes inner reads to the parent.
        // See `ThreadLocals.isInsideMemoizeObserve`.
        if threadLocals.isInsideMemoizeObserve { return nil }

        let id = context.anyModelID

        if context.isDestructed {
            lock {
                observers[id] = nil
            }
            return nil
        }

        if let root, root.isDestructed {
            lock {
                observers.removeAll(keepingCapacity: true)
            }
            return nil
        }

        lock.lock()

        let observer = (observers[id] as? Observer<M>) ?? Observer(context: context, viewAccess: self)
        observers[id] = observer

        if observer.accesses[path] == nil {
#if DEBUG
            // In DEBUG, capture the initial rendered value of this property so a
            // later `$model.debug(.triggers(.withValue))` attached anywhere in
            // body (or in a future render) can produce a meaningful `old → new`
            // line on the next mutation. Without this, late-attached debug would
            // only have a "new" value to print.
            //
            // Only capture for real-state writable key paths. Synthetic key paths
            // (`[memoizeKey:]`, `[environmentKey:]`, `[preferenceKey:]`,
            // `[_parentsObservationKey:]`) have `fatalError()` getters intended
            // for key-path construction only — evaluating them crashes. This
            // mirrors the `WritableKeyPath` filter used in `DebugAccessCollector`.
            //
            // The typed context-storage subscripts `[_metadata:]` and `[_preference:]`
            // are *also* writable but ALSO have `fatalError()` getters — their value
            // lives outside `_ModelState`. When the read came through
            // `Context.willAccessStorage`, that callee has pre-set
            // `threadLocals.precomputedStorageValue` exactly so the closure here can
            // skip the keypath read. Use that value when present; only fall back to
            // the keypath when it's a real `_ModelState` property.
            //
            // Cost: one `String(customDumping:)` per accessed real property per
            // render, DEBUG-only.
            if path is WritableKeyPath<M._ModelState, Value> {
                // Honour the currently-attached debug's `.withValue(maxLines:maxDepth:)`
                // when capturing so the first emit's `oldStr` doesn't blow out the log
                // with an untruncated `customDump`. When debug is not attached yet, or
                // its triggers format isn't `.withValue` (e.g. `.withDiff`, which does
                // its own diffing without `maxLines`), capture the unbounded form —
                // a later `$model.debug(.triggers(.withValue(maxLines:)))` will still
                // see something on first emit, and the emit-side defensive truncation
                // below caps the output even in that case.
                //
                // `isInsideDebugDump` suppresses re-entrant `willAccess` registration
                // while `customDump` walks the model tree — without it, every traversed
                // field would register as a tracked dep (and its access stack would be
                // the dump path, not user code). See `ThreadLocals.isInsideDebugDump`.
                let initialValue = threadLocals.withValue(true, at: \.isInsideDebugDump) {
                    usingActiveAccess(nil) {
                        threadLocals.withValue(true, at: \.includeChildrenInMirror) {
                            // Prefer the precomputed value when this `willAccess` was
                            // dispatched from `Context.willAccessStorage` (sets
                            // `precomputedStorageValue`) or `willAccessPreferenceValue`
                            // (sets `precomputedPreferenceValue`) — it's the only way to
                            // read the typed `[_metadata:]` / `[_preference:]` subscripts
                            // without crashing on their `fatalError()` stub getters.
                            let v: Value
                            if let precomputed = (threadLocals.precomputedStorageValue
                                                  ?? threadLocals.precomputedPreferenceValue) as? Value {
                                v = precomputed
                            } else {
                                v = context._modelSeed[keyPath: M._modelStateKeyPath][keyPath: path]
                            }
                            if case .withValue(let maxLines, let maxDepth) = self.debug?.triggers {
                                return dumpForDebug(v, maxLines: maxLines, maxDepth: maxDepth)
                            }
                            return String(customDumping: v)
                        }
                    }
                }
                observer.debugLastValues[path] = initialValue
            }

            // If `captureAccessStack` is set, snapshot the raw return-address
            // stack now — cheap, no symbolication. `emitDebugTrigger` will
            // symbolicate and append it iff this path actually fires a trigger.
            if let depth = self.debug?.captureAccessStack, depth > 0 {
                let addrs = Thread.callStackReturnAddresses
                    .prefix(depth)
                    .map { $0.uintValue }
                observer.debugAccessStacks[path] = addrs
            }
#endif

            lock.unlock()

            // Capture the suppress flag at registration time so the callback closure
            // doesn't have to re-lock to read mutable state on every mutation. The
            // flag never changes for the lifetime of a `ViewAccess` (set once in
            // `updateObserved`), so the capture is safe.
            let suppressObjectWillChange = self.suppressObjectWillChange

            let access = context.onModify(for: path) { [weak self] finished, _ in
                guard let self else {
                    return {}
                }

                return {
                    if !finished {
#if DEBUG
                        // Read the current debug state at fire time (not at
                        // registration). `$model.debug(...)` may be called *after*
                        // some reads have already registered — the body-side API
                        // makes no ordering guarantee. Reading here under the lock
                        // ensures every mutation that fires sees the latest debug
                        // attachment for this render.
                        if let currentDebug = self.lock({ self.debug }) {
                            self.emitDebugTrigger(
                                debug: currentDebug,
                                observer: observer,
                                context: context,
                                path: path
                            )
                        }
#endif
                        if !suppressObjectWillChange {
                            context.mainCallQueue {
                                self.objectWillChange.send()
                            }
                        }
                    } else {
                        self.lock {
                            observer.accesses[path] = nil
                            observer.debugLastValues[path] = nil
                            observer.debugAccessStacks[path] = nil
                        }
                    }
                }
            }

            lock.lock()
            observer.accesses[path] = access
        }

        observers[id] = observer

#if DEBUG
        // Capture the access observer under lock, fire it AFTER releasing. This lets
        // observers do expensive work (stack capture, breakpoint trap) without holding
        // swift-model locks. Fires on *every* willAccess call so observers see real
        // access frequency; built-in `FirstAccessObserver` deduplicates internally.
        let capturedAccessObserver: (any AccessObserver)? = self.debug?.accessObserver
#endif

        lock.unlock()

#if DEBUG
        if let accessObserver = capturedAccessObserver {
            let modelType = String(describing: M.self)
            let propName = debugPropertyName(
                from: context._modelSeed,
                path: M._modelStateKeyPath.appending(path: path)
            ) ?? ""
            accessObserver.observeAccess(modelType: modelType, path: propName)
        }
#endif
        return nil
    }

    override var shouldPropagateToChildren: Bool { true }

#if DEBUG
    /// Emits a debug trigger line to the captured printer.
    ///
    /// Called from the `onModify` post-lock callback after a tracked property has
    /// already been mutated — so `context._modelSeed[…][keyPath: path]` reads the
    /// post-mutation value. For `.withValue` / `.withDiff` the stored `debugLastValues`
    /// entry holds the previous rendering, which we compare against the new one.
    private func emitDebugTrigger<M: Model, Value>(
        debug: ViewAccessDebug,
        observer: Observer<M>,
        context: Context<M>,
        path: KeyPath<M._ModelState, Value> & Sendable
    ) {
        // Skip when the user only attached an access observer or stack capture
        // (no trigger output requested). The captured stack stays alive on the
        // observer for the lifetime of the registration; it just isn't emitted.
        guard let triggers = debug.triggers else { return }

        let propName = debugPropertyName(from: context._modelSeed, path: M._modelStateKeyPath.appending(path: path))
        let modelType = String(describing: M.self)
        let target = propName.map { "\(modelType).\($0)" } ?? modelType
        let header = "\(debug.label) ← \(target)"

        // Synthetic paths (memoize/environment/preference/parents) have
        // `fatalError()` getters — never read their value. Fall back to the
        // header-only line for `.withValue` / `.withDiff` in that case.
        //
        // The typed context-storage subscripts (`[_metadata:]`, `[_preference:]`)
        // are also writable-with-fatalError, but `Context.didModifyStorage`
        // pre-sets `threadLocals.precomputedStorageValue` for exactly this read.
        // Treat that as the canonical "current value" source — fall back to
        // direct keypath read only for real `_ModelState` properties.
        let canReadValue = path is WritableKeyPath<M._ModelState, Value>
        @Sendable func readValue() -> Value? {
            if let precomputed = (threadLocals.precomputedStorageValue
                                  ?? threadLocals.precomputedPreferenceValue) as? Value {
                return precomputed
            }
            guard canReadValue else { return nil }
            return context._modelSeed[keyPath: M._modelStateKeyPath][keyPath: path]
        }

        // Format the per-format body for this trigger.
        let body: String
        switch triggers {
        case .name:
            body = header
        case .withValue(let maxLines, let maxDepth):
            guard let value = readValue() else {
                debug.printer.write(header + accessStackSuffix(observer: observer, path: path))
                return
            }
            // `isInsideDebugDump` suppresses re-entrant `willAccess` during the
            // customDump walk inside `dumpForDebug` — see `ThreadLocals.isInsideDebugDump`.
            let newStr = threadLocals.withValue(true, at: \.isInsideDebugDump) {
                usingActiveAccess(nil) {
                    threadLocals.withValue(true, at: \.includeChildrenInMirror) {
                        dumpForDebug(value, maxLines: maxLines, maxDepth: maxDepth)
                    }
                }
            }
            // Defensive truncation on the stored `oldStr`. The capture site in
            // `willAccess` honours the current `.withValue(maxLines:maxDepth:)` when
            // possible, but it can run before debug is attached or when a different
            // format was active — in those cases the stored string is unbounded.
            // Re-applying `truncateToMaxLines` here guarantees the emit output
            // respects `maxLines` regardless of how `oldStr` was originally captured.
            // (`maxDepth` cannot be re-applied to a stored string; the capture site
            // is the only place that can enforce it.)
            let storedOld = lock { observer.debugLastValues[path] }
            let oldStr = storedOld.map { truncateToMaxLines($0, maxLines: maxLines) } ?? newStr
            lock { observer.debugLastValues[path] = newStr }
            body = "\(header): \(oldStr) → \(newStr)"
        case .withDiff(let style):
            guard let value = readValue() else {
                debug.printer.write(header + accessStackSuffix(observer: observer, path: path))
                return
            }
            // `isInsideDebugDump` suppresses re-entrant `willAccess` during the
            // customDump walk — see `ThreadLocals.isInsideDebugDump`.
            let newStr = threadLocals.withValue(true, at: \.isInsideDebugDump) {
                usingActiveAccess(nil) {
                    threadLocals.withValue(true, at: \.includeChildrenInMirror) {
                        String(customDumping: value)
                    }
                }
            }
            let oldStr = lock { observer.debugLastValues[path] }
            lock { observer.debugLastValues[path] = newStr }
            if let oldStr, oldStr != newStr,
               let diff = snapshotLineDiff(oldStr, newStr, style: style) {
                body = "\(header)\n\(diff)"
            } else {
                // First fire (no prior snapshot) or identical strings: emit the new value plainly.
                body = "\(header) = \(newStr)"
            }
        }

        debug.printer.write(body + accessStackSuffix(observer: observer, path: path))
    }

    /// Returns a `"\n  read from:\n    <frame>\n    <frame>…"` suffix when a stack
    /// was captured for this path via `captureAccessStack`, otherwise `""`.
    /// Symbolicates lazily (so the cost is paid only for paths that actually fire)
    /// and trims the leading SwiftModel-internal frames so the first visible frame
    /// is the user-code line that performed the read.
    private func accessStackSuffix<M: Model, Value>(
        observer: Observer<M>,
        path: KeyPath<M._ModelState, Value> & Sendable
    ) -> String {
        let addrs = lock { observer.debugAccessStacks[path] }
        guard let addrs, !addrs.isEmpty else { return "" }
        let frames = trimSwiftModelInternalFrames(symbolicateAccessStack(addrs))
        guard !frames.isEmpty else { return "" }
        return "\n  read from:\n    " + frames.joined(separator: "\n    ")
    }
#endif
}

#endif
