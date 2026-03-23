import Foundation
import Testing
@testable import SwiftModel
import CustomDump
import IssueReporting
import InlineSnapshotTesting

// MARK: - Test models
//
// Note: Models with only auto-generated ModelID use non-deterministic values in failure output,
// so such tests normalize ModelIDs before snapshot comparison.

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

                \u{2007} Counter(
                \u{2007}   id: 1,
                −   count: 5
                +   count: 9
                \u{2007} )

            (Expected: −, Actual: +)
            """
        }
    }

    // diffMessage with includeInMirror reveals the explicit id field when it is the only change.
    @Test("diffMessage with includeInMirror: id-only diff shows the id field")
    func diffMessageIdFieldVisible() {
        let a = Counter(id: 1, count: 5).withAnchor()
        let b = Counter(id: 2, count: 5).withAnchor()
        let msg = threadLocals.withValue(true, at: \.includeImplicitIDInMirror) {
            diffMessage(expected: a, actual: b, title: "Counter.id")
        }
        assertInlineSnapshot(of: msg, as: .lines) {
            """
            Counter.id: …

                \u{2007} Counter(
                −   id: 1,
                +   id: 2,
                \u{2007}   count: 5
                \u{2007} )

            (Expected: −, Actual: +)
            """
        }
    }

    // Exhaustion output when a data field changes: only one message, no ModelID in the diff.
    @Test("unasserted data field change: single message, no ModelID")
    func unassertedDataFieldChange() async {
        await assertIssueSnapshot {
            await withModelTesting {
                let model = CounterHolder().withAnchor()
                model.item.count = 7
                await expect { }
            }
        } matches: {
            """
            State not exhausted: …

            Modifications not asserted:

                Counter.count == 7
            """
        }
    }

    // Exhaustion output when a child model is replaced with a different explicit id.
    @Test("unasserted child model replacement with explicit id: single message with id")
    func unassertedChildModelReplacementExplicitId() async {
        await assertIssueSnapshot {
            await withModelTesting {
                let model = CounterHolder().withAnchor()
                model.item = Counter(id: 99, count: 7)
                await expect { }
            }
        } matches: {
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

// MARK: - assertion failure messages

/// Tests for messages emitted by `expect` when predicates fail.
@Suite("tester.assert failure messages")
struct TesterAssertOutputTests {

    @Test("failed predicate produces diff with expected/actual markers")
    func predicateFailureMessage() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .off) {
                let model = SimpleCounter().withAnchor()
                model.count = 3
                // Explicit TestPredicate type annotation forces the TestPredicate-returning == overload,
                // which captures both sides as autoclosures and produces the diff format on failure.
                let pred: TestPredicate = model.count == 99
                await expect(pred, timeoutNanoseconds: 1_000_000)
            }
        } matches: {
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
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .off) {
                let model = SimpleCounter().withAnchor()
                model.count = 5
                await expect { model.count == 5 }
            }
        } matches: {
            """
            """
        }
    }
}

// MARK: - customDump output for model types

/// Tests for how `customDump` renders model types.
@Suite("customDump output for model types")
struct CustomDumpOutputTests {

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

    @Test("includeInMirror shows data fields and ModelID")
    func customDumpWithIncludeInMirrorShowsID() {
        let model = Counter(id: 42, count: 7).withAnchor()

        var output = ""
        _ = threadLocals.withValue(true, at: \.includeImplicitIDInMirror) {
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

/// Tests for all the exhaustion-check failure messages emitted when side effects were not consumed.
@Suite("exhaustion failure messages")
struct ExhaustionFailureTests {

    @Test("unasserted scalar state change reports State not exhausted with value")
    func unassertedStateChange() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .state) {
                let model = SimpleCounter().withAnchor()
                model.count = 42
                await expect { }
            }
        } matches: {
            """
            State not exhausted: …

            Modifications not asserted:

                SimpleCounter.count == 42
            """
        }
    }

    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test("unasserted implicit-id child replacement: single diff message showing id change")
    func unassertedImplicitIdChildReplacement() async {
        // ModelID integers are non-deterministic, so we capture and normalize before snapshot.
        let reporter = CapturingIssueReporter()
        await withIssueReporters([reporter]) {
            await withModelTesting {
                let model = ItemHolder().withAnchor()
                model.item = SimpleCounter()
            }
        }
        let normalized = reporter.messages.joined(separator: "\n")
            .replacing(#/ModelID\(\d+\)/#, with: "ModelID(N)")
        assertInlineSnapshot(of: normalized, as: .lines) {
            """
            State not exhausted: …

                \u{2007} ItemHolder(
                \u{2007}   id: ModelID(N),
                \u{2007}   item: SimpleCounter(
                −     id: ModelID(N),
                +     id: ModelID(N),
                \u{2007}     count: 0
                \u{2007}   )
                \u{2007} )

            (Expected: −, Actual: +)
            """
        }
    }

    @Test("unasserted event reports event name and model type")
    func unassertedEvent() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .events) {
                let model = ExhaustionEventSender().withAnchor()
                model.tap()
            }
        } matches: {
            """
            Event `ExhaustionEventSender.Event.tapped` sent from `ExhaustionEventSender` was not handled
            """
        }
    }

    @Test("two active tasks report '2 active tasks' in summary line")
    func twoActiveTasksSummaryPlural() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .tasks) {
                let model = LongTaskRunner().withAnchor()
                model.startTasks()
            }
        } matches: {
            """
            Models of type `LongTaskRunner` have 2 active tasks still running
            Active task of `LongTaskRunner` still running (registered here)
            Active task of `LongTaskRunner` still running (registered here)
            """
        }
    }

    @Test("one active task reports '1 active task' (singular) in summary line")
    func oneActiveTaskSummarySingular() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .tasks) {
                let model = SingleTaskRunner().withAnchor()
                model.startTask()
            }
        } matches: {
            """
            Models of type `SingleTaskRunner` have 1 active task still running
            Active task of `SingleTaskRunner` still running (registered here)
            """
        }
    }

    @Test("named probe exhaustion message includes probe name with space-separated quote")
    func namedProbeExhaustionMessage() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .probes) {
                let onLoad = TestProbe("myLoader")
                let model = TraitLoader(onLoad: onLoad.call).withAnchor()
                model.load(value: "hello")
            }
        } matches: {
            """
            Failed to assert calling of probe "myLoader":
                "hello"
            """
        }
    }

    @Test("unnamed probe exhaustion message uses bare 'probe:' format")
    func unnamedProbeExhaustionMessage() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .probes) {
                let onLoad = TestProbe()
                let model = TraitLoader(onLoad: onLoad.call).withAnchor()
                model.load(value: "hello")
            }
        } matches: {
            """
            Failed to assert calling of probe:
                "hello"
            """
        }
    }
}

// MARK: - Timeout-path probe messages

/// Tests for the messages emitted when a `wasCalled(with:)` predicate times out.
@Suite("timeout-path probe failure messages")
struct TimeoutProbeFailureTests {

    @Test("probe with no values reports 'No available probe values'")
    func probeNoValues() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .off) {
                let onLoad = TestProbe()
                let _ = TraitLoader(onLoad: onLoad.call).withAnchor()
                await expect(timeoutNanoseconds: 1_000_000) {
                    onLoad.wasCalled(with: "hello")
                }
            }
        } matches: {
            """
            Failed to assert calling of probe:
                "hello"

            No available probe values
            """
        }
    }

    @Test("probe with one wrong value emits diff")
    func probeOneWrongValue() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .off) {
                let onLoad = TestProbe()
                let model = TraitLoader(onLoad: onLoad.call).withAnchor()
                model.load(value: "actual")
                await expect(timeoutNanoseconds: 1_000_000) {
                    onLoad.wasCalled(with: "expected")
                }
            }
        } matches: {
            """
            Probe does not match: …

                − "expected"
                + "actual"

            (Expected: −, Actual: +)
            """
        }
    }

    @Test("probe with multiple values lists all available probe values")
    func probeMultipleValues() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .off) {
                let onLoad = TestProbe()
                let model = TraitLoader(onLoad: onLoad.call).withAnchor()
                model.load(value: "first")
                model.load(value: "second")
                await expect(timeoutNanoseconds: 1_000_000) {
                    onLoad.wasCalled(with: "nonexistent")
                }
            }
        } matches: {
            """
            Failed to assert calling of probe:
                "nonexistent"

            2 Available probe values to assert:
                "first"
                "second"
            """
        }
    }

    @Test("named probe timeout message includes probe name with space-separated quote")
    func namedProbeTimeoutMessage() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .off) {
                let onLoad = TestProbe("myLoader")
                let _ = TraitLoader(onLoad: onLoad.call).withAnchor()
                await expect(timeoutNanoseconds: 1_000_000) {
                    onLoad.wasCalled(with: "hello")
                }
            }
        } matches: {
            """
            Failed to assert calling of probe "myLoader":
                "hello"

            No available probe values
            """
        }
    }
}

// MARK: - Unwrap timeout message

/// Tests for the failure message from `require` when the value stays nil.
@Suite("unwrap timeout failure messages")
struct UnwrapTimeoutTests {

    @Test("tester.unwrap timeout includes the type name")
    func unwrapTimeoutIncludesTypeName() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .off) {
                let _ = TraitLoader().withAnchor()
                _ = try? await require(nil as String?, timeoutNanoseconds: 1_000_000)
            }
        } matches: {
            """
            Failed to unwrap value of type String
            """
        }
    }
}

// MARK: - Out-of-scope usage messages

/// Tests for errors emitted when global functions or model methods are called outside their
/// required scope.
@Suite("out-of-scope usage messages")
struct OutOfScopeTests {

    @Test("expect() outside modelTesting scope reports clear error")
    func expectOutsideScope() async {
        await assertIssueSnapshot {
            await expect(true)
        } matches: {
            """
            expect() must be called inside a @Test(.modelTesting) test function
            """
        }
    }

    @Test("require() outside modelTesting scope reports clear error")
    func requireOutsideScope() async {
        await assertIssueSnapshot {
            _ = try? await require(nil as String?)
        } matches: {
            """
            require() must be called inside a @Test(.modelTesting) test function
            """
        }
    }

    @Test("withExhaustivity() outside modelTesting scope reports clear error")
    func withExhaustivityOutsideScope() async {
        await assertIssueSnapshot {
            await withExhaustivity(.off) { }
        } matches: {
            """
            withExhaustivity() must be called inside a @Test(.modelTesting) test function
            """
        }
    }

    @Test("didSend() outside assert block reports clear error")
    func didSendOutsideAssertBlock() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .off) {
                let model = EventSenderForOutOfScope().withAnchor()
                _ = model.didSend(EventSenderForOutOfScope.Event.tapped)
            }
        } matches: {
            """
            Can only call didSend inside a ModelTester assert
            """
        }
    }

    @Test("didSend() on unanchored model inside assert block reports clear error")
    func didSendOnUnanchoredModel() async {
        let unanchored = EventSenderForOutOfScope()
        let fileAndLine = FileAndLine(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
        let fakeContext = TestAccess<EventSenderForOutOfScope>.TesterAssertContext(events: { [] }, fileAndLine: fileAndLine)
        await assertIssueSnapshot {
            TesterAssertContextBase.$assertContext.withValue(fakeContext) {
                _ = unanchored.didSend(EventSenderForOutOfScope.Event.tapped)
            }
        } matches: {
            """
            Can only call didSend on a model that is part of a ModelTester
            """
        }
    }

    @Test("probe.wasCalled() outside assert block reports clear error")
    func probeWasCalledOutsideAssertBlock() async {
        let probe = TestProbe()
        await assertIssueSnapshot {
            _ = probe.wasCalled(with: "hello")
        } matches: {
            """
            Can only call wasCalled inside a ModelTester assert or expect block
            """
        }
    }

    @Test("probe.install() outside modelTesting scope reports clear error")
    func probeInstallOutsideScope() async {
        let probe = TestProbe()
        await assertIssueSnapshot {
            probe._install()
        } matches: {
            """
            install() must be called inside a @Test(.modelTesting) test function
            """
        }
    }
}

// MARK: - Assertion failed (no-access fallback)

/// Tests for the fallback message when a predicate fails without any property accesses.
@Suite("assertion failed fallback message")
struct AssertionFailedFallbackTests {

    @Test("false literal predicate emits 'Assertion failed'")
    func falseLiteralPredicate() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .off) {
                let _ = SimpleCounter().withAnchor()
                await expect(timeoutNanoseconds: 1_000_000) {
                    false
                }
            }
        } matches: {
            """
            Assertion failed
            """
        }
    }
}
