import SwiftModel
import XCTest
import Dependencies

@testable import Standups

final class StandupDetailTests: XCTestCase {
  func testSpeechRestricted() async {
    let (standupDetail, tester) = StandupDetail(standup: .mock).andTester() {
      $0.speechClient.authorizationStatus = { .restricted }
    }

    standupDetail.startMeetingButtonTapped()
    await tester.assert(standupDetail.destination?.speechRecognitionRestricted != nil)
  }

  func testSpeechDenied() async throws {
    let (standupDetail, tester) = StandupDetail(standup: .mock).andTester() {
      $0.speechClient.authorizationStatus = { .denied }
    }

    standupDetail.startMeetingButtonTapped()
    await tester.assert(standupDetail.destination != nil)// == .alert(.speechRecognitionDenied))
  }

  func testOpenSettings() async throws {
    let settingsOpened = TestProbe()

    let (standupDetail, tester) = StandupDetail(standup: .mock).andTester() {
      $0.openSettings = settingsOpened.call
      $0.speechClient.authorizationStatus = { .denied }
    }

    standupDetail.startMeetingButtonTapped()

    try await tester.unwrap(standupDetail.destination?.speechRecognitionDenied).openSettings()
    await tester.assert {
      standupDetail.destination?.speechRecognitionDenied != nil
      settingsOpened.wasCalled()
    }
  }

  func testContinueWithoutRecording() async throws {
    let (standupDetail, tester) = StandupDetail(standup: .mock).andTester() {
      $0.speechClient.authorizationStatus = { .denied }
    }

    standupDetail.startMeetingButtonTapped()
    try await tester.unwrap(standupDetail.destination?.speechRecognitionDenied).continue()

    await tester.assert {
      standupDetail.destination?.speechRecognitionDenied != nil
      standupDetail.didSend(.startMeeting)
    }
  }

  func testSpeechAuthorized() async throws {
    let (standupDetail, tester) = StandupDetail(standup: .mock).andTester() {
      $0.speechClient.authorizationStatus = { .authorized }
    }

    standupDetail.startMeetingButtonTapped()
    await tester.assert(standupDetail.didSend(.startMeeting))
  }

  func testEdit() async throws {
    var standup = Standup.mock
    let (standupDetail, tester) = StandupDetail(standup: standup).andTester() {
      $0.uuid = .incrementing
    }

    standupDetail.editButtonTapped()
    await tester.assert(standupDetail.destination?.edit != nil)

    let edit = try await tester.unwrap(standupDetail.destination?.edit)
    standup.title = "Blob's Meeting"
    edit.form.standup = standup
    await tester.assert(edit.form.standup.title == "Blob's Meeting")

    edit.save(edit.form.standup)

    await tester.assert {
      standupDetail.destination == nil
      standupDetail.standup.title == "Blob's Meeting"
    }
  }
}
