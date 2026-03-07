import Foundation
import SwiftModel
import Testing

@testable import Standups

struct StandupFormTests {
  @Test func testAddAttendee() async {
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

  @Test func testFocus_RemoveAttendee() async {
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

    let attendees1 = standupForm.standup.attendees
    standupForm.deleteAttendees(atOffsets: [0])
    await store.assert {
      standupForm.focus == .attendee(attendees1[1].id)
      standupForm.standup.attendees == [
        attendees1[1],
        attendees1[2],
        attendees1[3],
      ]
    }

    let attendees2 = standupForm.standup.attendees
    standupForm.deleteAttendees(atOffsets: [1])
    await store.assert {
      standupForm.focus == .attendee(attendees2[2].id)
      standupForm.standup.attendees == [
        attendees2[0],
        attendees2[2],
      ]
    }

    let attendees3 = standupForm.standup.attendees
    standupForm.deleteAttendees(atOffsets: [1])
    await store.assert {
      standupForm.focus == .attendee(attendees3[0].id)
      standupForm.standup.attendees == [
        attendees3[0],
      ]
    }

    standupForm.deleteAttendees(atOffsets: [0])
    await store.assert {
      standupForm.focus == .attendee(Attendee.ID(UUID(0)))
      standupForm.standup.attendees == [
        Attendee(id: Attendee.ID(UUID(0)))
      ]
    }
  }
}
