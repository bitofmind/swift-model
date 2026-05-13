import Foundation
import CustomDump
import Dependencies

// MARK: - snapshotLineDiff

/// Computes a line-level context diff between two multi-line snapshot strings.
/// Returns nil when the strings are equal.
///
/// Each output line is prefixed with `"  "` (unchanged context), `"- "` (removed),
/// or `"+ "` (added). Uses LCS to find the minimal set of changes, so unchanged lines
/// (e.g. a struct's other fields) appear as context rather than being fully replaced.
/// The `style` controls how much context is included around the changed lines.
func snapshotLineDiff(_ prev: String, _ next: String, style: DiffStyle = .compact) -> String? {
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

// MARK: - Value rendering helpers

/// Truncates a multi-line string to at most `maxLines` lines, appending a
/// `"… (N more line[s])"` suffix when truncated. Pluralisation matches the
/// dropped-line count so the marker reads naturally for `1` as well as `N`.
///
/// Used by `.withValue` / `.value` debug formats to bound otherwise-unbounded
/// `customDump` output. Cheap — splits and rejoins lines; no Mirror walk.
func truncateToMaxLines(_ s: String, maxLines: Int) -> String {
    guard maxLines < .max else { return s }
    let lines = s.components(separatedBy: "\n")
    guard lines.count > maxLines else { return s }
    let kept = lines.prefix(maxLines).joined(separator: "\n")
    let dropped = lines.count - maxLines
    let plural = dropped == 1 ? "line" : "lines"
    return "\(kept)\n… (\(dropped) more \(plural))"
}

/// Renders `value` via `customDump(..., maxDepth:)` and post-truncates the
/// resulting string to `maxLines`. Used by the `.withValue` and `.value` debug
/// formats — see `TriggerFormat.withValue` / `ChangeFormat.value` for the
/// rationale on the two knobs.
func dumpForDebug<T>(_ value: T, maxLines: Int, maxDepth: Int) -> String {
    var out = ""
    customDump(value, to: &out, maxDepth: maxDepth)
    return truncateToMaxLines(out, maxLines: maxLines)
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
    let debugAccessObserver = options.accessObserver
    let debugPrinterBox = PrinterBox(options.effectivePrinter)
    // Store lazy closures so that expensive operations (e.g. LCS diff) run in debugPrint,
    // outside the context lock, rather than blocking it during the onModify callback.
    let debugPendingTriggers = LockIsolated<[@Sendable () -> String]>([])
    let collectorBox = LockIsolated<DebugAccessCollector?>(nil)

    // The collector is needed whenever debug needs to observe accesses — either to
    // register trigger callbacks, fire the user's `accessObserver`, or capture
    // access stacks for trigger-time emission.
    let wantsStackCapture = (options.captureAccessStack ?? 0) > 0
    if debugTriggerFormat != nil || debugAccessObserver != nil || wantsStackCapture {
        let collector = DebugAccessCollector(
            triggerFormat: debugTriggerFormat,
            isShallow: options.isShallow,
            accessObserver: debugAccessObserver,
            captureAccessStack: options.captureAccessStack
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
            case .value(let maxLines, let maxDepth):
                lines.append("\(label) = \(dumpForDebug(value, maxLines: maxLines, maxDepth: maxDepth))")
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
    /// lock — so that expensive operations (e.g. LCS diff, stack symbolication) don't block
    /// other threads.
    let onTrigger: @Sendable (@Sendable @escaping () -> String) -> Void

    /// One entry per live subscription keyed by `(modelID, path)`.
    /// - `cancellation`: cancels the `onModify` registration.
    /// - `lastValueStr`: last-seen rendered value for `.withValue` / `.withDiff`. `nil` for `.name`.
    /// - `accessStack`: raw return-address stack captured at first-access when
    ///   `captureAccessStack > 0`; symbolicated lazily on trigger emission. Empty otherwise.
    struct Subscription: Sendable {
        var cancellation: @Sendable () -> Void
        var lastValueStr: String?
        /// Raw return addresses stored as bit-pattern `UInt`s so the stack is
        /// trivially `Sendable` for capture in `@Sendable` `onTrigger` closures.
        var accessStack: [UInt]
    }
    let subscriptions = LockIsolated<[Key: Subscription]>([:])

    /// `nil` when the collector is installed solely to fire `accessObserver` — in that
    /// case no `onModify` callbacks are registered and `onTrigger` is never called.
    let triggerFormat: TriggerFormat?
    let isShallow: Bool
    /// When `isShallow` is true and this is non-nil, only properties on the root model
    /// (the one whose ID matches) are registered as trigger dependencies. Properties on
    /// child models are ignored so their changes don't produce trigger output.
    let rootModelID: ModelID?
    /// Optional read-side hook. Fired on every `willAccess` (before the dedup check),
    /// so observer implementations can rate-limit or filter as they choose.
    let accessObserver: (any AccessObserver)?
    /// When non-nil and `> 0`, captures the call stack at first-registration for each
    /// tracked path and appends a `\n  read from: …` block to the trigger emission for
    /// that path. Cheap at capture time (raw addresses); symbolication runs lazily in
    /// each fired path's `onTrigger` closure.
    let captureAccessStack: Int?

    init(
        triggerFormat: TriggerFormat?,
        isShallow: Bool = false,
        rootModelID: ModelID? = nil,
        accessObserver: (any AccessObserver)? = nil,
        captureAccessStack: Int? = nil,
        onTrigger: @Sendable @escaping (@Sendable @escaping () -> String) -> Void
    ) {
        self.triggerFormat = triggerFormat
        self.isShallow = isShallow
        self.rootModelID = rootModelID
        self.accessObserver = accessObserver
        self.captureAccessStack = captureAccessStack
        self.onTrigger = onTrigger
        super.init(useWeakReference: false)
    }

    deinit {
        cancelAll()
    }

    func cancelAll() {
        let cancels = subscriptions.withValue { subs -> [@Sendable () -> Void] in
            let cs = subs.values.map(\.cancellation)
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

        // Fire the user's `accessObserver` on every read. It runs outside our subscription
        // lock so observers may freely perform expensive work (stack capture, breakpoint
        // trap). `FirstAccessObserver` does its own per-key dedup, so spammy hot-path
        // properties don't flood the hook.
        if let accessObserver {
            let modelType = String(describing: M.self)
            let propName = debugPropertyName(
                from: context._modelSeed,
                path: M._modelStateKeyPath.appending(path: path)
            ) ?? ""
            accessObserver.observeAccess(modelType: modelType, path: propName)
        }

        // If we're only here to fire `accessObserver` (no trigger output requested), stop.
        guard let triggerFormat else { return nil }

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
        case .withValue(let maxLines, let maxDepth):
            if needsPrecomputedValue {
                initialValueStr = nil
                returnClosure = { [weak self] in
                    guard let self else { return }
                    let precomputed: Any? = isPreferencePath
                        ? threadLocals.precomputedPreferenceValue
                        : threadLocals.precomputedStorageValue
                    if let val = precomputed as? T {
                        let str = usingActiveAccess(nil) { dumpForDebug(val, maxLines: maxLines, maxDepth: maxDepth) }
                        self.subscriptions.withValue { $0[key]?.lastValueStr = str }
                    }
                }
            } else {
                // usingActiveAccess(nil) suppresses the DebugAccessCollector during the keypath read.
                // _modelSeed uses .live source; state property reads go directly to _stateHolder.
                initialValueStr = usingActiveAccess(nil) {
                    dumpForDebug(context._modelSeed[keyPath: M._modelStateKeyPath][keyPath: path],
                                 maxLines: maxLines, maxDepth: maxDepth)
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
                        self.subscriptions.withValue { $0[key]?.lastValueStr = str }
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

        // Snapshot the call stack at first registration when configured. Cheap —
        // raw return addresses only (as `UInt` bit patterns), symbolicated lazily
        // inside the per-trigger closures below so the cost is only paid for paths
        // that actually fire.
        //
        // `Thread.callStackReturnAddresses` is unavailable on WASI (no threading
        // model, Thread isn't part of swift-foundation's WASI slice). Falls back
        // to an empty stack on that platform — the trigger line simply omits its
        // `read from:` suffix there, matching the symbolication fallback in
        // `AccessObserver.symbolicateAccessStack`.
        let accessStack: [UInt]
#if !os(WASI)
        if let depth = captureAccessStack, depth > 0 {
            accessStack = Thread.callStackReturnAddresses
                .prefix(depth)
                .map { $0.uintValue }
        } else {
            accessStack = []
        }
#else
        accessStack = []
#endif

        let cancellation = context.onModify(for: path) { [weak self] finished, _ in
            guard !finished, let self else { return {} }

            // Resolve the captured access stack for this path under the subscriptions
            // lock. Symbolication happens lazily inside the `onTrigger` closure (outside
            // any swift-model lock), so `wrappedOnUpdate` pays the cost only for paths
            // that fire — and only the first time a given (path, image) pair is dumped.
            let stackForPath: [UInt] = self.subscriptions.withValue {
                $0[key]?.accessStack ?? []
            }

            switch fmt {
            case .name:
                // Lazy closure: trivial, just returns the pre-computed label plus
                // the access-stack suffix (empty when capture isn't configured).
                self.onTrigger { baseLabel + collectorAccessStackSuffix(stackForPath) }
                return nil
            case .withValue(let maxLines, let maxDepth):
                // For storage/preference paths, read new value from precomputed thread-locals
                // (set by Context.didModifyStorage/didModifyPreference for post-lock callbacks).
                // For regular paths, read directly via keypath.
                let newValueStr: String
                if needsPrecomputedValue {
                    let precomputed: Any? = isPreferencePath
                        ? threadLocals.precomputedPreferenceValue
                        : threadLocals.precomputedStorageValue
                    newValueStr = (precomputed as? T).map { val in
                        usingActiveAccess(nil) { dumpForDebug(val, maxLines: maxLines, maxDepth: maxDepth) }
                    } ?? "?"
                } else {
                    newValueStr = usingActiveAccess(nil) {
                        dumpForDebug(context._modelSeed[keyPath: M._modelStateKeyPath][keyPath: path],
                                     maxLines: maxLines, maxDepth: maxDepth)
                    }
                }
                // Atomically swap the stored value for old→new reporting.
                let oldValueStr = self.subscriptions.withValue { subs -> String in
                    let old = subs[key]?.lastValueStr ?? "?"
                    subs[key]?.lastValueStr = newValueStr
                    return old
                }
                self.onTrigger {
                    "\(baseLabel): \(oldValueStr) → \(newValueStr)" + collectorAccessStackSuffix(stackForPath)
                }
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
                    let old = subs[key]?.lastValueStr ?? "?"
                    subs[key]?.lastValueStr = newValueStr
                    return old
                }
                // onTrigger is called synchronously here (inside the context lock) so that
                // pendingTriggers is populated before wrappedOnUpdate reads it.
                self.onTrigger { [oldValueStr, newValueStr, baseLabel, style] in
                    let body: String
                    if let diffStr = snapshotLineDiff(oldValueStr, newValueStr, style: style) {
                        // Indent the diff block under "dependency changed: label:".
                        let indented = diffStr.components(separatedBy: "\n")
                            .map { "  " + $0 }
                            .joined(separator: "\n")
                        body = "\(baseLabel):\n\(indented)"
                    } else {
                        // Values appear identical after dump — fall back to just the label.
                        body = baseLabel
                    }
                    return body + collectorAccessStackSuffix(stackForPath)
                }
                return nil
            }
        }

        subscriptions.withValue {
            $0[key] = Subscription(
                cancellation: cancellation,
                lastValueStr: initialValueStr,
                accessStack: accessStack
            )
        }
        return returnClosure
    }

}

/// `"\n  read from:\n    <frame>\n    <frame>…"` suffix when `addrs` is non-empty,
/// otherwise `""`. Symbolication is deferred to this helper so it runs lazily inside
/// `onTrigger` closures (outside the context lock); the leading swift-model-internal
/// frames are trimmed so the first visible frame is the user-code line that
/// performed the read.
@Sendable
private func collectorAccessStackSuffix(_ addrs: [UInt]) -> String {
    guard !addrs.isEmpty else { return "" }
    let frames = trimSwiftModelInternalFrames(symbolicateAccessStack(addrs))
    guard !frames.isEmpty else { return "" }
    return "\n  read from:\n    " + frames.joined(separator: "\n    ")
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
    let accessObserver = options.accessObserver

    // Collect lazy trigger closures fired by the DebugAccessCollector's onModify callbacks.
    // Using closures (rather than pre-computed strings) defers expensive work (e.g. LCS diff)
    // to wrappedOnUpdate, which runs outside the context lock.
    let pendingTriggers = LockIsolated<[@Sendable () -> String]>([])

    // The collector is needed whenever debug needs to observe accesses — for trigger
    // registration, to fire the user's `accessObserver`, or to capture access stacks
    // that get appended to trigger emissions.
    let wantsStackCapture = (options.captureAccessStack ?? 0) > 0
    let debugCollector: DebugAccessCollector?
    if triggerFormat != nil || accessObserver != nil || wantsStackCapture {
        let collector = DebugAccessCollector(
            triggerFormat: triggerFormat,
            isShallow: options.isShallow,
            rootModelID: rootModelID,
            accessObserver: accessObserver,
            captureAccessStack: options.captureAccessStack
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
            case .value(let maxLines, let maxDepth):
                previous.setValue(snapshot(value))
                lines.append("\(label) = \(dumpForDebug(value, maxLines: maxLines, maxDepth: maxDepth))")
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
