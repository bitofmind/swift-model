# SharedState

A tabbed app demonstrating how SwiftModel enables multiple views to share state without tightly coupling their models together.


## What it demonstrates

### Shared model identity

The `CounterTab` and `ProfileTab` models both hold a reference to the same `Stats` model instance. Changes made on one tab are immediately visible on the other — no synchronisation code required. This is the core concept: two independent parts of the UI operate on a single source of truth.

```swift
init(stats: Stats = Stats()) {
    _counter = CounterTab(stats: stats)  // same Stats instance
    _profile = ProfileTab(stats: stats)  // shared with counter
}
```

Incrementing on the Counter tab updates `stats.count`; switching to the Profile tab shows the new value immediately, because there is only one `Stats` model — not two copies that need to be kept in sync.

## App structure

| Tab | Model | Responsibility |
|-----|-------|---------------|
| Counter | `CounterTab` + `Stats` | Increment/decrement, prime check |
| Profile | `ProfileTab` + `Stats` | Display stats, reset (same `Stats` instance) |
