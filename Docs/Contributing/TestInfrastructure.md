# Test infrastructure

Contributor notes on the testing framework internals: when to use `ModelTester` directly, the `GlobalTickScheduler`, timeouts and scaling, and the known load-sensitive tests. Read before touching `Sources/SwiftModel/Testing/`, the executor drive, or when investigating a flaky test.

## `ModelTester` directly — only for specific cases

Direct use of `ModelTester(model, ...)` (requires `@testable import SwiftModel`) is reserved for two scenarios:

1. **Post-deallocation verification**: Tests that need the model to actually be released to observe lifecycle behavior — teardown logs (`"d:tag"`), `onCancel` callbacks, stream termination. `@Suite(.modelTesting)` holds a strong reference for the full test duration, preventing deallocation. Use the `waitUntilRemoved` pattern with `withAnchor()`:

   ```swift
   // Do NOT put this in @Suite(.modelTesting) — it would hold the context alive.
   struct MyLifetimeTests {
       @Test func testTeardown() async {
           let testResult = TestResult()
           await waitUntilRemoved {
               MyModel().withAnchor {
                   $0.testResult = testResult
               }
           }
           // Assert post-deallocation behavior
           #expect(testResult.value.contains("d:tag"))
       }
   }
   ```

   Files currently in this category: `UniquelyReferencedTests`, `ModelDependencyTests`, `ModelDependencyBehaviourTests`, `ObserveAnyModificationLifetimeTests`.

2. **Testing the testing framework itself**: `OutputSnapshotTests` uses `withModelTesting` + `assertIssueSnapshot` to capture and snapshot the failure messages produced by the framework. The `didSendOnUnanchoredModel` test requires direct access to `TestAccess.TesterAssertContext` internals.

## Timeouts and `SWIFT_MODEL_TIMEOUT_SCALE`

A per-test 30 s wall-clock cap is enforced by the `.modelTesting` trait. Hangs surface as `[TRAIT timeout]` rather than freezing CI. Override the absolute value via the `SWIFT_MODEL_TEST_TIMEOUT` env var (seconds, float).

**`SWIFT_MODEL_TIMEOUT_SCALE`** — multiplier on every test-infrastructure timeout: `expect` (5 s default), in-test `settle` (5 s), cleanup `settle` (25 s), trait cap (30 s), `waitUntil`'s drive backstop (120 s), the drive's termination ceiling (2× the trait ceiling), the meta-test bounds, and **every `waitUntil` call** (default 5 s and any explicit `timeout:` arg). Note the drive's *fail* verdicts are evidence-based, not wall-clock (runaway-fire bound; see `Docs/test-determinism-executor-drain.md` Update 27) — the scale only stretches backstops and budgets, never the discriminator. Defaults to `1.0` for fast local feedback. CI sets this to `3` so the `.deferential` `.background` QoS callbacks have wall-clock to actually fire on small parallel-saturated runners. Bump to 2–4 in any environment where you see meta-test or budget timeouts that aren't real bugs. Explicit `waitUntil(..., timeout: X)` is scaled too — that's deliberate, so individual tests don't need to know about CI tolerance.

## `GlobalTickScheduler` (GTS) — settle's deadline source

`Sources/SwiftModel/Internal/GlobalTickScheduler.swift` is the GCD-backed deadline scheduler that every wait primitive (`expect`, `settle`, `waitUntil`, the per-test trait cap) routes through. Key design points worth knowing before touching it:

