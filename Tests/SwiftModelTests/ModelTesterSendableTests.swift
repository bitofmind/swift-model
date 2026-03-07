import Testing
import Observation
@testable import SwiftModel

/// Regression tests that verify ModelTester's closure-accepting APIs require @Sendable closures.
///
/// Each test is marked @MainActor so that the Swift 6 compiler enforces Sendable requirements
/// when closures capturing local state are passed across the suspension point in
/// `await tester.assert { }`. If @Sendable is ever removed from the ModelTester API,
/// these tests will fail to compile.
struct ModelTesterSendableTests {

    @Model struct CounterModel {
        var count = 0
    }

    /// Verifies that the result-builder assert overload accepts @Sendable closures from
    /// a @MainActor context. The builder closure and the == predicate both cross a
    /// suspension boundary, requiring @Sendable.
    @Test @MainActor func testAssertBuilderAcceptsSendableClosures() async {
        let (model, tester) = CounterModel().andTester()
        model.count = 1
        await tester.assert {
            model.count == 1
        }
    }

    /// Verifies that the autoclosure Bool overload of assert requires @Sendable.
    @Test @MainActor func testAssertAutoclosureAcceptsSendableClosures() async {
        let (model, tester) = CounterModel().andTester()
        model.count = 2
        await tester.assert(model.count == 2)
    }

    /// Verifies that unwrap requires a @Sendable autoclosure.
    @Test @MainActor func testUnwrapAcceptsSendableClosures() async throws {
        let (model, tester) = CounterModel().andTester()
        tester.exhaustivity = .off
        let value = try await tester.unwrap(model.count == 0 ? model.count : nil)
        #expect(value == 0)
    }

    /// Verifies that the TestPredicate == operator produces a @Sendable-compatible predicate
    /// when used from a @MainActor context.
    @Test @MainActor func testPredicateOperatorProducesSendablePredicate() async {
        let (model, tester) = CounterModel().andTester()
        model.count = 3
        let pred: TestPredicate = model.count == 3
        await tester.assert(pred)
    }
}
