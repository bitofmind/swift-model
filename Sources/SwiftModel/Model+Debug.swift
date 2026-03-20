import Foundation
import CustomDump
import ConcurrencyExtras

// MARK: - Debug options

/// Controls what a `node.debug`, `memoize(debug:)`, or `Observed(debug:)` call prints.
///
/// Build a value using the static factory members and combine them in an array literal:
///
/// ```swift
/// node.debug([.triggers, .changes]) { count }
/// node.memoize(for: "sorted", debug: [.triggers(.withValue), .changes(.value)]) { … }
/// ```
public struct DebugOptions: ExpressibleByArrayLiteral, Sendable {
    var options: [DebugOption]

    public init(arrayLiteral elements: DebugOption...) {
        self.options = elements
    }

    init(_ options: [DebugOption]) {
        self.options = options
    }

    // MARK: Convenience shorthands (allow passing a single option without brackets)

    /// Print the name of each dependency that changed: `"AppModel.filter"`.
    public static let triggers: DebugOptions = [.triggers()]

    /// Print each changed dependency with its old → new value: `"AppModel.filter: \"a\" → \"b\""`.
    public static let triggerValues: DebugOptions = [.triggers(.withValue)]

    /// Print a structured diff of each dependency's value when it triggers.
    ///
    /// More verbose than `.triggerValues` but reveals exactly which property changed
    /// inside a nested model — useful when `triggerValues` shows `TypeName() → TypeName()`.
    public static let triggerDiffs: DebugOptions = [.triggers(.withDiff)]

    /// Print a diff of the observed value when it changes.
    public static let changes: DebugOptions = [.changes()]

    /// Don't follow sub-model properties when tracking dependencies.
    public static let shallow: DebugOptions = [.shallow]

    var triggerFormat: TriggerFormat? {
        for case .triggers(let f) in options { return f }
        return nil
    }

    var changeFormat: ChangeFormat? {
        for case .changes(let f) in options { return f }
        return nil
    }

    var isShallow: Bool {
        options.contains { if case .shallow = $0 { return true }; return false }
    }

    var name: String? {
        for case .name(let n) in options { return n }
        return nil
    }

    var printer: (any TextOutputStream & Sendable)? {
        for case .printer(let p) in options { return p }
        return nil
    }

    var effectivePrinter: any TextOutputStream & Sendable {
        printer ?? PrintTextOutputStream()
    }
}

/// A single debug configuration element. Combine multiple in a `DebugOptions` array literal.
public enum DebugOption: Sendable {
    /// Print the name (and optionally value) of each dependency that triggered an update.
    case triggers(TriggerFormat = .name)

    /// Print the observed/memoized value when it changes.
    case changes(ChangeFormat = .diff)

    /// Don't propagate observation into sub-model properties.
    case shallow

    /// Override the label used in debug output (default: type name).
    case name(String)

    /// Override the output destination (default: `print()`).
    case printer(any TextOutputStream & Sendable)
}

public extension DebugOption {
    /// Shorthand for `.triggers()` — use when the default `.name` format is wanted.
    /// Allows `[.triggers, .name("...")]` instead of `[.triggers(), .name("...")]`.
    static var triggers: Self { .triggers() }

    /// Shorthand for `.changes()` — use when the default `.diff` format is wanted.
    /// Allows `[.changes, .name("...")]` instead of `[.changes(), .name("...")]`.
    static var changes: Self { .changes() }
}

/// Controls how a changed dependency is described in `.triggers` output.
public enum TriggerFormat: Sendable {
    /// Print only the property name: `"AppModel.filter"`.
    case name

    /// Print the property name and its old → new value: `"AppModel.filter: \"a\" → \"b\""`.
    case withValue

    /// Print a `−`/`+` diff of the dependency value with all model sub-properties expanded.
    ///
    /// Especially useful when the dependency is itself a model — this reveals exactly which
    /// nested property changed, rather than showing opaque `TypeName() → TypeName()`.
    case withDiff
}

/// Controls how the updated observed/memoized value is displayed in `.changes` output.
public enum ChangeFormat: Sendable {
    /// Show a `−`/`+` diff between the old and new value.
    case diff

