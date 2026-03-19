import Foundation
import Testing
@testable import SwiftModel
import SwiftModelTesting
import CustomDump
import IssueReporting
import InlineSnapshotTesting

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

// A parent model holding a Counter with explicit Int id, for deterministic replacement snapshots
@Model
private struct CounterHolder {
    var item: Counter = Counter(id: 1)
}

// A model with a callback closure, for testing probe exhaustion and timeout messages
@Model
private struct TraitLoader {
    var item: String? = nil
    var onLoad: @Sendable (String) -> Void = { _ in }

    func load(value: String) {
        item = value
        onLoad(value)
    }
}

// A model that sends events, for testing didSend() out-of-scope error
@Model
private struct EventSenderForOutOfScope {
    enum Event { case tapped }
    func tap() { node.send(.tapped) }
}

// Models for exhaustion failure tests — must be at file scope so @Model macro expansion is accessible
@Model
private struct ExhaustionEventSender {
    enum Event { case tapped }
    func tap() { node.send(.tapped) }
}

@Model
private struct LongTaskRunner {
    func startTasks() {
        node.task { try? await Task.sleep(nanoseconds: 100_000_000_000) }
        node.task { try? await Task.sleep(nanoseconds: 100_000_000_000) }
    }
}

@Model
private struct SingleTaskRunner {
    func startTask() {
        node.task { try? await Task.sleep(nanoseconds: 100_000_000_000) }
    }
}

// MARK: - diffMessage output

/// Tests for the raw `diffMessage` helper — the building block for all tester failure output.
@Suite("diffMessage output format")
struct DiffMessageOutputTests {

    @Test("int mismatch produces proportional diff")
    func intMismatch() {
        let msg = diffMessage(expected: 5, actual: 3, title: "Counter.count")
        assertInlineSnapshot(of: msg, as: .lines) {
            """
            Counter.count: …

                − 5
                + 3

            (Expected: −, Actual: +)
            """
        }
    }

    @Test("equal values produce nil")
    func equalValues() {
        let msg = diffMessage(expected: 42, actual: 42, title: "Counter.count")
        #expect(msg == nil)
    }

    @Test("string mismatch shows quoted strings")
    func stringMismatch() {
        let msg = diffMessage(expected: "hello", actual: "world", title: "Model.name")
        assertInlineSnapshot(of: msg, as: .lines) {
            """
            Model.name: …

                − "hello"
                + "world"

            (Expected: −, Actual: +)
            """
        }
    }

    @Test("bool mismatch")
    func boolMismatch() {
        let msg = diffMessage(expected: true, actual: false, title: "Counter.isEnabled")
        assertInlineSnapshot(of: msg, as: .lines) {
            """
            Counter.isEnabled: …

                − true
                + false

            (Expected: −, Actual: +)
            """
        }
    }

    // diffMessage with includeChildrenInMirror suppresses ModelID — only data fields differ.
    // The exhaustion tests below cover the full end-to-end message; this test pins the key
    // property: ModelID does NOT appear when data fields change.
    @Test("diffMessage with includeChildrenInMirror: data-field diff contains no ModelID")
    func diffMessageDataFieldsNoModelID() {
        let a = Counter(id: 1, count: 5).withAnchor()
        let b = Counter(id: 1, count: 9).withAnchor()
        let msg = threadLocals.withValue(true, at: \.includeChildrenInMirror) {
            diffMessage(expected: a, actual: b, title: "Counter.count")
        }
        assertInlineSnapshot(of: msg, as: .lines) {
            """
            Counter.count: …

                  Counter(
                    id: 1,
                −   count: 5
                +   count: 9
                  )

            (Expected: −, Actual: +)
            """
        }
    }

    // diffMessage with includeInMirror reveals the explicit id field when it is the only change.
    @Test("diffMessage with includeInMirror: id-only diff shows the id field")
    func diffMessageIdFieldVisible() {
        let a = Counter(id: 1, count: 5).withAnchor()
        let b = Counter(id: 2, count: 5).withAnchor()
        let msg = threadLocals.withValue(true, at: \.includeInMirror) {
            diffMessage(expected: a, actual: b, title: "Counter.id")
        }
        assertInlineSnapshot(of: msg, as: .lines) {
            """
            Counter.id: …

                  Counter(
                −   id: 1,
                +   id: 2,
                    count: 5
                  )

            (Expected: −, Actual: +)
            """
        }
    }

