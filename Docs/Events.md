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
