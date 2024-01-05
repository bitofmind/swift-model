import SwiftModel
import XCTest
import Dependencies

@testable import Standups

final class RecordMeetingTests: XCTestCase {
  func testTimer() async throws {
    let clock = TestClock()
    let onSave = TestProbe()

    let (recordMeeting, tester) = RecordMeeting(
      standup: Standup(
        id: Standup.ID(),
        attendees: [
          Attendee(id: Attendee.ID()),
          Attendee(id: Attendee.ID()),
          Attendee(id: Attendee.ID()),
        ],
        duration: .seconds(6)
      ),
      onSave: onSave.call,
      onDiscard: {}
    ).andTester {
      $0.continuousClock = clock
      $0.speechClient.authorizationStatus = { .denied }
    }
    tester.install(onSave)

    await clock.advance(by: .seconds(1))
    await tester.assert {
      recordMeeting.speakerIndex == 0
      recordMeeting.secondsElapsed == 1
      recordMeeting.durationRemaining == .seconds(5)
    }

    await clock.advance(by: .seconds(1))
    await tester.assert {
      recordMeeting.speakerIndex == 1
      recordMeeting.secondsElapsed == 2
      recordMeeting.durationRemaining == .seconds(4)
    }

    await clock.advance(by: .seconds(1))
    await tester.assert {
      recordMeeting.speakerIndex == 1
      recordMeeting.secondsElapsed == 3
      recordMeeting.durationRemaining == .seconds(3)
    }

    await clock.advance(by: .seconds(1))
    await tester.assert {
      recordMeeting.speakerIndex == 2
      recordMeeting.secondsElapsed == 4
      recordMeeting.durationRemaining == .seconds(2)
    }

    await clock.advance(by: .seconds(1))
    await tester.assert {
      recordMeeting.speakerIndex == 2
      recordMeeting.secondsElapsed == 5
      recordMeeting.durationRemaining == .seconds(1)
    }

    await clock.advance(by: .seconds(1))
    await tester.assert {
      recordMeeting.speakerIndex == 2
      recordMeeting.secondsElapsed == 6
      recordMeeting.durationRemaining == .seconds(0)
      onSave.wasCalled(with: "")
    }
  }

  func testRecordTranscript() async throws {
    let clock = TestClock()
    let onSave = TestProbe()

    let (recordMeeting, tester) = RecordMeeting(
      standup: Standup(
        id: Standup.ID(),
        attendees: [
          Attendee(id: Attendee.ID()),
          Attendee(id: Attendee.ID()),
          Attendee(id: Attendee.ID()),
        ],
        duration: .seconds(6)
      ),
      onSave: onSave.call,
      onDiscard: {}
    ).andTester {
      $0.continuousClock = clock
      $0.speechClient.authorizationStatus = { .authorized }
      $0.speechClient.startTask = { _ in
        AsyncThrowingStream { continuation in
          continuation.yield(
            SpeechRecognitionResult(
              bestTranscription: Transcription(formattedString: "I completed the project"),
              isFinal: true
            )
          )
          continuation.finish()
        }
      }
    }

    tester.install(onSave)
    tester.exhaustivity = .off

    await tester.assert(recordMeeting.transcript == "I completed the project")
    await clock.advance(by: .seconds(6))

    await tester.assert(onSave.wasCalled(with: "I completed the project"))
  }

  func testEndMeetingSave() async throws {
    let clock = TestClock()
    let onSave = TestProbe()

    let (recordMeeting, tester) = RecordMeeting(
      standup: .mock,
      onSave: onSave.call,
      onDiscard: {}
    ).andTester {
      $0.continuousClock = clock
      $0.speechClient.authorizationStatus = { .denied }
    }
    tester.install(onSave)

    recordMeeting.endMeetingButtonTapped()
    await tester.assert(recordMeeting.destination?.endMeeting != nil)

    await clock.advance(by: .seconds(3))

    recordMeeting.destination?.endMeeting?.confirmSave()
    await tester.assert(onSave.wasCalled(with: ""))
  }

