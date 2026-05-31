[← Back to README](../README.md)

## Events

Models often need to communicate across the hierarchy. The simplest tools are usually a callback closure (child → parent) or a direct method call (parent → child). For looser coupling — when the communication crosses several levels, may have multiple listeners, or the sender doesn't know the receiver — SwiftModel can send typed events up or down the tree.

```swift
enum AppEvent { case logout }

func onLogoutTapped() {                 // in a deep child
    node.send(AppEvent.logout)
}

func onActivate() {                     // in any ancestor
    node.forEach(node.event(of: AppEvent.logout)) {
        user = nil
    }
}
```

Models can also declare their own `Event` type. Listeners then receive both the event and the sending model instance:

```swift
@Model struct StandupDetail {
    enum Event { case deleteStandup, startMeeting }

    func deleteButtonTapped() { node.send(.deleteStandup) }
}

// in the parent:
node.forEach(node.event(fromType: StandupDetail.self)) { event, detail in
    switch event { case .deleteStandup: …; case .startMeeting: … }
}
```

### Routing

By default an event travels to `[.self, .ancestors]` — the sender and its parents. Override with an explicit `to:`:

```swift
node.send(AppEvent.syncRequired, to: .descendants)              // broadcast down
node.send(AppEvent.refresh, to: [.self, .children])            // immediate children
node.send(AppEvent.logout, to: [.self, .ancestors, .descendants])  // whole tree
```

| Relation | Direction |
|---|---|
| `.self` | the sending model only |
| `.ancestors` | all parents and grandparents (default upward path) |
| `.descendants` | all children and grandchildren |
| `.children` | direct children only |
| `.dependencies` | dependency models at each visited node |

### Events vs. callbacks

Reach for a **callback** when the parent creates the child and already knows what to do — it's explicit and directly testable with `TestProbe`. Reach for **events** when the communication crosses several hierarchy levels, multiple models might listen, or you'd otherwise thread a closure through intermediaries that don't care about it.
