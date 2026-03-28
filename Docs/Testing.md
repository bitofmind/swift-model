[← Back to README](../README.md)

## Testing

Because SwiftModel owns and tracks all of a model's state, events, and async tasks, it can make tests exhaustive by default: any side effect you didn't explicitly assert causes the test to fail. This catches regressions that are invisible to ordinary unit tests.

### Setup

Add the `.modelTesting` trait to `@Test` or `@Suite`, then call `withAnchor()` as usual inside the test body. Override dependencies in the `withAnchor` closure:

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

> Assertions must `await` because state and event propagation is asynchronous.

### Xcodeproj App-Hosted Tests

SPM-based packages work with no extra configuration — `import SwiftModel` is all you need.

If your test target uses `BUNDLE_LOADER` (the Xcode default for xcodeproj targets that test an app binary), two build settings are required on the **app target** (not the test target):

```
ENABLE_TESTING_SEARCH_PATHS = YES
OTHER_LDFLAGS = $(inherited) -weak_framework Testing
```

`ENABLE_TESTING_SEARCH_PATHS` makes the testing APIs available inside the app binary, which the test bundle inherits at runtime via `BUNDLE_LOADER`. `-weak_framework Testing` is required so the app doesn't crash at launch outside a test context — without it, `Testing.framework` is hard-linked and dyld fails to find it when the app runs standalone.

Do **not** add `SwiftModel` to the test target's Frameworks — the test bundle gets all symbols from the app, and adding extra links creates duplicate symbol errors.

The `expect` builder block accepts any number of predicates. Using `==` gives you a pretty-printed diff on failure; any other `Bool` expression also works:

```swift
await expect {
    model.count == 42          // diff on failure: shows actual vs expected
    model.isLoading == false   // diff on failure: shows actual vs expected
    model.title.hasPrefix("A") // no left/right diff — but model.title is still tracked as asserted
}
```

Use `require` to wait for an optional child model to appear before interacting with it:

```swift
let row = try await require(model.counters.first)
row.counter.incrementTapped()
await expect(row.counter.count == 1)
```

### Asserting Callbacks

Pass a `TestProbe` wherever the model expects a callback closure. Probe invocations are automatically tracked and exhaustion checking is enabled by default:

```swift
@Test(.modelTesting) func testFactButtonTapped() async {
    let onFact = TestProbe()
    let model = CounterModel(count: 2, onFact: onFact.call).withAnchor {
        $0.factClient.fetch = { "\($0) is a good number." }
    }

    model.factButtonTapped()

    await expect(onFact.wasCalled(with: 2, "2 is a good number."))
}
```

`TestProbe` also supports `callAsFunction`, so you can write `onFact: probe` directly instead of `onFact: probe.call`.

### Asserting Events

Assert that a model sent an event using `didSend(_:)` inside an `expect` block:

```swift
@Test(.modelTesting) func testContinueWithoutRecording() async throws {
    let model = StandupDetail(standup: .mock).withAnchor {
        $0.speechClient.authorizationStatus = { .denied }
    }

    model.startMeetingButtonTapped()
    try await require(model.destination?.speechRecognitionDenied).continue()

    await expect {
        model.destination?.speechRecognitionDenied != nil
        model.didSend(.startMeeting)
    }
}
```

### Exhaustivity

By default the trait enforces exhaustivity across six categories — any unasserted effect in any category fails the test at the end of the test function:

- **`.state`** — every state change must be consumed by an `expect` block
- **`.events`** — every event sent via `node.send()` must be observed with `didSend(_:)`
- **`.tasks`** — all async tasks must complete or be cancelled before the test ends
- **`.probes`** — every installed `TestProbe` invocation must be consumed by `wasCalled`
- **`.local`** — every `node.local` write must be consumed by an `expect` block
- **`.environment`** — every `node.environment` write must be consumed by an `expect` block
- **`.preference`** — every `node.preference` write must be consumed by an `expect` block

To focus a test on only some categories, pass an exhaustivity argument to `.modelTesting`:

```swift
// Absolute exhaustivity
@Test(.modelTesting(exhaustivity: .off))
@Test(.modelTesting(exhaustivity: [.state, .events]))

// Relative modifier — composes with the enclosing suite's exhaustivity
@Suite(.modelTesting(.removing(.events)))
struct MyTests {
    @Test(.modelTesting(.removing(.tasks)))  // → .full − .events − .tasks
    func example() async { }
}
```

You can also temporarily change exhaustivity for part of a test body using either an absolute value or a relative modifier:

```swift
// Absolute — turn exhaustivity off entirely for this block
await withExhaustivity(.off) {
    model.triggerSideEffects()
}

// Relative — remove a specific category while keeping the rest
await withExhaustivity(.removing(.state)) {
    model.triggerSideEffects()
}
```

### Time Control

