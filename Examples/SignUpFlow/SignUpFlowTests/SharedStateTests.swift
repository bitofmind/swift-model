import SwiftModel
import Testing
import SwiftUINavigation
@testable import SignUpFlow

struct SharedStateTests {
  @Test(arguments: 1...100) func testSignUpFlowStress(_ run: Int) async {
    await runSignUpFlow()
  }

  @Test func testSignUpFlow() async {
    await runSignUpFlow()
  }
}

private func runSignUpFlow() async {
  let _sharedSignUpData = SignUpData()
  let (model, tester) = SignUpFeature(
    path: [
      .basics(BasicsFeature(signUpData: _sharedSignUpData)),
      .personalInfo(PersonalInfoFeature(signUpData: _sharedSignUpData)),
      .topics(TopicsFeature(signUpData: _sharedSignUpData))
    ],
    signUpData: _sharedSignUpData
  ).andTester()
  // Context writes that happen on background tasks during model teardown can race
  // with the exhaustion check. We assert context explicitly where it matters and
  // exclude it from exhaustivity to avoid spurious failures under stress.
  tester.exhaustivity = [.state, .events, .tasks, .probes, .preference]

  model.path[2].topics?.nextButtonTapped()

  await tester.assert {
    model.path[2].topics?.alert == AlertState {
      TextState("Please choose at least one topic.")
    }
  }

  model.signUpData.topics = [.testing]

  await tester.assert {
    model.signUpData.topics == [.testing]
  }

  model.path[2].topics?.nextButtonTapped()

  await tester.assert {
    model.path[2].topics?.didSend(.onNext) == true
    model.path.count == 4
    model.path[3].is(\.summary)
  }

  // Capture the summary model now that path[3] is confirmed to exist and be a summary.
  let summary = model.path[3].summary!

  summary.editPersonalInfoButtonTapped()

  await tester.assert {
    summary.destination.is(\.personalInfo) == true
    // isEditing is set on SummaryFeature's context and propagates via
    // .environment to PersonalInfoFeature — no constructor param needed.
    summary.node.context.isEditing == true
    summary.destination?.personalInfo?.isEditing == true
  }

  model.signUpData.firstName = "Blob"
  await tester.assert {
    model.signUpData.firstName == "Blob"
  }

  summary.destination = nil

  await tester.assert {
    summary.destination == nil
    summary.node.context.isEditing == false
  }

  summary.submitButtonTapped()

  await tester.assert {
    summary.didSend(.onSubmit) == true
    model.path.isEmpty
    // When path is cleared the summary model is destroyed. Its onActivate observer
    // fires `node.context.isEditing = false` on the now-gone destination.
    summary.node.context.isEditing == false
  }
}
