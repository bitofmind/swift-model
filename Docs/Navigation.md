[← Back to README](../README.md)

## Navigation

Navigation state *is* model state. A sheet, a pushed screen, or a multi-destination flow is just an optional or an enum child model — no navigation library, no wrappers.

### Sheets and modals

Hold an optional `@ModelContainer` enum as state and present it with a case key-path binding (requires [swift-case-paths](https://github.com/pointfreeco/swift-case-paths)):

```swift
@Model struct StandupDetail {
    var destination: Destination?

    @ModelContainer @CasePathable @dynamicMemberLookup
    enum Destination: Sendable {
        case edit(StandupForm)
        case deleteConfirmation
    }

    func editButtonTapped() { destination = .edit(StandupForm(standup: standup)) }
}

// in the view:
.sheet(item: $model.destination.edit) { form in
    StandupFormView(model: form)
}
```

Setting `destination = nil` dismisses the sheet automatically.

### Stacks

Represent a navigation stack as an array of enum cases and bind it straight to `NavigationStack`:

```swift
@Model struct AppFeature {
    var path: [Path] = []

    @ModelContainer @CasePathable @dynamicMemberLookup
    enum Path: Hashable, Identifiable {
        case detail(StandupDetail)
        case record(RecordMeeting)
    }

    func standupTapped(_ standup: Standup) {
        path.append(.detail(StandupDetail(standup: standup)))
    }
}

// in the view:
NavigationStack(path: $model.path) {
    StandupsListView(model: model.standupsList)
        .navigationDestination(for: AppFeature.Path.self) { path in
            switch path {
            case let .detail(model): StandupDetailView(model: model)
            case let .record(model): RecordMeetingView(model: model)
            }
        }
}
```

> `NavigationStack` requires path elements to be `Hashable`; declaring `: Identifiable` additionally makes `[Path]` a `ModelContainer`, so each pushed screen gets a live context — its `onActivate` runs when pushed, tasks cancel when popped. `@ModelContainer` synthesises both conformances (and `id`); you never write `==`, `hash(into:)`, or `var id` by hand. (`@Model` values compare and hash by identity.)

### Deep links

Since navigation is plain state, programmatic navigation and deep links are direct mutations — no special infrastructure:

```swift
func handleDeepLink(_ url: URL) {
    path = [.detail(StandupDetail(standup: loadStandup(from: url)))]
}
```