  func testEndMeetingDiscard() async throws {
    let clock = TestClock()
    let onDiscard = TestProbe()

    let (recordMeeting, tester) = RecordMeeting(
      standup: .mock,
      onSave: { _ in },
      onDiscard: onDiscard.call
    ).andTester {
      $0.continuousClock = clock
      $0.speechClient.authorizationStatus = { .denied }
    }

    recordMeeting.endMeetingButtonTapped()
    let discardMeeting = try await tester.unwrap(recordMeeting.destination?.endMeeting?.discard)
    discardMeeting()

    await tester.assert(onDiscard.wasCalled())
  }

  func testNextSpeaker() async throws {
    let clock = TestClock()
    let onSave = TestProbe()

    let (recordMeeting, tester) = RecordMeeting(
      standup: Standup(
        id: Standup.ID(),
        attendees: [
          Attendee(id: Attendee.ID()),
          Attendee(id: Attendee.ID()),
          Attendee(id: Attendee.ID()),
        ],
        duration: .seconds(6)
      ),
      onSave: onSave.call,
      onDiscard: {}
    ).andTester {
      $0.continuousClock = clock
      $0.speechClient.authorizationStatus = { .denied }
    }

    recordMeeting.nextButtonTapped()
    await tester.assert {
      recordMeeting.speakerIndex == 1
      recordMeeting.secondsElapsed == 2
    }

    recordMeeting.nextButtonTapped()
    await tester.assert {
      recordMeeting.speakerIndex == 2
      recordMeeting.secondsElapsed == 4
    }

    recordMeeting.nextButtonTapped()
    let endMeeting = try await tester.unwrap(recordMeeting.destination?.endMeeting)
    await tester.assert(endMeeting.discard == nil)

    endMeeting.confirmSave()
    await tester.assert(onSave.wasCalled(with: ""))
  }

  func testSpeechRecognitionFailure_Continue() async throws {
    let clock = TestClock()
    let onSave = TestProbe()

    let (recordMeeting, tester) = RecordMeeting(
      standup: Standup(
        id: Standup.ID(),
        attendees: [
          Attendee(id: Attendee.ID()),
          Attendee(id: Attendee.ID()),
          Attendee(id: Attendee.ID()),
        ],
        duration: .seconds(6)
      ),
      onSave: onSave.call,
      onDiscard: {}
    ).andTester {
      $0.continuousClock = clock
      $0.speechClient.authorizationStatus = { .authorized }
      $0.speechClient.startTask = { _ in
        AsyncThrowingStream {
          $0.yield(
            SpeechRecognitionResult(
              bestTranscription: Transcription(formattedString: "I completed the project"),
              isFinal: true
            )
          )
          struct SpeechRecognitionFailure: Error {}
          $0.finish(throwing: SpeechRecognitionFailure())
        }
      }
    }

    await tester.assert {
      recordMeeting.destination?.speechRecognizerFailed != nil
      recordMeeting.transcript == "I completed the project ❌"
    }

    recordMeeting.destination = nil // dismiss alert

    await clock.advance(by: .seconds(6))

    await tester.assert {
      recordMeeting.secondsElapsed == 6
      recordMeeting.speakerIndex == 2
      recordMeeting.destination == nil
      onSave.wasCalled(with:  "I completed the project ❌")
    }
  }

  func testSpeechRecognitionFailure_Discard() async throws {
    let clock = TestClock()
    let onDiscard = TestProbe()

    let (recordMeeting, tester) = RecordMeeting(
      standup: .mock,
      onSave: { _ in },
      onDiscard: onDiscard.call
    ).andTester {
      $0.continuousClock = clock
      $0.speechClient.authorizationStatus = { .authorized }
      $0.speechClient.startTask = { _ in
        AsyncThrowingStream {
          struct SpeechRecognitionFailure: Error {}
          $0.finish(throwing: SpeechRecognitionFailure())
        }
      }
    }
    tester.install(onDiscard)

    let speechFailure = try await tester.unwrap(recordMeeting.destination?.speechRecognizerFailed)
    speechFailure() // discard

    await tester.assert(onDiscard.wasCalled())
  }
}
