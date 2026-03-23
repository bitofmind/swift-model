import SwiftModel
import Testing
import SwiftUINavigation
@testable import SignUpFlow

@Suite(.modelTesting(.removing(.local)))
struct SharedStateTests {
  @Test func testSharedSignUpData() async {
    let signUpData = SignUpData()
    let model = SignUpFeature(
      path: [
        .basics(BasicsFeature(signUpData: signUpData)),
        .personalInfo(PersonalInfoFeature(signUpData: signUpData)),
        .topics(TopicsFeature(signUpData: signUpData))
      ],
      signUpData: signUpData
    ).withAnchor()

    let liveData = model.signUpData

    liveData.topics = [.testing]
    await expect { model.signUpData.topics == [.testing] }

    liveData.firstName = "Blob"
    await expect { model.signUpData.firstName == "Blob" }
  }

  @Test func testSignUpFlow() async throws {
    let signUpData = SignUpData()
    let model = SignUpFeature(
      path: [
        .basics(BasicsFeature(signUpData: signUpData)),
        .personalInfo(PersonalInfoFeature(signUpData: signUpData)),
        .topics(TopicsFeature(signUpData: signUpData))
      ],
      signUpData: signUpData
    ).withAnchor()

    model.path[2].topics?.nextButtonTapped()

    await expect {
      model.path[2].topics?.alert == AlertState {
        TextState("Please choose at least one topic.")
      }
    }

    model.signUpData.topics = [.testing]

    await expect {
      model.signUpData.topics == [.testing]
    }

    model.path[2].topics?.nextButtonTapped()

    await expect {
      model.path[2].topics?.didSend(.onNext) == true
      model.path.count == 4
      model.path[3].is(\.summary)
    }

    let summary = try await require(model.path[3].summary)

    summary.editPersonalInfoButtonTapped()

    await expect {
      summary.destination.is(\.personalInfo) == true
      summary.node.environment.isEditing == true
      summary.destination?.personalInfo?.isEditing == true
    }

    model.signUpData.firstName = "Blob"

    await expect {
      model.signUpData.firstName == "Blob"
    }

    summary.destination = nil

    await expect {
      summary.destination == nil
      summary.node.environment.isEditing == false
    }

    summary.submitButtonTapped()

    await expect {
      summary.didSend(.onSubmit) == true
      model.path.isEmpty
    }
  }
}
