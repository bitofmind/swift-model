/// Tests for SwiftModel with `defaultIsolation: MainActor` enabled on this module.
///
/// This target validates that `@Model`-annotated types work correctly when the containing
/// module uses `@MainActor` as the default actor isolation (Swift 6.2+). The macro must
/// generate `nonisolated` on framework-facing members so that SwiftModel's non-`@MainActor`
/// internals can access them without compile errors.
import Testing
import SwiftModel
import Dependencies

// MARK: - Dependencies

nonisolated struct FactClient {
    var fetch: @Sendable (Int) async throws -> String
}

// nonisolated: DependencyKey.liveValue must be accessible from any isolation context.
// Under defaultIsolation: MainActor, protocol conformances that need to satisfy Sendable
// requirements must be explicitly nonisolated.
nonisolated extension FactClient: DependencyKey {
    static let liveValue = FactClient(fetch: { n in "\(n) is a great number." })
}

extension DependencyValues {
    nonisolated var factClient: FactClient {
        get { self[FactClient.self] }
        set { self[FactClient.self] = newValue }
    }
}

// MARK: - Models

/// Simple counter with explicit fact loading. Covers: tracked vars, ModelDependency.
@Model struct CounterModel {
    var count: Int = 0
    var fact: String? = nil
    var isLoading: Bool = false

    @ModelDependency var factClient: FactClient

    func increment() { count += 1 }
    func decrement() { count -= 1 }

    func loadFact() {
        node.task {
            isLoading = true
            defer { isLoading = false }
            fact = try await factClient.fetch(count)
        } catch: { _ in }
    }
}

/// Nested child model. Covers: optional child, let properties.
@Model struct FactPromptModel {
    let count: Int
    var fact: String
}

/// Root app model. Covers: array of child models, optional child model.
@Model struct AppModel {
    var counters: [CounterModel] = []
    var factPrompt: FactPromptModel? = nil

    func addCounter() {
        counters.append(CounterModel())
    }

    func remove(_ counter: CounterModel) {
        counters.removeAll { $0.id == counter.id }
    }

    func showPromptFor(counter: CounterModel, fact: String) {
        factPrompt = FactPromptModel(count: counter.count, fact: fact)
    }

    func dismissPrompt() {
        factPrompt = nil
    }
}

// MARK: - Tests

@Suite(.modelTesting)
struct MainActorCounterTests {

    @Test func incrementAndDecrement() async {
        let model = CounterModel().withAnchor()
        model.increment()
        await expect(model.count == 1)
        model.increment()
        await expect(model.count == 2)
        model.decrement()
        await expect(model.count == 1)
    }

    @Test func loadFact() async {
        let model = CounterModel(count: 5).withAnchor {
            $0.factClient.fetch = { n in "\(n) is great!" }
        }
        model.loadFact()
        await expect {
            model.isLoading == false
            model.fact == "5 is great!"
        }
    }

    @Test func loadFactLoadsCorrectCount() async {
        let model = CounterModel(count: 3).withAnchor {
            $0.factClient.fetch = { n in "number \(n)" }
        }
        model.increment()
        await expect(model.count == 4)
        model.loadFact()
        await expect {
            model.isLoading == false
            model.fact == "number 4"
        }
    }
}

@Suite(.modelTesting)
struct MainActorAppModelTests {

    @Test func addAndRemoveCounters() async {
        let model = AppModel().withAnchor()
        model.addCounter()
        model.addCounter()
        await expect(model.counters.count == 2)

        let first = model.counters[0]
        model.remove(first)
        await expect(model.counters.count == 1)
    }

    @Test func factPromptLifecycle() async throws {
        let model = AppModel().withAnchor()
        model.addCounter()
        await expect(model.counters.count == 1)

        let counter = try await require(model.counters.first)
        counter.increment()
        await expect(counter.count == 1)

        model.showPromptFor(counter: counter, fact: "interesting fact")
        await expect {
            model.factPrompt?.count == 1
            model.factPrompt?.fact == "interesting fact"
        }

        model.dismissPrompt()
        await expect(model.factPrompt == nil)
    }

    @Test func counterModificationsReflectInParent() async {
        let model = AppModel().withAnchor()
        model.addCounter()
        await expect(model.counters.count == 1)

        let counter = model.counters[0]
        counter.increment()
        counter.increment()
        await expect(model.counters[0].count == 2)
    }

    @Test func loadFactInChildModel() async {
        let model = AppModel().withAnchor {
            $0.factClient.fetch = { n in "\(n) fact" }
        }
        model.addCounter()
        await expect(model.counters.count == 1)

        let counter = model.counters[0]
        counter.loadFact()
        await expect {
            counter.isLoading == false
            counter.fact == "0 fact"
        }
    }
}
