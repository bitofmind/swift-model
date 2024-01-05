import SwiftModel
import XCTest

@testable import Standups

final class StandupFormTests: XCTestCase {
  func testAddAttendee() async {
    let (standupForm, store) = StandupForm(
      standup: Standup(
        id: Standup.ID(),
        attendees: [],
        title: "Engineering"
      )
    ).andTester {
      $0.uuid = .incrementing
    }

    await store.assert(standupForm.standup.attendees == [Attendee(id: Attendee.ID(UUID(0)))])

    standupForm.addAttendeeButtonTapped()

    await store.assert {
      standupForm.focus == .attendee(Attendee.ID(UUID(1)))
      standupForm.standup.attendees == [Attendee(id: Attendee.ID(UUID(0))), Attendee(id: Attendee.ID(UUID(1)))]
    }
  }

  func testFocus_RemoveAttendee() async {
    let (standupForm, store) = StandupForm(
      standup: Standup(
        id: Standup.ID(),
        attendees: [
          Attendee(id: Attendee.ID()),
          Attendee(id: Attendee.ID()),
          Attendee(id: Attendee.ID()),
          Attendee(id: Attendee.ID()),
        ],
        title: "Engineering"
      )
    ).andTester {
      $0.uuid = .incrementing
    }

    var attendees = standupForm.standup.attendees
    standupForm.deleteAttendees(atOffsets: [0])
    await store.assert {
      standupForm.focus == .attendee(attendees[1].id)
      standupForm.standup.attendees == [
        attendees[1],
        attendees[2],
        attendees[3],
      ]
    }

    attendees = standupForm.standup.attendees
    standupForm.deleteAttendees(atOffsets: [1])
    await store.assert {
      standupForm.focus == .attendee(attendees[2].id)
      standupForm.standup.attendees == [
        attendees[0],
        attendees[2],
      ]
    }

    attendees = standupForm.standup.attendees
    standupForm.deleteAttendees(atOffsets: [1])
    await store.assert {
      standupForm.focus == .attendee(attendees[0].id)
      standupForm.standup.attendees == [
        attendees[0],
      ]
    }

    attendees = standupForm.standup.attendees
    standupForm.deleteAttendees(atOffsets: [0])
    await store.assert {
      standupForm.focus == .attendee(Attendee.ID(UUID(0)))
      standupForm.standup.attendees == [
        Attendee(id: Attendee.ID(UUID(0)))
      ]
    }
  }
}
