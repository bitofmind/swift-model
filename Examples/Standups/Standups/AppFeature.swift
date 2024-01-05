import SwiftModel
import SwiftUI
import SwiftUINavigation
import Dependencies
import AsyncAlgorithms
import CustomDump
import Clocks
import IdentifiedCollections

@Model struct AppFeature: Sendable {
  var path: IdentifiedArrayOf<Path>
  private(set) var standupsList = StandupsList()

  func onActivate() {
    node.forEach(node.event(fromType: StandupDetail.self)) { event, standupDetail in
      switch event {
      case .deleteStandup:
        standupsList.standupDetails.remove(id: standupDetail.id)
        path.removeLast()

      case .startMeeting:
        path.append(.record(RecordMeeting(
          standup: standupDetail.standup,
          onSave: { transcript in
            standupDetail.standup.meetings.insert(
              Meeting(
                id: Meeting.ID(node.uuid()),
                date: node.date.now,
                transcript: transcript
              ),
              at: 0
            )
            path.removeLast()
          },
          onDiscard: {
            path.removeLast()
          }
        )))
      }
    }

    let standupUpdates = update(of: \.standupsList.standupDetails, recursive: true)
      .map { $0.map(\.standup) }
      .dropFirst()
      .removeDuplicates()
      .debounce(for: .seconds(1), clock: AnyClock(node.continuousClock))

    node.forEach(standupUpdates) { standups in
      try? await node.dataManager.save(JSONEncoder().encode(standups), .standups)
    }
  }

  @ModelContainer @CasePathable
  @dynamicMemberLookup
  enum Path: Hashable, Sendable, Identifiable {
    case detail(StandupDetail.ID)
    case meeting(Meeting, standup: Standup)
    case record(RecordMeeting)

    var id: AnyHashable {
      switch self {
      case let .detail(detail): detail
      case let .meeting(meeting, standup: standup): [AnyHashable(meeting.id), AnyHashable(standup.id)]
      case let .record(record): record.id
      }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
      hasher.combine(id)
    }
  }
}

struct AppView: View {
  @ObservedModel var model: AppFeature

  var body: some View {
    NavigationStack(path: $model.path) {
      StandupsListView(model: model.standupsList)
        .navigationDestination(for: AppFeature.Path.self) { path in
          switch path {
          case let .detail(id):
            if let model = model.standupsList.standupDetails[id: id] {
                StandupDetailView(model: model)
            } else {
              let _ = assertionFailure("Should never happen()")
              Text("Fatal error!")
            }
          case let .meeting(meeting, standup: standup):
            MeetingView(meeting: meeting, standup: standup)
          case let .record(recordMeeting):
            RecordMeetingView(model: recordMeeting)
          }
        }
    }
  }
}

extension URL {
  static let standups = Self.documentsDirectory.appending(component: "standups.json")
}

