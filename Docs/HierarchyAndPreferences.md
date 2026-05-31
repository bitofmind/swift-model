[← Back to README](../README.md)

## Environment, Local Storage, and Preferences

These let models share data across the hierarchy without threading it through every initialiser:

- **Environment** flows *downward* — like SwiftUI's `@Environment`.
- **Preferences** flow *upward* and aggregate — like SwiftUI's `PreferenceKey`.
- **Local storage** is private to a single node.

Each is declared by extending its namespace type with a computed property returning a storage descriptor, and accessed through `node`.

### Local storage — node-private

```swift
extension LocalKeys {
    var isFeatureEnabled: LocalStorage<Bool> { .init(defaultValue: false) }
}

node.local.isFeatureEnabled = true
let enabled = node.local.isFeatureEnabled
node.removeLocal(\.isFeatureEnabled)   // back to default
```

### Environment — top-down

A write on any ancestor is visible to all descendants; reading walks up to the nearest ancestor that set the value, falling back to the default. A descendant can locally override for its own subtree.

```swift
extension EnvironmentKeys {
    var isLoggedIn: EnvironmentStorage<Bool> { .init(defaultValue: false) }
}

rootModel.node.environment.isLoggedIn = true     // set for the whole subtree
let loggedIn = childModel.node.environment.isLoggedIn   // inherited
node.removeEnvironment(\.isLoggedIn)             // drop a local override
```

### Preferences — bottom-up

A preference descriptor carries a `reduce` closure that folds each node's contribution together. Any ancestor reads the aggregate of its whole subtree (self + descendants):

```swift
extension PreferenceKeys {
    var hasUnsavedChanges: PreferenceStorage<Bool> {
        .init(defaultValue: false) { $0 = $0 || $1 }
    }
}

node.preference.hasUnsavedChanges = isDirty       // each node contributes
let anyDirty = parentNode.preference.hasUnsavedChanges   // aggregate over subtree
node.removePreference(\.hasUnsavedChanges)
```

All three participate in observation: wrap a read in `Observed { … }` and the stream re-fires when any contributing node changes — or when nodes are added to or removed from the subtree.

## Traversing the hierarchy

SwiftModel knows every parent-child relationship, exposed through `node.mapHierarchy` and `node.reduceHierarchy`. Both take a `ModelRelation` option set selecting which models to visit:

| Relation | Visits |
|---|---|
| `.self` | the model itself |
| `.parent` / `.ancestors` | one hop up / all ancestors |
| `.children` / `.descendants` | one hop down / all descendants |
| `.dependencies` | dependency models at each visited node |

`mapHierarchy` collects non-nil transform results; `reduceHierarchy` folds into an accumulator:

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

### Observing across the hierarchy

Combining `Observed` with a hierarchy query yields a stream that tracks *both* property changes and structural changes across a whole subtree — a pattern most architectures can't express without manual subscriptions:

```swift
func onActivate() {
    // Re-evaluates when any descendant editor's isDirty changes,
    // AND when editors are added or removed.
    node.forEach(Observed { node.mapHierarchy(for: [.self, .descendants]) { ($0 as? EditorModel)?.isDirty } }) { flags in
        hasUnsavedChanges = flags.contains(true)
    }
}
```