    /// Show only the new value via `customDump`.
    case value
}

// MARK: - PrintTextOutputStream

public struct PrintTextOutputStream: TextOutputStream, Sendable {
    public init() {}
    public func write(_ string: String) {
        print(string)
    }
}

// MARK: - PrinterBox

/// A reference-type box that allows a `TextOutputStream` value to be safely
/// captured in `@Sendable` closures without triggering Swift 6 mutation warnings.
///
/// `TextOutputStream.write(_:)` is `mutating`, but we need to call it from
/// `@Sendable` closures. This box holds the printer behind an `NSLock` so the
/// captured `var` is always accessed under a lock, satisfying the concurrency checker.
final class PrinterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _write: (String) -> Void

    init(_ printer: any TextOutputStream & Sendable) {
        var p = printer
        _write = { p.write($0) }
    }

    func write(_ string: String) {
        lock.lock(); defer { lock.unlock() }
        _write(string)
    }
}

// MARK: - Public debug API

public extension Model where Self: Sendable {
    /// Will start to print state changes until cancelled, but only in `DEBUG` configurations.
    @available(*, deprecated, renamed: "debug()")
    @discardableResult
    func _printChanges(name: String? = nil, to printer: some TextOutputStream&Sendable = PrintTextOutputStream()) -> Cancellable {
        var opts = DebugOptions([DebugOption.changes()])
        if let name { opts = DebugOptions(opts.options + [.name(name)]) }
        if !(printer is PrintTextOutputStream) { opts = DebugOptions(opts.options + [.printer(printer)]) }
        return debug(opts)
    }

    // MARK: - debug

    /// Observes this model's entire state tree and prints debug information whenever anything changes.
    ///
    /// The no-closure form observes `self` — all stored properties are tracked as dependencies.
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.debug()                                        // diff output, whole model
    ///     node.debug([.changes(.value)])                     // print new value instead of diff
    ///     node.debug([.changes(), .name("MyModel")])        // custom label
    ///     node.debug([.triggers, .changes()])               // also show which properties changed
    /// }
    /// ```
    ///
    /// To track which specific properties triggered an update in a sub-expression,
    /// use the closure form: `node.debug([.triggers]) { expression }`
    ///
    /// Only active in `DEBUG` builds. Returns a `Cancellable` you can cancel early.
    @discardableResult
    func debug(_ options: DebugOptions = [.changes()]) -> Cancellable {
#if DEBUG
        guard let context = enforcedContext() else { return EmptyCancellable() }
        let label = options.name ?? typeDescription
        let printerBox = PrinterBox(options.effectivePrinter)
        let changeFormat = options.changeFormat

        // Snapshot helper: renders the model to a string via customDump, capturing the
        // current live values of all properties including child models. We store rendered
        // strings rather than raw model values because child model structs share the live
        // context reference — comparing them directly would always appear equal.
        // When `.shallow` is active, child models are rendered opaque (just their type name)
        // so that changes deep inside a child don't produce a diff line.
        let isShallow = options.isShallow
        @Sendable func snapshot(_ m: Self) -> String {
            threadLocals.withValue(true, at: \.includeChildrenInMirror) {
                guard isShallow else { return String(customDumping: m) }
                return threadLocals.withValue(0 as Int?, at: \.shallowMirrorDepth) {
                    String(customDumping: m)
                }
            }
        }

        let previous = LockIsolated<String?>(nil)

        // Initialize previous snapshot with the current model value.
        previous.setValue(snapshot(context.lock { context.readModel }))

        let cancel = context.onAnyModification { [weak context] didFinish in
            guard !didFinish, let context else { return nil }
            if let fmt = changeFormat {
                let value = context.lock { context.readModel }
                switch fmt {
                case .diff:
                    let prevSnap = previous.value
                    let newSnap = snapshot(value)
                    previous.setValue(newSnap)
                    if let prevSnap, prevSnap != newSnap,
                       let d = snapshotLineDiff(prevSnap, newSnap) {
                        printerBox.write("\(label) value changed:\n\(d)")
                    }
                case .value:
                    previous.setValue(snapshot(value))
                    let valueDesc = threadLocals.withValue(true, at: \.includeChildrenInMirror) {
                        String(customDumping: value)
                    }
                    printerBox.write("\(label) = \(valueDesc)")
                }
            }
            return nil
        }

        return AnyCancellable(cancellations: context.cancellations, onCancel: cancel)
#else
        return EmptyCancellable()
#endif
    }

