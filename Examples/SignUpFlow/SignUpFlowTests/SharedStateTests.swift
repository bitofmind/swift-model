import SwiftModel
import Testing
import SwiftUINavigation
@testable import SignUpFlow

struct SharedStateTests {
  @Test func testSignUpFlow() async {
    let _sharedSignUpData = SignUpData()
    let (model, tester) = SignUpFeature(
      path: [
        .basics(BasicsFeature(signUpData: _sharedSignUpData)),
        .personalInfo(PersonalInfoFeature(signUpData: _sharedSignUpData)),
        .topics(TopicsFeature(signUpData: _sharedSignUpData))
      ],
      signUpData: _sharedSignUpData
    ).andTester()

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

    model.path[3].summary?.editPersonalInfoButtonTapped()

    await tester.assert {
      model.path[3].summary?.destination.is(\.personalInfo) == true
    }

    model.signUpData.firstName = "Blob"
    await tester.assert {
      model.signUpData.firstName == "Blob"
    }

    model.path[3].summary?.destination = nil

    await tester.assert {
      model.path[3].summary?.destination == nil
    }
  }
}
