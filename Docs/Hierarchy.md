[← Back to README](../README.md)

## The Model Hierarchy

SwiftModel knows every parent-child relationship in your app, and that tree is more than structure — it's how models communicate without being wired together by hand. The same hierarchy carries three things:

- **Events** — typed messages sent up or down the tree.
- **Shared values** — environment flowing *down*, preferences aggregating *up*, local storage staying put.
- **Queries** — reading or folding state across any region of the tree.

Which models a given operation reaches is described by a `ModelRelation` option set, used the same way throughout:

| Relation | Reaches |
|---|---|
| `.self` | the model itself |
| `.parent` / `.ancestors` | one hop up / all ancestors |
| `.children` / `.descendants` | one hop down / all descendants |
| `.dependencies` | dependency models at each visited node |

Combine them freely: `[.self, .descendants]` is the model plus its whole subtree.

## Events

Models often need to talk across the hierarchy. The simplest tools are a callback closure (child → parent) or a direct method call (parent → child). For looser coupling — when the communication crosses several levels, may have multiple listeners, or the sender doesn't know the receiver — send a typed event:

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

A model can also declare its own `Event` type; listeners then receive both the event and the sending model instance:

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

By default an event travels to `[.self, .ancestors]` — the sender and its parents. Override with `to:` to broadcast elsewhere:

```swift
node.send(AppEvent.syncRequired, to: .descendants)                 // broadcast down
node.send(AppEvent.refresh, to: [.self, .children])               // immediate children
node.send(AppEvent.logout, to: [.self, .ancestors, .descendants]) // whole tree
```

**Events vs. callbacks.** Reach for a **callback** when the parent creates the child and already knows what to do — it's explicit and directly testable with `TestProbe`. Reach for **events** when the communication crosses several levels, multiple models might listen, or you'd otherwise thread a closure through intermediaries that don't care about it.

## Sharing values across the tree

Environment, preferences, and local storage let models share data without passing it through every initialiser. Each is declared by extending its namespace type with a computed property returning a storage descriptor, and accessed through `node`.

**Local storage — node-private.** Stays on one node; not inherited by descendants.

```swift
extension LocalKeys {
    var isFeatureEnabled: LocalStorage<Bool> { .init(defaultValue: false) }
}

node.local.isFeatureEnabled = true
node.removeLocal(\.isFeatureEnabled)   // back to default
```

**Environment — top-down.** A write on any ancestor is visible to all descendants; reading walks up to the nearest ancestor that set the value, falling back to the default. A descendant can locally override for its own subtree.

```swift
extension EnvironmentKeys {
    var isLoggedIn: EnvironmentStorage<Bool> { .init(defaultValue: false) }
}

rootModel.node.environment.isLoggedIn = true            // set for the whole subtree
let loggedIn = childModel.node.environment.isLoggedIn   // inherited
node.removeEnvironment(\.isLoggedIn)                    // drop a local override
```

**Preferences — bottom-up.** A preference descriptor carries a `reduce` closure that folds each node's contribution together. Any ancestor reads the aggregate of its whole subtree (self + descendants).

```swift
extension PreferenceKeys {
    var hasUnsavedChanges: PreferenceStorage<Bool> {
        .init(defaultValue: false) { $0 = $0 || $1 }
    }
}

node.preference.hasUnsavedChanges = isDirty            // each node contributes
let anyDirty = parentNode.preference.hasUnsavedChanges // aggregate over subtree
node.removePreference(\.hasUnsavedChanges)
```

All three participate in observation: wrap a read in `Observed { … }` and the stream re-fires when any contributing node changes — or when nodes are added to or removed from the subtree.

## Querying the tree

`node.mapHierarchy` and `node.reduceHierarchy` read across the models a `ModelRelation` selects — `mapHierarchy` collects non-nil transform results, `reduceHierarchy` folds into an accumulator:

```swift
// nearest ancestor of a type
let app = node.mapHierarchy(for: .ancestors) { $0 as? AppModel }.first

// sum across the subtree
let total = node.reduceHierarchy(
    for: [.self, .descendants],
    transform: { ($0 as? CounterModel)?.count },
    into: 0
) { $0 += $1 }
```

Combining a query with `Observed` yields a stream that tracks *both* property changes and structural changes across a whole subtree — a pattern most architectures can't express without manual subscriptions:

```swift
func onActivate() {
    // Re-evaluates when any descendant editor's isDirty changes,
    // AND when editors are added or removed.
    node.forEach(Observed { node.mapHierarchy(for: [.self, .descendants]) { ($0 as? EditorModel)?.isDirty } }) { flags in
        hasUnsavedChanges = flags.contains(true)
    }
}
```