    // Exhaustion output when a data field changes: only one message, no ModelID in the diff.
    @Test("unasserted data field change: single message, no ModelID")
    func unassertedDataFieldChange() async {
        let (model, tester) = CounterHolder().andTester()
        model.item.count = 7

        let issues = await captureIssues {
            await tester.assert(true)
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            State not exhausted: …

            Modifications not asserted:

                Counter.count == 7
            """
        }
    }

    // Exhaustion output when a child model is replaced with a different explicit id:
    // exactly one message, showing the new instance's id and fields.
    @Test("unasserted child model replacement with explicit id: single message with id")
    func unassertedChildModelReplacementExplicitId() async {
        let (model, tester) = CounterHolder().andTester()
        model.item = Counter(id: 99, count: 7)

        let issues = await captureIssues {
            await tester.assert(true)
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            State not exhausted: …

            Modifications not asserted:

                CounterHolder.item == Counter(
                  id: 99,
                  count: 7
                )
            """
        }
    }
}
// MARK: - tester.assert failure messages

/// Tests for messages emitted by `tester.assert` when predicates fail.
@Suite("tester.assert failure messages")
struct TesterAssertOutputTests {

    // Documents the exact failure message format from tester.assert.
    // The diff uses − for expected and + for actual.
    @Test("failed predicate produces diff with expected/actual markers")
    func predicateFailureMessage() async {
        let (model, tester) = SimpleCounter().andTester(exhaustivity: .off)
        model.count = 3

        let issues = await captureIssues {
            await tester.assert(timeoutNanoseconds: 1_000_000) { model.count == 99 }
        }

        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Failed to assert: SimpleCounter.count: …

                − 99
                + 3

            (Expected: −, Actual: +)
            """
        }
    }

    @Test("passing assertion emits no issues")
    func passingAssertionNoIssues() async {
        let (model, tester) = SimpleCounter().andTester(exhaustivity: .off)
        model.count = 5

        let issues = await captureIssues {
            await tester.assert { model.count == 5 }
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            """
        }
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
        assertInlineSnapshot(of: output.trimmingCharacters(in: .whitespacesAndNewlines), as: .lines) {
            """
            SimpleCounter()
            """
        }
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
        assertInlineSnapshot(of: output.trimmingCharacters(in: .whitespacesAndNewlines), as: .lines) {
            """
            SimpleCounter(count: 7)
            """
        }
    }

    // With includeInMirror set, both data fields AND the ModelID are shown.
    // Uses Counter with explicit id so the snapshot is deterministic.
    @Test("includeInMirror shows data fields and ModelID")
    func customDumpWithIncludeInMirrorShowsID() {
        let model = Counter(id: 42, count: 7).withAnchor()

        var output = ""
        _ = threadLocals.withValue(true, at: \.includeInMirror) {
            customDump(model, to: &output)
        }
        assertInlineSnapshot(of: output.trimmingCharacters(in: .whitespacesAndNewlines), as: .lines) {
            """
            Counter(
              id: 42,
              count: 7
            )
            """
        }
    }

    // Documents that a model with an explicit id: Int has that field in its dump.
    @Test("model with explicit id shows id field when includeChildrenInMirror is set")
    func explicitIdFieldVisible() {
        let model = Counter(id: 42, count: 7).withAnchor()

        var output = ""
        _ = threadLocals.withValue(true, at: \.includeChildrenInMirror) {
            customDump(model, to: &output)
        }
        assertInlineSnapshot(of: output.trimmingCharacters(in: .whitespacesAndNewlines), as: .lines) {
            """
            Counter(
              id: 42,
              count: 7
            )
            """
        }
    }
}

// MARK: - Exhaustion failure messages

/// Tests for all the exhaustion-check failure messages emitted at the end of a test
/// (or when an assert block runs) when side effects were not consumed.
@Suite("exhaustion failure messages")
struct ExhaustionFailureTests {

