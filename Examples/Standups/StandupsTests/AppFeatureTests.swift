import SwiftModel
import XCTest
import Dependencies

@testable import Standups

final class AppFeatureTests: XCTestCase {
  func testDelete() async throws {
    let standup = Standup.mock

    let (appFeature, tester) = AppFeature(path: []).andTester {
      $0.dataManager = .mock(initialData: try! JSONEncoder().encode([standup]))
      $0.continuousClock = ImmediateClock()
    }

    await tester.assert(appFeature.standupsList.standupDetails.first?.standup == standup)
    let detail = try await tester.unwrap(appFeature.standupsList.standupDetails.first)

    appFeature.path.append(.detail(detail.id))
    await tester.assert(appFeature.path.count == 1)

    detail.deleteButtonTapped()

    try await tester.unwrap(detail.destination?.deleteStandup)()

    await tester.assert {
      detail.didSend(.deleteStandup)
      appFeature.path.isEmpty
      appFeature.standupsList.standupDetails.isEmpty
    }
  }

  func testDetailEdit() async throws {
    var standup = Standup.mock
    let saveStandup = TestProbe()

    let (appFeature, tester) = AppFeature(path: []).andTester { dependencies in
      dependencies.continuousClock = ImmediateClock()
      dependencies.dataManager = .mock(
        initialData: try! JSONEncoder().encode([standup])
      )
      dependencies.dataManager.save = { [dependencies] data, url in
        saveStandup(try! JSONDecoder().decode([Standup].self, from: data))
        try await dependencies.dataManager.save(data, url)
      }
    }

    await tester.assert(appFeature.standupsList.standupDetails.first?.standup == standup)
    let detail = try await tester.unwrap(appFeature.standupsList.standupDetails.first)

    appFeature.path.append(.detail(detail.id))
    await tester.assert(appFeature.path.count == 1)

    detail.editButtonTapped()

    let edit = try await tester.unwrap(detail.destination?.edit)

    standup.title = "Blob"
    edit.form.standup = standup
    await tester.assert(edit.form.standup == standup)

    edit.save(standup)
    await tester.assert {
      detail.destination == nil
      detail.standup == standup
    }

    var savedStandup = standup
    savedStandup.title = "Blob"
    await tester.assert(saveStandup.wasCalled(with: [savedStandup]))
  }

  func testRecording() async throws {
    let speechResult = SpeechRecognitionResult(
      bestTranscription: Transcription(formattedString: "I completed the project"),
      isFinal: true
    )
    let standup = Standup(
      id: Standup.ID(),
      attendees: [
        Attendee(id: Attendee.ID()),
        Attendee(id: Attendee.ID()),
        Attendee(id: Attendee.ID()),
      ],
      duration: .seconds(6)
    )

    let (appFeature, tester) = AppFeature(path: [
      .detail(standup.id),
    ]).andTester {
      $0.dataManager = .mock(initialData: try! JSONEncoder().encode([standup]))
      $0.date.now = Date(timeIntervalSince1970: 1_234_567_890)
      $0.continuousClock = ImmediateClock()
      $0.speechClient.authorizationStatus = { .authorized }
      $0.speechClient.startTask = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(speechResult)
          continuation.finish()
        }
      }
      $0.uuid = .incrementing
    }

    tester.exhaustivity = .off

    let detailID = try await tester.unwrap(appFeature.path.first?.detail)
    let detail = try await tester.unwrap(appFeature.standupsList.standupDetails[id: detailID])

    detail.startMeetingButtonTapped()

    await tester.assert {
      detail.standup.meetings == [
        Meeting(
          id: Meeting.ID(UUID(0)),
          date: Date(timeIntervalSince1970: 1_234_567_890),
          transcript: "I completed the project"
        )
      ]
      appFeature.path.count == 1
    }
  }
}
