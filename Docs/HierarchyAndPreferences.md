[← Back to README](../README.md)

## Traversing the Hierarchy

SwiftModel maintains full knowledge of the parent-child relationships between all models in your application. The `node.reduceHierarchy` and `node.mapHierarchy` helpers expose this information so you can query or aggregate data across any portion of the hierarchy.

### ModelRelation

Both helpers accept a `ModelRelation` option set that controls which models are visited:

| Relation | Description |
|---|---|
| `.self` | Only the model itself |
| `.parent` | Direct parents (one hop up) |
| `.ancestors` | All ancestors recursively (parents, grandparents, …) |
| `.children` | Direct children (one hop down) |
| `.descendants` | All descendants recursively |
| `.dependencies` | Also include dependency models at each visited node |

Relations can be combined freely: `[.self, .descendants]` visits the model and its entire subtree.

### mapHierarchy

`mapHierarchy` applies a transform closure to each visited model and collects the non-nil results into an array:

```swift
// Find the nearest ancestor AppModel
let appModel = node.mapHierarchy(for: .ancestors) { $0 as? AppModel }.first

// Collect all descendant models of a specific type
let counters = node.mapHierarchy(for: [.self, .descendants]) { $0 as? CounterModel }
```

### reduceHierarchy

`reduceHierarchy` is the general form. It lets you fold results into an accumulator, which is useful when building up non-array results:

```swift
// Sum all counts across the descendant subtree
let total = node.reduceHierarchy(
    for: [.self, .descendants],
    transform: { ($0 as? CounterModel)?.count },
    into: 0
) { $0 += $1 }
```

### Observation with Hierarchy Traversal

Combining `Observed` with `mapHierarchy` or `reduceHierarchy` creates a stream that automatically tracks *both* property changes and structural changes across an entire subtree. This is a uniquely powerful pattern that most architectures cannot express without manual subscriptions.

```swift
func onActivate() {
    // Re-evaluates when count changes on any CounterModel in the hierarchy,
    // AND when counters are added or removed.
    node.forEach(Observed { node.mapHierarchy(for: [.self, .descendants]) { ($0 as? CounterModel)?.count } }) { counts in
        total = counts.reduce(0, +)
    }
}
```

The stream re-evaluates in two situations:
- **Property change**: any `count` on any visited `CounterModel` changes
- **Structural change**: a child model is added or removed from the hierarchy

A practical real-world example — a document model that tracks whether any sub-editor has unsaved changes:

```swift
@Model struct DocumentModel {
    var editors: [EditorModel] = []
    var hasUnsavedChanges = false

    func onActivate() {
        node.forEach(Observed { node.mapHierarchy(for: [.self, .descendants]) { ($0 as? EditorModel)?.isDirty } }) { dirtyFlags in
            hasUnsavedChanges = dirtyFlags.contains(true)
        }
    }
}
```

When a new `EditorModel` is added to `editors`, the stream immediately includes its `isDirty` property in the tracking set — no manual subscription needed.

## Context and Preferences

Context and preferences let models share data across the model hierarchy without explicit parent-to-child passing. **Context** flows downward (like SwiftUI's `@Environment`); **preferences** flow upward (like SwiftUI's `PreferenceKey`).

Both systems are declared by extending a namespace type with computed properties. Context storage comes in two flavours: **local** (node-private, not inherited) via `node.local`, and **environment** (top-down propagation, like SwiftUI's `@Environment`) via `node.environment`. Preferences are accessed via `node.preference`.

### Local storage — node-private

For values that belong to a single node and should not be inherited by descendants, extend `LocalKeys` with a computed property returning a `LocalStorage` descriptor:

```swift
extension LocalKeys {
    var isFeatureEnabled: LocalStorage<Bool> {
        .init(defaultValue: false)
    }
}
```

Read and write via `node.local`:

```swift
node.local.isFeatureEnabled = true      // write
let enabled = node.local.isFeatureEnabled  // read
```

To clear back to the default value:

```swift
node.removeLocal(\.isFeatureEnabled)
```

### Environment storage — top-down propagation

For values that should automatically flow to all descendants — like a colour scheme, a selection state, or an editing mode — extend `EnvironmentKeys` with a computed property returning an `EnvironmentStorage` descriptor:

```swift
extension EnvironmentKeys {
    var colorScheme: EnvironmentStorage<ColorScheme> {
        .init(defaultValue: .light)
    }
}
```

A write on any ancestor is visible to all descendants. Reading walks up the hierarchy to the nearest ancestor that has set the value, returning `defaultValue` if none has:

```swift
// Parent sets the scheme for its entire subtree:
parentModel.node.environment.colorScheme = .dark

// Any descendant reads it (returns .dark — inherited from parent):
let scheme = childModel.node.environment.colorScheme

// A child can locally override it; only that child and its descendants see the override:
childModel.node.environment.colorScheme = .light
```

To remove a local override and go back to inheriting from the nearest ancestor:

```swift
node.removeEnvironment(\.colorScheme)
```

### Preferences — bottom-up aggregation

Declare a preference key by extending `PreferenceKeys` with a computed property that returns a `PreferenceStorage` descriptor. The descriptor includes a `reduce` closure that folds contributions together:

```swift
extension PreferenceKeys {
    var totalCount: PreferenceStorage<Int> {
        .init(defaultValue: 0) { $0 += $1 }
    }
    var hasUnsavedChanges: PreferenceStorage<Bool> {
        .init(defaultValue: false) { $0 = $0 || $1 }
    }
}
```

Each node writes its own contribution:

```swift
node.preference.totalCount = 3
```

Any ancestor reads the aggregate of the whole subtree (self + all descendants):

```swift
let total = parentNode.preference.totalCount  // sum of all contributions in subtree
```

To remove a node's contribution:

```swift
node.removePreference(\.totalCount)
```

Both reads and writes participate in SwiftModel's observation system: wrapping a read in `Observed { ... }` creates a stream that re-fires whenever any contributing node changes, or when nodes are added or removed from the subtree.

### Common patterns

**Propagating a colour scheme / theme:**

```swift
extension EnvironmentKeys {
    var theme: EnvironmentStorage<AppTheme> {
        .init(defaultValue: .default)
    }
}

// Root model sets the theme once:
func onActivate() {
    node.environment.theme = userPreferences.theme
}

// Any descendant reads it:
let colors = node.environment.theme.colors
```

**Aggregating unsaved-changes across a subtree:**

```swift
extension PreferenceKeys {
    var hasUnsavedChanges: PreferenceStorage<Bool> {
        .init(defaultValue: false) { $0 = $0 || $1 }
    }
}

// Each editor signals its own dirty state:
func onActivate() {
    node.forEach(Observed { isDirty }) { dirty in
        node.preference.hasUnsavedChanges = dirty
    }
}

// The document root reads the aggregate:
var showsUnsavedIndicator: Bool {
    node.preference.hasUnsavedChanges
}
```