    // T16: Scalar state change not asserted.
    @Test("unasserted scalar state change reports State not exhausted with value")
    func unassertedStateChange() async {
        let (model, tester) = SimpleCounter().andTester(exhaustivity: .state)
        model.count = 42

        let issues = await captureIssues {
            await tester.assert(true)
        }

        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            State not exhausted: …

            Modifications not asserted:

                SimpleCounter.count == 42
            """
        }
    }

    // Replacing a child with a new instance that has the same data but a different implicit
    // ModelID: layer-2 fires on the deinit path (tester goes out of scope without asserting),
    // showing a before/after id diff. Exactly one message.
    @Test("unasserted implicit-id child replacement: single diff message showing id change")
    func unassertedImplicitIdChildReplacement() async {
        let issues = await captureIssues {
            let (model, tester) = ItemHolder().andTester()
            model.item = SimpleCounter()
            _ = tester  // deinit fires checkExhaustion(includeUpdates: false)
        }
        #expect(issues.count == 1)
        // ModelID integers are non-deterministic; normalize them to "N" for a stable snapshot.
        let normalized = (issues.first ?? "")
            .replacing(#/ModelID\(\d+\)/#, with: { _ in "ModelID(N)" })
        assertInlineSnapshot(of: normalized, as: .lines) {
            """
            State not exhausted: …

                  ItemHolder(
                    id: ModelID(N),
                    item: SimpleCounter(
                −     id: ModelID(N),
                +     id: ModelID(N),
                      count: 0
                    )
                  )

            (Expected: −, Actual: +)
            """
        }
    }

    // T14: Event not asserted — entire tester lifecycle is inside captureIssues so the
    // deinit fires while the custom reporter is active.
    @Test("unasserted event reports event name and model type")
    func unassertedEvent() async {
        let issues = await captureIssues {
            let (model, tester) = ExhaustionEventSender().andTester(exhaustivity: .events)
            model.tap()
            _ = tester
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Event `ExhaustionEventSender.Event.tapped` sent from `ExhaustionEventSender` was not handled
            """
        }
    }

    // T12: Active task summary (plural).
    // The CapturingReporter captures only message text (not file/line), so all three issues
    // are deterministic: one summary line + two "active task still running" lines (one per task).
    @Test("two active tasks report '2 active tasks' in summary line")
    func twoActiveTasksSummaryPlural() async {
        let issues = await captureIssues {
            let (model, tester) = LongTaskRunner().andTester(exhaustivity: .tasks)
            model.startTasks()
            await tester.assert(true, timeoutNanoseconds: 1_000_000)
        }
        assertInlineSnapshot(of: issues.first ?? "", as: .lines) {
            """
            Models of type `LongTaskRunner` have 2 active tasks still running
            """
        }
    }

    // T13: Each active task emits its own failure line.
    @Test("each active task emits its own failure line")
    func eachActiveTaskEmitsFailureLine() async {
        let issues = await captureIssues {
            let (model, tester) = LongTaskRunner().andTester(exhaustivity: .tasks)
            model.startTasks()
            await tester.assert(true, timeoutNanoseconds: 1_000_000)
        }
        // summary (issues[0]) + one registration-site line per task (issues[1...])
        let taskLines = issues.dropFirst()
        assertInlineSnapshot(of: taskLines.joined(separator: "\n"), as: .lines) {
            """
            Active task of `LongTaskRunner` still running (registered here)
            Active task of `LongTaskRunner` still running (registered here)
            """
        }
    }

    // T12 singular: one active task uses singular "task".
    @Test("one active task reports '1 active task' (singular) in summary line")
    func oneActiveTaskSummarySingular() async {
        let issues = await captureIssues {
            let (model, tester) = SingleTaskRunner().andTester(exhaustivity: .tasks)
            model.startTask()
            await tester.assert(true, timeoutNanoseconds: 1_000_000)
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Models of type `SingleTaskRunner` have 1 active task still running
            Active task of `SingleTaskRunner` still running (registered here)
            """
        }
    }

    // T15: Named probe exhaustion — deterministic message.
    // Tester goes out of scope at end of captureIssues block; deinit fires checkExhaustion.
    @Test("named probe exhaustion message includes probe name with space-separated quote")
    func namedProbeExhaustionMessage() async {
        let onLoad = TestProbe("myLoader")
        let issues = await captureIssues {
            let (model, tester) = TraitLoader(onLoad: onLoad.call).andTester(exhaustivity: .probes)
            tester.install(onLoad)
            model.load(value: "hello")
            _ = tester  // keep alive until end of block; deinit fires checkExhaustion
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Failed to assert calling of probe "myLoader":
                "hello"
            """
        }
    }

    // T15: Unnamed probe exhaustion.
    @Test("unnamed probe exhaustion message uses bare 'probe:' format")
    func unnamedProbeExhaustionMessage() async {
        let onLoad = TestProbe()
        let issues = await captureIssues {
            let (model, tester) = TraitLoader(onLoad: onLoad.call).andTester(exhaustivity: .probes)
            tester.install(onLoad)
            model.load(value: "hello")
            _ = tester
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Failed to assert calling of probe:
                "hello"
            """
        }
    }
}

// MARK: - Timeout-path probe messages (tester.assert with wrong value)

/// Tests for the messages emitted when a `wasCalled(with:)` predicate times out.
@Suite("timeout-path probe failure messages")
struct TimeoutProbeFailureTests {

    // T8: Probe never called.
    @Test("probe with no values reports 'No available probe values'")
    func probeNoValues() async {
        let onLoad = TestProbe()
        let issues = await captureIssues {
            let (_, tester) = TraitLoader(onLoad: onLoad.call).andTester(exhaustivity: .off)
            tester.install(onLoad)
            await tester.assert(timeoutNanoseconds: 1_000_000) {
                onLoad.wasCalled(with: "hello")
            }
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Failed to assert calling of probe:
                "hello"

            No available probe values
            """
        }
    }

    // T9: Probe called with wrong value — emits a diff.
    @Test("probe with one wrong value emits diff")
    func probeOneWrongValue() async {
        let onLoad = TestProbe()
        let issues = await captureIssues {
            let (model, tester) = TraitLoader(onLoad: onLoad.call).andTester(exhaustivity: .off)
            model.load(value: "actual")
            await tester.assert(timeoutNanoseconds: 1_000_000) {
                onLoad.wasCalled(with: "expected")
            }
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Probe does not match: …

                − "expected"
                + "actual"

            (Expected: −, Actual: +)
            """
        }
    }

    // T10: Multiple probe values queued — lists all available.
    @Test("probe with multiple values lists all available probe values")
    func probeMultipleValues() async {
        let onLoad = TestProbe()
        let issues = await captureIssues {
            let (model, tester) = TraitLoader(onLoad: onLoad.call).andTester(exhaustivity: .off)
            model.load(value: "first")
            model.load(value: "second")
            await tester.assert(timeoutNanoseconds: 1_000_000) {
                onLoad.wasCalled(with: "nonexistent")
            }
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Failed to assert calling of probe:
                "nonexistent"

            2 Available probe values to assert:
                "first"
                "second"
            """
        }
    }

    // Named probe in timeout-path failure.
    @Test("named probe timeout message includes probe name with space-separated quote")
    func namedProbeTimeoutMessage() async {
        let onLoad = TestProbe("myLoader")
        let issues = await captureIssues {
            let (_, tester) = TraitLoader(onLoad: onLoad.call).andTester(exhaustivity: .off)
            await tester.assert(timeoutNanoseconds: 1_000_000) {
                onLoad.wasCalled(with: "hello")
            }
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Failed to assert calling of probe "myLoader":
                "hello"

            No available probe values
            """
        }
    }
}

// MARK: - Unwrap timeout message

/// Tests for the failure message from `tester.unwrap` when the value stays nil.
@Suite("unwrap timeout failure messages")
struct UnwrapTimeoutTests {

    // T11: tester.unwrap times out — message includes the type name.
    @Test("tester.unwrap timeout includes the type name")
    func unwrapTimeoutIncludesTypeName() async {
        let (_, tester) = TraitLoader().andTester(exhaustivity: .off)
        let issues = await captureIssues {
            _ = try? await tester.unwrap(nil as String?, timeoutNanoseconds: 1_000_000)
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Failed to unwrap value of type String
            """
        }
    }
}

