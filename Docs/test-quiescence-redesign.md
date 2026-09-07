# Sketch: semantic quiescence for `.modelTesting`

**Status: proposal, not implemented.** Written 2026-09-07 to decide whether the idea holds
together before any code is written. Nothing here has shipped; `Docs/test-determinism-executor-drain.md`
describes what actually runs today.

## 1. The problem this replaces

Every wait verb (`expect`, `settle`, `waitUntil`) has to answer one question: *is the model
done reacting?* Today that question is answered by **observing the scheduler** — the drive
counts outstanding executor jobs, checks the background and main call queues, checks whether
any task has yet to start, and requires the answer to hold across two checks plus a grace
window.

That accounting can only be as complete as our visibility into the Swift runtime, and the
runtime does not expose task state or promise which executor a resumption travels through.
So there is an open-ended set of ways work can be *pending but invisible*. Three have been
found so far, each fixed separately:

| Blind spot | Symptom | Fix that shipped |
|---|---|---|
| Task parked on a `TestClock` deadline | premature fixpoint | test-side `settle()` before `advance` |
| Continuation hopping through the global executor after `Task.yield()` | premature fixpoint | grace window; then a yield round-trip (PR #70, rejected downstream — one hop per settle, 2.3–9× slower) |
| Job sitting at background QoS | executor "busy" forever → 1500 s ceiling | QoS floor on the drain queue (PR #70, did not remove the downstream wedge) |

There will be a fourth. **An open set cannot be closed by enumerating it.** That is the
ceiling of the current approach, and it is why this keeps recurring.

## 2. The principle

Everything a model does asynchronously goes through SwiftModel's own API. The framework
therefore *already knows* what work exists — it does not need to infer it from thread and
queue states. `Cancellations` already registers every `node.task` / `forEach` / `onChange`
from creation until its body returns (`TaskCancellable` unregisters from the body's `defer`).

The drive does not use that. It only asks `hasPendingStartTask` — "has any registered task
not yet had its first CPU slot". A child that *started* and then yielded is not pending-start,
and during its hop no job is outstanding, so it is invisible. **The information we need is
already in the registry; we are asking it the wrong question.**

## 3. The model: three states, one counter

Every unit of framework-owned async work is in exactly one state:

- **running** — its body is executing, or is suspended somewhere the framework did not put it
  (a `Task.yield`, an internal runtime hop, a suspension inside user code).
- **parked** — suspended at a suspension point *the framework itself owns*, waiting for input
  that can only arrive from outside: the `await iterator.next()` in `forEach`, an `Observed`
  emission, a clock sleep, an event-stream await.
- **finished** — body returned or was cancelled; unregistered.

> **Quiescent** ⇔ no registered work is **running**.
> Parked work does not block quiescence. Finished work is gone.

That is the whole rule. There is no wall clock in it, no executor idleness, no queue
inspection, no grace window.

Note what it buys on the three blind spots above: a task mid-`Task.yield` is **running**
(the framework did not park it), so the yield gap closes by construction — no round-trip,
no per-settle hop. A job starved at background QoS belongs to a task that is **running**,
so settle waits rather than declaring a fixpoint; and it never wedges the *verdict*, because
the verdict no longer asks whether an executor is busy. A task parked on a `TestClock` is
**parked**, so `settle()` after `withAnchor` stops being load-bearing.

## 4. Inventory: every async work source

This is the closure argument. If this table is complete, the rule is sound; if something is
missing, it is a hole.

| Source | Created by | Tracked today | Under this design |
|---|---|---|---|
| `node.task` | `TaskCancellable` | registry (create→return) | running; finished on return |
| `node.task(id:)`, `forEach`, `onChange` | `TaskCancellable` per body + outer | registry | outer parks on `await next()`; each body run is running |
| Activation tasks (`onActivate`) | `TaskCancellable` | registry + `hasPendingStartTask` | running until body returns |
| `Observed` / memoize recompute | `backgroundCall` queue item | `bg.isIdle` | queue item = one running unit |
| Main-registrar / `@ObservedModel` notifications | `mainCallQueue` item | `main.isIdle` | queue item = one running unit |
| `GlobalTickScheduler` deadline callbacks | GTS entry | none (it *is* the clock) | not work; a scheduled wake |
| Event / modification stream consumers | user `for await` inside a `node.task` | registry | parked — the **stream** marks it, see §5 |
| Dependency clocks (`clock.sleep`, `TestClock`) | user's injected dependency | none | **foreign** — SwiftModel defines no clock (verified: `swift-clocks` is only a package dependency, `node.clock` is the user's own property). Needs §6 tier 2. |
| **User code awaiting anything else foreign** (a real `URLSession`, an `AsyncStream` the user owns) | user | nothing | **running** — see §6 tier 3 |

The queue items are already counted correctly today (`isIdle`); they fold into the same
counter rather than being separate predicates.

### 4a. First pass of the audit — two holes already

A ten-minute pass over every `Task` created in `Sources/` found two framework-spawned units
that are in no registry at all. Both are tractable, and they are instructive about the shape
of the work:

- **`Context.swift` last-seen TTL cleanup** — a bare `Task { try? await Task.sleep(TTL); …clear state… }`
  spawned per destructed context. It must **not** count as running: `settle()` would then wait
  out the whole TTL. It is not model reaction at all, it is memory reclamation. So the
  inventory needs a fourth category: **excluded housekeeping**, work the framework spawns whose
  completion no test should ever wait for. That category must be explicit and short, because
  every entry in it is a deliberate blind spot — the same kind of thing that made the current
  design leak, and the reason each entry needs a written justification.
- **`ObservedModel.swift` priming** — `Task { @MainActor objectWillChange.send() }`. This is a
  SwiftUI notification and belongs on `mainCallQueue`, where it would be counted for free
  rather than being invisible.

Finding two on the first pass, one of which would break the rule outright if counted naively,
is the strongest argument for doing step 1 of §10 before writing any of the mechanism.

## 5. How a park is marked — the source marks it, not the loop

The first draft of this sketch put the marking in `forEach`'s loop. That is wrong, and the
reason matters: a user can write the loop by hand.

```swift
node.task {
    for await value in observeModifications() { … }   // raw loop, no forEach
}
```

If the marking lived in `forEach`, this task would count as running forever. So **the park
mark belongs to the input source**, which the framework owns in both cases. SwiftModel
produces these streams and holds their continuations, so their `next()` knows exactly when a
consumer is waiting on an empty buffer:

```swift
// inside SwiftModel's own AsyncStream/iterator machinery
func next() async -> Element? {
    if let buffered = takeBuffered() { return buffered }   // still running: work is available
    return await parked { await awaitNextYield() }          // parked: nothing to do until input
}
```

`parked { }` moves the *calling task's* registry entry to parked, awaits, and moves it back
before returning. This makes `forEach` and a hand-written `for await` behave identically,
which is the property that matters — the framework is not relying on users choosing its
sugar.

**The one race, and how it is handled.** Between marking parked and actually suspending, the
task is still runnable; if a value is already buffered, it resumes immediately. A `settle`
check landing exactly there could see "parked" for work that is about to run. Two properties
contain it:

1. For framework-owned sources (`Observed`, event streams, memoize sentinels) the *yield* of
   a value is itself an activity signal that already re-arms every waiter, so the window
   cannot produce a missed wake — only a redundant one.
2. Quiescence is confirmed across two observations with no **park-generation** change between
   them (a counter bumped on every park/unpark transition). This is the same double-check the
   drive does today, except it double-checks a *semantic* state that does not flicker with
   scheduling, rather than executor idleness which flickers constantly under load.

## 6. Three tiers of suspension — and the one that decides viability

**Tier 1 — framework-owned, marked automatically.** `Observed`, event streams, modification
streams, memoize sentinels. SwiftModel produces the stream and holds the continuation, so
§5 applies with no user action. Works through `forEach` or a raw `for await` alike.

**Tier 2 — declared. This is the tier the design lives or dies on.** A `clock.sleep` is the
single most common suspension in these tests and SwiftModel cannot see it: it defines no clock,
and `node.clock` is the user's own dependency property. If every clock sleep counted as running,
`settle()` would hang across a large part of the existing suite.

**The obvious mechanism does not work.** My first proposal was to wrap values conforming to
Swift's `Clock` at dependency-access time. Checked against the main downstream consumer and it
fails: parallel-apple defines its **own** `Clock` protocol (`imagien/Sources/Clock/Clock.swift`)
with `TestClock`, `RateClock`, `SyncClock`, `ImmediateClock`, `ConstantClock` conforming to it,
none of them to `_Concurrency.Clock`. A conformance check SwiftModel writes would match nothing.
Any mechanism that depends on recognising a *type* is fragile for the same reason.

**What does work: the adoption point is the source's own implementation, not its call sites.**
SwiftModel exposes one public primitive —

```swift
public func withModelParked<T>(_ body: () async throws -> T) async rethrows -> T
```

— which marks the calling task parked for the duration of `body`. Anything that hands external
input to a model wraps its own suspension in it, once. That is not a per-call-site migration:
parallel-apple's `Clock` protocol documents that *"callers always go through this method"*, so
the whole surface is **one default implementation plus two overrides** (`Clock.swift`'s default
`sleep(until:toleranceMs:)`, `TestClock`, `ImmediateClock`) — three edits in a module they own,
covering every `clock.sleep` in every model.

This generalises: any library feeding async input to models opts in with one wrap at its own
suspension point, and needs to know nothing else about SwiftModel.

**Tier 3 — foreign and undeclared.** Anything else counts as **running** until it returns. It
is genuinely outstanding work, so `settle()` waiting for it is correct rather than a bug. If
it never finishes, a generous backstop reports it — see §6a.

#### 6b. Worked examples: sleeps, clocks, and third-party sequences

The question that decides adoption cost is *where* the park mark goes. There are three
hooks, and they cover different amounts of ground for different amounts of work.

**Hook 1 — `node.forEach` marks its own `await`. Zero adoption, covers the most.**

`forEach` owns the loop, so it can park around its own `next()` call *whatever the sequence
is*. That includes every third-party operator, because the consumer is suspended on one
await regardless of how many tasks the operator runs internally:

```swift
// swift-async-algorithms debounce, consumed through forEach.
// Parks correctly with no user action and no knowledge of debounce's internals.
node.forEach(searchQueries.debounce(for: .seconds(0.3), clock: clock)) { query in
    results = await api.search(query)          // running: real work
}
```

While `debounce` is holding its 300 ms, the consuming task is suspended inside `forEach`'s
`next()`, so it is parked and `settle()` does not wait for it. The same holds for `throttle`,
`merge`, `chunked`, or anything else conforming to `AsyncSequence`. **This is why the design
is cheap in practice: `forEach` is the idiomatic API, so the common path needs no adoption.**

**Hook 2 — the sequence wrapper, for a hand-written loop over a foreign sequence.**

```swift
node.task {
    for await tick in externalTicker.parkedInModelTasks() { … }
}
```

One await, one park, no propagation subtleties. This is the most robust hook and the one to
recommend when someone insists on writing the loop themselves.

**Hook 3 — the source wraps its own suspension, for a bare sleep with no sequence.**

A `clock.sleep` sitting directly in a task body is not inside any `next()`, so hooks 1 and 2
do not see it. Here the clock wraps its own await, once, in code the clock's author owns.

For parallel-apple's `Clock` protocol this is genuinely three sites, because the protocol
already funnels every caller through one method (*"Callers always go through this method,
never `nonAdjustedSleep` directly"*):

```swift
// imagien/Sources/Clock/Clock.swift — the default implementation every clock inherits
extension Clock {
    public func sleep(until date: Date, toleranceMs: UInt64 = 100) async throws {
        try await withModelParked {                     // ← the only change
            try await retry { try await nonAdjustedSleep(until: date, toleranceMs: toleranceMs) }
        }
    }
}
```

plus the two clocks that override `sleep(until:)` directly (`TestClock`, `ImmediateClock`).
Three edits cover every `clock.sleep` in every model in the repo, and models themselves are
untouched. A clock that does *not* adopt still works — its sleeps count as running, so
`settle()` reports it by name (§6a) rather than being silently wrong.

**What a third-party library author has to do: nothing.** `swift-async-algorithms` needs no
change, because its operators are consumed through hook 1 or 2. A library only needs
`withModelParked` if it hands a model a *bare* suspension that is not an `AsyncSequence` and
not routed through a clock the user controls — which is rare, and is the same shape as
"provide a dependency" that the framework already asks for.

**Where task-locals do and do not help.** `withModelParked` identifies the work unit through
a task-local, so a suspension inside a child task the library spawned still marks the right
unit. That is what makes hook 3 work through library internals. It is also why hook 1 is
preferred where both apply: with one await there is exactly one thing to mark, whereas an
operator running several concurrent children could in principle park one while another runs.
`forEach`'s single `next()` makes that question disappear.

### 6c. An honest wrinkle: "parked" conflates two different things

`withModelParked` as described means *this task is suspended awaiting input*. But there are
two kinds:

- **Waiting for the test to act** — a `TestClock` sleep only resumes when the test calls
  `advance`. Ignoring it in the quiescence decision is exactly right.
- **Waiting for wall time** — a real-clock sleep resumes on its own. The model is arguably not
  "done"; it will do more work in 300 ms without anyone asking.

**Resolved (Måns, 2026-09-07): treat both as parked, and treat a real-clock sleep in a test as
the user error it is.** A test that sleeps on wall time is already wrong — it should be using a
controllable clock with an `advance` — so the framework should not contort its quiescence rule
to accommodate it. Today's drive does not distinguish the two either (an executor-idle check
declares quiescence during a real sleep too), so a single mark both preserves current behaviour
and points users at the right fix. If it ever needs splitting, `parkedUntilExternalInput` vs
`parkedOnTimer` is the shape; not needed now.

## 6a. The backstop, and what a timeout means now

A wall clock does come back, but only as a **reporter of unfinished work**, never as part of
the quiescence decision. The verdict is semantic; the clock only bounds how long we wait
before telling the user what is still running.

**Unmarked work is bounded by teardown, not only by the backstop** (Måns, 2026-09-07). A task
started from `onActivate` is lifetime-bound and registered, so end-of-test teardown cancels it
(`cancelAllRecursively` / `sealRecursively`). So the worst case of an unmarked suspension is:
`settle()` waits, the backstop reports it by name, and the task is reaped when the test ends —
**not** a wedged process. That is what makes adoption incremental and safe: a codebase does not
have to mark everything before the design is usable. Whatever is unmarked simply makes `settle()`
fail with a message naming exactly what to mark next.

That also answers the infinite-loop case: a `node.task` running `while true { compute() }` with
no suspension is *running* forever, `settle()` waits, and the backstop fires. That is user error
and should be reported as one — but the message can now be specific, because the registry knows
exactly which work is outstanding and where it was created:

> `settle() timed out: 1 task still running — "syncLoop() @ MyModel.swift:42" has not
> returned since it started 30 s ago and is not parked on any input.`

Compare the current message, which guesses at a deadlock in model code and sent two sessions
hunting lock inversions for a day. The same backstop covers tier 3: a test awaiting a real
network call gets told which task and where, instead of a mystery hang.

## 7. What this removes

- The grace window (`_settleGraceNs`, `_expectGraceNs`) — no longer part of correctness.
- The two-consecutive-idle-check heuristic on executor state.
- `hasPendingStartTask` as a special case (a task that has not started is simply *running*).
- The yield round-trip from PR #70 and its per-settle cost.
- The reason PR #70's QoS floor was needed *for correctness* — the floor may still be wanted
  for speed, but the verdict no longer depends on scheduling.
- The `[TRAIT timeout — ABSOLUTE CEILING]` message's claim that a wedge is "almost certainly
  a deadlock in model code" — under this design a stuck wait names the work that is still
  running, with its call site.

## 8. Why this is testable without a starved machine

Today's invariant is timing-dependent, so validating it needs a reproducer of a loaded CI
runner — which is what the last two days were spent failing to build locally. A semantic
invariant is deterministic: you assert the accounting directly.

- Unit tests over the registry: a task that yields is running; a task awaiting a stream is
  parked; a body dispatched from a parked outer loop is running; a cancelled task is finished.
- A test that a `settle()` returns *only* after a specific set of registered work reaches
  parked-or-finished, with no clock involved.
- The existing suite is the regression net for behaviour; the parallel-apple plan remains the
  acceptance test for the thing that started this (`settle()` overhead and the wedge).

## 9. Open questions — the things I am least sure about

0. **Tier 2 for clocks — narrowed, not closed.** (§6) Recognising a clock by *type* is dead
   (parallel-apple has its own `Clock` protocol). The `withModelParked` primitive works and is
   a 3-edit adoption there, but it is opt-in: an unadopted codebase gets `settle()` timeouts
   naming the unmarked work rather than silent wrongness. Is that adoption cost acceptable, and
   is one public primitive the right shape, or should SwiftModel also offer its own
   `node.sleep(for:)` so the common case needs no adoption at all?

1. **Is the inventory in §4 complete?** Any framework path that spawns work without
   registering it is a hole. Needs an audit, not a guess.
2. ~~**Long-lived tasks that never park.**~~ **Answered (Måns, 2026-09-07):** a compute loop
   with no await is user error; it should hit the backstop and be reported, not accommodated.
   §6a covers it, and the report now names the task and its call site. The design keeps a wall
   clock only for that report, never for the verdict.
3. **Production cost.** The state marking must be near-free outside tests. The registry
   already exists in production; the park marking adds two atomic operations per suspension.
   Probably fine, but it needs measuring, not assuming.
4. **Does this subsume the drive, or sit on top of it?** The drive's executor is still useful
   for *routing* model work somewhere identifiable. But if quiescence is semantic, the
   executor's job counting is redundant, and its QoS/hop hazards stop mattering for verdicts.
   Removing it is a much bigger change than adding the counter alongside it.
5. **The 3% wedge is not obviously addressed.** If a drive job is genuinely blocked inside
   `runSynchronously` on a lock, this design changes the *diagnosis* (settle would name the
   running work) but not the hang. That bug needs its own answer; the peer's sample hunt is
   the arm for it.

## 10. Suggested order of work

0. **Spike `withModelParked` first.** Cheapest thing that can kill the design. Show a task
   awaiting a foreign clock marking parked, `settle()` returning while it sleeps, and unparking
   on advance — then apply it to parallel-apple's three clock sites and run their plan.
1. Audit §4 to completion, with a test that fails if any framework path spawns unregistered
   work. Cheap, and it either validates the design or kills it.
2. Add the state + counter alongside the existing drive, with the new rule computed but
   **not** used for verdicts. Log both answers across the whole suite and every downstream
   plan run; find every disagreement.
3. Only then switch the verdicts over, and delete the machinery §7 lists.

Step 2 is what makes this safe: the two answers can be compared on real workloads before
anything depends on the new one.