    /// Observes specific properties and prints debug information when they change.
    ///
    /// The `access` closure declares which properties to watch — every property read
    /// inside it is tracked as a dependency via `AccessCollector`.
    ///
    /// ```swift
    /// func onActivate() {
    ///     // Print which dependency changed and the new computed value
    ///     node.debug([.triggers, .changes]) { (count, filter) }
    ///
    ///     // Watch a memoized result with a custom label
    ///     node.debug([.triggers, .name("sortedItems")]) { sortedItems }
    /// }
    /// ```
    ///
    /// Only active in `DEBUG` builds.
    @discardableResult
    func debug<T: Sendable>(_ options: DebugOptions = [.triggers(), .changes()], _ access: @Sendable @escaping () -> T) -> Cancellable {
#if DEBUG
        guard let context = enforcedContext() else { return EmptyCancellable() }
        let label = options.name ?? typeDescription

        let cancel = debugObserve(
            options: options,
            label: label,
            rootModelID: modelID,
            access: access,
            onUpdate: { _ in }
        ) { wrappedAccess, wrappedOnUpdate in
            let (cancel, _) = update(
                initial: false,
                isSame: nil,
                useWithObservationTracking: false,
                useCoalescing: false
            ) {
                wrappedAccess()
            } onUpdate: { value in wrappedOnUpdate(value) }
            return cancel
        }

        return AnyCancellable(cancellations: context.cancellations, onCancel: cancel)
#else
        return EmptyCancellable()
#endif
    }
}

// MARK: - snapshotLineDiff

/// Computes a line-level context diff between two multi-line snapshot strings.
/// Returns nil when the strings are equal.
///
/// Each output line is prefixed with `"  "` (unchanged context), `"- "` (removed),
/// or `"+ "` (added). Uses LCS to find the minimal set of changes, so unchanged lines
/// (e.g. a struct's other fields) appear as context rather than being fully replaced.
private func snapshotLineDiff(_ prev: String, _ next: String) -> String? {
    guard prev != next else { return nil }
    let pLines = prev.components(separatedBy: "\n")
    let nLines = next.components(separatedBy: "\n")
    let m = pLines.count, n = nLines.count

    // Build LCS lengths table: dp[i][j] = LCS length of pLines[..<i] and nLines[..<j].
    var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
    for i in 1...m {
        for j in 1...n {
            dp[i][j] = pLines[i-1] == nLines[j-1]
                ? dp[i-1][j-1] + 1
                : max(dp[i-1][j], dp[i][j-1])
        }
    }

    // Backtrack to collect edit operations (accumulated in reverse order).
    enum Edit { case context(String), remove(String), add(String) }
    var edits = [Edit]()
    edits.reserveCapacity(m + n)
    var i = m, j = n
    while i > 0 || j > 0 {
        if i > 0, j > 0, pLines[i-1] == nLines[j-1] {
            edits.append(.context(pLines[i-1])); i -= 1; j -= 1
        } else if j > 0, i == 0 || dp[i][j-1] >= dp[i-1][j] {
            edits.append(.add(nLines[j-1])); j -= 1
        } else {
            edits.append(.remove(pLines[i-1])); i -= 1
        }
    }

    return edits.reversed().map { edit -> String in
        switch edit {
        case .context(let line): return "  \(line)"
        case .remove(let line):  return "- \(line)"
        case .add(let line):     return "+ \(line)"
        }
    }.joined(separator: "\n")
}

// MARK: - memoizeDebugSetup