// MARK: - Out-of-scope usage messages

/// Tests for errors emitted when global functions or model methods are called outside their
/// required scope (e.g. `expect()` without `.modelTesting`, `didSend()` outside assert block).
@Suite("out-of-scope usage messages")
struct OutOfScopeTests {

    // TT1: expect() outside .modelTesting scope.
    @Test("expect() outside modelTesting scope reports clear error")
    func expectOutsideScope() async {
        let issues = await captureIssues {
            await expect { true }
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            expect() must be called inside a @Test(.modelTesting) test function
            """
        }
    }

    // TT2: require() outside .modelTesting scope.
    @Test("require() outside modelTesting scope reports clear error")
    func requireOutsideScope() async {
        let issues = await captureIssues {
            _ = try? await require(nil as String?)
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            require() must be called inside a @Test(.modelTesting) test function
            """
        }
    }

    // TT4: withExhaustivity() outside .modelTesting scope.
    @Test("withExhaustivity() outside modelTesting scope reports clear error")
    func withExhaustivityOutsideScope() async {
        let issues = await captureIssues {
            await withExhaustivity(.off) { }
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            withExhaustivity() must be called inside a @Test(.modelTesting) test function
            """
        }
    }

    // M1: didSend() outside assert block.
    @Test("didSend() outside assert block reports clear error")
    func didSendOutsideAssertBlock() async {
        let (model, tester) = EventSenderForOutOfScope().andTester(exhaustivity: .off)
        let issues = await captureIssues {
            _ = model.didSend(EventSenderForOutOfScope.Event.tapped)
        }
        _ = tester
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Can only call didSend inside a ModelTester assert
            """
        }
    }

