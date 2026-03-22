import SwiftModel
import Testing
import Dependencies

@testable import Standups

@Suite(.modelTesting)
struct StandupDetailTests {
  @Test func testSpeechRestricted() async {
    let standupDetail = StandupDetail(standup: .mock).withAnchor {
      $0.speechClient.authorizationStatus = { .restricted }
    }

    standupDetail.startMeetingButtonTapped()
    await expect(standupDetail.destination?.speechRecognitionRestricted != nil)
  }

  @Test func testSpeechDenied() async throws {
    let standupDetail = StandupDetail(standup: .mock).withAnchor {
      $0.speechClient.authorizationStatus = { .denied }
    }

    standupDetail.startMeetingButtonTapped()
    await expect(standupDetail.destination != nil)
  }

  @Test func testOpenSettings() async throws {
    let settingsOpened = TestProbe()

    let standupDetail = StandupDetail(standup: .mock).withAnchor {
      $0.openSettings = settingsOpened.call
      $0.speechClient.authorizationStatus = { .denied }
    }

    standupDetail.startMeetingButtonTapped()

    try await require(standupDetail.destination?.speechRecognitionDenied).openSettings()
    await expect {
      standupDetail.destination?.speechRecognitionDenied != nil
      settingsOpened.wasCalled()
    }
  }

  @Test func testContinueWithoutRecording() async throws {
    let standupDetail = StandupDetail(standup: .mock).withAnchor {
      $0.speechClient.authorizationStatus = { .denied }
    }

    standupDetail.startMeetingButtonTapped()
    try await require(standupDetail.destination?.speechRecognitionDenied).continue()

    await expect {
      standupDetail.destination?.speechRecognitionDenied != nil
      standupDetail.didSend(.startMeeting)
    }
  }

  @Test func testSpeechAuthorized() async throws {
    let standupDetail = StandupDetail(standup: .mock).withAnchor {
      $0.speechClient.authorizationStatus = { .authorized }
    }

    standupDetail.startMeetingButtonTapped()
    await expect(standupDetail.didSend(.startMeeting))
  }

  @Test func testEdit() async throws {
    var standup = Standup.mock
    let standupDetail = StandupDetail(standup: standup).withAnchor {
      $0.uuid = .incrementing
    }

    standupDetail.editButtonTapped()
    await expect(standupDetail.destination?.edit != nil)

    let edit = try await require(standupDetail.destination?.edit)
    standup.title = "Blob's Meeting"
    edit.form.standup = standup
    await expect(edit.form.standup.title == "Blob's Meeting")

    edit.save(edit.form.standup)

    await expect {
      standupDetail.destination == nil
      standupDetail.standup.title == "Blob's Meeting"
    }
  }
}