/// Sets up debug observation for a `memoize` call.
/// Returns nil values for all three when `options` is empty (zero cost path).
///
/// - Parameters:
///   - options: The `DebugOptions` passed to `memoize(debug:)`.
///   - label: The human-readable label used in printed output.
/// - Returns: A tuple of:
///   - `debugPrint`: Closure to call after each memoize update with `(newValue, previousValue)`.
///   - `debugPreviousValue`: Shared state tracking the previous value for diff computation.
///   - `debugCollectorBox`: Box holding the `DebugAccessCollector`; run `produce()` through
///     `usingActiveAccess(collectorBox.value)` after first `update()` to register trigger callbacks.
func memoizeDebugSetup<T: Sendable>(
    options: DebugOptions,
    label: String
) -> (
    debugPrint: (@Sendable (T, T?) -> Void)?,
    debugPreviousValue: LockIsolated<T?>?,
    debugCollectorBox: LockIsolated<DebugAccessCollector?>?
) {
    guard !options.options.isEmpty else {
        return (nil, nil, nil)
    }

    let debugTriggerFormat = options.triggerFormat
    let debugChangeFormat = options.changeFormat
    let debugPrinterBox = PrinterBox(options.effectivePrinter)
    // Store lazy closures so that expensive operations (e.g. LCS diff) run in debugPrint,
    // outside the context lock, rather than blocking it during the onModify callback.
    let debugPendingTriggers = LockIsolated<[@Sendable () -> String]>([])
    let collectorBox = LockIsolated<DebugAccessCollector?>(nil)

    if let fmt = debugTriggerFormat {
        let collector = DebugAccessCollector(
            triggerFormat: fmt,
            isShallow: options.isShallow
        ) { lazy in
            debugPendingTriggers.withValue { $0.append(lazy) }
        }
        collectorBox.setValue(collector)
    }

    // Prints debug output for a memoize update.
    // Capture collectorBox to keep the DebugAccessCollector alive for the
    // lifetime of the memoize subscription (so its onModify callbacks stay registered).
    let debugPrint: @Sendable (T, T?) -> Void = { [collectorBox] value, previous in
        _ = collectorBox  // keep alive
        var lines: [String] = []

        if debugTriggerFormat != nil {
            // Evaluate lazy trigger closures here — outside the context lock — so that
            // expensive work (e.g. LCS snapshotLineDiff for .withDiff) doesn't block
            // threads waiting on the context lock.
            let triggers = debugPendingTriggers.withValue { ts -> [@Sendable () -> String] in
                defer { ts.removeAll() }
                return ts
            }.map { $0() }
            if !triggers.isEmpty {
                lines.append("\(label) triggered update:")
                for t in triggers {
                    lines.append("  dependency changed: \(t)")
                }
            }
        }

        if let fmt = debugChangeFormat {
            switch fmt {
            case .diff:
                if let prev = previous, let d = diff(prev, value) {
                    lines.append("\(label) value changed:")
                    lines.append(d)
                }
            case .value:
                lines.append("\(label) = \(String(customDumping: value))")
            }
        }

        if !lines.isEmpty {
            debugPrinterBox.write(lines.joined(separator: "\n"))
        }
    }

    return (debugPrint, LockIsolated<T?>(nil), collectorBox)
}

// MARK: - DebugAccessCollector

/// A `ModelAccess` subclass used exclusively by the debug infrastructure.
///
/// Tracks which model properties are accessed inside an observed closure, registers
/// `onModify` callbacks on each, and fires `onTrigger` when any dependency changes.
/// Unlike `AccessCollector`, this class never re-registers subscriptions on `reset` —
/// it is a one-shot observer tied to the lifetime of the debug observation.
///
/// When `isShallow` is true, `shouldPropagateToChildren` returns `false` so the
/// access collector does not recurse into child model properties.
final class DebugAccessCollector: ModelAccess, @unchecked Sendable {
    struct Key: Hashable, @unchecked Sendable {
        var id: ModelID
        var path: AnyKeyPath
    }

    /// Called when a tracked dependency changes. Receives a lazy closure that produces
    /// the human-readable description like `"AppModel.filter"` or `"AppModel.filter: 3 → 4"`.
    /// The closure is evaluated lazily in `wrappedOnUpdate`/`debugPrint` — outside the context
    /// lock — so that expensive operations (e.g. LCS diff) don't block other threads.
    let onTrigger: @Sendable (@Sendable @escaping () -> String) -> Void

