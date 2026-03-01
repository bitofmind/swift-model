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

    model.path[3].summary?.editPersonalInfoButtonTapped()

    await tester.assert {
      model.path[3].summary?.destination.is(\.personalInfo) == true
    }

    model.path[3].summary?.signUpData.firstName = "Blob"

    await tester.assert {
      model.path[3].summary?.signUpData.firstName == "Blob"
    }

    model.path[3].summary?.destination = nil

    await tester.assert {
      model.path[3].summary?.destination == nil
    }
  }
}
