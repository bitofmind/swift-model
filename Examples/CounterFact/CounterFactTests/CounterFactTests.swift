import Testing
import SwiftModel
import Dependencies
@testable import CounterFact

@Suite(.modelTesting)
struct CounterFactTests {
    @Test func testExample() async throws {
        let appModel = AppModel().withAnchor {
            $0.factClient.fetch = { "\($0) is a good number." }
        }

        appModel.addButtonTapped()
        await expect(appModel.counters.count == 1)

        let counterRowModel = try await require(appModel.counters.first)
        let counterModel = counterRowModel.counter

        counterModel.incrementTapped()
        await expect(counterModel.count == 1)

        counterModel.factButtonTapped()
        await expect {
            appModel.factPrompt?.count == 1
            appModel.factPrompt?.fact == "1 is a good number."
        }

        let factPromptModel = try await require(appModel.factPrompt)

        factPromptModel.dismissTapped()
        await expect(appModel.factPrompt == nil)

        counterRowModel.removeButtonTapped()
        await expect(appModel.counters.isEmpty)
    }

    @Test func testFactButtonTapped() async throws {
        let onFact = TestProbe()
        let model = CounterModel(count: 2, onFact: onFact.call).withAnchor {
            $0.factClient.fetch = { "\($0) is a good number." }
        }

        model.factButtonTapped()

        await expect {
            onFact.wasCalled(with: 2, "2 is a good number.")
        }
    }
}