    /// Tracks live subscriptions keyed by (modelID, path).
    /// The `String?` slot holds the last-seen value string for the `.withValue` trigger format.
    let subscriptions = LockIsolated<[Key: (@Sendable () -> Void, String?)]>([:])

    let triggerFormat: TriggerFormat
    let isShallow: Bool
    /// When `isShallow` is true and this is non-nil, only properties on the root model
    /// (the one whose ID matches) are registered as trigger dependencies. Properties on
    /// child models are ignored so their changes don't produce trigger output.
    let rootModelID: ModelID?

    init(
        triggerFormat: TriggerFormat,
        isShallow: Bool = false,
        rootModelID: ModelID? = nil,
        onTrigger: @Sendable @escaping (@Sendable @escaping () -> String) -> Void
    ) {
        self.triggerFormat = triggerFormat
        self.isShallow = isShallow
        self.rootModelID = rootModelID
        self.onTrigger = onTrigger
        super.init(useWeakReference: false)
    }

    deinit {
        cancelAll()
    }

    func cancelAll() {
        let cancels = subscriptions.withValue { subs -> [@Sendable () -> Void] in
            let cs = subs.values.map(\.0)
            subs.removeAll()
            return cs
        }
        for cancel in cancels { cancel() }
    }

    override var shouldPropagateToChildren: Bool { !isShallow }

    override func willAccess<M: Model, T>(_ model: M, at path: KeyPath<M, T> & Sendable) -> (() -> Void)? {
        // In shallow mode, only track properties on the root model — skip child models.
        // `usingActiveAccess` installs this collector globally so `willAccess` fires for
        // every model; we filter here rather than relying on `shouldPropagateToChildren`.
        if isShallow, let rootModelID, model.modelID != rootModelID { return nil }

        guard let context = model.context else { return nil }

        let key = Key(id: model.modelID, path: path)

        // Only subscribe once per (model, path) pair.
        let alreadySubscribed = subscriptions.withValue { $0[key] != nil }
        guard !alreadySubscribed else { return nil }

        // Skip non-writable synthetic paths (untyped \M[environmentKey:] / \M[preferenceKey:]).
        // These fire alongside typed WritableKeyPath companions but have no working post-lock
        // callbacks — only the typed path's buildPostLockCallbacks fires. Registering them
        // produces dead subscriptions that waste memory without ever triggering output.
        guard path is WritableKeyPath<M, T> else { return nil }

        let modelType = String(describing: M.self)
        let propName = debugPropertyName(from: model, path: path)
        let baseLabel = propName.map { "\(modelType).\($0)" } ?? modelType

        // Capture the current value string now so that on first trigger we have "old → new".
        let fmt = triggerFormat

        // Helper: dump `value` with model sub-properties expanded (includeChildrenInMirror=true)
        // and with active access suppressed so dumping doesn't re-enter willAccess callbacks.
        @Sendable func dumpWithChildren(_ value: T) -> String {
            usingActiveAccess(nil) {
                threadLocals.withValue(true, at: \.includeChildrenInMirror) {
                    String(customDumping: value)
                }
            }
        }

        let initialValueStr: String?
        switch fmt {
        case .withValue:
            // usingActiveAccess(nil) suppresses the DebugAccessCollector during the keypath read.
            // Context/preference paths (_metadata, _preference) re-enter willAccessStorage/Preference
            // via their getters; with no active access, mc.willAccess returns nil and the cycle is broken.
            initialValueStr = usingActiveAccess(nil) {
                context.lock { String(customDumping: context.readModel[keyPath: path]) }
            }
        case .withDiff:
            // Same re-entry guard as .withValue: suppress active access while reading the keypath.
            // frozenCopy prevents child/metadata lock deadlocks during the subsequent dumpWithChildren.
            let initialFrozen: T = usingActiveAccess(nil) {
                context.lock { frozenCopy(context.readModel[keyPath: path]) }
            }
            initialValueStr = dumpWithChildren(initialFrozen)
        case .name:
            initialValueStr = nil
        }

        let cancellation = context.onModify(for: path) { [weak self] finished, _ in
            guard !finished, let self else { return {} }

            switch fmt {
            case .name:
                // Lazy closure: trivial, just returns the pre-computed label.
                self.onTrigger { baseLabel }
                return nil
            case .withValue:
                let newValueStr = usingActiveAccess(nil) {
                    context.lock { String(customDumping: context.readModel[keyPath: path]) }
                }
                // Atomically swap the stored value for old→new reporting.
                let oldValueStr = self.subscriptions.withValue { subs -> String in
                    let old = subs[key]?.1 ?? "?"
                    subs[key]?.1 = newValueStr
                    return old
                }
                self.onTrigger { "\(baseLabel): \(oldValueStr) → \(newValueStr)" }
                return nil
            case .withDiff:
                // Freeze the value under the lock so `dumpWithChildren` sees a consistent snapshot.
                // `frozenCopy` walks the model struct and sets each nested model's source to
                // `.frozenCopy`, so property accesses on the result read directly from struct
                // fields — no live context access, no child/metadata context lock acquisitions.
                // This prevents the potential deadlock where `dumpWithChildren` on a live model
                // tries to acquire a metadata context lock that another thread already holds while
                // waiting for this same context lock.
                let newFrozen: T = usingActiveAccess(nil) {
                    context.lock { frozenCopy(context.readModel[keyPath: path]) }
                }
                // `dumpWithChildren` on a frozen copy reads struct fields only — safe to call
                // while still nominally inside the onModify callback window.
                let newValueStr = dumpWithChildren(newFrozen)
                // Atomically swap old → new under the subscriptions lock (separate from context lock).
                let oldValueStr = self.subscriptions.withValue { subs -> String in
                    let old = subs[key]?.1 ?? "?"
                    subs[key]?.1 = newValueStr
                    return old
                }
                // onTrigger is called synchronously here (inside the context lock) so that
                // pendingTriggers is populated before wrappedOnUpdate reads it.
                self.onTrigger { [oldValueStr, newValueStr, baseLabel] in
                    if let diffStr = snapshotLineDiff(oldValueStr, newValueStr) {
                        // Indent the diff block under "dependency changed: label:".
                        let indented = diffStr.components(separatedBy: "\n")
                            .map { "  " + $0 }
                            .joined(separator: "\n")
                        return "\(baseLabel):\n\(indented)"
                    } else {
                        // Values appear identical after dump — fall back to just the label.
                        return baseLabel
                    }
                }
                return nil
            }
        }

        subscriptions.withValue { $0[key] = (cancellation, initialValueStr) }
        return nil
    }

}

