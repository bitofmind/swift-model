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
