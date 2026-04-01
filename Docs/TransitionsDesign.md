# Transitions Mode Design Plan

## Context

This document captures the design of **Transitions mode** — a new exhaustive state-tracking mode for `ModelTester` / `@Test(.modelTesting)`. It is intended as a handover document for implementation.

## Problem Statement

The current exhaustive state testing uses **last-write-wins** semantics: if a property goes `false → true → false`, it is collapsed into a single `ValueUpdate(from: false, to: false)`. This means:

1. Intermediate state transitions (e.g. `isLoading: false → true`) can go undetected if only the final state is asserted.
2. `expect { !model.isLoading }` can fire on the **initial** `false` value (before a background task even runs), causing a race condition. Our empirical test measured this at ~0.6% of iterations (3/500).
3. Tests that "pass" in this way are silently incomplete — they didn't actually verify the loading behaviour.

## Empirical Evidence

`ConcurrencyTests.observeExpectFiringTiming` (already committed) runs 500 iterations of:
```swift
model.load()
await expect { !model.isLoading }
```
Results: 3/500 fired before the task ran at all (initial `false`). 497/500 fired after the task completed. The race is real and non-deterministic.

## Layer A (Already Done)

Enriched chain messages in exhaustion failure output. When a path is written multiple times, the failure message now shows the full chain: `"isLoading: false → true → false"` instead of just the final value. This was committed and all tests pass.

## The Full Solution: Transitions Mode

### Core Principle

In **Transitions mode**, `expect` NEVER evaluates against the live model value. It always evaluates against recorded history. Specifically:

- If the **FIFO queue is non-empty** for a path: use the **front entry's `to` value**
- If the **FIFO queue is empty** for a path: use **`expectedState[path]`** (the baseline after the last assertion)
- **Never use `model.context![path]`** (the live model value) in transitions mode

The live value is the result of applying ALL writes. It tells you the final state but loses intermediate transitions. History preserves them.

### Data Model Change

**Current:**
```swift
var valueUpdates: [PartialKeyPath<Root>: ValueUpdate] = [:]
```
One entry per path. Subsequent writes update the existing entry (last-write-wins).

**New:**
```swift
var valueUpdates: [PartialKeyPath<Root>: [ValueUpdate]] = [:]
```
FIFO queue per path. Each write **appends** a new entry to the back.

`ValueUpdate` gains one new field:
```swift
struct ValueUpdate {
    var apply: (inout Root) -> Void
    var debugInfo: () -> String
    var area: Exhaustivity
    var fromDescription: (() -> String)?
    var throughDescriptions: [() -> String] = []
    var toDescription: (() -> String)?
    // NEW: the typed `to` value stored as Any, for use in willAccess during history evaluation
    var rawValue: Any
}
```

### How `didModify` Changes

Instead of updating an existing entry (building a chain), **always append** a new entry:
```swift
// Each write creates a new queue entry:
let newEntry = ValueUpdate(
    apply: { $0[keyPath: fullPath] = value },
    rawValue: value,  // NEW
    ...
)
valueUpdates[fullPath, default: []].append(newEntry)
lastState[keyPath: fullPath] = value
```

The change-chain description (`false → true → false`) previously accumulated within a single `ValueUpdate`. With FIFO, each entry has its own `from`/`to` pair. The failure message will list them separately or can still be displayed as a chain by joining consecutive entries.

### How `willAccess` Changes

In the closure returned by `willAccess` (the post-access capture), instead of reading `model.context![path]`:

```swift
// Transitions mode:
let value: Value
if let front = self.lock({ self.valueUpdates[fullPath]?.first }),
   let typed = front.rawValue as? Value {
    value = frozenCopy(typed)   // use history front's value
} else {
    // Queue empty: use expectedState baseline (initial value / last asserted value)
    value = threadLocals.withValue(true, at: \.isApplyingSnapshot) {
        expectedState[keyPath: fullPath]
    }
}
```

This is what makes history evaluation work **without a two-pass approach**. The predicate closure runs once, sees history values, and its return value reflects historical state naturally.

### How `expect` Changes

The main evaluation loop is largely unchanged — `expect` already retries on each `didModify` event. The changes are:

1. **On pass**: instead of `valueUpdates[path] = nil` (clearing the whole entry), **pop from the front**: `valueUpdates[path]?.removeFirst()`. If the queue becomes empty, remove the key.

2. **On timeout failure**: the error message should show the **front of the queue** (the oldest unasserted transition), not just the predicate diff. E.g.: `"Expected isLoading == false but the oldest unasserted transition is isLoading: false → true. Did you forget to assert the intermediate state?"`

