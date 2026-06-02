[← Back to README](../README.md)

## Dependencies

Models reach external services — network clients, persistence, clocks — through a typed dependency system, resolved at the model's position in the hierarchy. That positioning is what makes dependencies trivial to override per-test, per-preview, or per-subtree.

> SwiftModel integrates with [swift-dependencies](https://github.com/pointfreeco/swift-dependencies) by Point-Free, so the growing ecosystem of community-built dependency wrappers works out of the box.

### Defining and accessing a dependency

Conform a type to `DependencyKey` for its live default, then extend `DependencyValues` for keypath access:

```swift
import Dependencies

struct FactClient {
    var fetch: @Sendable (Int) async throws -> String
}

extension FactClient: DependencyKey {
    static let liveValue = FactClient(fetch: { number in /* … real call … */ })
}

extension DependencyValues {
    var factClient: FactClient {
        get { self[FactClient.self] }
        set { self[FactClient.self] = newValue }
    }
}
```

Access it from inside the model via `node`:

```swift
let fact = try await node.factClient.fetch(count)
```

> `node` is the model's own interface to the runtime — dependencies, tasks, events, memoization, hierarchy queries. Use it from inside the model's implementation (`onActivate()`, methods, extensions), not from external consumers.

If you want a dependency to appear in the memberwise initialiser, declare it on the struct with `@ModelDependency` (pass a keypath when the type has no `DependencyKey` of its own):

```swift
@Model struct TimerModel {
    @ModelDependency(\.continuousClock) var clock: any Clock<Duration>
}
```

For most cases, `node.factClient` / `node.continuousClock` are simpler — no property needed.

### Overriding

Override defaults in a trailing closure when anchoring — the main path for tests and previews. Descendants inherit their parent's dependencies, and you can re-override a subtree with `withDependencies`:

```swift
let model = AppModel().withAnchor {
    $0.factClient.fetch = { "\($0) is a great number!" }
}

appModel.factPrompt = FactPromptModel(...).withDependencies {
    $0.factClient.fetch = { "\($0) is a great number!" }
}
```

### Models as dependencies

A `@Model` type can itself be a dependency. Conform it to `DependencyKey` and SwiftModel integrates it into the hierarchy as a **shared model** — one live instance across all consumers, with full lifecycle:

```swift
@Model struct AnalyticsService {
    var isEnabled = true
    func track(_ event: String) { … }
}

extension AnalyticsService: DependencyKey {
    static let liveValue = AnalyticsService()
    static let testValue = AnalyticsService()   // used automatically in tests
}

extension DependencyValues {
    var analyticsService: AnalyticsService {
        get { self[AnalyticsService.self] }
        set { self[AnalyticsService.self] = newValue }
    }
}
```

Because it's a real model, host models can observe its properties and exchange events with it, just like any child:

```swift
func onActivate() {
    node.analyticsService.track("app_launched")
    node.forEach(Observed { node.analyticsService.isEnabled }) { isEnabled in … }
}
```

Its `onActivate()` runs once when first accessed and it deactivates when the last host is removed; all hosts share the same context. A couple of routing notes follow from it being off the normal parent chain: events *to* a dependency need `.dependencies` in the relation (`node.send(.refresh, to: [.self, .children, .dependencies])`), and `mapHierarchy` / `reduceHierarchy` only visit dependency models when you include `.dependencies`. See [The model hierarchy](Hierarchy.md).

### Swift 6.2 — `defaultIsolation: MainActor`

Xcode 26 may create projects with `defaultIsolation: MainActor`, which isolates every declaration. SwiftModel relies on its lock rather than actor isolation, so you don't *need* this setting for safety — but if it's on, mark your domain structs, dependency types, `DependencyKey` conformances, and `DependencyValues` accessors `nonisolated` so they stay reachable from nonisolated test targets:

```swift
nonisolated struct FactClient { var fetch: @Sendable (Int) async throws -> String }

nonisolated extension FactClient: DependencyKey {
    static let liveValue = FactClient(...)
}
```

Any private helper types inside `liveValue` closures (e.g. `Decodable` structs) need the same treatment.
