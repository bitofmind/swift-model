/// Debug hook for exposing internal state to test infrastructure.
///
/// Production code calls `DebugHook.record(_)` to emit debug information.
/// Test code connects this hook to Swift Testing's `Attachment.record`.
///
/// ## Usage in Production Code
///
/// ```swift
/// DebugHook.record("onChange fired: value=\(value)")
/// ```
///
/// ## Usage in Tests
///
/// ```swift
/// import Testing
///
/// @Test func example() {
///     DebugHook.record = { message in
///         Attachment.record(message, named: "DEBUG_LOG", contentType: .plainText)
///     }
///     // Run test...
/// }
/// ```
///
/// Production code NEVER depends on the Testing module directly.
/// This maintains clean separation between library and test infrastructure.
public enum DebugHook {
    /// Hook function that tests can override to capture debug output.
    ///
    /// Default implementation does nothing (zero runtime cost in production).
    ///
    /// Note: Marked as nonisolated(unsafe) because tests control the lifecycle
    /// and ensure thread-safe usage. The hook is set once at test start and
    /// reset at test end, with no concurrent mutations.
    nonisolated(unsafe) public static var record: @Sendable (String) -> Void = { _ in }
}
