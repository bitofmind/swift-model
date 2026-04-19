import Foundation
import CustomDump
import Dependencies

// MARK: - Debug options

/// Controls what a `node.debug`, `memoize(debug:)`, or `Observed(debug:)` call prints.
///
/// Use `.all` for the common case (both trigger and change output), or the static
/// factory methods to enable only one kind of output:
///
/// ```swift
/// node.debug()                                    // triggers + changes (default)
/// node.debug(.triggers(.withValue))               // just triggers with old → new values
/// node.debug(.init(name: "App"))                  // all output with a custom label
///
/// memoize(debug: .all) { ... }                    // on with defaults
/// memoize(debug: .init(name: "sorted")) { ... }   // on with a custom label
/// memoize { ... }                                 // no debug (nil = disabled)
/// ```
public struct DebugOptions: Sendable {
    /// How (or whether) to report which dependencies triggered an update.
    var triggers: TriggerFormat?

    /// How (or whether) to report the observed/memoized value when it changes.
    var changes: ChangeFormat?

    /// When `true`, child model properties are not tracked as dependencies.
    var isShallow: Bool

    /// Label used in debug output. Defaults to the model's type name when `nil`.
    var name: String?

    /// Output destination. Defaults to `print()` when `nil`.
    var printer: (any TextOutputStream & Sendable)?

    /// Creates a `DebugOptions` value.
    ///
    /// All parameters have sensible defaults so calling `.init()` produces full output —
    /// triggers with `.name` format and changes with `.diff()` format.
    ///
    /// - Parameters:
    ///   - triggers: How to format trigger output; `nil` suppresses trigger lines.
    ///   - changes: How to format change output; `nil` suppresses change lines.
    ///   - isShallow: When `true`, child model properties are not tracked as dependencies.
    ///   - name: Custom label. Defaults to the model's type name when `nil`.
    ///   - printer: Custom output stream. Defaults to `print()` when `nil`.
    public init(
        triggers: TriggerFormat? = .name,
        changes: ChangeFormat? = .diff(),
        isShallow: Bool = false,
        name: String? = nil,
        printer: (any TextOutputStream & Sendable)? = nil
    ) {
        self.triggers = triggers
        self.changes = changes
        self.isShallow = isShallow
        self.name = name
        self.printer = printer
    }

    // MARK: - Shorthands

    /// Enables all output: triggers with `.name` format and changes with `.diff()` format.
    ///
    /// Equivalent to `DebugOptions()`.
    public static let all = Self()

    /// Enables trigger output only, with the specified format.
    ///
    /// ```swift
    /// node.debug(.triggers())              // triggers with .name format (default)
    /// node.debug(.triggers(.withValue))    // triggers showing old → new value
    /// node.debug(.triggers(.withDiff))     // triggers with a structured diff
    /// ```
    public static func triggers(_ format: TriggerFormat = .name) -> Self {
        .init(triggers: format, changes: nil)
    }

    /// Enables change output only, with the specified format.
    ///
    /// ```swift
    /// node.debug(.changes())               // diff format (default)
    /// node.debug(.changes(.value))         // new value only
    /// node.debug(.changes(.diff(.full)))   // full diff with all context
    /// ```
    public static func changes(_ format: ChangeFormat = .diff()) -> Self {
        .init(triggers: nil, changes: format)
    }

    var effectivePrinter: any TextOutputStream & Sendable {
        printer ?? PrintTextOutputStream()
    }
}

/// Controls how a diff is displayed when comparing old and new values.
public enum DiffStyle: Sendable {
    /// Show only changed lines and their structural ancestors (default).
    case compact

    /// Like `compact`, but replaces each omitted run with `… (N unchanged)`.
    case collapsed

    /// Show all context lines — the complete before/after representation.
    case full
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
    case withDiff(DiffStyle = .compact)
}

public extension TriggerFormat {
    /// Shorthand for `.withDiff()` — uses the default `.compact` diff style.
    static var withDiff: Self { .withDiff() }
}

/// Controls how the updated observed/memoized value is displayed in `.changes` output.
public enum ChangeFormat: Sendable {
    /// Show a `−`/`+` diff between the old and new value.
    case diff(DiffStyle = .compact)

    /// Show only the new value via `customDump`.
    case value
}

