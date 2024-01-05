import SwiftModel
import SwiftUI
import Dependencies
import Speech
import SwiftUINavigation

@Model struct StandupDetail: Sendable {
  fileprivate(set) var destination: Destination?
  var standup: Standup

  var id: Standup.ID { standup.id }

  enum Event {
    case deleteStandup
    case startMeeting
  }

  @ModelContainer @CasePathable
  @dynamicMemberLookup
  enum Destination: Sendable {
    case speechRecognitionRestricted(continue: @Sendable () -> Void)
    case deleteStandup(confirm: @Sendable () -> Void)
    case speechRecognitionDenied(continue: @Sendable () -> Void, openSettings: @Sendable () -> Void)
    case edit(form: StandupForm, save: @Sendable (Standup) -> Void, discard: @Sendable () -> Void)
  }

  func deleteButtonTapped() {
    destination = .deleteStandup {
      node.send(.deleteStandup)
    }
  }

  func deleteMeetings(atOffsets indices: IndexSet) {
    standup.meetings.remove(atOffsets: indices)
  }

  func editButtonTapped() {
    destination = .edit(
      form: StandupForm(standup: standup),
      save: { standupToSave in
        standup = standupToSave
        destination = nil
      },
      discard: {
        destination = nil
      }
    )
  }

  func startMeetingButtonTapped() {
    switch node.speechClient.authorizationStatus() {
    case .notDetermined, .authorized:
      node.send(.startMeeting)
    case .denied:
      destination = .speechRecognitionDenied {
        node.send(.startMeeting)
      } openSettings: {
        node.task {
          await node.openSettings()
        }
      }    
    case .restricted:
      destination = .speechRecognitionRestricted {
        node.send(.startMeeting)
      }
    @unknown default: break
    }
  }
}

struct StandupDetailView: View {
  @ObservedModel var model: StandupDetail

  var body: some View {
    List {
      Section {
        Button {
          model.startMeetingButtonTapped()
        } label: {
          Label("Start Meeting", systemImage: "timer")
            .font(.headline)
            .foregroundColor(.accentColor)
        }
        HStack {
          Label("Length", systemImage: "clock")
          Spacer()
          Text(model.standup.duration.formatted(.units()))
        }

        HStack {
          Label("Theme", systemImage: "paintpalette")
          Spacer()
          Text(model.standup.theme.name)
            .padding(4)
            .foregroundColor(model.standup.theme.accentColor)
            .background(model.standup.theme.mainColor)
            .cornerRadius(4)
        }
      } header: {
        Text("Standup Info")
      }

      if !model.standup.meetings.isEmpty {
        Section {
          ForEach(model.standup.meetings) { meeting in
            NavigationLink(value: AppFeature.Path.meeting(meeting, standup: model.standup)) {
              HStack {
                Image(systemName: "calendar")
                Text(meeting.date, style: .date)
                Text(meeting.date, style: .time)
              }
            }
          }
          .onDelete { indices in
            model.deleteMeetings(atOffsets: indices)
          }
        } header: {
          Text("Past meetings")
        }
      }

      Section {
        ForEach(model.standup.attendees) { attendee in
          Label(attendee.name, systemImage: "person")
        }
      } header: {
        Text("Attendees")
      }

      Section {
        Button("Delete") {
          model.deleteButtonTapped()
        }
        .foregroundColor(.red)
        .frame(maxWidth: .infinity)
      }
    }
    .navigationTitle(model.standup.title)
    .toolbar {
      Button("Edit") {
        model.editButtonTapped()
      }
    }
    .sheet(unwrapping: $model.destination.edit) { $edit in
      NavigationStack {
        StandupFormView(model: edit.form)
          .navigationTitle(model.standup.title)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel", action: edit.discard)
            }
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") {
                edit.save(edit.form.standup)
              }
            }
          }
      }
    }
    .alert(title: { _ in
      Text("Speech recognition restricted")
    }, unwrapping: $model.destination.speechRecognitionRestricted) { onContinue in
      Button("Continue without recording", action: onContinue)
      Button("Cancel", role: .cancel) { }
    } message: { _ in
      Text("Your device does not support speech recognition and so your meeting will not be recorded.")
    }
    .alert(title: { _ in
      Text("Delete?")
    }, unwrapping: $model.destination.deleteStandup) { onConfirm in
      Button("Yes", action: onConfirm)
      Button("Nevermind", role: .cancel) { }
    } message: { _ in
      Text("Are you sure you want to delete this meeting?")
    }
    .alert(title: { _ in
      Text("Speech recognition denied")
    }, unwrapping: $model.destination.speechRecognitionDenied) { onContinue, onOpenSettings in
      Button("Continue without recording", action: onContinue)
      Button("Open settings", action: onOpenSettings)
      Button("Cancel", role: .cancel) { }
    } message: { _ in
      Text(
        """
        You previously denied speech recognition and so your meeting meeting will not be \
        recorded. You can enable speech recognition in settings, or you can continue without \
        recording.
        """
      )
    }
  }
}

struct StandupDetail_Previews: PreviewProvider {
  static var previews: some View {
    NavigationStack {
      StandupDetailView(model: StandupDetail(standup: .mock).withAnchor())
    }
  }
}
