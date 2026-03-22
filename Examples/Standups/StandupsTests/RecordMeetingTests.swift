import SwiftModel
import Testing
import Dependencies

@testable import Standups

@Suite(.modelTesting)
struct RecordMeetingTests {
  @Test func testTimer() async throws {
    let clock = TestClock()
    let onSave = TestProbe()

    let recordMeeting = RecordMeeting(
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
    ).withAnchor {
      $0.continuousClock = clock
      $0.speechClient.authorizationStatus = { .denied }
    }

    await clock.advance(by: .seconds(1))
    await expect {
      recordMeeting.speakerIndex == 0
      recordMeeting.secondsElapsed == 1
      recordMeeting.durationRemaining == .seconds(5)
    }

    await clock.advance(by: .seconds(1))
    await expect {
      recordMeeting.speakerIndex == 1
      recordMeeting.secondsElapsed == 2
      recordMeeting.durationRemaining == .seconds(4)
    }

    await clock.advance(by: .seconds(1))
    await expect {
      recordMeeting.speakerIndex == 1
      recordMeeting.secondsElapsed == 3
      recordMeeting.durationRemaining == .seconds(3)
    }

    await clock.advance(by: .seconds(1))
    await expect {
      recordMeeting.speakerIndex == 2
      recordMeeting.secondsElapsed == 4
      recordMeeting.durationRemaining == .seconds(2)
    }

    await clock.advance(by: .seconds(1))
    await expect {
      recordMeeting.speakerIndex == 2
      recordMeeting.secondsElapsed == 5
      recordMeeting.durationRemaining == .seconds(1)
    }

    await clock.advance(by: .seconds(1))
    await expect {
      recordMeeting.speakerIndex == 2
      recordMeeting.secondsElapsed == 6
      recordMeeting.durationRemaining == .seconds(0)
      onSave.wasCalled(with: "")
    }
  }

  @Test(.modelTesting(exhaustivity: .off)) func testRecordTranscript() async throws {
    let clock = TestClock()
    let onSave = TestProbe()

    let recordMeeting = RecordMeeting(
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
    ).withAnchor {
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

    await expect(recordMeeting.transcript == "I completed the project")
    await clock.advance(by: .seconds(6))

    await expect(onSave.wasCalled(with: "I completed the project"))
  }

  @Test func testEndMeetingSave() async throws {
    let clock = TestClock()
    let onSave = TestProbe()

    let recordMeeting = RecordMeeting(
      standup: .mock,
      onSave: onSave.call,
      onDiscard: {}
    ).withAnchor {
      $0.continuousClock = clock
      $0.speechClient.authorizationStatus = { .denied }
    }

    recordMeeting.endMeetingButtonTapped()
    await expect(recordMeeting.destination?.endMeeting != nil)

    await clock.advance(by: .seconds(3))

    recordMeeting.destination?.endMeeting?.confirmSave()
    await expect(onSave.wasCalled(with: ""))
  }

  @Test func testEndMeetingDiscard() async throws {
    let clock = TestClock()
    let onDiscard = TestProbe()

    let recordMeeting = RecordMeeting(
      standup: .mock,
      onSave: { _ in },
      onDiscard: onDiscard.call
    ).withAnchor {
      $0.continuousClock = clock
      $0.speechClient.authorizationStatus = { .denied }
    }

    recordMeeting.endMeetingButtonTapped()
    let discardMeeting = try await require(recordMeeting.destination?.endMeeting?.discard)
    discardMeeting()

    await expect(onDiscard.wasCalled())
  }

  @Test func testNextSpeaker() async throws {
    let clock = TestClock()
    let onSave = TestProbe()

    let recordMeeting = RecordMeeting(
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
    ).withAnchor {
      $0.continuousClock = clock
      $0.speechClient.authorizationStatus = { .denied }
    }

    recordMeeting.nextButtonTapped()
    await expect {
      recordMeeting.speakerIndex == 1
      recordMeeting.secondsElapsed == 2
    }

    recordMeeting.nextButtonTapped()
    await expect {
      recordMeeting.speakerIndex == 2
      recordMeeting.secondsElapsed == 4
    }

    recordMeeting.nextButtonTapped()
    let endMeeting = try await require(recordMeeting.destination?.endMeeting)
    await expect(endMeeting.discard == nil)

    endMeeting.confirmSave()
    await expect(onSave.wasCalled(with: ""))
  }

  @Test func testSpeechRecognitionFailure_Continue() async throws {
    let clock = TestClock()
    let onSave = TestProbe()

    let recordMeeting = RecordMeeting(
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
    ).withAnchor {
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

    await expect {
      recordMeeting.destination?.speechRecognizerFailed != nil
      recordMeeting.transcript == "I completed the project ❌"
    }

    recordMeeting.destination = nil // dismiss alert

    await clock.advance(by: .seconds(6))

    await expect {
      recordMeeting.secondsElapsed == 6
      recordMeeting.speakerIndex == 2
      recordMeeting.destination == nil
      onSave.wasCalled(with:  "I completed the project ❌")
    }
  }

  @Test func testSpeechRecognitionFailure_Discard() async throws {
    let clock = TestClock()
    let onDiscard = TestProbe()

    let recordMeeting = RecordMeeting(
      standup: .mock,
      onSave: { _ in },
      onDiscard: onDiscard.call
    ).withAnchor {
      $0.continuousClock = clock
      $0.speechClient.authorizationStatus = { .authorized }
      $0.speechClient.startTask = { _ in
        AsyncThrowingStream {
          struct SpeechRecognitionFailure: Error {}
          $0.finish(throwing: SpeechRecognitionFailure())
        }
      }
    }

    let speechFailure = try await require(recordMeeting.destination?.speechRecognizerFailed)
    speechFailure() // discard

    await expect(onDiscard.wasCalled())
  }
}
