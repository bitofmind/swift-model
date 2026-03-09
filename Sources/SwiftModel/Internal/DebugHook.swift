/// Debug hook for exposing internal state to test infrastructure.
///
/// Production code calls `DebugHook.record(_)` to emit debug information.
/// Test code connects this hook using `DebugHook.withRecording(_:perform:)`,
/// which scopes the hook to the current task so parallel tests never interfere.
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
/// @Test func example() async {
///     await DebugHook.withRecording { message in
///         Attachment.record(message, named: "DEBUG_LOG", contentType: .plainText)
///     } perform: {
///         // Run test...
///     }
/// }
/// ```
///
/// Production code NEVER depends on the Testing module directly.
/// This maintains clean separation between library and test infrastructure.
public enum DebugHook {
    /// Task-local recording hook. `nil` means no recording (zero cost in production).
    @TaskLocal static var _record: (@Sendable (String) -> Void)? = nil

    /// Emit a debug message to whichever recording hook is active in this task, if any.
    public static func record(_ message: String) {
        _record?(message)
    }

    /// Scopes a recording hook to the current task (and any child tasks it spawns).
    /// Parallel tests each have their own task, so they never share or trample hooks.
    public static func withRecording(
        _ hook: @escaping @Sendable (String) -> Void,
        perform: () async throws -> Void
    ) async rethrows {
        try await $_record.withValue(hook) {
            try await perform()
        }
    }
}