- **One-shot timer source, not periodic.** The timer is armed for the soonest pending deadline; after each fire it re-arms to the next-soonest, or stops if no deadlines remain. Zero idle CPU; natural coalescing when many deadlines cluster within tens of ms.
- **Timer fires at `.userInitiated` QoS** so deadlines surface promptly regardless of cooperative-pool load.
- **Per-callback execution priority.** Each scheduled entry carries a `CallbackPriority`:
  - `.responsive` (default) — callback runs inline on the timer's `.userInitiated` GCD queue. Used for the 30 s trait cap, polling (`waitUntil`), and `expect`'s 5 s budget callback. `expect` is purely reactive, so a wall-clock fast-fail at the budget is the correct signal — if the predicate hasn't been re-evaluated by then, the test is genuinely stuck.
  - `.deferential` — callback hops to `DispatchQueue.global(qos: .background)` before executing. Used by **in-test** settle's quiet-window check. The failure signal should only fire once higher-priority cooperative-pool work has drained — otherwise we'd declare "stuck" based on wall-clock without consulting the scheduler signal we built the mechanism to listen for. Under parallel test execution, fast-fail on wall-clock provides no benefit (the test slot would have been busy with other tests' work regardless), so deferring to `.background` is strictly an improvement. Predicate evaluation itself stays inline on every `_noteActivity`, so the happy-path latency is unchanged.
- **Cleanup settle uses `.responsive`** — by the time `checkExhaustion` runs, `cancelAllRecursively` has torn down active tasks and the 200 ms cleanup window absorbs cancel-handler writes naturally. Deferring here would stall every test's teardown behind the `.background` queue's drain cadence, producing visible test-bunching clusters.
- **No load-aware scaling, no multipliers.** `GTS` doesn't track or apply a `load_factor`. Adaptation under load lives entirely in the OS scheduler's QoS prioritisation of `.background` work. This is deliberate — earlier iterations with scaling caused either feedback loops (2024 "congestion debt") or fragile one-spike-pins-a-deadline-for-seconds patterns.
- **Diagnostic tracing**: set `SWIFT_MODEL_GTS_TRACE=1` to write per-event logs to `/tmp/swift-model-gts-trace.log` and `/tmp/swift-model-settle-trace.log`. Tags every `schedule`, `armTimer`, `fire`, `_quietDeadline` call with absolute monotonic-ns timestamps for correlating settle latency with GTS scheduling.

## Known load-sensitive tests under extreme parallel stress

The full suite is **clean on both serial and parallel CI**, and clean on local sub-x100 parallel runs. A small set of tests can flake at extreme parallel stress on a developer machine (x1000+) — typically because the test asserts a timing property that depends on the cooperative pool's scheduling cadence, which we don't control. None block CI.

**Resolved (drive path):** the four clock-driven tests that previously headed this
list — `ClockTests.testImmediateClock`, `ChildActivationTaskTests.childTasksCompleteBeforeTeardown`,
`ClockTests.testClockStepByStep`, `OnChangeTests.testOnChangeCancelPreviousDiscardsStalework`
— are now stable on the drive via two distinct mechanisms, because they were two
distinct classes of problem:

- **Premature-fixpoint (work routed *through* the executor)** — `testImmediateClock`
  and `childTasksCompleteBeforeTeardown`. Their pending work (immediate-clock ticks,
  child activation tasks) runs on the drain executor, so it's countable. Fixed by the
  **global-quiescence fail-gate** in `TestExecutorDrive.swift`: a still-unmet `expect`
  is only failed once the *whole process* is executor-quiescent (`_globalOutstanding == 0`
  across all parallel tests + no global activity for the grace), not merely when the
  one test looks idle. A child parked mid-`clock.sleep` while the run is busy no longer
  trips a false fixpoint — the fail defers until the work actually completes and the
  predicate passes reactively. The global counter is a relaxed Swift 6 `Atomic` (lock-free
  hot path on every enqueue/completion).
- **TestClock registration ordering (work parked *off* the executor)** — `testClockStepByStep`
  and `testOnChangeCancelPreviousDiscardsStalework`. Their pending work is a `TestClock`
  deadline, invisible to *any* executor-quiescence accounting, gated by an
  `advance`-vs-`subscribe` race (the consumer must register its `clock.sleep` before the
  test advances). This is a TestClock scheduling property, not a model invariant, so it's
  fixed **test-side**: `await settle()` after `withAnchor` and between steps parks the
  timer (registering its next deadline) before each `advance`. This is the documented
  `settle()`-after-`withAnchor` pattern; the old code relied on `Task.yield()` ordering
  (the point-free `megaYield` gamble) to win the race, which parallel load loses.

The discriminator for any new clock/timing flake: **is the pending work routed through
our executor?** If yes, the drive/global-gate owns it (a real framework responsibility —
don't paper over it with a manual `settle()`). If it's parked on an external clock with a
registration race, the test owns the ordering (`settle()` before `advance`).

The remaining flake surface is tests where the assertion's success depends on a quantity of cooperative-pool work (ticks, sleeps, task starts) that under x1000 saturation can't all be scheduled within the wall-clock budget:

  • `MemoizeDirtyObservationTests.testDirtyPathWithOnModifyCallback` — `#expect(updateCount.value >= 1)` after a 5 s poll for a memoize-coalesced `performUpdate` to fire its `onModify` callback.
  • `MemoizeTests.testMemoizeWithNestedModelMutations` (`.accessCollector`) and `testMemoizeWithBranchingDependencies_WithAnchor` (`.withObservationTracking`) — both wait on `expect` that the memoize's recompute has settled to the expected final value after rapid-fire mutations. Under parallel-test load the OT `performUpdate` Task and the test's `expect` evaluator interleave in ways that can let the predicate see partial state; rate ~1–2/100 at x100 parallel.
  • `StandupsTests.testRecordTranscript` / `testSpeechRecognitionFailure_Continue` (Examples/Standups) — `await clock.advance(by: .seconds(6))` releases 6 timer wake-ups at once; under x1000 saturation the 6 tick-processing steps don't all get CPU slots before the next `expect`'s budget expires.
  • `DualRegistrarTests.testObservedStreamWithModelAccessingObservable` — Observable interop, not officially supported. Listed for completeness; expected to flake.
  • `UpdateStreamTests.testRaceVariant` (and `testRace`) — two unstructured `Task {}` (one writes `count = 7`, one starts a `forEach(Observed)` collector) racing the Observed registration gap; asserts convergence (`counts.last == 7`). A lost update in the gap (rare, ~per-1000) fails it. Pre-existing on both flag states; not specific to the executor-drive.

These are a small remnant of a much larger tail that the executor-drive removed: on the legacy wall-clock path (which now survives only as the automatic fallback for test hosts that can't run the drive — pre-macOS-15 / pre-iOS-18 / older Swift / WASM), the dev-machine `--parallel` flake population was ~5–10× larger. The drive is the unconditional default wherever it can run; there is no opt-out flag. See `Docs/test-determinism-executor-drain.md`.

When investigating new load flakes, check first whether the test matches this pattern (asserting a property whose truth requires N cooperative-pool slots to land within a fixed wall-clock budget, or relying on coalescing/observation timing that the cooperative scheduler doesn't guarantee) before chasing a library bug.

**Never hard-code a *shorter-than-default* `waitUntil(..., timeout:)` in a
drive-less suite.** `waitUntil` only becomes load-tolerant when the executor-drive
is installed — and the drive is installed by `ModelTestingTrait` **only**. A suite
written without `@Suite(.modelTesting)` falls back to the plain wall-clock budget
`timeout × SWIFT_MODEL_TIMEOUT_SCALE`. Two families of suite are drive-less:
the `waitUntilRemoved` / post-deallocation pattern (`ModelDependencyTests`,
`ModelDependencyOverrideTests`, `ReduceHierarchyTests`, …), and suites carrying
only `.backgroundCallIsolation` (`MemoizeDirtyObservationTests`) — that trait
swaps a `BackgroundCallQueue` task-local and installs no executor. An explicit timeout
*shorter* than the 5 s default is therefore a fixed budget with no scheduler signal
behind it, and scaling only stretches that smaller base: 3 s becomes 18 s on the TSan
job (scale 6) where the default would give 30 s, and TSan's 5–15× slowdown plus
parallel execution on a 2–3 core runner can exceed 18 s. That is exactly how `ModelDependencyOverrideTests.sharedInjectedDepActivatedOnce`
flaked on 2026-08-13 (run 31711303262, no TSan report — a bare timeout). Omit the
argument and inherit the 5 s default unless a test genuinely needs a *longer* one.
