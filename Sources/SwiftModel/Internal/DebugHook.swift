// Internal hook for routing debug output to a capturable channel (e.g. Xcode MCP agents
// that cannot read stdout). Task-local so parallel tests never interfere with each other.
enum DebugHook {
    /// Task-local recording hook. `nil` means no recording (zero cost in production).
    @TaskLocal static var _record: (@Sendable (String) -> Void)? = nil

    /// Emit a debug message to whichever recording hook is active in this task, if any.
    static func record(_ message: String) {
        _record?(message)
    }

    /// Scopes a recording hook to the current task (and any child tasks it spawns).
    /// Parallel tests each have their own task, so they never share or trample hooks.
    static func withRecording(
        _ hook: @escaping @Sendable (String) -> Void,
        perform: () async throws -> Void
    ) async rethrows {
        try await $_record.withValue(hook) {
            try await perform()
        }
    }
}
