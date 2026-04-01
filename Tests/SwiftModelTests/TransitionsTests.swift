import Testing
@testable import SwiftModel

// MARK: - Test models

/// A model that sets `isLoading` around an async task, representative of real loading patterns.
@Model
private struct LoadingModel {
    var isLoading = false
    var result: String? = nil

    /// Spawns a task that sets `isLoading` to `true`, performs work, sets `result`, then
    /// sets `isLoading` back to `false`. Produces two consecutive state transitions on
    /// `isLoading`: false → true, then true → false.
    func load() {
        node.task {
            isLoading = true
            try? await Task.sleep(nanoseconds: 1_000)
            result = "loaded"
            isLoading = false
        }
    }
}

// MARK: - Passing tests (correct patterns)

/// Tests for `.transitions` exhaustivity mode (FIFO history-based assertions).
///
/// `.transitions` mode makes `expect` evaluate against recorded history in FIFO order
/// rather than the live model value. Each property write appends a queue entry; assertions
/// pop entries from the front. This ensures all intermediate state transitions are verified
/// and eliminates the race where `expect { !model.isLoading }` fires on the initial
/// `false` value before the loading task has even started.
@Suite(.modelTesting(exhaustivity: .adding(.transitions)))
struct TransitionsTests {

    // MARK: Direct-mutation patterns

    /// The correct two-step pattern: assert `true` first, then `false`.
    /// Each `expect` pops the front FIFO entry; both transitions consumed → clean.
    @Test func twoStepPatternPasses() async {
        let model = LoadingModel().withAnchor()
        model.isLoading = true
        model.isLoading = false
        await expect { model.isLoading }   // consumes false → true
        await expect { !model.isLoading }  // consumes true → false
    }

    /// Setting the same property multiple times — each intermediate value must be asserted.
    @Test func multipleWritesRequireMultipleAssertions() async {
        let model = LoadingModel().withAnchor()
        model.result = "first"
        model.result = "second"
        model.result = "third"
        await expect { model.result == "first" }   // consumes nil → "first"
        await expect { model.result == "second" }  // consumes "first" → "second"
        await expect { model.result == "third" }   // consumes "second" → "third"
    }

    // MARK: Async task pattern

    /// Full load cycle with a real async task. Both `isLoading` transitions must be asserted.
    ///
    /// This works regardless of task timing:
    /// - If task completes first: history already has [false→true, true→false]. Both
    ///   `expect` calls pass immediately by replaying history in order.
    /// - If task hasn't started: queue is empty, `expect` waits until the task runs and
    ///   writes `isLoading = true`, then waits for `isLoading = false`.
    @Test func asyncTaskBothTransitionsAsserted() async {
        let model = LoadingModel().withAnchor()
        model.load()
        await expect { model.isLoading }   // waits for / replays false → true
        await expect { !model.isLoading }  // waits for / replays true → false
        await expect { model.result == "loaded" }
    }
}

// MARK: - Non-transitions mode regression

/// Regression tests ensuring default `.full` exhaustivity (no `.transitions`) is unaffected.
///
/// In non-transitions mode the predicate always sees the live model value, so a single
/// assertion for the final value is sufficient regardless of how many intermediate writes
/// occurred.
@Suite(.modelTesting)
struct NonTransitionsRegressionTests {

    /// Multiple writes followed by a single final-value assertion — the pre-transitions pattern.
    @Test func finalValueAssertionSuffices() async {
        let model = LoadingModel().withAnchor()
        model.isLoading = true
        model.isLoading = false
        // Live value is false; single assertion is enough — no FIFO overhead.
        await expect { !model.isLoading }
    }

    @Test func multipleWritesFinalValueSuffices() async {
        let model = LoadingModel().withAnchor()
        model.result = "a"
        model.result = "b"
        model.result = "c"
        await expect { model.result == "c" }
    }
}

// MARK: - Failure-output snapshot tests

#if !os(Android)
import IssueReporting
import InlineSnapshotTesting

/// Snapshot tests for the failure messages emitted when transitions-mode assertions are wrong.
@Suite("transitions mode failure messages")
struct TransitionsFailureTests {

    /// Asserting only the final state when there is an unasserted intermediate transition
    /// produces an exhaustion failure listing the skipped entry.
    @Test("unasserted intermediate transition: exhaustion reports skipped entry")
    func unassertedIntermediateTransition() async {
        await assertIssueSnapshot {
            await withModelTesting(exhaustivity: .adding(.transitions)) {
                let model = LoadingModel().withAnchor()
                model.isLoading = true
                model.isLoading = false
                // Correct: `await expect { model.isLoading }` first, then `!model.isLoading`.
                // Wrong: skip the intermediate true → immediately assert false.
                // Result: first expect { model.isLoading } passes, exhaustion fires for true→false.
                await expect { model.isLoading }
                // Missing: await expect { !model.isLoading }
            }
        } matches: {
            """
            State not exhausted: …

            Modifications not asserted:

                LoadingModel.isLoading: true → false
            """
        }
    }

    /// Asserting the final `false` before asserting the intermediate `true` times out,
    /// because the FIFO front presents `true` and the predicate `!model.isLoading` fails.
    @Test("asserting final value before intermediate: expect times out")
    func assertFinalBeforeIntermediate() async {
        await TestAccessOverrides.$hardCapNanoseconds.withValue(50_000_000) {
            await assertIssueSnapshot {
                await withModelTesting(exhaustivity: .adding(.transitions)) {
                    let model = LoadingModel().withAnchor()
                    model.isLoading = true
                    model.isLoading = false
                    // Predicate sees FIFO front to=true; !true = false → never passes.
                    await expect { !model.isLoading }
                }
            } matches: {
                """
                Expectation not met: LoadingModel.isLoading == true
                State not exhausted: …

                Modifications not asserted:

                    LoadingModel.isLoading: false → true

                    LoadingModel.isLoading: true → false
                """
            }
        }
    }
}
#endif
