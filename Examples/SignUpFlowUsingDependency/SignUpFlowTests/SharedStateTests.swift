import SwiftModel
import Testing
import SwiftUINavigation
@testable import SignUpFlowUsingDependency

@Suite(.modelTesting(.removing(.context)))
struct SharedStateTests {
  @Test func testSignUpFlow() async throws {
    let model = SignUpFeature().withAnchor {
      $0[SignUpData.self] = SignUpData()
    }

    model.path = [
      .basics(BasicsFeature()),
      .personalInfo(PersonalInfoFeature()),
      .topics(TopicsFeature())
    ]

    await expect { model.path.count == 3 }

    model.path[2].topics?.nextButtonTapped()

    await expect {
      model.path[2].topics?.alert == AlertState {
        TextState("Please choose at least one topic.")
      }
    }

    model.path[2].topics?.signUpData.topics = [.testing]

    await expect {
      model.path[2].topics?.signUpData.topics == [.testing]
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
      summary.node.context.isEditing == true
      summary.destination?.personalInfo?.isEditing == true
    }

    summary.signUpData.firstName = "Blob"

    await expect {
      summary.signUpData.firstName == "Blob"
    }

    summary.destination = nil

    await expect {
      summary.destination == nil
      summary.node.context.isEditing == false
    }

    summary.submitButtonTapped()

    await expect {
      summary.didSend(.onSubmit) == true
      model.path.isEmpty
    }
  }
}