/// Returns a human-readable property name for `path` on `model`, or nil for synthetic/subscript paths.
func debugPropertyName<M: Model, T>(from model: M, path: KeyPath<M, T>) -> String? {
    // Context/preference typed path: storageName is set in thread-locals by
    // willAccessStorage and willAccessPreferenceValue while the typed-path willAccess is running.
    if let name = threadLocals.storageName, !name.isEmpty {
        switch threadLocals.modificationArea {
        case .context:    return "context.\(name)"
        case .preference: return "preference.\(name)"
        default: break
        }
    }
    // Try WritableKeyPath via Mirror (covers @Model state properties).
    if let writablePath = path as? WritableKeyPath<M, T> {
        // Disable active access while using Mirror to avoid re-entering willAccess callbacks.
        // Also enable includeChildrenInMirror so the @Model struct's customMirror returns real
        // children (by default it returns an empty mirror to keep LLDB output clean).
        return usingActiveAccess(nil) {
            threadLocals.withValue(true, at: \.includeChildrenInMirror) {
                propertyName(from: model, path: writablePath)
            }
        }
    }
    // Synthetic paths (memoize keys, untyped environment/preference) have no mirror name.
    return nil
}

// MARK: - debugObserve helper

/// Sets up a debug observation alongside a normal `update()` observation.
///
/// The `DebugAccessCollector` (when `.triggers` is requested) is run as a **separate pass**
/// after `setupObservation` completes — mirroring the same approach memoize uses.
/// This avoids the nested-`usingActiveAccess` problem where wrapping `access` would
/// shadow `update()`'s own `AccessCollector`, preventing dependency registration.
///
/// - `setupObservation` receives the original `access` (unmodified) and a `wrappedOnUpdate`
///   that prints trigger + change output. It returns a cancel closure.
/// - After setup, `access()` is run once through `usingActiveAccess(debugCollector)` so
///   the collector registers `onModify` callbacks for trigger reporting.
///
/// Returns a cancel closure that tears down both the main observation and the debug collector.
func debugObserve<T: Sendable>(
    options: DebugOptions,
    label: String,
    rootModelID: ModelID? = nil,
    access: @Sendable @escaping () -> T,
    onUpdate: @Sendable @escaping (T) -> Void,
    setupObservation: (@Sendable @escaping () -> T, @Sendable @escaping (T) -> Void) -> @Sendable () -> Void
) -> @Sendable () -> Void {
#if DEBUG
    let printerBox = PrinterBox(options.effectivePrinter)
    let triggerFormat = options.triggerFormat
    let changeFormat = options.changeFormat

    // Collect lazy trigger closures fired by the DebugAccessCollector's onModify callbacks.
    // Using closures (rather than pre-computed strings) defers expensive work (e.g. LCS diff)
    // to wrappedOnUpdate, which runs outside the context lock.
    let pendingTriggers = LockIsolated<[@Sendable () -> String]>([])

    let debugCollector: DebugAccessCollector?
    if let fmt = triggerFormat {
        let collector = DebugAccessCollector(
            triggerFormat: fmt,
            isShallow: options.isShallow,
            rootModelID: rootModelID
        ) { lazy in
            pendingTriggers.withValue { $0.append(lazy) }
        }
        debugCollector = collector
    } else {
        debugCollector = nil
    }

    // Snapshot helper: capture the current string representation of a value.
    // We store rendered strings rather than raw `T` values because `T` may contain
    // live-context model structs whose properties always reflect the CURRENT live state.
    // Storing a rendered string captures the actual values at the moment of each update,
    // so consecutive diffs correctly reflect the change between updates.
    @Sendable func snapshot(_ v: T) -> String {
        threadLocals.withValue(true, at: \.includeChildrenInMirror) {
            String(customDumping: v)
        }
    }

    // Previous rendered snapshot for diff computation.
    let previous = LockIsolated<String?>(snapshot(access()))

    let wrappedOnUpdate: @Sendable (T) -> Void = { value in
        var lines: [String] = []

        // Trigger lines — evaluate lazy closures here, outside the context lock.
        if triggerFormat != nil {
            let triggers = pendingTriggers.withValue { ts -> [@Sendable () -> String] in
                defer { ts.removeAll() }
                return ts
            }.map { $0() }
            if !triggers.isEmpty {
                lines.append("\(label) triggered update:")
                for t in triggers {
                    lines.append("  dependency changed: \(t)")
                }
            }
        }

        // Change lines
        if let fmt = changeFormat {
            switch fmt {
            case .diff:
                let prevSnap = previous.value
                let newSnap = snapshot(value)
                previous.setValue(newSnap)
                if let prevSnap, prevSnap != newSnap {
                    if let d = snapshotLineDiff(prevSnap, newSnap) {
                        lines.append("\(label) value changed:")
                        lines.append(d)
                    }
                }
            case .value:
                previous.setValue(snapshot(value))
                lines.append("\(label) = \(String(customDumping: value))")
            }
        }

        if !lines.isEmpty {
            printerBox.write(lines.joined(separator: "\n"))
        }

        onUpdate(value)
    }

    // Pass the original `access` to setupObservation so update()'s own AccessCollector
    // can register dependencies without interference.
    let cancelObservation = setupObservation(access, wrappedOnUpdate)

    // Separately run access() through the DebugAccessCollector to register onModify
    // callbacks for trigger reporting — same pattern as memoize's debug collector pass.
    if let collector = debugCollector {
        _ = usingActiveAccess(collector) { access() }
    }

    return {
        cancelObservation()
        debugCollector?.cancelAll()
    }
#else
    return setupObservation(access, onUpdate)
#endif
}
