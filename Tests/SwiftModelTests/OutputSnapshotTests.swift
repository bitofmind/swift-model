import Foundation
import Testing
@testable import SwiftModel
import CustomDump
import IssueReporting

// MARK: - Helper: Issue capture

/// A custom `IssueReporter` that collects failure messages for inspection in tests.
///
/// Use `captureIssues` to run a block and collect any failure messages that
/// `reportIssue` would normally emit as test failures.
private final class CapturingReporter: IssueReporter, @unchecked Sendable {
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

/// Runs `body` with all issues routed to a `CapturingReporter` and returns them as strings.
private func captureIssues(_ body: () async throws -> Void) async rethrows -> [String] {
    let reporter = CapturingReporter()
    try await withIssueReporters([reporter], operation: body)
    return reporter.messages
}

// MARK: - Test models
//
// Note: tester.assert property name capture relies on @ModelTracked property observation.
// Models with only auto-generated ModelID use non-deterministic values in failure output,
// so output tests use string-contains checks rather than exact string matching.

@Model
private struct Counter {
    let id: Int           // explicit stable id for deterministic output
    var count: Int = 0
}

// A model with only ModelID (auto-generated) for testing ModelID rendering
@Model
private struct SimpleCounter {
    var count: Int = 0
}

// A parent model that holds a child model, for testing how replacement diffs look
@Model
private struct ItemHolder {
    var item: SimpleCounter = SimpleCounter()
}

// MARK: - diffMessage output

/// Tests for the raw `diffMessage` helper — the building block for all tester failure output.
/// These tests pin the exact string format so regressions are caught immediately.
@Suite("diffMessage output format")
struct DiffMessageOutputTests {

