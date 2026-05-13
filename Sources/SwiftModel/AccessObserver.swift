import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - AccessObserver

/// A hook fired when a debug-tracked property is *read* (not when it changes).
///
/// Set `accessObserver` on a `DebugOptions` value to receive a callback every time
/// any property reachable through the active debug observation is accessed — useful
/// for custom telemetry, conditional breakpoint trapping, or any "fire something on
/// access" use case.
///
/// > For the common "which read caused this trigger?" question, prefer the dedicated
/// > `captureAccessStack:` field on `DebugOptions` — it captures the call stack at
/// > access time but only emits when the property *actually* fires a trigger,
/// > avoiding the noise of stack dumps for properties that were read but never
/// > invalidated.
///
/// The framework fires `observeAccess(modelType:path:)` on *every* read, **outside**
/// any internal locks. Implementations are responsible for deduplication,
/// rate-limiting, or filtering. See ``FirstAccessObserver`` and its factory helpers
/// (``firstAccess(limit:action:)``, ``firstAccessBreakpoint(limit:)``) for ready-made
/// implementations.
///
/// `accessObserver` is supported on:
///
/// - `$model.debug(_:)` (`@ObservedModel`)
/// - `ModelScope(debug:)`
/// - `Observed(debug:)`
/// - `memoize(debug:)`
/// - `node.debug(_:_:)` (the closure-taking form)
///
/// It is silently ignored on `node.debug(_:)` (no-closure form) and
/// `observeModifications(debug:)`, which observe mutations rather than reads.
public protocol AccessObserver: Sendable {
    /// Fired once per `willAccess` for any path observed under the active debug
    /// observation. Called outside swift-model's internal locks.
    ///
    /// - Parameters:
    ///   - modelType: The `String(describing:)` form of the model containing the
    ///     accessed property (e.g. `"EditorModel"`).
    ///   - path: The dotted property name (e.g. `"canvas.scale"`), or `""` for
    ///     synthetic paths (memoize keys, environment, preference, parents).
    func observeAccess(modelType: String, path: String)
}

// MARK: - FirstAccessObserver

/// An `AccessObserver` that invokes its action only for the first `limit` accesses
/// of each distinct `(modelType, path)` pair.
///
/// Use one of the static factories on `AccessObserver` to construct common shapes
/// — `.firstAccess { … }`, `.firstAccessBreakpoint()`. The count is held on the
/// observer instance, so a single observer reused across renders or across multiple
/// debug sites keeps the same tally.
public final class FirstAccessObserver: AccessObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private let limit: Int
    private let action: @Sendable (_ modelType: String, _ path: String) -> Void

    /// Creates a `FirstAccessObserver` that calls `action` the first `limit` times
    /// each unique `(modelType, path)` pair is accessed.
    ///
    /// - Parameters:
    ///   - limit: How many accesses per key fire `action` before subsequent reads
    ///     are silently swallowed. Default `1`.
    ///   - action: Called on each "first" access. Runs outside swift-model's
    ///     internal locks; safe to perform expensive work (stack capture, printing,
    ///     breakpoint trap).
    public init(
        limit: Int = 1,
        action: @escaping @Sendable (_ modelType: String, _ path: String) -> Void
    ) {
        self.limit = limit
        self.action = action
    }

    public func observeAccess(modelType: String, path: String) {
        let key = "\(modelType).\(path)"
        let shouldFire: Bool = lock.withLock {
            let count = counts[key, default: 0]
            guard count < limit else { return false }
            counts[key] = count + 1
            return true
        }
        if shouldFire {
            action(modelType, path)
        }
    }
}

// MARK: - Static factories

public extension AccessObserver where Self == FirstAccessObserver {
    /// Calls `action` the first `limit` times each unique `(modelType, path)` pair
    /// is accessed. Subsequent reads of the same property are silently dropped.
    ///
    /// ```swift
    /// $editor.debug(.init(name: "EditorMidBar",
    ///                     accessObserver: .firstAccess { type, path in
    ///     print("[REDRAW first-access] \(type).\(path)")
    /// }))
    /// ```
    static func firstAccess(
        limit: Int = 1,
        action: @escaping @Sendable (_ modelType: String, _ path: String) -> Void
    ) -> FirstAccessObserver {
        FirstAccessObserver(limit: limit, action: action)
    }

