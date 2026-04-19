[← Back to README](../README.md)

## Dependencies

For improved control of a model's dependencies to outside systems, such as backend services, SwiftModel has a system where a model can access its dependencies without needing to know how they were configured or set up. This is very similar to how SwiftUI's environment is working.

> This has been popularized by the [swift-dependency](https://github.com/pointfreeco/swift-dependencies) package which SwiftModel integrates with.

You define a dependency type by conforming it to DependencyKey where you provide a default value:

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
```

A model accesses its dependencies via its `node`.

```swift
let fact = try await node[FactClient.self].fetch(count)
```

> `node` is the model implementor's interface to the SwiftModel runtime. It provides access to dependencies, async tasks, events, cancellations, memoization, and hierarchy queries. It is intended to be used from within a model's own implementation — in `onActivate()`, in methods, and in extensions — not by external consumers of the model.

There is also a convenience macro for dependencies:

```swift
@Model struct CounterModel {
    @ModelDependency var factClient: FactClient
}
```

`@ModelDependency` uses the property's declared type to identify the dependency (via `DependencyKey`). If you want to look up a dependency by key path instead — mirroring SwiftUI's `@Environment(\.keyPath)` syntax — you can pass a key path argument:

```swift
@Model struct TimerModel {
    @ModelDependency(\.continuousClock) var clock: any Clock<Duration>
}
```

This is useful when the property type is a protocol or other abstract type that has no `DependencyKey` conformance of its own, or simply to make the link to `DependencyValues` explicit and visible at the declaration site. For most cases though, accessing dependencies directly through `node` (e.g. `node.continuousClock`) tends to be more convenient since it doesn't require a dedicated property declaration.

### DependencyValues

By also extending `DependencyValues` you will get more convenient access to commonly used dependencies:

```
extension DependencyValues {
  var factClient: FactClient {
    get { self[FactClient.self] }
    set { self[FactClient.self] = newValue }
  }
}
```

```swift
let fact = try await node.factClient.fetch(count)
```

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
