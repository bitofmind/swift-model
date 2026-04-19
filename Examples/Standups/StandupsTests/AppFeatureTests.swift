import Foundation
import SwiftModel
import Testing
import Dependencies

@testable import Standups

@Suite(.modelTesting)
struct AppFeatureTests {
    @Test func testDelete() async throws {
        let standup = Standup.mock

        let appFeature = AppFeature(path: []).withAnchor {
            $0.dataManager = .mock(initialData: try! JSONEncoder().encode([standup]))
            $0.continuousClock = ImmediateClock()
        }

        await expect(appFeature.standupsList.standupDetails.first?.standup == standup)
        let detail = try await require(appFeature.standupsList.standupDetails.first)

        appFeature.path.append(.detail(detail.id))
        await expect(appFeature.path.count == 1)

        detail.deleteButtonTapped()

        try await require(detail.destination?.deleteStandup)()

        await expect {
            detail.didSend(.deleteStandup)
            appFeature.path.isEmpty
            appFeature.standupsList.standupDetails.isEmpty
        }
    }

    @Test func testDetailEdit() async throws {
        var standup = Standup.mock
        let saveStandup = TestProbe()

        let appFeature = AppFeature(path: []).withAnchor { dependencies in
            dependencies.continuousClock = ImmediateClock()
            dependencies.dataManager = .mock(
                initialData: try! JSONEncoder().encode([standup])
            )
            dependencies.dataManager.save = { [dependencies] data, url in
                saveStandup(try! JSONDecoder().decode([Standup].self, from: data))
                try await dependencies.dataManager.save(data, url)
            }
        }

        let standup0 = standup
        await expect(appFeature.standupsList.standupDetails.first?.standup == standup0)
        // The Observed fires once when StandupsList loads the data from the mock manager
        // (standupDetails changes from [] to [standup0]). Consume that initial save.
        await expect(saveStandup.wasCalled(with: [standup0]))
        let detail = try await require(appFeature.standupsList.standupDetails.first)

        appFeature.path.append(.detail(detail.id))
        await expect(appFeature.path.count == 1)

        detail.editButtonTapped()

        let edit = try await require(detail.destination?.edit)

        standup.title = "Blob"
        let editedStandup = standup
        edit.form.standup = editedStandup
        await expect(edit.form.standup == editedStandup)

        edit.save(editedStandup)
        await expect {
            detail.destination == nil
            detail.standup == editedStandup
        }

        await expect(saveStandup.wasCalled(with: [editedStandup]))
    }

    @Test(.modelTesting(exhaustivity: .off)) func testRecording() async throws {
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

        let appFeature = AppFeature(path: [
            .detail(standup.id),
        ]).withAnchor {
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

        let detailID = try await require(appFeature.path.first?.detail)
        let detail = try await require(appFeature.standupsList.standupDetails[id: detailID])

        detail.startMeetingButtonTapped()

        await expect {
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
