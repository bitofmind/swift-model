import SwiftModel
import Testing
import SwiftUINavigation
import Observation
@testable import SignUpFlowUsingDependency

// MARK: - Test helper

/// Wraps the sign-up flow and owns all path-element models as direct typed
/// properties. Because they are named @Model properties on this wrapper they
/// become live anchored children, and the shared SignUpData dependency is
/// resolved through the test dependency container.
///
/// Unlike the non-dependency SignUpFlow example, models here access SignUpData
/// via @ModelDependency rather than constructor injection. The test sets up the
/// dependency once via andTester's dependency closure, and the TestHelper
/// forwards the onNext event to expose a live SummaryFeature reference.
@Model private struct TestHelper {
  var topics: TopicsFeature
  var summary: SummaryFeature?

  init() {
    _topics = TopicsFeature()
  }

  func onActivate() {
    // When TopicsFeature fires .onNext, create a live SummaryFeature and
    // store it here so the test can get a typed live reference to it.
    node.forEach(node.event(of: .onNext, fromType: TopicsFeature.self)) { _ in
      summary = SummaryFeature()
    }
  }
}

// MARK: - Tests

struct SharedStateTests {
  @Test func testSignUpFlow() async throws {
    let (helper, tester) = TestHelper().andTester {
      $0[SignUpData.self] = SignUpData()
    }
    tester.exhaustivity = [.state, .events, .tasks, .probes, .preference]

    let topics = helper.topics

    // nextButtonTapped with no topics selected should set an alert.
    topics.nextButtonTapped()

    await tester.assert {
      topics.alert == AlertState {
        TextState("Please choose at least one topic.")
      }
    }

    // Set topics via the dependency — all models share the same SignUpData context.
    topics.signUpData.topics = [.testing]

    await tester.assert {
      topics.signUpData.topics == [.testing]
    }

    // nextButtonTapped now fires .onNext; TestHelper.onActivate creates a live
    // SummaryFeature and stores it on helper.summary.
    topics.nextButtonTapped()

    await tester.assert {
      topics.didSend(.onNext) == true
    }

    let summary = try await tester.unwrap(helper.summary)

    summary.editPersonalInfoButtonTapped()

    await tester.assert {
      summary.destination.is(\.personalInfo) == true
      summary.node.context.isEditing == true
      summary.destination?.personalInfo?.isEditing == true
    }

    summary.signUpData.firstName = "Blob"

    await tester.assert {
      summary.signUpData.firstName == "Blob"
    }

    summary.destination = nil

    await tester.assert {
      summary.destination == nil
      summary.node.context.isEditing == false
    }

    summary.submitButtonTapped()

    await tester.assert {
      summary.didSend(.onSubmit) == true
    }
  }
}
