[← Back to README](../README.md)

## Models and Composition

Models are the central building block in SwiftModel. A model declares its state together with the operations on it, and composes with other models to form a hierarchy that propagates dependencies and events. Apply the `@Model` macro to a struct to set it up for composition and observation tracking:

```swift
import SwiftModel

@Model struct CountModel {
    var count = 0

    func decrementTapped() { count -= 1 }
    func incrementTapped() { count += 1 }
}
```

> **`@Model` structs behave like SwiftUI's `@State`.** The struct is a lightweight handle into a reference-counted backing store; `count += 1` writes through a context pointer to that store rather than mutating the struct. This is why setters are non-mutating (you can write to a `let model`) and why `[weak self]` is both unnecessary and rejected by the compiler. The hybrid is intentional: value semantics make snapshots, diffing, and undo trivial (a snapshot is a cheap struct copy), while reference semantics handle shared mutable state and any-thread mutation without `@MainActor`. See [Lifetime and Asynchronous Work](Lifecycle.md) for the threading model.

### No retain cycles — a structural guarantee

Because models are structs, the **compiler** makes retain cycles impossible: you can't take a `weak` reference to a struct, so `[weak self]` is a compile error rather than a discipline. Strong ownership lives in the hierarchy (parent → child); closures capture a context pointer, not a strong object reference. So you can freely store callbacks and capture `self` without risk:

```swift
@Model struct RecordMeetingModel {
    let onSave: @Sendable (String) -> Void
    let onDiscard: @Sendable () -> Void
}

@Model struct AppModel {
    var recording: RecordMeetingModel? = nil

    func startRecording() {
        recording = RecordMeetingModel(
            onSave: { transcript in self.saveTranscript(transcript) },  // safe — no retain cycle
            onDiscard: { self.recording = nil }                         // safe — no retain cycle
        )
    }
}
```

This is categorically stronger than reference-type architectures — a plain `@Observable` view model, an `ObservableObject`, any class-based store — where avoiding cycles relies on `[weak self]` discipline in every closure.

### Composition

Models compose as inline children, optionals, or collections:

```swift
@Model struct AppModel {
    var counters: [CounterRowModel] = []
    var factPrompt: FactPromptModel? = nil

    var sum: Int { counters.reduce(0) { $0 + $1.counter.count } }
}
```

> Each model has an identity and conforms to `Identifiable` (with a generated `id` unless you override it), which is how models are tracked in arrays. An [`IdentifiedArray`](https://github.com/pointfreeco/swift-identified-collections) is often safer than a plain array.

For SwiftModel to discover composed models, any container holding them must conform to `ModelContainer`. `@Model` provides this automatically; for your own enums and structs that nest models, use the `@ModelContainer` macro:

```swift
@ModelContainer enum Path {
    case detail(StandupDetail)
    case meeting(Meeting, standup: Standup)
}
```

It works on structs too, which makes reusable wrappers (a generic paginated list, say) transparent to the hierarchy — SwiftModel traverses into their model-typed properties for activation, observation, and event propagation.

### Anchoring and lifetime

A model is backed by a behind-the-scenes *context* holding its shared state, hierarchy relationships, and overridden dependencies. The context is held *weakly* by the model (this is what avoids cycles with callback closures); a model holds *strong* references to its children, but something has to anchor the root. That's `withAnchor()`:

```swift
struct MyApp: App {
    let model = AppModel().withAnchor()
    var body: some Scene {
        WindowGroup { AppView(model: model) }
    }
}
```

For a view created at most once you can anchor inline (`CounterView(model: CounterModel().withAnchor())`), and `returningAnchor()` hands back the model and anchor separately when you need to control the lifetime explicitly:

```swift
let (model, anchor) = AppModel().returningAnchor()
```

A model starts in an *initial* state, becomes *anchored* when added to an anchored hierarchy, and enters a *destructed* state when removed. (It can also be snapshotted into an immutable *frozen* copy — used for state-diff printing and test comparisons.)

### Activation

`onActivate()` is called once a model becomes part of an anchored hierarchy — the place to populate state from dependencies and set up listeners on child events and changes. Parents always activate before their children (so a parent can listen to its children); deactivation cancels a model's own work before its children's.

```swift
func onActivate() {
    if standup.attendees.isEmpty {
        standup.attendees.append(Attendee(id: .init(node.uuid())))
    }
}
```

You can also compose activation from the outside with `withActivation` (runs after `onActivate()`) and `withSetup` (runs before it) — handy for tests and previews. Both are covered in [Lifetime and Asynchronous Work](Lifecycle.md).

### Shared models

A model usually lives at one place in the hierarchy, but the same *instance* can live at several points at once. Unlike approaches that synchronise a copied *value* across consumers, a shared SwiftModel model is a single live instance — it keeps its full lifecycle, runs `onActivate()` once, and sends/receives events once (emissions and deliveries are coalesced across its locations). It's activated on first anchoring and deactivated when its last reference is removed, inheriting the dependencies of its initial entry point.

`node.isUniquelyReferenced` is `true` when a model has exactly one owner and `false` when shared. It participates in observation like any property, so you can drive logic from it — react with `onChange(of:)`, restart a `task(id:)` on it, or fold it into a computed property:

```swift
func onActivate() {
    node.onChange(of: node.isUniquelyReferenced) { _, isExclusive in
        isEditable = isExclusive
    }
}
```

## SwiftUI Integration

Where plain SwiftUI uses `ObservableObject` + `@ObservedObject`, SwiftModel uses `@Model` + `@ObservedModel`. Accessing child models and derived properties works the way you'd expect:

```swift
struct AppView: View {
    @ObservedModel var model: AppModel

    var body: some View {
        List {
            Text("Sum: \(model.sum)")
            ForEach(model.counters) { row in CounterRowView(model: row) }
        }
    }
}
```

> `@ObservedModel` triggers a view update only when a property the view actually reads changes — unlike `@ObservedObject`, which re-renders on any `@Published` change.

It also vends bindings to model properties (`$model.count`) for use with `Stepper`, `TextField`, and the rest.

### ModelScope

`ModelScope` confines observation to its content, so only that sub-tree re-renders when its reads change — rather than the whole enclosing view:

```swift
struct TrackView: View {
    var segment: SegmentModel  // no @ObservedModel — view stays stable

    var body: some View {
        baseTrackView.overlay {
            ModelScope {  // only this re-renders when isHovering changes
                if segment.isHovering { HoverOverlay() }
            }
        }
    }
}
```

On iOS 17+ it's a transparent pass-through (the platform already scopes observation per view). On iOS 16 it additionally fixes model reads inside lazy `@ViewBuilder` closures (`.sheet`, `.popover`, `NavigationStack` destinations) that otherwise wouldn't be observed.

## Debugging

See **[Debugging](Debugging.md)** for `withDebug()`, trigger tracing, and the `DebugOptions` shared by `memoize`, `Observed`, and view-side hooks.
