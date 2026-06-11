/// Executes `body` with model property reads untracked — no observation dependencies
/// are registered for any `@Model` property, memoized property, environment or
/// preference value read inside the scope.
///
/// A tracked read pays for fine-grained observation on every access: an
/// `ObservationRegistrar.access` call, dependency bookkeeping for any active access
/// (SwiftUI view tracking, `ModelTester`, `Observed`), and access stamping of returned
/// child models. For bulk scans over many models — hit-testing, snapping, validation
/// passes, building derived values element by element — that per-read overhead
/// dominates and the caller typically doesn't want a dependency on every visited
/// property anyway. Wrapping the scan in `withUntrackedModelReads` reduces each read
/// to a lock-protected raw state read:
///
/// ```swift
/// let hit = withUntrackedModelReads {
///     timeline.segments.first { $0.timeSpan.contains(playhead) }
/// }
/// ```
///
/// ## Semantics
///
/// - **Reads register no observation dependencies.** A SwiftUI view body (or an
///   `Observed { }` stream, memoize, or test expectation) evaluating reads inside this
///   scope will *not* re-run when those properties later change. Callers own their
///   invalidation: depend on the scanned state through some tracked read outside the
///   scope, or recompute via an explicit trigger (e.g. `node.onChange`).
/// - **Reads stay thread-safe.** Unlike a raw snapshot, reads still go through the
///   model's context lock, so scanning while other threads write is memory-safe and
///   each individual property read is consistent. (A multi-property scan is still not
///   atomic as a whole — same as tracked reads; use `node.transaction` for that.)
/// - **Writes are unaffected.** A write inside the scope notifies observers exactly as
///   it would outside.
/// - **Models returned from reads carry no access stamping.** Extracting a child model
///   inside the scope and reading it *outside* later behaves like a fresh un-stamped
///   value (falls back to task-local access). Prefer extracting plain values, not
///   models, when the result outlives the scope.
/// - **Dependency collection inside the framework is immune.** Setting up a
///   `node.memoize` or `Observed { }` inside the scope still tracks its own
///   dependencies correctly — only the *caller's* dependency registration is skipped.
/// - The scope is thread-local and re-entrant. It does not propagate into tasks
///   spawned inside `body`.
public func withUntrackedModelReads<T>(_ body: () throws -> T) rethrows -> T {
    // Direct field access instead of `threadLocals.withValue(_:at:)` — the
    // ReferenceWritableKeyPath-based helper costs ~2 μs per scope in Release,
    // which would dwarf the reads this API exists to make cheap.
    let tl = threadLocals
    let previous = tl.untrackedReads
    tl.untrackedReads = true
    defer { tl.untrackedReads = previous }
    return try body()
}
