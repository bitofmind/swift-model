import Testing
import SwiftModel
import Dependencies
@testable import CounterFact

struct CounterFactTests {
    @Test func testExample() async throws {
        let (appModel, tester) = AppModel().andTester {
            $0.factClient.fetch = { "\($0) is a good number." }
        }

        appModel.addButtonTapped()
        await tester.assert(appModel.counters.count == 1)

        let counterRowModel = try await tester.unwrap(appModel.counters.first)
        let counterModel = counterRowModel.counter

        counterModel.incrementTapped()
        await tester.assert(counterModel.count == 1)

        counterModel.factButtonTapped()
        await tester.assert {
            appModel.factPrompt?.count == 1
            appModel.factPrompt?.fact == "1 is a good number."
        }

        let factPromptModel = try await tester.unwrap(appModel.factPrompt)

        factPromptModel.dismissTapped()
        await tester.assert(appModel.factPrompt == nil)

        counterRowModel.removeButtonTapped()
        await tester.assert(appModel.counters.isEmpty)
    }

    @Test func testFactButtonTapped() async throws {
        let onFact = TestProbe()
        let (model, tester) = CounterModel(count: 2, onFact: onFact.call).andTester {
            $0.factClient.fetch = { "\($0) is a good number." }
        }

        model.factButtonTapped()

        await tester.assert {
            onFact.wasCalled(with: 2, "2 is a good number.")
        }
    }
}
