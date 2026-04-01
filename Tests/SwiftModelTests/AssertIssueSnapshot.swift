#if !os(Android)
import Foundation
import IssueReporting
import InlineSnapshotTesting

// MARK: - assertIssueSnapshot

/// Runs `body`, captures all issues emitted via `reportIssue`, joins them with newlines,
/// and asserts the result matches `expected` using inline snapshot testing.
///
/// This is a convenience wrapper replacing the two-step `captureIssues { } + assertInlineSnapshot`
/// pattern in `OutputSnapshotTests`. Write:
///
/// ```swift
/// await assertIssueSnapshot {
///     let (model, tester) = Counter().andTester()
///     model.count = 7
///     await tester.access.expect(timeoutNanoseconds: NSEC_PER_SEC, at: tester.fileAndLine, predicates: [])
/// } matches: {
///     """
///     State not exhausted: …
///
///     Modifications not asserted:
///
///         Counter.count == 7
///     """
/// }
/// ```
///
/// When `matches` is omitted (or on first run), the library writes the captured output back into
/// the source file automatically — the same auto-fill behaviour as `assertInlineSnapshot`.
func assertIssueSnapshot(
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: UInt = #line,
    column: UInt = #column,
    _ body: () async throws -> Void,
    matches expected: (() -> String)? = nil
) async rethrows {
    // Capture all reportIssue messages emitted during body.
    let reporter = CapturingIssueReporter()
    try await withIssueReporters([reporter], operation: body)
    let captured = reporter.messages.joined(separator: "\n")

    // assertInlineSnapshot is sync — we already have the captured string.
    // The body closure is trailing-closure #0; the matches: closure is #1 (offset 1).
    assertInlineSnapshot(
        of: captured,
        as: .lines,
        syntaxDescriptor: InlineSnapshotSyntaxDescriptor(
            trailingClosureLabel: "matches",
            trailingClosureOffset: 1
        ),
        matches: expected,
        fileID: fileID,
        file: filePath,
        function: function,
        line: line,
        column: column
    )
}

// MARK: - CapturingIssueReporter

/// Collects failure messages from `reportIssue` calls without emitting them as test failures.
final class CapturingIssueReporter: IssueReporter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var messages: [String] = []

    func reportIssue(
        _ message: @autoclosure () -> String?,
        severity: IssueSeverity,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) {
        let m = message() ?? ""
        lock.withLock { messages.append(m) }
    }
}
#endif
