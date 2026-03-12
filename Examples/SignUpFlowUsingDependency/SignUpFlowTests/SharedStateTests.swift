import SwiftModel
import Testing
import SwiftUINavigation
@testable import SignUpFlowUsingDependency

struct SharedStateTests {
  @Test func testSignUpFlow() async {
    let (model, tester) = SignUpFeature().andTester {
      $0[SignUpData.self] = SignUpData()
    }

    model.path = [
      .basics(BasicsFeature()),
      .personalInfo(PersonalInfoFeature()),
      .topics(TopicsFeature())
    ]

    model.path[2].topics?.nextButtonTapped()

    await tester.assert {
      model.path[2].topics?.alert == AlertState {
        TextState("Please choose at least one topic.")
      }
    }

    model.path[2].topics?.signUpData.topics = [.testing]

    await tester.assert {
      model.path[2].topics?.signUpData.topics == [.testing]
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
      model.path.isEmpty
    }
  }
}
