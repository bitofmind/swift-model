# Search — GitHub Repository Browser

A GitHub repository search app that demonstrates real-world async patterns in SwiftModel.

## What this example shows

| Pattern | Where |
|---|---|
| Cancel-in-flight | `SearchModel.onActivate()` — `node.forEach(Observed { query }, cancelPrevious: true)` cancels the previous search task on each new keystroke |
| Per-item async loading | `SearchResultItem.onActivate()` — `node.task` loads a detail line per row, cancelled automatically when the item is removed |
| `observeAnyModification()` | `FilterModel.onActivate()` — fires whenever any property in the model changes; useful for autosave |
| Targeted debug | `SearchModel.onActivate()` — `Observed(debug: [.triggers(), .changes()]) { (query, results.count) }` prints only when those two properties change |
| `withActivation` | Previews and tests inject extra setup (e.g. pre-set query) without touching `onActivate()` |
| Optional child models | `filter: FilterModel?` and `detail: RepoDetailModel?` — exist only while their sheets are open |
| Deep links | `AppModel.handleURL(_:)` sets `search.query` from a `githubsearch://search?q=…` URL |

## Project structure

```
SearchApp.swift        — App entry point; attaches .withDebug() for console logging
GitHubClient.swift     — @ModelDependency with live (GitHub API), preview, and test values
SearchFeature.swift    — All models and views
```

## Key code patterns

### Cancel-in-flight search

```swift
node.forEach(Observed { query }, cancelPrevious: true) { q in
    await search(for: q)
}
```

Each new value of `query` cancels the previous `search(for:)` task before starting the next.
`Observed { query }` also emits the **current** value immediately on activation, so the search
starts right away without needing a separate trigger.

### Per-item async loading (node.task)

```swift
func onActivate() {
    node.task {
        try await Task.sleep(for: .milliseconds(200))
        detailLine = repo.language.map { "Written in \($0)" } ?? "Language unknown"
    } catch: { _ in }
}
```

The task is tied to the item's lifetime: when `SearchResultItem` is removed from `results`,
the task is cancelled automatically — no manual cleanup needed.

### withActivation in previews

```swift
AppView(model: AppModel()
    .withActivation { app in
        app.search.results = Repo.mocks.map { SearchResultItem(repo: $0) }
        app.search.query   = "swift"
    }
    .withAnchor())
```

`withActivation` runs its block right after `onActivate()`, letting you inject extra state
for a preview or test without modifying the model itself.

## Tests

```
SearchTests/SearchTests.swift
```

The tests use `@Suite(.modelTesting(exhaustivity: .off))` because the async search pipeline
produces intermediate `isSearching` state transitions that are not the focus of the assertions.

| Test | What it checks |
|---|---|
| `cancelInFlight` | Only the second (non-cancelled) query's results land |
| `searchCallsClientWithQuery` | `TestProbe` verifies the client receives the right query |
| `initialState` | `settle()` drains activation, then model is idle and empty |
| `filterSortsByName` | Applying sort-by-name reorders `results` alphabetically |
| `emptyQueryClearsResults` | Setting `query = ""` clears results immediately |
| `deepLinkSetsQuery` | `handleURL` with `githubsearch://search?q=vapor` sets the query |
| `withActivationPrePopulatesResults` | `withActivation { $0.query = "swift" }` triggers a search during activation |
