# Test determinism: from wall-clock quiescence to executor-drain quiescence

**Status:** design note + validated spike (branch `claude/spike-drain-executor`).
**Audience:** SwiftModel maintainers.
**TL;DR:** `.modelTesting`'s load-sensitivity is not a bug in any one wait
mechanism — it is intrinsic to *defining "the model has reacted" as "the wall
clock saw no activity for a debounce window."* Model work runs on the
uncontrolled cooperative pool; "done" is inferred from the wall clock. Those
are two independent clocks that desynchronise under load. The durable fix is to
let the **test harness own the execution** of model work and define quiescence
as a **logical executor fixpoint** (drive-to-completion), not a wall-clock
window. A spike validates the core primitive: complete and load-independent.

---

## 1. Symptom

`@Test(.modelTesting)` suites intermittently fail under machine load — most
visibly on shared/self-hosted CI when a second `xcodebuild` runs concurrently.
Failures take two shapes:

- **`settle()` false timeout** — `settle() timed out: model still has active
  tasks` with an *empty* active-task list (the model had actually gone idle; the
  `.deferential` quiet-window confirmation was starved on the `.background`
  queue). `-retry-tests-on-failure` re-runs into the same condition and the job
  blows its wall-clock budget.
- **`expect` can't observe model work in time** — the documented "known
  load-sensitive tests" (`CLAUDE.md`): `ClockTests.testImmediateClock`,
  `ChildActivationTaskTests.childTasksCompleteBeforeTeardown`, the Standups
  `clock.advance(by: 6s)` cases, etc. Their assertions need *N cooperative-pool
  slots to land within a fixed wall-clock budget*; under saturation they don't.

Both are the **same** failure.

## 2. Root cause

