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

The spike proves the *primitive*. Integration risks, to validate by wiring one
real flaky test (`ChildActivationTaskTests.childTasksCompleteBeforeTeardown`)
end-to-end:

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
