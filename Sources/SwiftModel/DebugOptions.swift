import Foundation

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

    /// Optional observer fired on each property access while debug is active.
    /// Use for custom telemetry on access patterns, or `.firstAccessBreakpoint()`
    /// to drop into LLDB at the moment a read registers. For the more common
    /// "which read caused this trigger?" question, prefer ``captureAccessStack``,
    /// which captures at access time but only emits when the property fires.
    /// Ignored on debug entry points that observe mutations rather than reads.
    var accessObserver: (any AccessObserver)?

    /// Capture a call stack at `willAccess` registration for each tracked path
    /// and append it to the trigger emission for that path. Set to the number
    /// of frames to keep (e.g. `15`); `nil` (default) skips capture entirely.
    ///
    /// Unlike `accessObserver`, this is **silent for paths that are read but
    /// never fire** — the stack is captured cheaply at access time (raw return
    /// addresses, no symbolication), held alongside the access registration,
    /// and symbolicated lazily inside the trigger emission only for paths that
    /// actually invalidate the view. The result is one self-contained log
    /// entry per real re-render that names the model, property, old/new value,
    /// *and* the body that read it — instead of stack dumps for every
    /// property a complex view happens to touch.
    ///
    /// Costs in DEBUG only: at access time, one `Thread.callStackReturnAddresses`
    /// call (≈ tens of µs for ~30 frames) plus per-path storage of an
    /// `[UnsafeRawPointer?]`. At trigger time, one `backtrace_symbols` call per
    /// fired path. Free when this field is `nil`. No effect outside `DEBUG`.
    ///
    /// Honoured by every debug entry point that has a `willAccess` hook to capture
    /// from: `$model.debug(_:)` (`@ObservedModel`), `ModelScope(debug:)`,
    /// `Observed(debug:)`, `memoize(debug:)`, and `node.debug(_:_:)` (the closure
    /// form). Ignored on `node.debug(_:)` (no-closure form) and
    /// `observeModifications(debug:)`, which observe mutations rather than reads
    /// and have no `willAccess` to attach to.
    var captureAccessStack: Int?

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
    ///   - accessObserver: Optional read-side hook. See ``AccessObserver``.
    ///   - captureAccessStack: Optional frame count for capturing the body's
    ///     call stack at access time and stitching it onto fired trigger lines.
    ///     See the field docs for details.
    public init(
        triggers: TriggerFormat? = .name,
        changes: ChangeFormat? = .diff(),
        isShallow: Bool = false,
        name: String? = nil,
        printer: (any TextOutputStream & Sendable)? = nil,
        accessObserver: (any AccessObserver)? = nil,
        captureAccessStack: Int? = nil
    ) {
        self.triggers = triggers
        self.changes = changes
        self.isShallow = isShallow
        self.name = name
        self.printer = printer
        self.accessObserver = accessObserver
        self.captureAccessStack = captureAccessStack
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

    /// Returns a copy with `name` set to `defaultName` if and only if the receiver
    /// has no `name` set. Every other field — including `accessObserver` and
    /// `captureAccessStack` — is preserved.
    ///
    /// Used by the view-side `$model.debug(_:)` and `ModelScope(debug:)` auto-label
    /// machinery. The previous "rebuild the struct field-by-field" approach silently
    /// dropped any newly-added field that wasn't enumerated in the rebuild — this
    /// helper is the single point of truth, so adding a new `DebugOptions` field
    /// requires no follow-up edits in the view-side callers.
    func withDefaultName(_ defaultName: @autoclosure () -> String) -> DebugOptions {
        guard name == nil else { return self }
        var copy = self
        copy.name = defaultName()
        return copy
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
    ///
    /// `maxLines` caps the rendered dump of each side at the given line count, appending
    /// `"… (N more line[s])"` when truncated. The default of `20` protects logs from
    /// blowing up on large value types (e.g. timeline structs with hundreds of nested
    /// entries). Pass `Int.max` to disable line truncation.
    ///
    /// `maxDepth` is passed through to `customDump` — when set below `.max` the Mirror
    /// walk short-circuits at the given depth and emits `…` for nested values beyond it.
    /// This is the real CPU-saving knob for deep types; line truncation alone doesn't
    /// avoid the underlying reflection cost. The default of `4` is symmetric with
    /// `maxLines: 20` — both are bounded safety nets, opt out with `Int.max` if you
    /// want the unbounded form. For typical `@Model` graphs, depth `4` shows the
    /// model's top fields (`depth 1`), its nested child structs / array elements
    /// (`depth 2-3`), and their leaf fields (`depth 4`) — enough signal to see
    /// what changed without walking the entire tree.
    case withValue(maxLines: Int = 20, maxDepth: Int = 4)

    /// Print a `−`/`+` diff of the dependency value with all model sub-properties expanded.
    ///
    /// Especially useful when the dependency is itself a model — this reveals exactly which
    /// nested property changed, rather than showing opaque `TypeName() → TypeName()`.
    case withDiff(DiffStyle = .compact)
}

public extension TriggerFormat {
    /// Shorthand for `.withValue()` — uses the defaults `maxLines: 20`, `maxDepth: 4`.
    static var withValue: Self { .withValue() }
    /// Shorthand for `.withDiff()` — uses the default `.compact` diff style.
    static var withDiff: Self { .withDiff() }
}

/// Controls how the updated observed/memoized value is displayed in `.changes` output.
public enum ChangeFormat: Sendable {
    /// Show a `−`/`+` diff between the old and new value.
    case diff(DiffStyle = .compact)

    /// Show only the new value via `customDump`.
    ///
    /// `maxLines` caps the rendered dump at the given line count, appending
    /// `"… (N more line[s])"` when truncated. The default of `20` protects logs from
    /// blowing up on large value types. Pass `Int.max` to disable line truncation.
    ///
    /// `maxDepth` is passed through to `customDump`; at depths beyond it the Mirror walk
    /// short-circuits and emits `…`. This is the real CPU-saving knob. The default of
    /// `4` is symmetric with `maxLines: 20` — both are bounded safety nets. Pass
    /// `Int.max` for the unbounded form.
    case value(maxLines: Int = 20, maxDepth: Int = 4)
}

public extension ChangeFormat {
    /// Shorthand for `.diff()` — uses the default `.compact` diff style.
    static var diff: Self { .diff() }
    /// Shorthand for `.value()` — uses the defaults `maxLines: 20`, `maxDepth: 4`.
    static var value: Self { .value() }
}

// MARK: - debugFileLocation

/// Formats a `#fileID` + `#line` pair as `"filename.swift:line"` — identical to
/// `FileAndLine.description` used in memoize auto-keys.
func debugFileLocation(_ fileID: StaticString, _ line: UInt) -> String {
    let s = "\(fileID)"
    let filename = String(s.split(separator: "/").last ?? Substring(s))
    return "\(filename):\(line)"
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
