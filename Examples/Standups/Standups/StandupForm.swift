import SwiftModel
import SwiftUI
import SwiftUINavigation
import Dependencies

@Model struct StandupForm: Sendable {
  fileprivate(set) var focus: Field? = .title
  var standup: Standup

  enum Field: Hashable {
    case attendee(Attendee.ID)
    case title
  }

  func onActivate() {
    if standup.attendees.isEmpty {
      standup.attendees.append(Attendee(id: Attendee.ID(node.uuid())))
    }
  }

  func addAttendeeButtonTapped() {
    let attendee = Attendee(id: Attendee.ID(node.uuid()))
    standup.attendees.append(attendee)
    focus = .attendee(attendee.id)
  }

  func deleteAttendees(atOffsets indices: IndexSet) {
    standup.attendees.remove(atOffsets: indices)
    if standup.attendees.isEmpty {
      standup.attendees.append(Attendee(id: Attendee.ID(node.uuid())))
    }
    
    guard let firstIndex = indices.first else { return }

    let index = min(firstIndex, standup.attendees.count - 1)
    focus = .attendee(standup.attendees[index].id)
  }
}

struct StandupFormView: View {
  @ObservedModel var model: StandupForm
  @FocusState var focus: StandupForm.Field?

  var body: some View {
    Form {
      Section {
        TextField("Title", text: $model.standup.title)
          .focused($focus, equals: .title)
        HStack {
          Slider(value: $model.standup.duration.minutes, in: 5...30, step: 1) {
            Text("Length")
          }
          Spacer()
          Text(model.standup.duration.formatted(.units()))
        }
        ThemePicker(selection: $model.standup.theme)
      } header: {
        Text("Standup Info")
      }
      Section {
        ForEach($model.standup.attendees) { $attendee in
          TextField("Name", text: $attendee.name)
            .focused(self.$focus, equals: .attendee(attendee.id))
        }
        .onDelete { indices in
          model.deleteAttendees(atOffsets: indices)
        }

        Button("New attendee") {
          model.addAttendeeButtonTapped()
        }
      } header: {
        Text("Attendees")
      }
    }
    .bind($model.focus, to: $focus)
  }
}

struct ThemePicker: View {
  @Binding var selection: Theme

  var body: some View {
    Picker("Theme", selection: self.$selection) {
      ForEach(Theme.allCases) { theme in
        ZStack {
          RoundedRectangle(cornerRadius: 4)
            .fill(theme.mainColor)
          Label(theme.name, systemImage: "paintpalette")
            .padding(4)
        }
        .foregroundColor(theme.accentColor)
        .fixedSize(horizontal: false, vertical: true)
        .tag(theme)
      }
    }
  }
}

extension Duration {
  fileprivate var minutes: Double {
    get { Double(self.components.seconds / 60) }
    set { self = .seconds(newValue * 60) }
  }
}

struct EditStandup_Previews: PreviewProvider {
  static var previews: some View {
    NavigationStack {
      StandupFormView(model: StandupForm(standup: .mock).withAnchor())
    }
  }
}
