[← Back to README](../README.md)

## Testing

Because SwiftModel owns and tracks all of a model's state, events, and async tasks, tests are **exhaustive by default**: any side effect you don't explicitly assert fails the test. This catches the regressions ordinary unit tests miss — a loading flag that flickered, an error that appeared and cleared, a task left running.

### Setup

Add the `.modelTesting` trait, then anchor and drive the model as usual. Override dependencies in the `withAnchor` closure:

```swift
import Testing
import SwiftModel

@Test(.modelTesting) func testAddCounter() async {
    let model = AppModel().withAnchor {
        $0.factClient.fetch = { "\($0) is a good number." }
    }

    model.addButtonTapped()

    await expect(model.counters.count == 1)
}
```

Assertions `await` because state and event propagation are asynchronous.

> On Swift 6.0 the `.modelTesting` trait isn't available (it needs 6.1+); wrap the body in `await withModelTesting { … }` instead.

### Asserting state, callbacks, and events

`expect { }` accepts any number of `Bool` predicates and waits for them all to become true; `==` gives a pretty-printed diff on failure. Use `require` to wait for an optional child to appear before interacting with it:

```swift
await expect {
    model.count == 42
    model.isLoading == false
}

let row = try await require(model.counters.first)
row.counter.incrementTapped()
```

Pass a `TestProbe` wherever the model expects a callback closure — invocations are tracked automatically and asserted with `wasCalled`. Events sent via `node.send` are asserted with `didSend` inside an `expect` block:

```swift
let onFact = TestProbe()
let model = CounterModel(count: 2, onFact: onFact.call).withAnchor { … }
model.factButtonTapped()

await expect {
    onFact.wasCalled(with: 2, "2 is a good number.")
    model.didSend(.startMeeting)
}
```

### Exhaustivity

By default the trait enforces exhaustivity across these categories — anything unasserted fails the test at the end:

| Category | Must be consumed by |
|---|---|
| `.state` | an `expect` predicate reading the property (a `private`/`fileprivate` property is excluded — tests can't read it) |
| `.events` | `didSend(_:)` |
| `.tasks` | completing or being cancelled before the test ends |
| `.probes` | `wasCalled` |
| `.local` / `.environment` / `.preference` | an `expect` predicate |
| `.transitions` *(opt-in)* | sequential `expect` blocks matching recorded writes in order |

State failures show the full change chain from the baseline — including round trips that returned to the original value, which is how fire-and-forget mutations get caught:

```
Modifications not asserted:

    SearchModel.error: nil → NetworkError.timeout → nil
```

Scope a test to fewer categories with an absolute set or a relative modifier, at the suite, test, or block level:

```swift
@Test(.modelTesting(exhaustivity: [.state, .events]))   // only these
@Suite(.modelTesting(.removing(.events)))               // composes with enclosing suite

await withExhaustivity(.off) { model.triggerSideEffects() }  // for part of a body
```

### Settling

A model that does async work during activation — loading in `onActivate()`, subscribing to streams — may not be ready when `withAnchor()` returns, and asserting every intermediate activation change is brittle. `settle()` waits for activation to quiesce, then resets the exhaustivity baseline so your test covers only what happens *after*:

```swift
@Test(.modelTesting) func testRefresh() async {
    let model = DashboardModel().withAnchor()
    await settle()   // let activation finish; clear the baseline

    model.refresh()
    await expect { model.lastSyncDate != nil }
}
```

Pass a predicate (`settle { model.isReady }`) to also wait on a condition, or `resetting:` to keep some categories visible — e.g. `settle(resetting: .full.removing(.events))` lets events sent during activation still be asserted afterward.

### Time control

Inject a clock to test timers without real delays. A `TestClock` (from [swift-clocks](https://github.com/pointfreeco/swift-clocks)) advances explicitly; an `ImmediateClock` fires everything synchronously when you only care about the end state:

```swift
let clock = TestClock()
let model = TimerModel().withAnchor { $0.continuousClock = clock }

await clock.advance(by: .seconds(1))
await expect(model.secondsElapsed == 1)
```

### Refactor-resilient tests

SwiftModel tests assert **final state**, not the sequence of actions or effects that produced it. There is no action enum to enumerate and no `send`/`receive` script to keep in sync — you call a method and assert the outcome:

```swift
// Rename factButtonTapped(), split it into two, move work to a helper —
// the test keeps passing as long as model.fact ends up correct.
model.factButtonTapped()
await expect { model.fact == "42 is a great number" }
```

So you can freely restructure model internals and existing tests keep passing as long as the observable outcome is unchanged. The exhaustivity guarantee is undiminished — any state change you didn't assert is still a failure — the test is simply decoupled from *how* the model got there.

When you *do* want step-by-step fidelity — asserting each transition in order — opt into `.adding(.transitions)` and use sequential `expect` blocks, each matched against the next recorded write:

```swift
@Test(.modelTesting(.adding(.transitions))) func testFact() async {
    model.factButtonTapped()
    await expect { model.isLoading == true }     // loading starts
    await expect {
        model.isLoading == false                 // loading completes
        model.fact == "42 is a great number"
    }
}
```

> Architectures that test against an ordered action sequence (such as TCA's `send`/`receive`) make this trade-off everywhere on purpose: encoding each step gives precise control, at the cost of tests that must change when those steps are refactored. With SwiftModel it's opt-in, per test.

### Xcodeproj Setup

> **App target prerequisite:** any Xcode app target using SwiftModel must add `OTHER_LDFLAGS = $(inherited) -weak_framework Testing` to its build settings for the app to launch, independently of whether you have tests. See [Install](../README.md#install).

If your test target uses `BUNDLE_LOADER` (the Xcode default when testing an app binary), add one more setting on the **app target**:

```
ENABLE_TESTING_SEARCH_PATHS = YES
```

This makes the testing APIs available inside the app binary, which the test bundle inherits via `BUNDLE_LOADER`. Do **not** also add `SwiftModel` to the test target's Frameworks — the bundle gets all symbols from the app, and the extra link causes duplicate-symbol errors.
