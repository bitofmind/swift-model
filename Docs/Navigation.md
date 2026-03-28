[← Back to README](../README.md)

## Navigation

Navigation state is just model state. A modal sheet, a pushed screen, or a multi-destination flow is expressed as an optional or an enum child model — no wrappers, no navigation libraries required.

### Modal / sheet navigation

Declare a `Destination` enum annotated with `@ModelContainer` and `@CasePathable`, then hold an optional instance as model state:

```swift
@Model struct StandupDetail {
    var standup: Standup
    var destination: Destination?

    @ModelContainer @CasePathable
    @dynamicMemberLookup
    enum Destination: Sendable {
        case edit(StandupForm)
        case deleteConfirmation
    }

    func editButtonTapped() {
        destination = .edit(StandupForm(standup: standup))
    }

    func onActivate() {
        node.forEach(node.event(fromType: StandupForm.self)) { event, form in
            switch event {
            case .save:
                standup = form.standup
                destination = nil
            case .discard:
                destination = nil
            }
        }
    }
}
```

In the view, use `.sheet(item:)` with a case key-path binding (requires [`swift-case-paths`](https://github.com/pointfreeco/swift-case-paths)):

```swift
struct StandupDetailView: View {
    @ObservedModel var model: StandupDetail

    var body: some View {
        List { ... }
            .sheet(item: $model.destination.edit) { form in
                StandupFormView(model: form)
            }
    }
}
```

Setting `destination = nil` dismisses any active sheet automatically.

### Stack navigation

Represent a navigation stack as an array of `@ModelContainer` enum cases. Each case carries the model for that screen:

```swift
@Model struct AppFeature {
    var standupsList = StandupsList()
    var path: [Path] = []

    // Declare Hashable and Identifiable — @ModelContainer synthesises both.
    // Hashable: @Model values compare/hash by identity; Equatable/Hashable values use full equality.
    // Identifiable: the synthesised `var id` makes [Path] a ModelContainer, so each pushed
    // screen gets its own live context in the model hierarchy.
    @ModelContainer @CasePathable
    @dynamicMemberLookup
    enum Path: Hashable, Identifiable {
        case detail(StandupDetail)
        case record(RecordMeeting)
    }

    func standupTapped(_ standup: Standup) {
        path.append(.detail(StandupDetail(standup: standup)))
    }
}
```

In the view, bind `$model.path` directly to `NavigationStack`:

```swift
struct AppView: View {
    @ObservedModel var model: AppFeature

    var body: some View {
        NavigationStack(path: $model.path) {
            StandupsListView(model: model.standupsList)
                .navigationDestination(for: AppFeature.Path.self) { path in
                    switch path {
                    case let .detail(model): StandupDetailView(model: model)
                    case let .record(model): RecordMeetingView(model: model)
                    }
                }
        }
    }
}
```

> `NavigationStack` requires path elements to be `Hashable`. Declaring `: Identifiable` additionally makes `[Path]` conform to `ModelContainer`, so each screen on the stack gets a live context in the model hierarchy — its `onActivate` runs when pushed, and tasks cancel when popped. Both conformances are synthesised automatically by `@ModelContainer`; you never need to write `==`, `hash(into:)`, or `var id` by hand.

### Deep links and programmatic navigation

Because navigation state is plain model state, programmatic navigation is a direct array mutation:

```swift
func handleDeepLink(_ url: URL) {
    path = [.detail(StandupDetail(standup: loadStandup(from: url)))]
}
```

No special deep-link handling infrastructure is needed — change the state, SwiftUI reflects it.
