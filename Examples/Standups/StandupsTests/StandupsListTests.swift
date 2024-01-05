import SwiftModel
import XCTest
import Dependencies

@testable import Standups

final class StandupsListTests: XCTestCase {
  func testAdd() async throws {
    let (standupList, tester) = StandupsList().andTester() {
      $0.continuousClock = ImmediateClock()
      $0.dataManager = .mock()
      $0.uuid = .incrementing
    }

    var standup = Standup(
      id: Standup.ID(UUID(0)),
      attendees: [
        Attendee(id: Attendee.ID(UUID(1)))
      ]
    )
    standupList.addStandupButtonTapped()
    let addStandup = try await tester.unwrap(standupList.destination?.add)
    await tester.assert(addStandup.form.standup == standup)

    standup.title = "Engineering"
    addStandup.form.standup = standup
    await tester.assert(addStandup.form.standup == standup)

    addStandup.add(addStandup.form.standup)
    await tester.assert {
      standupList.destination == nil
      standupList.standupDetails.map(\.standup) == [standup]
    }
  }

  func testAdd_ValidatedAttendees() async throws {
    let uuid = UUIDGenerator.incrementing
    let (standupList, tester) = StandupsList().withActivation {
      $0.destination = $0.addDestination(
        for: Standup(
          id: Standup.ID(uuidString: "deadbeef-dead-beef-dead-beefdeadbeef")!,
          attendees: [
            Attendee(id: Attendee.ID(uuid()), name: ""),
            Attendee(id: Attendee.ID(uuid()), name: "    "),
          ],
          title: "Design"
        )
      )
    }.andTester() {
      $0.continuousClock = ImmediateClock()
      $0.dataManager = .mock()
      $0.uuid = uuid
    }

    let addStandup = try await tester.unwrap(standupList.destination?.add)
    addStandup.add(addStandup.form.standup)

    await tester.assert {
      standupList.destination == nil
      standupList.standupDetails.map(\.standup) == [
        Standup(
          id: Standup.ID(uuidString: "deadbeef-dead-beef-dead-beefdeadbeef")!,
          attendees: [
            Attendee(id: Attendee.ID(UUID(0)))
          ],
          title: "Design"
        )
      ]
    }
  }

  func testLoadingDataDecodingFailed() async throws {
    let (standupList, tester) = StandupsList().andTester {
      $0.continuousClock = ImmediateClock()
      $0.dataManager = .mock(
        initialData: Data("!@#$ BAD DATA %^&*()".utf8)
      )
    }

    let dataFailedToLoad = try await tester.unwrap(standupList.destination?.dataFailedToLoad)

    dataFailedToLoad() // confirm
    await tester.assert {
      standupList.standupDetails.map(\.standup) == [
        .mock,
        .designMock,
        .engineeringMock,
      ]
    }
  }

  func testLoadingDataFileNotFound() async throws {
    let (standupList, tester) = StandupsList().andTester {
      $0.continuousClock = ImmediateClock()
      $0.dataManager.load = { _ in
        struct FileNotFound: Error {}
        throw FileNotFound()
      }
    }

    await tester.assert(standupList.destination == nil)
  }
}
