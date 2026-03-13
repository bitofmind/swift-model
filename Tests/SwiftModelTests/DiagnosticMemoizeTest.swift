import Testing
import Observation
@testable import SwiftModel
import ConcurrencyExtras

/// Diagnostic tests to understand withObservationTracking + memoize interaction
struct DiagnosticMemoizeTest {

    /// Test WITH sleep: Wait for onChange before accessing memoized value
    @Test func testWithSleepBeforeAccess() async throws {
        let (model, tester) = BasicMemoizeModel().andTester(exhaustivity: .off)

        _ = model.doubled
        await tester.assert { model.accessCount == 1 }

        model.value = 5
        await tester.assert { model.value == 5 }

        await tester.assert(timeout: .seconds(5)) {
            model.doubled == 10
        }
    }

    /// Test WITHOUT sleep: Access immediately after mutation.
    ///
    /// With dual registrar implementation, background registrar fires synchronously,
    /// so we get fresh values immediately (no race condition).
    @Test func testWithoutSleep() async throws {
        let (model, tester) = BasicMemoizeModel().andTester(options: [.disableMemoizeCoalescing], exhaustivity: .off)

        _ = model.doubled
        await tester.assert { model.accessCount == 1 }

        model.value = 5
        await tester.assert { model.value == 5 }

        let result = model.doubled
        #expect(result == 10, "Expected fresh value with dual registrar implementation")
    }

    /// Test using ModelTester.assert polling
    @Test func testWithTesterAssertPolling() async throws {
        let (model, tester) = BasicMemoizeModel().andTester(exhaustivity: .off)

        _ = model.doubled
        await tester.assert { model.accessCount == 1 }

        model.value = 5
        await tester.assert { model.value == 5 }

        await tester.assert(timeout: .seconds(2)) {
            model.doubled == 10
        }
    }
}

@Model private struct BasicMemoizeModel {
    var value = 0
    var accessCount = 0

    var doubled: Int {
        accessCount += 1
        return node.memoize(for: "doubled") {
            value * 2
        }
    }
}