3. **Settlement check**: the current check verifies that live model values match what was read. In transitions mode, we read from history, not live values — so this check should be skipped for transitions paths (or adapted to verify queue consistency).

### Exhaustion Check

Any **remaining entries in any FIFO queue** at exhaustion time are failures, reported as before. Each entry in the queue that was never popped is an unasserted state transition.

### Correct Test Pattern

```swift
model.load()   // spawns task: isLoading goes false → true → false

// Transitions ON (new default):
await expect { model.isLoading }    // sees front entry to=true → consumes it
await expect { !model.isLoading }   // sees front entry to=false → consumes it
// queue empty → clean ✓

// Wrong pattern → correctly fails:
await expect { !model.isLoading }
// sees front entry to=true, predicate wants false → mismatch
// exhaustion failure: "Unasserted: isLoading: false → true"
```

### Race Elimination

With the correct pattern above:
- **Task completes before `expect`**: history has `[false→true, true→false]`. `willAccess` returns `true` (front). `expect { model.isLoading }` passes immediately, consuming `false→true`. Then `expect { !model.isLoading }` sees `false`, passes, consumes `true→false`. Clean. ✓
- **Task hasn't started yet**: history empty. `willAccess` returns `expectedState[isLoading] = false`. `expect { model.isLoading }` fails (false ≠ true). Waits for `didModify`. Task starts → `false→true` added → retry → front is `true` → passes, consumes. Then waits for `true→false`. Task completes → added → passes. Clean. ✓

The race is eliminated in both cases.

### `settle()` Role — Unchanged

`settle()` means "acknowledge all pending changes, start fresh." With FIFO queues it does the same thing — clears all queues and advances `expectedState` to match `lastState`. Same role, same semantics.

### Opt-Out

The `Exhaustivity` OptionSet already has `.state`. The transitions granularity would be controlled within `.state` — either:
- A new `.transitions` bit that can be subtracted: `exhaustivity: .full.removing(.transitions)`
- Or simply: transitions is the new meaning of `.state`, and removing `.state` from exhaustivity is the opt-out

The default `@Suite(.modelTesting)` would use Transitions ON. Tests that genuinely only need final-state checking can opt out.

**Note**: "Transitions OFF + state exhaustivity OFF" = same effect (no state checking). The distinction between Transitions OFF (last-write-wins) and state exhaustivity OFF may not be worth keeping. Simplest design: Transitions ON = exhaustive state, `.state` removed from exhaustivity = no state checking. The last-write-wins middle tier could be removed entirely.

## What NOT to Change

- The `Exhaustivity` OptionSet structure (other than adding or reinterpreting `.state`)
- Events, probes, tasks, local, environment, preference exhaustion — all unchanged
- `settle()` semantics — same role
- The `TestProbe` / event FIFO behaviour — already works correctly
- `OutputSnapshotTests` — failure message format may change slightly for state; snapshots need updating

## Files to Modify

1. **`Sources/SwiftModel/Internal/TestAccess.swift`** — primary change:
   - `valueUpdates` type change to `[PartialKeyPath<Root>: [ValueUpdate]]`
   - Add `rawValue: Any` to `ValueUpdate`
   - `didModify`: append instead of update
   - `willAccess`: return history front value or expectedState baseline
   - `expect` loop: pop front on pass, skip settlement check for transitions paths
   - Exhaustion check: report remaining queue entries
   - Timeout failure: show front-of-queue in error

2. **`Sources/SwiftModel/Testing/ModelTestingSupport.swift`** — if `Exhaustivity` gains a new bit

3. **`Tests/SwiftModelTests/OutputSnapshotTests.swift`** — snapshot strings will change; update snapshots

4. **`Tests/SwiftModelTests/ConcurrencyTests.swift`** — `observeExpectFiringTiming` test already there; may want to add a test verifying the race is eliminated

## Already Committed Work

- **Layer A** (enriched chain messages): committed on branch `improvements3`
- **`lastState` vs `expectedState` crash fix**: committed — `didModify` now uses `lastState` instead of `expectedState` for capturing the "from" value on first write to a path through a container type
- **`_TimingLoader` empirical test**: `ConcurrencyTests.observeExpectFiringTiming` committed

## Key Invariants to Preserve

- `lastState` is always immediately updated in `didModify` (unchanged)
- `expectedState` advances only when an assertion passes (unchanged — but now means "front entries consumed")
- The lock discipline in `didModify` / `willAccess` (post-lock callbacks) is unchanged
- Linux compatibility — no ObjC, no `DispatchQueue`-only APIs
- Swift 6 strict concurrency throughout
