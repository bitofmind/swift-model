import SwiftModel
import Testing
import SwiftUINavigation
import Observation
@testable import SignUpFlow

// MARK: - Test helper

/// Wraps SignUpFeature and owns all the path-element models as direct typed
/// properties. Because they are named @Model properties on this wrapper they
/// become live anchored children, allowing the test to interact with them
/// via their real contexts.
///
/// The shared SignUpData instance is established by the framework: all models
/// created from the same SignUpData value (same ModelID) share one context once
/// the hierarchy is anchored.
@Model private struct TestHelper {
  var signUpData = SignUpData()
  var topics: TopicsFeature
  var summary: SummaryFeature?

  init() {
    // signUpData is a @Model property on TestHelper — the framework will anchor
    // it and make it the single live instance shared across the hierarchy.
    // We pass the same value to every model so they all get the same ModelID
    // and therefore the same context after anchoring.
    let data = SignUpData()
    _topics = TopicsFeature(signUpData: data)
    signUpData = data
  }

  func onActivate() {
    // Capture the SummaryFeature that SignUpFeature creates when topics fires
    // .onNext. We listen here (parent fires before child) so we can expose a
    // live reference to the test.
    node.forEach(node.event(of: .onNext, fromType: TopicsFeature.self)) { _ in
      summary = SummaryFeature(signUpData: signUpData)
    }
  }
}

// MARK: - Tests

struct SharedStateTests {
  @Test func testSharedSignUpData() async {
    // Verify that mutations to a shared SignUpData propagate through the hierarchy.
    let signUpData = SignUpData()
    let (model, tester) = SignUpFeature(
      path: [
        .basics(BasicsFeature(signUpData: signUpData)),
        .personalInfo(PersonalInfoFeature(signUpData: signUpData)),
        .topics(TopicsFeature(signUpData: signUpData))
      ],
      signUpData: signUpData
    ).andTester()
    tester.exhaustivity = [.state, .events, .tasks, .probes, .preference]

    // The live signUpData is model.signUpData — the local `signUpData` above is
    // an initial snapshot after anchoring.
    let liveData = model.signUpData

    liveData.topics = [.testing]

    await tester.assert {
      model.signUpData.topics == [.testing]
    }

    liveData.firstName = "Blob"

    await tester.assert {
      model.signUpData.firstName == "Blob"
    }
  }

  @Test func testTopicsAndSummaryFlow() async throws {
    let (helper, tester) = TestHelper().andTester()
    tester.exhaustivity = [.state, .events, .tasks, .probes, .preference]

    let topics = helper.topics

    // nextButtonTapped with no topics selected should set an alert.
    topics.nextButtonTapped()

    await tester.assert {
      topics.alert == AlertState {
        TextState("Please choose at least one topic.")
      }
    }

    // Set topics via the live signUpData — topics model shares the same instance.
    helper.signUpData.topics = [.testing]

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

    helper.signUpData.firstName = "Blob"

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