    // M2: didSend() inside assert block but on an unanchored model (lifetime < .active).
    // The model must be active to call didSend; an unanchored model has no tester context.
    // We use $assertContext.withValue to establish an assert context without the polling
    // loop — this lets us verify the message fires exactly once for a single didSend call.
    @Test("didSend() on unanchored model inside assert block reports clear error")
    func didSendOnUnanchoredModel() async {
        let (model, tester) = EventSenderForOutOfScope().andTester(exhaustivity: .off)
        // An initial (unanchored) model — lifetime is .initial, not .active
        let unanchored = EventSenderForOutOfScope()
        let fileAndLine = FileAndLine(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
        let fakeContext = TestAccess<EventSenderForOutOfScope>.TesterAssertContext(events: { [] }, fileAndLine: fileAndLine)
        let issues = await captureIssues {
            await TesterAssertContextBase.$assertContext.withValue(fakeContext) {
                _ = unanchored.didSend(EventSenderForOutOfScope.Event.tapped)
            }
        }
        _ = (model, tester)
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Can only call didSend on a model that is part of a ModelTester
            """
        }
    }

    // P2: wasCalled() outside assert block.
    @Test("probe.wasCalled() outside assert block reports clear error")
    func probeWasCalledOutsideAssertBlock() async {
        let probe = TestProbe()
        let issues = await captureIssues {
            _ = probe.wasCalled(with: "hello")
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Can only call wasCalled inside a ModelTester assert or expect block
            """
        }
    }

    // P1: probe.install() outside .modelTesting scope.
    @Test("probe.install() outside modelTesting scope reports clear error")
    func probeInstallOutsideScope() async {
        let probe = TestProbe(autoInstall: false)
        let issues = await captureIssues {
            probe.install()
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            install() must be called inside a @Test(.modelTesting) test function
            """
        }
    }
}

// MARK: - Assertion failed (no-access fallback)

/// Tests for the fallback message "Assertion failed" when a predicate fails
/// without any property accesses, events, models, or probe calls recorded.
@Suite("assertion failed fallback message")
struct AssertionFailedFallbackTests {

    // T5: Boolean literal predicate — no property accesses.
    @Test("false literal predicate emits 'Assertion failed'")
    func falseLiteralPredicate() async {
        let (_, tester) = SimpleCounter().andTester(exhaustivity: .off)
        let issues = await captureIssues {
            await tester.assert(timeoutNanoseconds: 1_000_000) {
                false
            }
        }
        assertInlineSnapshot(of: issues.joined(separator: "\n"), as: .lines) {
            """
            Assertion failed
            """
        }
    }
}