public extension ChangeFormat {
    /// Shorthand for `.diff()` — uses the default `.compact` diff style.
    static var diff: Self { .diff() }
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
        let p: (any TextOutputStream & Sendable)? = (printer is PrintTextOutputStream) ? nil : printer
        return debug(.init(triggers: nil, name: name, printer: p))
    }

    // MARK: - debug

    /// Observes this model's entire state tree and prints debug information whenever anything changes.
    ///
    /// The no-closure form observes `self` — all stored properties are tracked as dependencies.
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.debug()                                    // triggers + diff output (default)
    ///     node.debug(.changes(.value))                   // print new value instead of diff
    ///     node.debug(.init(name: "MyModel"))             // custom label
    ///     node.debug(.triggers(.withValue))              // just show which properties changed
    /// }
    /// ```
    ///
    /// To track which specific properties triggered an update in a sub-expression,
    /// use the closure form: `node.debug(.triggers()) { expression }`
    ///
    /// Only active in `DEBUG` builds. Returns a `Cancellable` you can cancel early.
    @discardableResult
    func debug(_ options: DebugOptions = .all) -> Cancellable {
#if DEBUG
        guard let context = enforcedContext() else { return EmptyCancellable() }
        let label = options.name ?? typeDescription
        let printerBox = PrinterBox(options.effectivePrinter)
        let changeFormat = options.changes

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
        previous.setValue(snapshot(context._modelSeed))

        let cancel = context.onAnyModification { [weak context] didFinish in
            guard !didFinish, let context else { return nil }
            if let fmt = changeFormat {
                let value = context._modelSeed
                switch fmt {
                case .diff(let style):
                    let prevSnap = previous.value
                    let newSnap = snapshot(value)
                    previous.setValue(newSnap)
                    if let prevSnap, prevSnap != newSnap,
                       let d = snapshotLineDiff(prevSnap, newSnap, style: style) {
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
    ///     node.debug(.all) { (count, filter) }
    ///
    ///     // Watch a memoized result with a custom label
    ///     node.debug(.init(name: "sortedItems")) { sortedItems }
    /// }
    /// ```
    ///
    /// Only active in `DEBUG` builds.
    @discardableResult
    func debug<T: Sendable>(_ options: DebugOptions = .all, _ access: @Sendable @escaping () -> T) -> Cancellable {
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
/// The `style` controls how much context is included around the changed lines.
private func snapshotLineDiff(_ prev: String, _ next: String, style: DiffStyle = .compact) -> String? {
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

    let rawDiff = edits.reversed().map { edit -> String in
        switch edit {
        case .context(let line): return "  \(line)"
        case .remove(let line):  return "- \(line)"
        case .add(let line):     return "+ \(line)"
        }
    }.joined(separator: "\n")

    switch style {
    case .compact:   return compactLineDiff(rawDiff)
    case .collapsed: return collapsedLineDiff(rawDiff)
    case .full:      return rawDiff
    }
}

// MARK: - Diff line helpers

/// Parsed representation of a single line in a raw `"  "/"- "/"+ "` diff.
private struct ParsedDiffLine {
    enum Kind { case context, remove, add }
    let kind: Kind
    let indent: Int     // leading-space count of the content (after stripping the 2-char prefix)
    let content: String // content after stripping the 2-char prefix
    let raw: String     // original line including the prefix

    init(_ raw: String) {
        let c: Substring
        if raw.hasPrefix("- ")      { kind = .remove;  c = raw.dropFirst(2) }
        else if raw.hasPrefix("+ ") { kind = .add;     c = raw.dropFirst(2) }
        else                        { kind = .context; c = raw.dropFirst(2) }
        indent = c.prefix(while: { $0 == " " }).count
        content = String(c)
        self.raw = raw
    }
}

private func parseDiffLines(_ rawDiff: String) -> [ParsedDiffLine] {
    rawDiff.components(separatedBy: "\n").map { ParsedDiffLine($0) }
}

/// Returns a boolean mask indicating which context lines are structural ancestors of at
/// least one changed (+/−) line. Changed lines are always marked `true`.
///
/// A context line at indentation `I` is an ancestor of changed line C when:
///   - `C.indent > I` (C is deeper / inside the block opened by L), **and**
///   - no other context line at indent ≤ `I` sits strictly between L and C
///     (which would mean they are in separate scopes).
///
/// This correctly keeps every opener/closer on the path from the root to a change,
/// while discarding siblings and fully-unchanged sub-trees.
private func ancestorKeepMask(_ lines: [ParsedDiffLine]) -> [Bool] {
    let n = lines.count
    let changedIndices = (0..<n).filter { lines[$0].kind != .context }
    var keep = [Bool](repeating: true, count: n)
    guard !changedIndices.isEmpty else { return keep }

    for i in 0..<n where lines[i].kind == .context {
        let I = lines[i].indent
        var isAncestor = false
        for c in changedIndices {
            guard lines[c].indent > I else { continue }
            let range = i < c ? (i + 1)..<c : (c + 1)..<i
            let blocked = range.contains { j in
                lines[j].kind == .context && lines[j].indent <= I
            }
            if !blocked { isAncestor = true; break }
        }
        keep[i] = isAncestor
    }
    return keep
}

/// Post-processes a raw diff to show only changed lines and their structural ancestors.
private func compactLineDiff(_ rawDiff: String) -> String {
    let lines = parseDiffLines(rawDiff)
    let changedIndices = (0..<lines.count).filter { lines[$0].kind != .context }
    guard !changedIndices.isEmpty else { return rawDiff }
    let keep = ancestorKeepMask(lines)
    return (0..<lines.count).filter { keep[$0] }.map { lines[$0].raw }.joined(separator: "\n")
}

/// Post-processes a raw diff like `compactLineDiff`, but replaces each contiguous run of
/// discarded context lines with a single `… (N unchanged)` summary line.
///
/// `N` is the count of non-closing-bracket lines at the minimum indentation of the run,
/// which approximates the number of sibling entries (properties or collection elements) omitted.
private func collapsedLineDiff(_ rawDiff: String) -> String {
    let lines = parseDiffLines(rawDiff)
    let changedIndices = (0..<lines.count).filter { lines[$0].kind != .context }
    guard !changedIndices.isEmpty else { return rawDiff }
    let keep = ancestorKeepMask(lines)

    var result: [String] = []
    var i = 0
    while i < lines.count {
        if keep[i] || lines[i].kind != .context {
            result.append(lines[i].raw)
            i += 1
        } else {
            // Collect a contiguous run of discarded context lines.
            let runStart = i
            while i < lines.count && !keep[i] && lines[i].kind == .context { i += 1 }
            let run = runStart..<i

            // Find the minimum content-indentation in the run.
            let minIndent = run.map { lines[$0].indent }.min()!

            // Count non-closing lines at that minimum indent (each represents one sibling).
            let count = run.filter { j in
                guard lines[j].indent == minIndent else { return false }
                let trimmed = lines[j].content.drop(while: { $0 == " " })
                return !trimmed.hasPrefix(")") && !trimmed.hasPrefix("]") && !trimmed.hasPrefix("}")
            }.count

            if count > 0 {
                result.append("  \(String(repeating: " ", count: minIndent))… (\(count) unchanged)")
            }
        }
    }
    return result.joined(separator: "\n")
}

// MARK: - memoizeDebugSetup

/// Sets up debug observation for a `memoize` call.
/// Returns nil values for all three when `options` is nil (zero cost path).
///
/// - Parameters:
///   - options: The `DebugOptions` passed to `memoize(debug:)`, or nil to disable.
///   - label: The human-readable label used in printed output.
/// - Returns: A tuple of:
///   - `debugPrint`: Closure to call after each memoize update with `(newValue, previousValue)`.
///   - `debugPreviousValue`: Shared state tracking the previous value for diff computation.
///   - `debugCollectorBox`: Box holding the `DebugAccessCollector`; run `produce()` through
///     `usingActiveAccess(collectorBox.value)` after first `update()` to register trigger callbacks.
func memoizeDebugSetup<T: Sendable>(
    options: DebugOptions?,
    label: String
) -> (
    debugPrint: (@Sendable (T, T?) -> Void)?,
    debugPreviousValue: LockIsolated<T?>?,
    debugCollectorBox: LockIsolated<DebugAccessCollector?>?
) {
    guard let options else {
        return (nil, nil, nil)
    }

    let debugTriggerFormat = options.triggers
    let debugChangeFormat = options.changes
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
            case .diff(let style):
                if let prev = previous, var d = diff(prev, value) {
                    switch style {
                    case .compact:   d = compactLineDiff(d)
                    case .collapsed: d = collapsedLineDiff(d)
                    case .full:      break
                    }
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

    override func willAccess<M: Model, T>(from context: Context<M>, at path: KeyPath<M._ModelState, T> & Sendable) -> (() -> Void)? {
        // In shallow mode, only track properties on the root model — skip child models.
        // `usingActiveAccess` installs this collector globally so `willAccess` fires for
        // every model; we filter here rather than relying on `shouldPropagateToChildren`.
        if isShallow, let rootModelID, context.anyModelID != rootModelID { return nil }

        let key = Key(id: context.anyModelID, path: path)

        // Only subscribe once per (model, path) pair.
        let alreadySubscribed = subscriptions.withValue { $0[key] != nil }
        guard !alreadySubscribed else { return nil }

        // Skip non-writable synthetic paths (untyped \M._ModelState[environmentKey:] etc.).
        // These fire alongside typed WritableKeyPath companions but have no working post-lock
        // callbacks — only the typed path's buildPostLockCallbacks fires. Registering them
        // produces dead subscriptions that waste memory without ever triggering output.
        guard path is WritableKeyPath<M._ModelState, T> else { return nil }

        // Detect context-storage and preference paths. Their _metadata/_preference getter stubs
        // call fatalError() — reading through the keypath is not safe. Instead we use the
        // precomputed values that Context passes via thread-locals:
        //   • willAccessStorage sets precomputedStorageValue for the returned closure.
        //   • didModifyStorage sets precomputedStorageValue for runPostLockCallbacks.
        //   • willAccessPreferenceValue sets precomputedPreferenceValue for the returned closure.
        //   • didModifyPreference sets precomputedPreferenceValue for runPostLockCallbacks.
        // modificationArea is set by those call sites while this willAccess invocation is running.
        // Use .contains() rather than == to avoid the custom == operator in ModelTester.swift
        // that overloads == for any Equatable&Sendable type to return TestPredicate.
        let isPreferencePath: Bool = threadLocals.modificationArea?.contains(.preference) ?? false
        let isStoragePath: Bool = !isPreferencePath &&
            (threadLocals.modificationArea?.contains(.local) ?? false ||
             threadLocals.modificationArea?.contains(.environment) ?? false)
        let needsPrecomputedValue: Bool = isStoragePath || isPreferencePath

        let modelType = String(describing: M.self)
        let propName = debugPropertyName(from: context._modelSeed, path: M._modelStateKeyPath.appending(path: path))
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

        // For storage/preference paths the initial value is unavailable at willAccess call time —
        // precomputedStorageValue/precomputedPreferenceValue are only set for the returned closure.
        // We return a non-nil closure that reads the precomputed value and updates the subscription.
        // For regular paths we read directly via keypath and return nil.
        let initialValueStr: String?
        let returnClosure: (() -> Void)?

        switch fmt {
        case .withValue:
            if needsPrecomputedValue {
                initialValueStr = nil
                returnClosure = { [weak self] in
                    guard let self else { return }
                    let precomputed: Any? = isPreferencePath
                        ? threadLocals.precomputedPreferenceValue
                        : threadLocals.precomputedStorageValue
                    if let val = precomputed as? T {
                        let str = usingActiveAccess(nil) { String(customDumping: val) }
                        self.subscriptions.withValue { $0[key]?.1 = str }
                    }
                }
            } else {
                // usingActiveAccess(nil) suppresses the DebugAccessCollector during the keypath read.
                // _modelSeed uses .live source; state property reads go directly to _stateHolder.
                initialValueStr = usingActiveAccess(nil) {
                    String(customDumping: context._modelSeed[keyPath: M._modelStateKeyPath][keyPath: path])
                }
                returnClosure = nil
            }
        case .withDiff(_):
            if needsPrecomputedValue {
                initialValueStr = nil
                returnClosure = { [weak self] in
                    guard let self else { return }
                    let precomputed: Any? = isPreferencePath
                        ? threadLocals.precomputedPreferenceValue
                        : threadLocals.precomputedStorageValue
                    if let val = precomputed as? T {
                        let frozen: T = usingActiveAccess(nil) { frozenCopy(val) }
                        let str = dumpWithChildren(frozen)
                        self.subscriptions.withValue { $0[key]?.1 = str }
                    }
                }
            } else {
                // Same re-entry guard as .withValue: suppress active access while reading the keypath.
                // frozenCopy prevents child/metadata lock deadlocks during the subsequent dumpWithChildren.
                let initialFrozen: T = usingActiveAccess(nil) {
                    frozenCopy(context._modelSeed[keyPath: M._modelStateKeyPath][keyPath: path])
                }
                initialValueStr = dumpWithChildren(initialFrozen)
                returnClosure = nil
            }
        case .name:
            initialValueStr = nil
            returnClosure = nil
        }

        let cancellation = context.onModify(for: path) { [weak self] finished, _ in
            guard !finished, let self else { return {} }

            switch fmt {
            case .name:
                // Lazy closure: trivial, just returns the pre-computed label.
                self.onTrigger { baseLabel }
                return nil
            case .withValue:
                // For storage/preference paths, read new value from precomputed thread-locals
                // (set by Context.didModifyStorage/didModifyPreference for post-lock callbacks).
                // For regular paths, read directly via keypath.
                let newValueStr: String
                if needsPrecomputedValue {
                    let precomputed: Any? = isPreferencePath
                        ? threadLocals.precomputedPreferenceValue
                        : threadLocals.precomputedStorageValue
                    newValueStr = (precomputed as? T).map { val in
                        usingActiveAccess(nil) { String(customDumping: val) }
                    } ?? "?"
                } else {
                    newValueStr = usingActiveAccess(nil) {
                        String(customDumping: context._modelSeed[keyPath: M._modelStateKeyPath][keyPath: path])
                    }
                }
                // Atomically swap the stored value for old→new reporting.
                let oldValueStr = self.subscriptions.withValue { subs -> String in
                    let old = subs[key]?.1 ?? "?"
                    subs[key]?.1 = newValueStr
                    return old
                }
                self.onTrigger { "\(baseLabel): \(oldValueStr) → \(newValueStr)" }
                return nil
            case .withDiff(let style):
                // Freeze the value under the lock so `dumpWithChildren` sees a consistent snapshot.
                // `frozenCopy` walks the model struct and sets each nested model's source to
                // `.frozenCopy`, so property accesses on the result read directly from struct
                // fields — no live context access, no child/metadata context lock acquisitions.
                // This prevents the potential deadlock where `dumpWithChildren` on a live model
                // tries to acquire a metadata context lock that another thread already holds while
                // waiting for this same context lock.
                let newFrozen: T
                if needsPrecomputedValue {
                    let precomputed: Any? = isPreferencePath
                        ? threadLocals.precomputedPreferenceValue
                        : threadLocals.precomputedStorageValue
                    guard let val = precomputed as? T else { return nil }
                    newFrozen = usingActiveAccess(nil) { frozenCopy(val) }
                } else {
                    newFrozen = usingActiveAccess(nil) {
                        frozenCopy(context._modelSeed[keyPath: M._modelStateKeyPath][keyPath: path])
                    }
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
                self.onTrigger { [oldValueStr, newValueStr, baseLabel, style] in
                    if let diffStr = snapshotLineDiff(oldValueStr, newValueStr, style: style) {
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
        return returnClosure
    }

}

/// Returns a human-readable property name for `path` on `model`, or nil for synthetic/subscript paths.
func debugPropertyName<M: Model, T>(from model: M, path: KeyPath<M, T>) -> String? {
    // Context/preference typed path: storageName is set in thread-locals by
    // willAccessStorage and willAccessPreferenceValue while the typed-path willAccess is running.
    if let name = threadLocals.storageName, !name.isEmpty {
        switch threadLocals.modificationArea {
        case .local:       return "local.\(name)"
        case .environment: return "environment.\(name)"
        case .preference:  return "preference.\(name)"
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
    let triggerFormat = options.triggers
    let changeFormat = options.changes

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
            case .diff(let style):
                let prevSnap = previous.value
                let newSnap = snapshot(value)
                previous.setValue(newSnap)
                if let prevSnap, prevSnap != newSnap {
                    if let d = snapshotLineDiff(prevSnap, newSnap, style: style) {
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
