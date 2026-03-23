import Testing
import Observation
@testable import SwiftModel
import SwiftModel

/// Regression tests that verify ModelTester's closure-accepting APIs require @Sendable closures.
///
/// Each test is marked @MainActor so that the Swift 6 compiler enforces Sendable requirements
/// when closures capturing local state are passed across the suspension point in
/// `await expect { }`. If @Sendable is ever removed from the ModelTester API,
/// these tests will fail to compile.
@Suite(.modelTesting)
struct ModelTesterSendableTests {

    @Model struct CounterModel {
        var count = 0
    }

    /// Verifies that the result-builder assert overload accepts @Sendable closures from
    /// a @MainActor context. The builder closure and the == predicate both cross a
    /// suspension boundary, requiring @Sendable.
    @Test @MainActor func testAssertBuilderAcceptsSendableClosures() async {
        let model = CounterModel().withAnchor()
        model.count = 1
        await expect(model.count == 1)
    }

    /// Verifies that the autoclosure Bool overload of assert requires @Sendable.
    @Test @MainActor func testAssertAutoclosureAcceptsSendableClosures() async {
        let model = CounterModel().withAnchor()
        model.count = 2
        await expect(model.count == 2)
    }

    /// Verifies that unwrap requires a @Sendable autoclosure.
    @Test @MainActor func testUnwrapAcceptsSendableClosures() async throws {
        let model = CounterModel().withAnchor()
        let value = try await require(model.count == 0 ? model.count : nil)
        #expect(value == 0)
    }

    /// Verifies that the TestPredicate == operator produces a @Sendable-compatible predicate
    /// when used from a @MainActor context.
    @Test @MainActor func testPredicateOperatorProducesSendablePredicate() async {
        let model = CounterModel().withAnchor()
        model.count = 3
        let pred: TestPredicate = model.count == 3
        await expect(pred)
    }
}