    /// Raises a debugger trap (`SIGTRAP`) the first `limit` times each unique
    /// `(modelType, path)` pair is accessed. Lets you stop in LLDB and inspect
    /// the actual reader — far more precise than a stack-symbols dump because
    /// you get live frames, locals, and the option to `bt` / `up` / `down`.
    ///
    /// Compiled out in release: outside `DEBUG` the action is a no-op.
    ///
    /// ```swift
    /// $editor.debug(.init(name: "EditorView",
    ///                     accessObserver: .firstAccessBreakpoint()))
    /// ```
    static func firstAccessBreakpoint(limit: Int = 1) -> FirstAccessObserver {
        FirstAccessObserver(limit: limit) { _, _ in
            // WASI has no process-level signal model — `raise(3)` / `SIGTRAP`
            // aren't surfaced by Swift's WASI libc overlay, and there's no
            // debugger workflow that would catch a trap there anyway. The
            // factory itself stays callable cross-platform so source written
            // against `.firstAccessBreakpoint()` compiles everywhere; the
            // action just no-ops on WASI.
#if DEBUG && !os(WASI)
            raise(SIGTRAP)
#endif
        }
    }
}

// MARK: - Stack symbolication (internal)

// These helpers are not guarded by `#if DEBUG`. The `DebugAccessCollector`
// machinery in `DebugDiff.swift` compiles unconditionally (it's only instantiated
// from `#if DEBUG`-gated call sites), and its `onTrigger` closures reference the
// helpers below. Gating these on `#if DEBUG` would mean DebugDiff.swift fails to
// compile in release. The helpers are pure functions that do nothing at runtime
// when the caller doesn't invoke them, so leaving them in the release binary is
// harmless — only debug paths reach them.

/// Symbolicates raw return-address frames (as bit-pattern `UInt`s) into
/// human-readable strings using `backtrace_symbols(3)`. Called lazily from
/// `ViewAccess.emitDebugTrigger` and `DebugAccessCollector`'s onTrigger lazy
/// closures to resolve stacks captured at `willAccess` time for `captureAccessStack`.
///
/// Addresses are stored as `UInt` rather than `UnsafeMutableRawPointer?` so the
/// stack can travel through `@Sendable` closures without an `@unchecked` escape
/// hatch — `UInt` is `Sendable`, raw pointers are not.
///
/// Returns an empty array if symbolication isn't available on this platform
/// (Linux, Android, WASM) or if the input is empty. Swift's `Glibc` overlay
/// doesn't re-export `backtrace_symbols(3)`, Android's Bionic doesn't ship it,
/// and WASM has no stack-symbolication API — so we only call it on Darwin.
/// The C `backtrace_symbols` allocation is freed before returning.
internal func symbolicateAccessStack(_ addrs: [UInt]) -> [String] {
#if canImport(Darwin)
    guard !addrs.isEmpty else { return [] }
    var ptrs: [UnsafeMutableRawPointer?] = addrs.map { UnsafeMutableRawPointer(bitPattern: $0) }
    return ptrs.withUnsafeMutableBufferPointer { (mutableBuf: inout UnsafeMutableBufferPointer<UnsafeMutableRawPointer?>) -> [String] in
        guard let base = mutableBuf.baseAddress else { return [] }
        guard let symbols = backtrace_symbols(base, Int32(mutableBuf.count)) else { return [] }
        defer { free(symbols) }
        var out: [String] = []
        out.reserveCapacity(mutableBuf.count)
        for i in 0..<mutableBuf.count {
            if let cstr = symbols[i] {
                out.append(String(cString: cstr))
            }
        }
        return out
    }
#else
    return []
#endif
}

/// Drops the leading consecutive frames that belong to swift-model itself, so
/// the first frame of the returned slice is the user-code line that performed
/// the read. Stops at the first non-SwiftModel frame and returns everything
/// from there onward unchanged — SwiftModel frames that appear *deeper* in the
/// stack (e.g. user code → memoize internals → user `produce` closure) are
/// preserved because they tell a real story.
///
/// Detection is a substring match on `"SwiftModel"` against each symbolicated
/// frame line. This catches both spellings:
///
/// - **Dynamic linking** (framework build): the image name in `backtrace_symbols`
///   output is literally `SwiftModel`.
/// - **Static linking** (SPM apps): the image name is the app's binary, but
///   internal symbols are Swift-mangled as `_$s11SwiftModel…` — the length-prefixed
///   module name appears verbatim in the mangled symbol.
///
/// A module named with `"SwiftModel"` as a substring (rare) would hit false
/// positives at the top of the stack; callers who need exact frames can use
/// `accessObserver` with their own `Thread.callStackSymbols` capture instead.
internal func trimSwiftModelInternalFrames(_ frames: [String]) -> [String] {
    var i = 0
    while i < frames.count && frames[i].contains("SwiftModel") {
        i += 1
    }
    return Array(frames[i...])
}
