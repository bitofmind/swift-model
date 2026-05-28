[← Back to README](../README.md)

## Dependencies

Models access external services — network clients, persistence, clocks — through a typed dependency system similar to SwiftUI's `@Environment`. Dependencies are resolved at the model's position in the hierarchy, making them trivial to override per-test, per-preview, or per-model-subtree.

> SwiftModel integrates with [swift-dependencies](https://github.com/pointfreeco/swift-dependencies) by Point-Free, which means the growing ecosystem of community-built dependency wrappers conforms out of the box.

### Defining a dependency

Conform your dependency type to `DependencyKey` to provide a live default, then extend `DependencyValues` for convenient keypath access:

```swift
import Dependencies

struct FactClient {
    var fetch: @Sendable (Int) async throws -> String
}

extension FactClient: DependencyKey {
    static let liveValue = FactClient(
        fetch: { number in
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://numbersapi.com/\(number)")!)
            return String(decoding: data, as: UTF8.self)
        }
    )
}

extension DependencyValues {
    var factClient: FactClient {
        get { self[FactClient.self] }
        set { self[FactClient.self] = newValue }
    }
}
```

Access the dependency via `node`:

```swift
let fact = try await node.factClient.fetch(count)
```

> `node` is the model implementor's interface to the SwiftModel runtime. It provides access to dependencies, async tasks, events, cancellations, memoization, and hierarchy queries. It is intended to be used from within a model's own implementation — in `onActivate()`, in methods, and in extensions — not by external consumers of the model.

### Declaring dependencies on a model

For dependencies that should be visible at the struct level — for example, when you want the dependency to appear in the memberwise initialiser — use `@ModelDependency`:

```swift
@Model struct CounterModel {
    @ModelDependency var factClient: FactClient
}
```

When the property type is a protocol or abstract type with no `DependencyKey` conformance of its own, pass a keypath argument to identify it via `DependencyValues`:

```swift
@Model struct TimerModel {
    @ModelDependency(\.continuousClock) var clock: any Clock<Duration>
}
```

For most cases, `node.factClient` and `node.continuousClock` are simpler — no property declaration needed.

### Overriding Dependencies

When anchoring your root model you can provide a trailing closure where you can override default dependencies. This is especially useful for testing and previews.

```swift
let model = AppModel().withAnchor {
  $0.factClient.fetch = { "\($0) is a great number!" }
}
```

Any descendant models will inherit its parent's dependencies.

You can also override a child model's dependencies (and its descendants) using the `withDependencies()` modifier:

```swift
appModel.factPrompt = FactPromptModel(...).withDependencies {
  $0.factClient.fetch = { "\($0) is a great number!" }
}
```

### Model Dependency

A `@Model` type can also be used as a dependency by conforming to `DependencyKey`. When accessed via `@ModelDependency` (or `node[Dep.self]`), SwiftModel integrates it into the context hierarchy as a shared model — one instance, shared across all consumers.

```swift
@Model struct AnalyticsService {
    var isEnabled: Bool = true

    func track(_ event: String) { ... }
}

extension AnalyticsService: DependencyKey {
    static let liveValue = AnalyticsService()
    static let testValue = AnalyticsService()  // used automatically in tests
}

@Model struct FeatureModel {
    @ModelDependency var analytics: AnalyticsService
}
```

Alternatively — and in practice the most convenient approach — extend `DependencyValues` just like you would for a plain dependency:

```swift
extension DependencyValues {
    var analyticsService: AnalyticsService {
        get { self[AnalyticsService.self] }
        set { self[AnalyticsService.self] = newValue }
    }
}
```

This lets every model access the dependency directly via `node`, with no `@ModelDependency` property needed:

```swift
func onActivate() {
    node.analyticsService.track("app_launched")
    node.forEach(Observed { node.analyticsService.isEnabled }) { isEnabled in
        // react to changes
    }
}
```

Overriding works the same way, using either the key path or the subscript form:

```swift
let model = AppModel().withAnchor {
    $0.analyticsService = AnalyticsService(isEnabled: false)  // key path
    // or: $0[AnalyticsService.self] = AnalyticsService(isEnabled: false)
}
```

**Lifecycle.** The dependency model's `onActivate()` is called when it is first accessed by any model in the hierarchy. It is deactivated when the last host model is removed. Multiple models that access the same dependency type receive the same shared context — `onActivate()` runs once and `onCancel` fires once.

**Observation.** A host model can observe properties of the dependency model via `Observed`, exactly as it would observe any child model's properties:

```swift
func onActivate() {
    node.forEach(Observed { analytics.isEnabled }) { isEnabled in
        // fires whenever analytics.isEnabled changes
    }
}
```

**Events from the dependency.** Events sent by the dependency model with the default `to: [.self, .ancestors]` travel up to the host model's event listeners, because the dependency context has the host as a parent.

**Events to the dependency.** The default `node.send(event)` relation `[.self, .ancestors]` does **not** reach dependency models. To deliver an event to a dependency, you must include both `.children` and `.dependencies` in the relation:

```swift
node.send(MyEvent.refresh, to: [.self, .children, .dependencies])
```

**Hierarchy traversal.** `reduceHierarchy` and `mapHierarchy` do not visit dependency models by default. Include `.dependencies` alongside `.descendants` or `.children` to traverse them:

```swift
let services = node.mapHierarchy(for: [.self, .descendants, .dependencies]) {
    $0 as? AnalyticsService
}
```

### Swift 6.2 — `defaultIsolation: MainActor`

Xcode 26 creates new projects with `defaultIsolation: MainActor`, isolating every declaration by default. SwiftModel uses a lock, not actor isolation, so a few targeted `nonisolated` annotations are needed where the setting would otherwise inject `@MainActor`:

**Domain structs and dependency types:**

```swift
// Without nonisolated, let/var accessors become @MainActor-isolated,
// breaking cross-module access from nonisolated test targets.
nonisolated struct Repo: Sendable { let name: String; let owner: String }
nonisolated struct FactClient { var fetch: @Sendable (Int) async throws -> String }
```

**`DependencyKey` conformance and `DependencyValues` accessor:**

```swift
nonisolated extension FactClient: DependencyKey {
    static let liveValue = FactClient(...)
}

extension DependencyValues {
    nonisolated var factClient: FactClient {
        get { self[FactClient.self] }
        set { self[FactClient.self] = newValue }
    }
}
```

Any private helper types inside `liveValue` closures that appear in a `nonisolated` context (e.g. `Decodable` structs for JSON parsing) need the same treatment.

> You don't need `defaultIsolation: MainActor` in a SwiftModel module for safety — model state is protected by SwiftModel's internal lock regardless of actor isolation. If Xcode 26 added it automatically, the patterns above are all that's needed.
