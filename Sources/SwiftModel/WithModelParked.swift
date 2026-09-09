/// Marks the calling model task **parked** for the duration of `body`.
///
/// SwiftModel's test-wait verbs (`expect`, `settle`, `waitUntil`) need to know
/// when a model is done reacting. Work that is suspended waiting for input that
/// can only arrive from outside — a clock deadline, an external event source —
/// is not "reacting"; work that is executing, or suspended somewhere the
/// framework cannot see, is. SwiftModel marks its own suspension points
/// automatically (notably `node.forEach`, which parks around its `next()`, so
/// any `AsyncSequence` — including `swift-async-algorithms` `debounce` /
/// `throttle` — parks with no adoption at all).
///
/// Use this primitive when you hand a model a *bare* suspension that is not an
/// `AsyncSequence`: the canonical case is a clock's own `sleep` implementation.
/// The adoption point is the source's implementation, not its call sites — a
/// clock protocol that funnels every caller through one `sleep` method needs
/// one wrap, and every `clock.sleep` in every model is covered:
///
/// ```swift
/// extension MyClock {
///     public func sleep(until date: Date) async throws {
///         try await withModelParked {
///             try await self.nonAdjustedSleep(until: date)
///         }
///     }
/// }
/// ```
///
/// The current work unit is found through a task-local set when a model task
/// body starts, so a suspension inside a child task the library spawned still
/// marks the right unit. Outside any model task this is a plain passthrough —
/// it never traps and never has an effect.
///
/// - Note: Not marking something is safe, merely less precise: unmarked
///   suspensions count as running work, so a wait verb waits for them and can
///   report them by name rather than being silently wrong.
public func withModelParked<T>(_ body: () async throws -> T) async rethrows -> T {
    try await _withCurrentWorkUnitParked(body)
}
