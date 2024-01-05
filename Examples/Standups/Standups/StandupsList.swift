import SwiftModel
import SwiftUI
import IdentifiedCollections
import SwiftUINavigation
import Dependencies

@Model struct StandupsList: Sendable {
  var standupDetails: IdentifiedArrayOf<StandupDetail>
  var destination: Destination?

  init(standupDetails: IdentifiedArrayOf<StandupDetail> = [], destination: Destination? = nil) {
    _standupDetails = standupDetails
    _destination = destination
  }

  @ModelContainer @CasePathable
  @dynamicMemberLookup
  enum Destination {
    case add(form: StandupForm, add: @Sendable (Standup) -> Void, dismiss: @Sendable () -> Void)
    case dataFailedToLoad(confirmLoadMockData: @Sendable () -> Void)
  }

  func onActivate() {
    do {
      standupDetails = try IdentifiedArray(uniqueElements: JSONDecoder().decode(IdentifiedArrayOf<Standup>.self, from: node.dataManager.load(.standups)).map { StandupDetail(standup: $0) })
    } catch is DecodingError {
      destination = .dataFailedToLoad(confirmLoadMockData: {
        standupDetails = IdentifiedArray(uniqueElements: [
          Standup.mock,
          .designMock,
          .engineeringMock,
        ].map { StandupDetail(standup: $0) })
      })
    } catch {
    }
  }

  func addDestination(for standup: Standup) -> Destination {
    .add(
      form: StandupForm(standup: standup),
      add: { editStandup in
        var standup = editStandup
        standup.attendees.removeAll { attendee in
          attendee.name.allSatisfy(\.isWhitespace)
        }
        if standup.attendees.isEmpty {
          standup.attendees.append(
            editStandup.attendees.first
            ?? Attendee(id: Attendee.ID(node.uuid()))
          )
        }
        standupDetails.append(StandupDetail(standup: standup))
        destination = nil
      },
      dismiss: {
        destination = nil
    })
  }

  func addStandupButtonTapped() {
    destination = addDestination(for: Standup(id: Standup.ID(node.uuid())))
  }

  func dismissAddStandupButtonTapped() {
    destination = nil
  }
}

struct StandupsListView: View {
  @ObservedModel var model: StandupsList

  var body: some View {
    List {
      ForEach(model.standupDetails) { standupDetail in
        let standup = standupDetail.standup
        NavigationLink(value: AppFeature.Path.detail(standupDetail.id)) {
          CardView(standup: standup)
        }
        .listRowBackground(standup.theme.mainColor)
      }
    }
    .toolbar {
      Button {
        model.addStandupButtonTapped()
      } label: {
        Image(systemName: "plus")
      }
    }
    .navigationTitle("Daily Standups")
    .sheet(unwrapping: $model.destination.add) { $item in
      NavigationStack {
        StandupFormView(model: item.form)
          .navigationTitle("New standup")
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Dismiss", action: item.dismiss)
            }
            ToolbarItem(placement: .confirmationAction) {
              Button("Add") {
                item.add(item.form.standup)
              }
            }
          }
      }
    }
    .alert(title: { _ in
      Text("Data failed to load")
    }, unwrapping: $model.destination.dataFailedToLoad) { confirmLoadMockData in
      Button("Yes", action: confirmLoadMockData)
      Button("No", role: .cancel) { }
    } message: { _ in
      Text(
        """
        Unfortunately your past data failed to load. Would you like to load some mock data to play \
        around with?
        """
      )
    }
  }
}

struct CardView: View {
  let standup: Standup

  var body: some View {
    VStack(alignment: .leading) {
      Text(standup.title)
        .font(.headline)
      Spacer()
      HStack {
        Label("\(standup.attendees.count)", systemImage: "person.3")
        Spacer()
        Label(standup.duration.formatted(.units()), systemImage: "clock")
          .labelStyle(.trailingIcon)
      }
      .font(.caption)
    }
    .padding()
    .foregroundColor(standup.theme.accentColor)
  }
}

struct TrailingIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack {
      configuration.title
      configuration.icon
    }
  }
}

extension LabelStyle where Self == TrailingIconLabelStyle {
  static var trailingIcon: Self { Self() }
}

struct StandupsList_Previews: PreviewProvider {
  static var previews: some View {
    StandupsListView(model: StandupsList().withAnchor {
      $0.dataManager.load = { _ in
        try JSONEncoder().encode([
          Standup.mock,
          .designMock,
          .engineeringMock,
        ])
      }
    })

    StandupsListView(model: StandupsList().withAnchor {
      $0.dataManager = .mock(initialData: Data("!@#$% bad data ^&*()".utf8))
    })
    .previewDisplayName("Load data failure")
  }
}