    @Test("int mismatch produces proportional diff")
    func intMismatch() {
        let msg = diffMessage(expected: 5, actual: 3, title: "Counter.count")
        #expect(msg == """
        Counter.count: …

            − 5
            + 3

        (Expected: −, Actual: +)
        """)
    }

    @Test("equal values produce nil")
    func equalValues() {
        let msg = diffMessage(expected: 42, actual: 42, title: "Counter.count")
        #expect(msg == nil)
    }

    @Test("string mismatch shows quoted strings")
    func stringMismatch() {
        let msg = diffMessage(expected: "hello", actual: "world", title: "Model.name")
        #expect(msg == """
        Model.name: …

            − "hello"
            + "world"

        (Expected: −, Actual: +)
        """)
    }

    @Test("bool mismatch")
    func boolMismatch() {
        let msg = diffMessage(expected: true, actual: false, title: "Counter.isEnabled")
        #expect(msg == """
        Counter.isEnabled: …

            − true
            + false

        (Expected: −, Actual: +)
        """)
    }

    // ModelID has a CustomStringConvertible conformance (description returns the integer)
    // and an empty customMirror. customDump falls back to description for types with empty
    // mirrors that conform to CustomStringConvertible, so it renders the plain integer.
    // This test pins that behaviour — if ModelID printing changes it will be visible here.
    @Test("ModelID renders as its integer value in customDump via CustomStringConvertible")
    func modelIDCurrentRepresentation() {
        let id = ModelID.generate()
        var output = ""
        customDump(id, to: &output)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Should be "ModelID(<integer>)", e.g. "ModelID(5)"
        // If this starts failing it means CustomStringConvertible was removed or customDump
        // changed its fallback behaviour.
        #expect(trimmed.hasPrefix("ModelID(") && trimmed.hasSuffix(")"), "Expected ModelID(<integer>), got: \(trimmed)")
        let inner = trimmed.dropFirst("ModelID(".count).dropLast()
        #expect(Int(inner) != nil, "Expected integer inside ModelID(...), got: \(inner)")
    }

    // When a child @Model property is replaced (item = SimpleCounter()), the tester's
    // exhaustion output lists the unasserted modification with the new instance's ModelID visible.
    // The ModelID renders as a plain integer, making it clear which instance was assigned.
    //
    // Actual exhaustion output (IDs are non-deterministic integers, but always plain integers):
    //
    //   State not exhausted: …
    //
    //   Modifications not asserted:
    //
    //       ItemHolder.item == SimpleCounter(
    //         id: ModelID(6),
    //         count: 0
    //       )
    //
    // This test pins that id renders as "ModelID(<integer>)" in the exhaustion output.
    @Test("replacing a child model shows new ModelID as plain integer in exhaustion output")
    func childModelReplacementShowsIntegerID() async {
        let (model, tester) = ItemHolder().andTester()

        // Replace the child with a brand-new instance — this changes the id field
        model.item = SimpleCounter()

        // Trigger exhaustion without consuming the item change
        let issues = await captureIssues {
            await tester.assert(true)
        }

        #expect(!issues.isEmpty, "Expected exhaustion failure for unasserted item replacement")

        if let msg = issues.first {
            // The message should describe the unasserted modification
            #expect(msg.contains("Modifications not asserted"), "Expected 'Modifications not asserted' in exhaustion output:\n\(msg)")
            // id must render as "ModelID(<integer>)", not as a bare integer or opaque "ModelID()"
            #expect(msg.contains("ModelID("), "Expected 'ModelID(' in exhaustion output:\n\(msg)")
            // The model type name should appear in the property path
            #expect(msg.contains("ItemHolder"), "Expected model type name in exhaustion output:\n\(msg)")
        }
    }
}

// MARK: - tester.assert failure messages

/// Tests for messages emitted by `tester.assert` when predicates fail.
@Suite("tester.assert failure messages")
struct TesterAssertOutputTests {

    // Documents the exact failure message format from tester.assert.
    // The title shows "Failed to assert: ModelName.propertyName" when property access
    // tracking fires correctly. The diff uses − for expected and + for actual.
    @Test("failed predicate produces diff with expected/actual markers")
    func predicateFailureMessage() async {
        let (model, tester) = SimpleCounter().andTester(exhaustivity: .off)
        model.count = 3

        let issues = await captureIssues {
            await tester.assert { model.count == 99 }
        }

        // Exactly one failure message is emitted
        #expect(issues.count == 1)
        let msg = issues[0]

        // The message always starts with "Failed to assert"
        #expect(msg.hasPrefix("Failed to assert"))

        // Diff body — expected is on the − side, actual on +
        #expect(msg.contains("− 99"))
        #expect(msg.contains("+ 3"))
        #expect(msg.contains("(Expected: −, Actual: +)"))
    }

    @Test("passing assertion emits no issues")
    func passingAssertionNoIssues() async {
        let (model, tester) = SimpleCounter().andTester(exhaustivity: .off)
        model.count = 5

        let issues = await captureIssues {
            await tester.assert { model.count == 5 }
        }
        #expect(issues.isEmpty)
    }
}

// MARK: - customDump output for model types

/// Tests for how `customDump` renders model types.
///
/// Key behaviour to understand: `@Model`-generated `customMirror` returns no children by
/// default. It only populates children when the `includeChildrenInMirror` or `includeInMirror`
/// thread-local is set (done internally by `tester.assert` when computing diffs). This is why
/// `customDump(model)` outside a tester context shows `"TypeName()"` with no fields.
@Suite("customDump output for model types")
struct CustomDumpOutputTests {

    // Documents that plain customDump outside the tester renders the type name with no fields,
    // because the @Model macro's customMirror returns empty children without the tester thread-local.
    @Test("plain customDump of anchored model shows type name only (no fields by default)")
    func plainCustomDumpShowsTypeName() {
        let model = SimpleCounter().withAnchor()
        var output = ""
        customDump(model, to: &output)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // The model type name should appear but no field contents by default
        #expect(trimmed.contains("SimpleCounter"))
        // Without includeChildrenInMirror, properties are NOT shown
        #expect(!trimmed.contains("count:"))
    }

    // With includeChildrenInMirror set, data fields are shown but id is NOT.
    // This is the mode used for structural diffs — "did any data change?"
    // The id is intentionally suppressed here so noise-free diffs only show real changes.
    @Test("includeChildrenInMirror shows data fields but suppresses id")
    func customDumpWithIncludeChildrenInMirrorShowsFields() {
        let model = SimpleCounter().withAnchor()
        model.count = 7

        var output = ""
        _ = threadLocals.withValue(true, at: \.includeChildrenInMirror) {
            customDump(model, to: &output)
        }
        #expect(output.contains("count: 7"))
        // id must NOT appear — it would add noise to data-only diffs
        #expect(!output.contains("id:"), "id should be suppressed in includeChildrenInMirror mode")
    }

    // With includeInMirror set, both data fields AND the ModelID are shown.
    // This is the second-pass mode used to detect instance replacement (where data is
    // unchanged but the model ID differs — e.g. item = SomeModel() with same field values).
    @Test("includeInMirror shows data fields and ModelID")
    func customDumpWithIncludeInMirrorShowsID() {
        let model = SimpleCounter().withAnchor()
        model.count = 7

        var output = ""
        _ = threadLocals.withValue(true, at: \.includeInMirror) {
            customDump(model, to: &output)
        }
        #expect(output.contains("count: 7"))
        // id MUST appear — this mode is specifically for catching identity changes
        #expect(output.contains("id: ModelID("), "id should be visible in includeInMirror mode")
    }

    // Documents that a model with an explicit id: Int has that field in its dump.
    @Test("model with explicit id shows id field when includeChildrenInMirror is set")
    func explicitIdFieldVisible() {
        let model = Counter(id: 42, count: 7).withAnchor()

        var output = ""
        _ = threadLocals.withValue(true, at: \.includeChildrenInMirror) {
            customDump(model, to: &output)
        }
        #expect(output.contains("count: 7"))
        #expect(output.contains("id: 42"))
    }
}