Model reactions execute on the **shared, uncontrolled Swift cooperative pool**
(`Cancellables` spawns every `node.task`/`forEach` body with bare
`Task`/`Task.detached`, no executor preference; the `CallQueue` /
`BackgroundCallQueue` pumps use `Task.detached(priority: .userInitiated)`). But
tests decide **"the reaction is done" using the wall clock** (`waitUntilSettled`
debounce; `expect`'s 5 s budget).

Two independent clocks. On an unloaded machine they coincide; under load they
desynchronise, and **no amount of tuning the second clock fixes a dependence on
the first.** `CLAUDE.md` already states the true shape of it: *"a property whose
truth requires N cooperative-pool slots to land within a fixed wall-clock
budget."*

This also explains why *"settle needs waiting by nature"* feels true: it needs
waiting **only because the work was handed to a pool we don't control**, so the
only way to learn it finished is to watch a clock and infer.

## 3. Every prior attempt was measurement-side

A partial history (commit refs on `main`):

| Attempt | Commits | Category |
|---|---|---|
| Increase / "patience" timeouts | `9a10423`, `5ed9a85`, `3f6acfb` | wait longer |
| Global `SWIFT_MODEL_TIMEOUT_SCALE` knob | `e35f639`, `eda289e` | wait longer (scaled) |
| Adaptive **calibration** (measure pool latency, scale) | `20bcb31`, `169e278` — *since removed* | wait longer (adaptive) |
| Priority-queue tuning (`.deferential`/`.background`) | `f6000db`, GTS design | when to give up |
| `yieldToScheduler` / Dispatch hops | `fae431e`, `ff0183d` | how to wait |
| GCD-backed `GlobalTickScheduler` | `f6000db` | non-starvable *deadlines* |
| Serial **and** parallel CI matrix | `0c461ec`, `c004ce6` | avoid contention |
| `.responsive` budget-cap backstop | `bdc6f4a`, `7136d94` | fail faster |

Every one changes **how long / at what priority / with what backstop we wait to
observe quiescence**. None changes **what runs the work being waited on.** So
each relocates the flake instead of removing it — and the end state is a
*documented list of known-flaky tests* rather than zero. Falling back to serial
CI "feels like a failure" because it is a workaround for a correctness model
that isn't load-independent.

## 4. The foundational shift: drive-to-completion

Stop *inferring* quiescence from the wall clock. Instead **own the execution**
of model work in tests and **run it to a fixpoint**.

- In `.modelTesting`, give model-spawned tasks a **`TaskExecutor` preference**
  (SE-0417) pointing at a **per-test harness executor**.
- Define quiescence as an **executor fixpoint**: drain the ready queue (plus the
  MainActor call queue and the bg pipeline) until no ready job remains. A slow
  machine takes more wall-time to drain the *same finite* set of jobs — the
  *answer is identical*. **Load-independent by construction.**
- The only remaining cap is a **logical step cap** (a runaway re-enqueues
  forever and never reaches a stable empty queue) — deterministic on every
  machine, and the wall clock is demoted to a last-resort guard for genuinely
  stuck *external* async (a real test bug).

The reactive ergonomics survive:

| Verb | Today | Proposed |
|---|---|---|
| `expect { }` | evaluate; wait up to 5 s wall-clock | drain until predicate true **or** fixpoint, then evaluate |
| `settle()` | wait for 50 ms wall-clock quiet window | drain to fixpoint |
| end-of-test exhaustivity | `cancelAll`; wait up to 25 s | `cancelAll`; drain to fixpoint; check |
| runaway | hits wall-clock budget | hits **logical** step cap (deterministic) |

This collapses three wall-clock budgets (expect 5 s / settle 5 s / cleanup 25 s)
+ `SWIFT_MODEL_TIMEOUT_SCALE` + the `.deferential`/`.background` QoS dance into a
single `drainToQuiescence()`.

### Why this *fixes* parallel rather than threatening it

Today parallel is unsafe because all tests' model work shares one pool and
"done" is wall-clock-bounded, so serial is the only correctness guarantee. With
**per-test owned execution + fixpoint quiescence, determinism is per-test and
load-independent**: parallel tests contend for CPU (slower wall-time) but each
drains its *own* finite work deterministically. Parallel becomes correct **by
construction**; serial demotes from *the* safety gate to a speed / odd-race
check. The parallel-execution differentiator (vs TCA's enforced `@MainActor`)
is preserved — and finally trustworthy.

## 5. Spike evidence (`claude/spike-drain-executor`)

`Tests/SwiftModelTests/SpikeDrainExecutorTests.swift` validates the load-bearing
unknown in isolation. `DrainTaskExecutor` counts outstanding ready jobs;
`waitUntilQuiescent()` hops barriers on its own serial queue until the ready
queue stays empty twice (fixpoint) or a logical step cap trips (runaway). No
wall clock in the decision.

| Test | Claim | Result |
|---|---|---|
| **A** drain completeness under load | after `waitUntilQuiescent()`, every task in a depth-3/breadth-3 tree (5 suspension points each) completed | 150 iters/run × 3 runs = **450 completions, 0 flakes**, half the cores saturated |
| **B** logical runaway cap | `while { await Task.yield() }` never reaches a stable empty queue → caught by the **step count**, not a clock | deterministic — the case the budget-cap patch *couldn't* distinguish from idle |
| **C** honest caveat | a task parked on an **off-executor** GCD timer empties the queue → premature fixpoint | confirmed → **controlled dependencies are a hard rule** |

## 6. Honest risks / what real wiring must clear

> **Update — end-to-end wiring attempted; NEGATIVE result (valuable).** Branch
> `claude/spike-drain-executor` also contains a first end-to-end wiring (INERT by
> default; opt in with `SWIFT_MODEL_EXPERIMENTAL_DRAIN=1`): model task spawns
> (`Cancellables`) take an `executorPreference` to a per-test executor via a
> `_TestExecutorBox` task-local set by the trait, and `expect`/`settle` drive it
> via `_startExecutorDrive`. With the flag on, it **deadlocks real model
> settle/teardown** — `SettlingTests` time out and
> `ChildActivationTaskTests.childTasksCompleteBeforeTeardown` hits the trait
> wall-clock cap. Cause: a **single serial-queue** executor does not compose with
> real model work — model **context locks**, the **off-executor bg pump**
> (`BackgroundCallQueue`/`Task.detached`, which ignores executor preference), and
> **`@MainActor` hops** can leave the one serial thread blocked. The isolated
> primitive (Tests A/B/C) remains sound; the lesson is the executor must be a
> **counted *concurrent* executor**, and the fixpoint must **union the bg and
> MainActor queues** — risks #1/#2 below are not optional. The wiring is left in,
> inert and flagged, as the substrate for that next iteration; the end-to-end
> test is `.disabled` with this finding.

> **Update 2 — concurrent executor + union fixpoint: STILL not working (second
> negative result).** Iteration 2 made the executor **concurrent** (to kill the
> serial head-of-line deadlock) and made the `expect` drive's fixpoint the
> **union** of executor-idle + `BackgroundCallQueue.isIdle` + `MainCallQueue.isIdle`
> + `!hasPendingStartTask`. With the flag on it *still* fails: `SettlingTests`
> time out and `childTasksCompleteBeforeTeardown` now **hangs to the 30 s trait
> cap** — i.e. the child `onActivate` tasks **never run to completion on the
> custom executor at all**. So the blocker is not the executor's shape; it's that
> **model tasks don't make progress when moved off the default cooperative pool**
> — most likely an actor-isolation / clock-resumption interaction (the child
> awaits `node.continuousClock.sleep`, whose continuation must resume back onto
> the preferred executor), and possibly that `settle` itself still resolves via
> the wall-clock quiet-window rather than the drive. Diagnosing this needs real
> instrumentation (GTS/settle tracing, confirming `enqueue`/resumption actually
> fire for a task that hops through `ImmediateClock`/`@MainActor`), **not** more
> blind rebuild cycles. The wiring remains inert-by-default (flag off ⇒ suite
> green, verified); the experimental path is parked here pending that
> investigation. **Revised conclusion: the executor migration is a deeper rework
> than "add executorPreference + a drive" — it also requires making `settle`
> drive-based and solving task-progress-on-a-custom-executor — and is best done
> with a maintainer pairing + tracing, not autonomous trial-and-error.**

> **Update 3 — RESOLVED: end-to-end works (iteration 3).** A layered
> micro-diagnosis (`DiagExecutorClockTests`) refuted the clock-resumption
> hypothesis — a bare `Task(executorPreference:)` over `ImmediateClock`/
> `ContinuousClock` sleeps resumes on the executor fine, and a *real* `@Model`
> `node.task` polled directly **completes** on the executor. So the hang was not
> the tasks; it was the **drive itself**: it used `queue.async(flags: .barrier)`
> to detect idle, and on a concurrent queue a barrier is a read-WRITE barrier
> that **blocks all other jobs while pending** — so polling with it throttled the
> very model work we were waiting on. Fix: detect idle with the **outstanding
> counter + an event-driven, cancellation-aware `waitUntilIdle()`** (resume
> waiters when the count hits 0), never a barrier. With that, the flag-on path is
> green on the targeted suites **including under deliberate CPU load**:
> `ChildActivationTaskTests` (previously hung), `SettlingTests` (previously timed
> out), the runaway `settleInfiniteChangesTimeout` (still correctly reported),
> and the end-to-end load-stressed `realModelChildTasksAreLoadIndependentEndToEnd`
> (40 iterations under load). In the same machine-load moment, the flag-OFF
> (wall-clock) path *flaked* `SettlingTests` while flag-ON stayed green —
> the thesis demonstrated live. Note: `settle` benefits transitively — its
> predicate phase (`expect` with empty predicates) drives the executor to a
> fixpoint, so its wall-clock quiet-window has nothing left to wait on. Still
> opt-in; remaining to reach full quality: the full suite under load, flip the
> default on, then parallel-apple + the parallel-CI flip.

> **Update 4 — full-PARALLEL gate fails; the real remaining scope is exposed.**
> Iteration 3 is green on *targeted* suites under load, but the **full suite
> run in parallel** (91 suites / 813 tests, the actual goal) fails broadly —
> first with per-test concurrent queues exploding GCD's thread pool, then, after
> backing all executors with **one shared concurrent queue** (iteration 4),
> still ~288 failures: `settle() timed out` *and* `Timeout after 3–5 s waiting
> for condition` in `waitUntil`-based tests. Root cause: **moving model work to a
> custom executor doesn't add capacity — it relocates the same contention** —
> and, decisively, **the drive is only *additive*: every wait still carries a
> wall-clock deadline** (`expect` 5 s, `settle` 5 s, `waitUntil` 3–5 s; the last
> isn't wired to the drive at all). Under full parallel, those wall-clock budgets
> are the binding constraint, so load still fails them regardless of the executor.
>
> **Revised, honest scope:** true load-independence under parallel requires the
> step the design note calls "make the drain the PRIMARY resolution" — i.e.
> **rewrite every wait primitive (`expect`, `settle`, `waitUntil`, exhaustion) to
> resolve on the executor/queue *fixpoint*, demoting the wall clock to a generous
> last-resort hang-catcher (e.g. 60 s)** — not an additive drive alongside the
> existing 5 s budgets. That is a substantial rework of the wait core
> (`TestAccess`/`TestExpect`/`TestWaitSupport`), and it's the genuine remaining
> work. The primitive and small-scale end-to-end are validated; the wait-core
> migration is not done. Parked here (inert by default); this is the point where
> a maintainer who owns the wait core should drive the rewrite.

> **Update 5 — the firing semantics are proven, and they redirect the design
> AWAY from the executor.** Clarified intent: the per-wait timeouts are internal
> and arbitrary; under load they may take *as long as necessary*; in the happy
> case they never fire; a broken test/refactor should fire *fast when a human
> runs one test* and correctly under CI load. That reframes the "timeout" as a
> **fixpoint check, not a time budget**: resolve *pass* when the target is met,
> resolve *fail* the moment the model is **quiescent with the target still
> unmet**; the wall clock is only a last-resort hang-catcher.
>
> Stage 1 made `expect` fixpoint-primary (fail when quiescent-but-unmet; wall
> clock pushed to a 600 s backstop). **It works for the firing semantics** — an
> unsatisfiable `expect` failed in **247 ms**, not 600 s (Test E). But it
> *false-failed healthy* tests (`childTasks`), and the cause is decisive:
>
> **An instantaneous "executor idle (`outstanding == 0`)" is a PREMATURE
> fixpoint.** A task suspended at `await clock.sleep` (even `ImmediateClock`) is
> not a ready job, so when several child tasks are momentarily suspended
> mid-sleep the counter reads 0 and the drive declares "fixpoint" while the work
> is actually in flight — resolving "unmet" there is a false failure. Tasks
> suspend and resume; a single idle instant cannot mean "done."
>
> **This is exactly why SwiftModel already uses a DEBOUNCED quiet window** (a
> suspended task that resumes does activity within the window and re-arms it). So
> the correct fixpoint detector is the **existing quiet window** (debounced over
> `_noteActivity` = writes + task-body-starts + enqueues), **not a custom
> executor** — the executor's idle count is both unnecessary and *worse*
> (premature). 
>
> **Recommended direction (supersedes the executor route):** make
> `expect`/`settle`/`waitUntil` resolve on the **quiet-window fixpoint with the
> total budget removed** — i.e. wait as long as needed for the model to go quiet
> (only a generous hang backstop, e.g. the trait cap), and **fail `expect` when
> the model is quiet but the predicate is still unmet**. This reuses the
> mechanism SwiftModel *already* relies on for `settle` (`awaitSettled`:
> quiet-window + bg-idle), drops the executor wiring entirely, and avoids the
> premature-fixpoint false failures. It is *less* invasive than the executor
> migration. The executor spike (Tests A–E, iterations 1–4) remains as the
> investigation record that led here; it should not ship.

> **Update 6 — runtime balance: resolve EVENT-DRIVEN, don't pay a fixed
> debounce.** Constraint raised: many tests call `settle()` several times;
> stability matters most, but the fix must not make tests wait unnecessarily
> (N settles × a fixed window × many tests = real total-runtime cost). Note the
> status quo *already* pays this — `awaitSettled` always arms a 50 ms quiet
> window and waits it out even when the model is already quiet.
>
> Resolution: don't keep the fixed debounce as the primary latency. Resolve a
> wait **event-driven, the instant the model is genuinely quiescent**, via an
> **authoritative in-flight signal** — the *correct* version of what the executor
> attempted. The executor counted **ready jobs** (premature: a task suspended at
> `clock.sleep` reads as 0). Instead count **in-flight TRANSIENT tasks from
> registration until completion**, so a suspended-mid-await task still counts
> (fixes the premature-fixpoint bug), and a wait resolves the moment that count
> hits 0 ∧ bg idle ∧ main idle ∧ no pending-start. SwiftModel's `TaskCancellable`
> infra already separates the relevant kinds: `node.task` bodies and `forEach`
> **inner per-element** bodies are transient (counted = "work happening now");
> `forEach`'s outer loop / `onChange` consumers parked awaiting the next element
> are long-lived (excluded — parked ≠ busy). Outcome: happy-path settles are
> near-instant (often *faster* than today's 50 ms floor → shorter total
> runtime); broken assertions still fail fast at quiescence; under load it waits
> as long as needed (no budget, hang-backstop only); the 50 ms debounce drops to
> a *fallback* for genuinely ambiguous cases. Stability first, without
> unnecessary waiting.

> **Update 7 — CORRECTION: the debounce is fundamental; completion-counting
> cannot replace it.** Update 6's "resolve event-driven on an in-flight transient
> count, drop the debounce" is **unsound**. A supported pattern — a long-lived
> user `node.task { while !cancelled { let x = await stream.next(); self.y = x } }`
> — *never completes*, so a registration→completion count never returns to 0 and
> the wait would hang. `CLAUDE.md` states this is supported: long-lived consumers
> "correctly settle … as long as they aren't currently writing." Classification
> can't save it: `forEach`/`onChange` are framework-known-long-lived, but a user
> `node.task` may be transient OR a `while` loop and is indistinguishable at
> spawn. Only the **debounce quiet-window** correctly settles a parked long-lived
> consumer *and* waits out a suspended-mid-`sleep` transient. So the debounce
> stays; the runtime win is a fast-path (zero-registered-tasks → immediate) and
> possibly a shorter window — NOT eliminating the debounce.
>
> **Corrected sound plan (priority = stability + load-independence):**
> 1. Keep the debounce quiet-window as the detector.
> 2. Remove the total budget; replace the hang-catch with an **inactivity
>    watchdog** — fail after X s of *zero* activity (writes, task starts/ends),
>    reset on any progress. Slow-but-progressing never trips; a true deadlock
>    (no activity) trips at X. Load-independent and deadlock-catching.
> 3. Make the quiet-window confirmation **non-starvable** (drop the
>    `.deferential`→`.background` QoS hop for `.responsive`).
> 4. `expect` fails when **quiescent-but-unmet** (fast interactive failure).
> 5. Drop the executor (premature/wrong detector).
> 6. Runtime: fast-path immediate return when zero registered tasks; debounce
>    window stays (tunable).
> Open tuning (maintainer judgment): the watchdog duration X, and whether to
> shorten the debounce window.

> **Update 8 — EVALUATION: budget-scaling is refuted; `.background` starvation
> is the unbounded disease; the executor-drain is the only resolution.** Ran the
> full suite in PARALLEL with `SWIFT_MODEL_TIMEOUT_SCALE=100` (every budget ×100,
> executor OFF — pure existing code). Result: **93 unexpected failures, 23-minute
> runtime, and 72 are still `settle() timed out: model still has active tasks`**
> — at a 500 s budget. A model's real work never takes 500 s, so the budget is
> not the constraint: settle's quiet-check runs `.deferential` →
> `DispatchQueue.global(qos: .background)`, which macOS starves **indefinitely**
> under parallel load, so the confirmation never fires and the `.responsive`
> backstop trips the false timeout at *any* budget. **Scaling (the lever this
> project has relied on for years) cannot fix this**; it only makes the run
> pathologically slow.
>
> The tension this exposes: `.deferential`/`.background` is *race-safe* (lets an
> about-to-write task run before the quiet-check) but *starvable*; `.responsive`
> is *non-starvable* but reintroduces the toggleExpanded race. **Neither is both
> via QoS.** The only mechanism that is both is the **executor-drain**: it *runs*
> ready work to a fixpoint deterministically rather than *observing* quiescence
> through a starvable callback — an about-to-write task is a ready job, so the
> drain runs it, then the check sees the write. Iteration 3 confirmed the
> executor-drain makes settle work at small scale; its failures were Stage-1's
> premature *resolve-as-fail* (use the drain to DETECT, not to fail) and
> full-parallel scale (the shared-queue fix), both scoped. **Conclusion: abandon
> budget/QoS tuning; the path is the executor-drain as the settle *quiescence
> detector* (not a failure trigger), made primary and scaled. This is a core
> concurrency-design decision for the maintainer.**

> **Update 9 — drive-PRIMARY implemented: settle FIXED; `expect`+clock is the
> residual hard core.** Implemented the corrected plan: `settle`/`expect`/
> `waitUntil` resolve on the executor-drain fixpoint (non-starvable), with a
> short non-starvable debounce (executor-idle must persist since the last
> enqueue — bridges suspend→resume gaps), `mainCall` excluded from the per-test
> fixpoint (it's process-global → would hang under parallel), and a generous
> deadlock watchdog. Full-parallel result (flag on): **the 72 `settle() timed
> out` failures are GONE**, runtime **165 s** (vs 1379 s for ×100 budgets).
> Settle's `.background`-starvation disease is cured.
>
> Residual (~23 distinct): **`expect`+clock** (`testImmediateClock`,
> `testClockStepByStep`, `childTasks`, `testChangeOf*`), **deadlock-stress**
> (`checkExhaustion*DoesNotDeadlock*`), **events** (`featureEvents`,
> `testChildEvents`). The core one is `expect`'s premature-fixpoint race under
> parallel load: `settle` only needs "quiescent" (robust), but `expect` judges
> the predicate *at* the fixpoint — so a clock task whose resume+write is delayed
> past the debounce under load yields "fixpoint, predicate false" → a FALSE
> failure on a healthy test. A re-confirmation fixpoint narrowed but did not
> eliminate it (a delayed resume is unbounded under load). Race-free options:
> (a) `expect` fails only at the watchdog — stable, but a genuine wrong-assertion
> fails slowly (sacrifices fast-interactive-fail); (b) fold the test-clock's
> pending-sleeper set into the fixpoint so it's never declared while a task is
> clock-parked — clean, but clock-internals-deep. The deadlock-stress/event
> clusters need separate investigation (the drive may resolve before events
> propagate / interact with `checkExhaustion`'s locking).
>
> **Status: settle drive-primary is a validated win; `expect` drive-primary needs
> the (a)/(b) decision + the stress/event clusters. Inert by default.**

> **Update 10 — activity-grace (general, no dependency): settle stays fixed;
> expect residual is scaling + a long tail.** Per the maintainer's steer (must
> NOT depend on the clock or any specific dependency), the fixpoint debounce now
> keys on **all activity** — every `_noteActivity` (write/event/probe/task-start,
> via a new `_lastActivityNs`) AND executor enqueues — with a per-verb grace
> (settle 30 ms, expect 250 ms). Any activity (a clock-parked task resuming and
> writing) resets the grace, so on a single test it's quiet at once (fast) and
> under stress it waits until genuinely done. Full-parallel (flag on): **0 settle
> timeouts**, unexpected failures **118 → ~51**.
>
> Residual, now precisely characterized (two different things):
> 1. **Trait-cap hangs** (`childTasks`, `testImmediateClock` fail at exactly
>    ~30.7 s = the trait cap). NOT a premature fail — the drive *correctly*
>    waits, but under full-parallel ONE shared GCD queue backs every test's model
>    tasks, so hundreds contend and the test's tasks queue behind them; the 30 s
>    trait cap fires before they drain. Trading iter4's thread-explosion for a
>    shared-queue bottleneck. Fix: the trait cap must itself be load-tolerant (an
>    inactivity watchdog, not an absolute 30 s), and/or a bounded-but-larger
>    executor concurrency.
> 2. **Long tail of genuine interactions** (fast fails): `testClockStepByStep`
>    (manual clock stepping), `checkExhaustion*DoesNotDeadlock` (preference-
>    exhaustion), `testChildEvents`/`testTouchThenRealWrite` (event/transition
>    propagation) — the drive resolves before/around these in ways their
>    assertions don't expect.
>
> **Conclusion: `settle` drive-primary is a clean, validated, SHIPPABLE win (the
> core disease). `expect` drive-primary is deeper R&D** — it needs (a) a
> load-tolerant trait cap + executor concurrency tuning for the scaling hangs,
> (b) the fundamental fast-fail-vs-delayed-resume race accepted via watchdog-only
> failure (general, no-dependency, race-free, but slow-fail) or lived-with as
> much-reduced residual flakiness, and (c) the long-tail interactions resolved
> one by one. Recommend banking settle and treating expect as a separate effort.

> **Update 11 — follow-up branch `claude/expect-drain` (stacks on #23): item 1a
> done; the "long-tail events" collapse INTO item 2.** Rebased the expect
> drive-primary changes onto `claude/settle-drain` (#23) as a separate follow-up.
> Reproduced Update 10's state: with the flag on, the item-1 trait-cap suites
> (`childTasksCompleteBeforeTeardown`, `testImmediateClock`, `testClockStepByStep`)
> all **pass in isolation** — the drive is sound at small scale; they only fail
> under full-parallel by hitting the absolute 30 s trait cap.
>
> **Item 1a implemented — load-tolerant trait cap.** The per-test wall-clock cap
> is now an **inactivity watchdog** keyed on the test's own `_DrainTestExecutor`
> activity (`activityNs`: `now` while a job is running/ready, else the most
> recent enqueue/completion, floored at the executor's birth time). It re-arms on
> every executor advance and trips only after a full 30 s window of *genuine*
> inactivity — so a healthy-but-slow test whose jobs queue behind hundreds on the
> shared drain queue never trips, while a real per-test stall still surfaces (the
> signal is per-test, not process-global). Flag-off path is untouched (absolute
> cap). Green on the item-1 suites + `SettlingTests` + `ExecutorDrainSettleTests`
> in isolation; flag-off inert. The full-parallel effect on the residual is the
> next gate (a heavy run — deferred pending maintainer go-ahead).
>
> **Key finding — item 3's "event long-tail" is item 2, not a separate bug.**
> `testChildEvents` **passes when run alone** (flag on) and only fails when other
> suites add parallel pressure. The mechanism is exactly the item-2 race: an
> `expect` predicate (`…optChild.didSend(.count(7))`) is judged *unmet at a
> declared fixpoint* while the satisfying event is merely delayed under
> contention; `_resolveUnmetPredicatesAtFixpoint` then false-fails it, the event
> is never consumed, and `checkExhaustion` reports "event … was not handled". So
> the 250 ms `_expectGraceNs` is NOT being reset by the in-flight event delivery —
> i.e. some event/continuation resume is reaching the test *without* registering
> as executor activity or `_noteActivity` during the grace window. That points
> back at doc risk #3 (executor-preference inheritance through `forEach`/event/
> `Observed` continuation chains): if every model continuation resumed on the
> counted executor, the grace would cover the delay and fixpoint-fail would be
> race-free — the general (no-dependency) form of Update 9's option (b). Whether
> to (A) make `expect` watchdog-only-fail (race-free, but a genuinely-wrong
> assertion slow-fails), (B) close the executor-coverage gap so fixpoint-fail
> becomes race-free (more work, best outcome), or (C) ship 1a + live with reduced
> residual, is the open maintainer decision.

> **Update 12 — pursued (B); it is necessary coverage but NOT sufficient; the
> data points back to (A).** Maintainer chose (B): close the executor-coverage
> gap. Findings:
>
> 1. **The gap is real and now closed for observation.** Off-main model writes
>    deliver the *main* registrar's willSet/didSet (`withObservationTracking` /
>    `Observed` / `onChange`) via `context.mainCallQueue` — a queue earlier
>    iterations excluded as "process-global." It is in fact **per-context
>    (per-test)** (`AnyContext.mainCallQueue = parent?.mainCallQueue ?? .init()`);
>    only the bare `let mainCall` global is process-wide. So the drive can safely
>    wait on it (the shared `@MainActor` drains this test's items in finite time,
>    watchdog-bounded, never an inter-test hang). The fixpoint now unions
>    executor-idle + bg-idle + **per-test main-observation-idle** + no-pending-
>    start. (`useMainThreadObservation` is true for `.modelTesting` on Darwin,
>    confirmed.)
> 2. **It does not measurably reduce the residual.** Full-parallel (flag on,
>    UNLOADED machine — runs in ~8.5 s vs the doc's 165 s loaded): ~15–16 flaky
>    unexpected failures both with and without the mainCall union, and the
>    *membership varies run to run* (events, `onChange`/`Observed`, transitions,
>    preference-exhaustivity, child recursion, the `checkExhaustion*DoesNotDeadlock`
>    pair). `testChildEvents` / `testChangeOf` / `featureEvents` fail in BOTH.
>    Single runs can't measure a small effect at this variance, but the event
>    races can't be a mainCall artifact at all — **events don't use the registrar**
>    (`node.send` is synchronous: `sendEvent` → AsyncStream continuation →
>    `forEach` consumer, which already resumes on the counted executor).
> 3. **Diagnosis: the residual is one phenomenon — a fine-grained fixpoint-
>    *sampling* race, not a whole-queue exclusion.** Under contention the drive
>    samples "idle ∧ no activity for grace" at an instant when a satisfying
>    write/event/consumer-resume is in-flight but has not yet registered as
>    activity within the (finite) grace window; `_resolveUnmetPredicatesAtFixpoint`
>    then false-fails. It surfaces on every path that relies on "the consumer has
>    propagated by the time `expect` samples," which is why it looks like a
>    scattered long tail but is a single cause. This is exactly Update 8's
>    theorem: **with a dependency-free signal, no finite grace can distinguish
>    "quiescent, predicate never true" from "quiescent, a delayed resume is about
>    to make it true" — the delay is unbounded under load.** (B) cannot beat that
>    by covering more queues; a re-confirmation fixpoint already failed to (U9).
> 4. **Recommendation: pivot to (A) — `expect` must not self-fail at a fixpoint.**
>    A healthy `expect` still resolves reactively the instant its predicate is
>    true (fast happy path, unchanged). A still-unmet predicate fails only when the
>    model has been genuinely quiescent — *and the natural quiescence signal is the
>    per-test inactivity watchdog built for item 1a* (30 s of true no-activity),
>    surfacing the proper `expect` diff at that point rather than a generic
>    `[TRAIT timeout]`. Race-free and dependency-free by construction. Cost: a
>    genuinely-wrong assertion run by a human in isolation fails after the
>    inactivity window rather than instantly — tunable (a shorter expect-specific
>    inactivity-fail window, since true silence ≠ contention). The mainCall union
>    from (1) is correct coverage regardless (doc risk #1) and is kept, but it is
>    not the fix. **Open call for the maintainer: accept the (A) slow-fail
>    tradeoff (and pick the expect inactivity-fail window), vs. keep fixpoint-fail
>    + lived-with residual.**

> **Update 13 — (A) implemented (2 s tunable expect inactivity-fail window,
> scaled by `timeoutScale`); it helps the targeted class but the DOMINANT
> residual is a broad propagation race that neither (A) nor (B) cracks.**
> `_expectGraceNs` is now the expect inactivity-fail window (2 s × scale); `expect`
> resolves PASS reactively/instantly as before and only FAILs after a sustained
> window of genuine inactivity (every activity/enqueue/queue-drain resets it, so
> under load the fail defers until truly quiet — no false fail; settle keeps its
> 30 ms grace).
>
> Evidence:
> - **Targeted win:** `testChildEvents` flake rate fell from ~1/3 to 0/8 in a
>   focused combo loop — the deferred-resume class is helped.
> - **Aggregate ≈ neutral.** Full-parallel (flag on, UNLOADED machine, ~7–8.5 s,
>   spike/diag investigation tests removed): 12–18 unexpected failures/run,
>   union ≈ 25 over 3 runs, dominated by **observation / transition / event
>   propagation** — `testChangeOf*`, `testOnChange*`,
>   `testRecursive{Child,Children,OptChild}`,
>   `testCapturedObservedFiresOnEveryMutation`, `testTaskId*`, `testChildEvents`,
>   `featureEvents`, `asyncTaskBothTransitionsAsserted` — plus the
>   `checkExhaustion*DoesNotDeadlock` stress pair. Same order of magnitude as the
>   pre-(A) ~15–16. (`awaitQuietWindow_firesAfterQuietWindow` also appears but is a
>   pre-existing wall-clock-timing META-test flake — `5.0 s < 4.5 s` under
>   contention — unrelated to the drive; flakes on `main` too.)
> - **High variance** on a shared/unloaded machine makes single-run aggregate
>   deltas unreliable; the documented baselines (118→51→…) were on a far busier
>   machine (165 s runs vs ~8 s here).
>
> Diagnosis: the dominant residual is ONE phenomenon — the executor-drive's
> quiescence detector **systematically mis-times observation/transition/event
> propagation under contention**. Neither lengthening the grace (A) nor unioning
> the per-test mainCall queue (B) resolves it, which means the satisfying consumer
> write reaches the test through a path that, under load, is *both* uncounted by
> the executor *and* slow enough to beat a multi-second inactivity window — or it
> is a genuine clock-parked-transient premature-fixpoint (a task parked
> mid-`sleep` is not a ready job and emits no activity, so no finite grace covers
> it; Update 5's hard core, dependency-free-unsolvable per U7/U8).
>
> **Conclusion — stop blind grace/coverage tuning; the next step is TRACING, as
> Updates 2 & 9 already concluded.** Shippable now (flag still OFF by default):
> item 1a (load-tolerant trait cap) + (B) per-test mainCall union + (A) tunable
> expect inactivity-fail — all correct, low-risk, a strict improvement on the
> targeted classes. The broad propagation residual needs instrumented diagnosis
> (`SWIFT_MODEL_GTS_TRACE` + executor enqueue/idle logging) on ONE failing
> observation test under reproduced load, to pinpoint *exactly* where the
> satisfying write lands relative to the fixpoint sample — distinguishing an
> uncounted continuation-resume path (fixable by threading `executorPreference`
> through it — doc risk #3) from an irreducible unbounded delay (→ keep the flag
> off for those, accept as residual). Best done with maintainer pairing, not
> further autonomous trial-and-error.

> **Update 14 — CORRECTED BASELINE: the earlier "neutral" read was apples-to-
> oranges; with a same-machine flag-OFF control the drive is a clear win on
> BOTH speed and parallel-flake.** Update 13 compared flag-on numbers against the
> *doc's historical* baselines without re-measuring flag-off on the same
> (unloaded) machine. Doing so reframes everything (`scripts/test` = `--parallel`;
> CLAUDE.md notes dev-machine `--parallel` flakes for *any* path — CI's
> deterministic gate is `--no-parallel`):
>
> | Config | Result |
> |---|---|
> | flag-OFF, `--no-parallel` (CI gate) | **GREEN**, 0 unexpected, **112 s** |
> | flag-ON, `--no-parallel` | **~5–6 FLAKY** unexpected/run (set VARIES run-to-run), **43 s** |
> | flag-OFF, `--parallel` (this machine) | **~31** unexpected |
> | flag-ON, `--parallel` (this machine) | **~12–18** unexpected |
>
> Takeaways:
> 1. **Flag-off inert path is preserved** — serial CI gate stays green. ✓
> 2. **The drive is ~2.6× FASTER serially** (43 s vs 112 s) — it resolves at
>    fixpoints instead of waiting out wall-clock debounce windows.
> 3. **The drive HALVES `--parallel` flake** (≈31→≈12–18) — the load-tolerance
>    thesis, confirmed against a real control.
> 4. **But it is NOT a strict win on the serial gate:** flag-on adds a small
>    FLAKY residual (~5–6/run, membership varies — observation `testOnChange*`/
>    `testRecursive*`/`testCapturedObserved*`, events `featureEvents`/
>    `testChildEvents`, and the `checkExhaustion*DoesNotDeadlock` stress pair)
>    that flag-off serial does not have. So the fixpoint-sampling race (Update 8)
>    manifests even SERIALLY at low rate — the shared drain queue + cooperative
>    pool retain within-test scheduling slack. Each such test PASSES in isolation;
>    it is an inter-test / within-test-concurrency timing effect, not a
>    deterministic logic bug.
>
> Net: items 1a + B + A are shippable (flag OFF by default) and make the opt-in
> drive faster and markedly more parallel-tolerant than the wall-clock path; the
> ~5–6 serial flaky residual is the remaining barrier to flipping the default on,
> and it is the same fundamental sampling race — now correctly bounded and
> measured. The tracing-based diagnosis in Update 13's conclusion stands as the
> next step; the bar is "flag-on serial reaches 0 unexpected, stably" before the
> default flips.

The spike proves the *primitive*. Integration risks, confirmed by the wiring
attempts above:

1. **MainActor hop.** Work that hops to `@MainActor` (`MainCallQueue`) runs on
   the main executor, not the drain executor. The fixpoint must drain that queue
   too (we already own it).
2. **GCD / `Task.detached` internals.** `CallQueue` / `BackgroundCallQueue`
   pumps and GTS sit off any controlled executor. In test mode they must route
   through it (or be virtual-time) or the "ready queue empty" signal lies.
3. **`executorPreference` inheritance** through `forEach` / `Observed` chains
   and child-model task trees (the spike set it manually per `Task`; the
   framework's `Cancellables` spawn path must thread it through).
4. **External async = a hard rule.** A task awaiting an *uncontrolled* real
   async op idles the executor while work is pending elsewhere → premature
   fixpoint (Test C). Tests must use controlled dependencies — the discipline
   TCA enforces by construction.
5. **Availability.** Custom task executors need the Swift 6 runtime
   (`macOS 15+` / `iOS 18+`). CI is `macos-15`; the production library is
   unaffected (test-only opt-in).

## 7. Migration path (incremental, non-breaking)

1. Introduce the per-test drain executor + `executorPreference` on model task
   spawns **under `.modelTesting` only** (production unchanged).
2. Add `drainToQuiescence()` that unions executor-idle + `MainCallQueue` idle +
   bg idle + `!hasPendingStartTask`. Make `settle`/`expect` resolve on it, with
   the existing wall-clock path kept as a **fallback** so nothing else breaks
   during migration.
3. Once trusted, demote the wall-clock debounce to the runaway/iteration cap and
   remove the QoS / `.deferential` / scale machinery.
4. Virtualise internal scheduling (GTS, call-queue pumps) last.

Each step is independently shippable and reversible.

> **Update 15 — DIAGNOSTIC REDIRECT: the dominant residual is window-INDEPENDENT
> fast-fail, NOT the inactivity/delayed-resume race.** Targeted the most-reliable
> residual tests (`testChangeOf`, `testRecursive{Child,Children,OptChild}`,
> `testCapturedObservedFiresOnEveryMutation`, `testTaskId*`). Concrete failure: an
> `expect` over an ACCUMULATED update sequence sees the LAST update missing —
> e.g. `counts == [5]` when `[5, 8]` was expected — and it FAILS FAST (0.05–0.1 s).
>
> Decisive experiment: temporarily set the expect inactivity-fail window to 30 s.
> The tests **still fail at 0.05–0.1 s**, unchanged. So these failures do NOT go
> through the drive`'s inactivity-fail path at all, and (A) cannot address them —
> they are not a delayed-resume that a longer grace would catch. The Update 13/14
> framing ("fixpoint-sampling / delayed-resume race") is WRONG for this
> (dominant) sub-class; it is right only for the EVENT sub-class (`testChildEvents`),
> which (A) did measurably help (1/3 → 0/8).
>
> New hypothesis (for the tracing/pairing session): moving the Observed/onChange
> consumer onto the per-test drain executor changes the INTERLEAVING between the
> test thread`'s successive mutations and the consumer`'s appends — so an
> accumulated-sequence assertion observes the wrong sequence (a missing or merged
> update) at evaluation time, independent of any wait window. This is an
> executor-ordering effect, not a quiescence-detection effect. Next concrete step:
> trace one `testChangeOf` failure (consumer append timestamps + the executor
> enqueue order vs the two `count +=` mutations) to confirm whether an update is
> merged/dropped or merely reordered. (A) is KEPT at 2 s — correct for the event
> sub-class and the chosen semantics — but is now known not to be the lever for
> the Observed/transition residual.

> **Update 16 — ROOT-CAUSED & FIXED: the dominant residual was a cancelled-driver
> bug, not an irreducible race. Flag-on serial is now GREEN.** Tracing (Update 15's
> plan) pinpointed it immediately. `expect()` starts a per-call executor driver
> (`_startExecutorDrive`) and cancels it (`executorDriver?.cancel()`) the instant
> its `awaitPredicate` resolves. But the driver loop ran
> `_resolveUnmetPredicatesAtFixpoint()` on EVERY iteration — including the one
> where `_driveToStableFixpoint` returned `false` because the Task had just been
> CANCELLED. Since `_pendingExpects` is shared across a test's sequential
> `expect`s, the just-cancelled driver of expect *A* would, on its way out, fail
> whatever predicate expect *B* had freshly registered — before B's satisfying
> write/event arrived. That is precisely the observed signature: a fast,
> window-independent false failure leaving an accumulated Observed/onChange/event
> sequence missing its LAST element (`counts == [5]` vs `[5, 8]`). It explained
> why neither (A) grace-length nor (B) queue-coverage helped: the fail did not
> come from B's own drive at all — it came from A's cancellation unwind.
>
> Fix (one line of intent): the driver bails on `Task.isCancelled` BEFORE touching
> the shared pending entries — a cancelled driver must never fail another expect's
> predicate. `_driveToStableFixpoint` returns `false` for both cancellation and
> the hang watchdog, so the guard checks `Task.isCancelled` specifically (a real
> deadlock still surfaces via the per-test inactivity watchdog).
>
> Results (same machine):
> | Config | Before fix | After fix |
> |---|---|---|
> | flag-OFF serial (CI gate) | green, 112 s | green, 112 s (unchanged) |
> | flag-ON serial | ~5–6 flaky/run | **GREEN, 2/2, 42 s** |
> | flag-ON `--parallel` | ~12–18/run | **1–3/run** |
> | OnChange+UpdateStream combo (was ~1/run) | flaky | **0 / 6 runs** |
>
> The whole observation/transition/event class (`testChangeOf*`, `testRecursive*`,
> `testCapturedObserved*`, `testTaskId*`, `testChildEvents`, `featureEvents`) is
> gone. **Flag-on serial — the bar to flip the default — is GREEN.** Remaining
> `--parallel` residual is the pre-existing `awaitQuietWindow_firesAfterQuietWindow`
> wall-clock-timing META-test flake (flakes on `main` too) plus occasional
> `testClockStepByStep` / `testOnChangeCancelPreviousDiscardsStalework` — to be
> confirmed as the genuine dev-machine `--parallel` tail (CLAUDE.md's documented
> class) vs anything new, before proposing the default flip.
>
> Net of this branch: items 1a + B + A (now correctly understood as helping the
> event sub-class only) + the cancelled-driver fix make the opt-in drive **2.6×
> faster serially, serial-clean, and an order of magnitude less parallel-flaky**
> than the wall-clock path. Lesson restated: the design note kept saying "trace,
> don't tune" — tracing found a concrete one-line bug after grace/coverage tuning
> had stalled.
