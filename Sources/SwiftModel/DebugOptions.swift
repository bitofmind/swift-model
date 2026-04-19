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
