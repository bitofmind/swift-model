[← Back to README](../README.md)

## Events

It is common that models need to communicate up or down the model hierarchy. Often it is most natural to set up a callback closure for children to communicate back to parents, or for parents to call methods directly on children. But for more complicated setups, SwiftModel also supports sending events up and down the model hierarchy.

```swift
enum AppEvent {
  case logout
}

func onLogoutTapped() { // ChildModel
  node.send(AppEvent.logout)
}

func onActivate() { // AppModel
  node.forEach(node.event(of: AppEvent.logout)) {
    user = nil
  }
}
```

By default an event is sent to the sending model itself and any of its ancestors, but you can override that behavior by providing a custom receivers list.

```swift
node.send(AppEvent.userWasLoggedOut, to: .descendants)
```

Often events are specific to one type of model, and SwiftModel adds special support for `Model`'s using their `Event` extension point.

```swift
@Model struct StandupDetail {
  enum Event {
    case deleteStandup
    case startMeeting
  }

  func deleteButtonTapped() {
    node.send(.deleteStandup)
  }
}
```

Now you can explicitly ask for events from composed models, and you will also receive an instance of the sending model.

```swift
node.forEach(node.event(fromType: StandupDetail.self)) { event, standupDetail in
  switch event {
  case .deleteStandup: ...
  case .startMeeting: ...
  }
}
```

### Event Routing

By default events travel to `[.self, .ancestors]` — the sending model and all of its parents. Override this with an explicit `to:` argument:

```swift
node.send(AppEvent.syncRequired, to: .descendants)       // broadcast down
node.send(AppEvent.refresh, to: [.self, .children])      // only immediate children
node.send(AppEvent.logout, to: [.self, .ancestors, .descendants])  // entire tree
```

Available relations:

| Relation | Direction |
|---|---|
| `.self` | The sending model only |
| `.ancestors` | All parents and grandparents (default upward path) |
| `.descendants` | All children and grandchildren |
| `.children` | Direct children only |
| `.dependencies` | Dependency models at each visited node |

### Events vs. Callbacks

The right choice depends on coupling:

**Use a callback closure** when the parent creates the child and already knows what to do. It is simpler, more explicit, and directly testable with `TestProbe`:

```swift
@Model struct RecordMeetingModel {
    let onSave: @Sendable (String) -> Void
    let onDiscard: @Sendable () -> Void
}
```

**Use events** when the communication crosses several levels of the hierarchy, when multiple models might listen, or when you want to avoid threading a closure through intermediaries:

```swift
// Any ancestor can listen — no closure threading required
node.forEach(node.event(of: AppEvent.logout)) {
    user = nil
}
```

Events are also a natural fit when the sender doesn't know who the receiver is — for example, a deep leaf model that triggers a navigation pop or a global state reset at the root.