Models that use `node.continuousClock` for timers — such as polling loops or countdowns — are fully testable without real wall-clock delays. Inject a `TestClock` (from [swift-clocks](https://github.com/pointfreeco/swift-clocks)) via `withAnchor` and advance time explicitly in your test:

```swift
// Model under test
@Model struct TimerModel {
    var secondsElapsed = 0

    func onActivate() {
        node.forEach(node.continuousClock.timer(interval: .seconds(1))) { _ in
            secondsElapsed += 1
        }
    }
}

// Test
@Test(.modelTesting) func testTimer() async throws {
    let clock = TestClock()
    let model = TimerModel().withAnchor {
        $0.continuousClock = clock
    }

    await clock.advance(by: .seconds(1))
    await expect(model.secondsElapsed == 1)

    await clock.advance(by: .seconds(2))
    await expect(model.secondsElapsed == 3)
}
```

For tests that only care about the end result and not intermediate timer ticks, use `ImmediateClock()` instead. It fires all timer intervals synchronously, letting the model reach its final state without manual advancement:

```swift
@Test(.modelTesting(exhaustivity: .off)) func testTimerFinal() async {
    let model = TimerModel().withAnchor {
        $0.continuousClock = ImmediateClock()
    }
    await expect(model.secondsElapsed > 0)
}
```

### Settling

Models that perform async work during activation — loading data in `onActivate()`, subscribing to streams, or triggering `forEach` callbacks — may not be fully ready when `withAnchor()` returns. Asserting every intermediate state change produced during activation is tedious and brittle. Use `settle()` to wait for activation to complete, then reset the exhaustivity baseline so your test only covers post-activation behaviour:

```swift
@Model struct DashboardModel {
    var items: [Item] = []
    var isLoading = false
    var lastSyncDate: Date? = nil

    func onActivate() {
        node.task {
            isLoading = true
            items = try await fetchItems()
            isLoading = false
            lastSyncDate = .now
        }
    }
}

@Test(.modelTesting) func testRefresh() async {
    let model = DashboardModel().withAnchor()

    // Four state changes happen during activation: isLoading (true), items,
    // isLoading (false), lastSyncDate. settle() lets all of that complete
    // and clears the baseline so the test only cares about what happens after.
    await settle()

    // Baseline is now clean — only changes after this point are tracked.
    model.refresh()
    await expect { model.lastSyncDate != nil }
}
```

Settling performs three steps after the predicate passes:

1. **Wait for activation tasks** — all tasks started from `onActivate()` must enter their body.
2. **Idle cycle** — waits until one full scheduling round passes with no state changes, ensuring `forEach` callbacks and cascading effects have settled.
3. **Reset baseline** — clears tracked state changes, events, and probe calls so exhaustivity only covers post-settling behaviour.

If you don't need to verify the activation outcome, use `settle()` with no predicate to just let activation finish and reset the baseline:

```swift
@Test(.modelTesting) func testUserInteraction() async {
    let model = ItemListModel().withAnchor()
    await settle()

    // Test user interactions without worrying about activation details.
    model.refresh()
    await expect { model.items.count > 0 }
}
```

To selectively reset specific exhaustivity categories, pass a `resetting:` parameter. For example, to keep events from activation visible to subsequent assertions:

```swift
await settle(resetting: .full.removing(.events)) { model.activated == true }
// Events sent during activation are still tracked and can be asserted.
await expect { model.didSend(.loaded) }
```

Without `settle()`, the test would need to assert every intermediate state change caused by activation — brittle and unnecessary when you only care about the steady state.

### Failure Messages

SwiftModel produces specific, actionable failure messages for every category. Here is what each looks like.

**`expect` predicate not met** — shows actual vs expected with a diff:

```
Expectation not met: Counter.count: …

    − 99
    + 3

(Expected: −, Actual: +)
```

**Unasserted state change** — shows the property and its final value:

```
State not exhausted: …

Modifications not asserted:

    Counter.count == 42
```

**Unasserted event** — names the event type and the model it came from:

```
Event `CounterModel.Event.incrementTapped` sent from `CounterModel` was not handled
```

**Active tasks still running** — names each task and links to its registration call site in Xcode:

```
Models of type `SyncModel` have 2 active tasks still running
Active task 'upload' of `SyncModel` still running  → SyncModel.swift:34
Active task 'validate' of `SyncModel` still running  → SyncModel.swift:35
```

**Probe called but not consumed** — shows the argument values that were passed:

```
Expected probe not called "onFact":
    (id: 2, fact: "2 is a perfect number.")
```

### Refactor-Resilient Tests

SwiftModel tests assert **final state**, not the sequence of actions or effects that produced it. This means you can freely restructure model internals — split a method, rename a case, change how async work is dispatched — and existing tests continue to pass as long as the observable outcome is unchanged.

TCA tests encode the full action sequence: renaming an action case or splitting an effect requires rewriting tests even when visible behaviour is identical. SwiftModel has no action enum, so there is nothing to encode and nothing to break.
