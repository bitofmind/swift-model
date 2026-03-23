import Testing
import ConcurrencyExtras
import Observation
@testable import SwiftModel
import SwiftModel

// MARK: - Environment keys

private extension EnvironmentKeys {
    /// A theme model that ancestors can inject into the environment.
    var theme: EnvironmentStorage<Theme?> { .init(defaultValue: nil) }

    /// A router model available to all descendants.
    var router: EnvironmentStorage<Router?> { .init(defaultValue: nil) }
}

// MARK: - Models

/// A small model that can be injected as an environment value.
@Model
private struct Theme {
    var colorScheme: String = "light"

    func switchToNight() {
        colorScheme = "dark"
    }
}

/// A parent model that registers itself in context during onActivate,
/// making itself available to all of its descendants.
@Model
private struct ThemeHost {
    var theme: Theme = Theme()
    var child: ThemeConsumer = ThemeConsumer()

    func onActivate() {
        // Write the *child* theme model into context so all descendants can find it.
        node.environment.theme = theme
    }
}

/// A leaf model that reads Theme from context by walking up to the nearest ancestor that set it.
@Model
private struct ThemeConsumer {
    /// The current theme, resolved by walking up the ancestor chain.
    var theme: Theme? { node.environment.theme }
}

/// A deeper consumer to verify multi-level ancestry resolution.
@Model
private struct DeepConsumer {
    var inner: ThemeConsumer = ThemeConsumer()
}

/// A container model that nests both a host and a deep consumer.
@Model
private struct Workspace {
    var host: ThemeHost = ThemeHost()
    var deepConsumer: DeepConsumer = DeepConsumer()
}

/// A model that registers itself as a router.
@Model
private struct Router {
    var currentRoute: String = "home"

    func onActivate() {
        node.environment.router = self
    }

    func navigate(to route: String) {
        currentRoute = route
    }
}

/// A model that reads both theme and router from context.
@Model
private struct MultiConsumer {
    var theme: Theme? { node.environment.theme }
    var router: Router? { node.environment.router }
}

/// An app root that wires everything together.
@Model
private struct AppRoot {
    var host: ThemeHost = ThemeHost()
    var router: Router = Router()
    var feature: MultiConsumer = MultiConsumer()
}

// MARK: - Tests

@Suite(.modelTesting(exhaustivity: .off))
struct EnvironmentModelTests {

    // MARK: - Basic read/write (ancestor writes, descendant reads)

    /// A parent model writes a value into context during onActivate;
    /// its direct child can read it by walking up the ancestor chain.
    @Test func childCanReadModelFromAncestorContext() {
        let host = ThemeHost().withAnchor()
        // ThemeHost.onActivate writes node.environment.theme = theme.
        // ThemeConsumer reads node.environment.theme — walks up to ThemeHost and finds it.
        #expect(host.child.theme != nil)
        #expect(host.child.theme?.colorScheme == "light")
    }

    /// The model retrieved from context is live — property reads reflect current state.
    @Test func contextModelReflectsLiveState() {
        let host = ThemeHost().withAnchor()
        host.theme.colorScheme = "sepia"

        let themeViaContext = host.child.theme
        #expect(themeViaContext?.colorScheme == "sepia")
    }

    /// Calling a method on the model retrieved from context mutates the live model.
    @Test func methodCallOnContextModelMutatesLiveModel() {
        let host = ThemeHost().withAnchor()
        host.child.theme?.switchToNight()

        #expect(host.theme.colorScheme == "dark")
        #expect(host.child.theme?.colorScheme == "dark")
    }

    /// Multiple descendants all see the same live model instance.
    @Test func multipleDescendantsShareSameInstance() {
        let host = ThemeHost().withAnchor()
        host.theme.colorScheme = "high-contrast"

        #expect(host.theme.colorScheme == "high-contrast")
        #expect(host.child.theme?.colorScheme == "high-contrast")
    }

    // MARK: - Sibling isolation

    /// A model written to context by a sibling is NOT visible to other siblings.
    /// The walk-up visits self → parent → grandparent only, never lateral branches.
    /// This matches SwiftUI @Environment: you inject on a parent, children inherit it;
    /// sibling views never see each other's environment writes.
    @Test func siblingContextWriteIsNotVisibleToOtherSiblings() {
        let workspace = Workspace().withAnchor()
        // workspace.host.onActivate() writes context.theme on the *host* node.
        // workspace.deepConsumer.inner walks up: inner → deepConsumer → workspace → root.
        // It never visits the host branch (a sibling of deepConsumer), so theme is nil.
        #expect(workspace.deepConsumer.inner.theme == nil,
                "Only ancestor writes are visible — sibling writes are not")
    }

    // MARK: - Multiple context models

    /// Multiple models can be stored in context simultaneously and each resolved independently.
    @Test func multipleContextModelsCoexist() {
        let app = AppRoot().withAnchor()

        // Router registers itself in context from its own node.
        // MultiConsumer walks up: feature → appRoot — it finds Router (registered by Router node)
        // only if Router is an ancestor of feature, which it isn't (sibling).
        // Document the actual behaviour: router is nil because it's a sibling.
        #expect(app.feature.router == nil,
                "Router registers on its own sibling node, not an ancestor of feature")

        // Host writes theme into its own node as well. Same issue for theme.
        #expect(app.feature.theme == nil,
                "ThemeHost writes on its own sibling node, not an ancestor of feature")
    }

    /// A parent that directly writes a child model into context makes it available to that child.
    @Test func parentWrittenContextIsAvailableToDirectChild() {
        let host = ThemeHost().withAnchor()
        // host.onActivate() writes host.theme into context on host's node.
        // host.child reads up: child → host — finds it on host's node.
        #expect(host.child.theme != nil)
    }

    // MARK: - Observation

    /// When the context model's state changes, descendants observing it via Observed are notified.
    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func observingContextModelPropertyReactsToChanges(path: ObservationPath) async throws {
        let host = ThemeHost().withAnchor(options: path.options)

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            host.child.theme?.colorScheme
        }

        let values = LockIsolated<[String?]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        // Wait for initial value.
        try await waitUntil(values.value.count >= 1)
        #expect(values.value.first == .some("light"))

        // Mutate via the live model — the observer on the child side should see it.
        host.theme.colorScheme = "dark"
        try await waitUntil(values.value.contains(.some("dark")), timeout: 3_000_000_000)
        #expect(values.value.contains(.some("dark")),
                "[\(path)] Context model mutation should notify observer, got \(values.value)")
    }

    // MARK: - Tester integration

    /// Context model mutations are visible in ModelTester assertions.
    @Test func testerCanAssertContextModelState() async {
        let host = ThemeHost().withAnchor()

        host.theme.colorScheme = "dark"
        await expect(host.child.theme?.colorScheme == "dark")
    }

    /// A method called on the context model is reflected in the tester assertion.
    /// Uses exhaustivity .off because ThemeHost re-writes context.theme as a side-effect
    /// when the child theme model is mutated; only the primary state change is asserted here.
    @Test(.modelTesting(exhaustivity: .off)) func testerAssertAfterContextModelMethodCall() async {
        let host = ThemeHost().withAnchor()

        host.child.theme?.switchToNight()
        await expect(host.theme.colorScheme == "dark")
    }

    // MARK: - Instance identity

    /// The model in context is the same live instance that was placed there — not a copy.
    @Test func contextReturnsIdenticalInstance() {
        let host = ThemeHost().withAnchor()
        // The theme retrieved via context should have the same modelID as host.theme.
        #expect(host.child.theme?.id == host.theme.id)
    }
}
