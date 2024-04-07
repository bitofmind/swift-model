import SwiftModel
import SwiftUI
import SwiftUINavigation

@Model
struct SignUpData: Sendable {
  var email = ""
  var firstName = ""
  var lastName = ""
  var password = ""
  var passwordConfirmation = ""
  var phoneNumber = ""
  var topics: Set<Topic> = []

  enum Topic: String, Identifiable, CaseIterable {
    case advancedSwift = "Advanced Swift"
    case composableArchitecture = "Composable Architecture"
    case concurrency = "Concurrency"
    case modernSwiftUI = "Modern SwiftUI"
    case swiftUI = "SwiftUI"
    case testing = "Testing"
    var id: Self { self }
  }
}

struct StackItem<Value: Identifiable>: Hashable  {
  var value: Value

  init(_ value: Value) {
    self.value = value
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.value.id == rhs.value.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(value.id)
  }
}

extension RangeReplaceableCollection where Element: Identifiable {
  var stackItems: [StackItem<Element>] {
    get { map { StackItem($0) } }
    set { self = .init(newValue.map(\.value)) }
  }
}

extension NavigationLink where Destination == Never {
  init<P>(_ titleKey: LocalizedStringKey, item: P?) where Label == Text, P : Identifiable {
    self.init(titleKey, value: item.map { StackItem($0) })
  }
}

@Model
struct SignUpFeature: Sendable {
  @ModelContainer @CasePathable
  @dynamicMemberLookup
  enum Path: Identifiable  {
    case basics(BasicsFeature)
    case personalInfo(PersonalInfoFeature)
    case summary(SummaryFeature)
    case topics(TopicsFeature)

    var id: AnyHashable {
      switch self {
      case let .basics(model): model.id
      case let .personalInfo(model): model.id
      case let .summary(model): model.id
      case let .topics(model): model.id
      }
    }
  }

  var path: [Path] = []
  var signUpData: SignUpData

  func onActivate() {
    node.forEach(node.event(of: .onNext, fromType: TopicsFeature.self)) { _ in
      path.append(.summary(SummaryFeature(signUpData: signUpData)))
    }
  }
}

struct SignUpFlow: View {
  @ObservedModel var model: SignUpFeature

  var body: some View {
    NavigationStack(path: $model.path.stackItems) {
      Form {
        Section {
          Text("Welcome! Please sign up.")
          NavigationLink(
            "Sign up",
            item: SignUpFeature.Path.basics(BasicsFeature(signUpData: model.signUpData))
          )
        }
      }
      .navigationTitle("Sign up")
      .navigationDestination(for: StackItem<SignUpFeature.Path>.self) { path in
        switch path.value {
        case let .basics(model):
          BasicsStep(model: model)
        case let .personalInfo(model):
          PersonalInfoStep(model: model)
        case let .summary(model):
          SummaryStep(model: model)
        case let .topics(model):
          TopicsStep(model: model)
        }
      }
    }
  }
}

#Preview("Sign up") {
  SignUpFlow(model: SignUpFeature(signUpData: SignUpData()).withAnchor())
}

@Model
struct BasicsFeature: Sendable {
  var signUpData: SignUpData
}

struct BasicsStep: View {
  @ObservedModel var model: BasicsFeature

  var body: some View {
    Form {
      Section {
        TextField("Email", text: $model.signUpData.email)
      }
      Section {
        SecureField("Password", text: $model.signUpData.password)
        SecureField("Password confirmation", text: $model.signUpData.passwordConfirmation)
      }
    }
    .navigationTitle("Basics")
    .toolbar {
      ToolbarItem {
        NavigationLink(
          "Next",
          item: SignUpFeature.Path.personalInfo(PersonalInfoFeature(signUpData: model.signUpData))
        )
      }
    }
  }
}

#Preview("Basics") {
  NavigationStack {
    BasicsStep(model: BasicsFeature(signUpData: SignUpData()).withAnchor())
  }
}

@Model
struct PersonalInfoFeature: Sendable {
  var signUpData: SignUpData
}

struct PersonalInfoStep: View {
  @ObservedModel var model: PersonalInfoFeature
  var isEditingFromSummary = false
  @Environment(\.dismiss) var dismiss

  var body: some View {
    Form {
      Section {
        TextField("First name", text: $model.signUpData.firstName)
        TextField("Last name", text: $model.signUpData.lastName)
        TextField("Phone number", text: $model.signUpData.phoneNumber)
      }
    }
    .navigationTitle("Personal info")
    .toolbar {
      ToolbarItem {
        if !isEditingFromSummary {
          NavigationLink(
            "Next",
            item: SignUpFeature.Path.topics(TopicsFeature(signUpData: model.signUpData))
          )
        } else {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
  }
}

#Preview("Personal info") {
  NavigationStack {
    PersonalInfoStep(model: PersonalInfoFeature(signUpData: SignUpData()).withAnchor())
  }
}

@Model
struct TopicsFeature: Sendable {
  var alert: AlertState<Never>?
  var signUpData: SignUpData

  enum Event {
    case onDone
    case onNext
  }

  func doneButtonTapped() {
    if signUpData.topics.isEmpty {
      alert = AlertState {
        TextState("Please choose at least one topic.")
      }
    } else {
      node.send(.onDone)
    }
  }

  func nextButtonTapped() {
    if signUpData.topics.isEmpty {
      alert = AlertState {
        TextState("Please choose at least one topic.")
      }
    } else {
      node.send(.onNext)
    }
  }
}

struct TopicsStep: View {
  @ObservedModel var model: TopicsFeature
  var isEditingFromSummary = false

  var body: some View {
    Form {
      Section {
        Text("Please choose all the topics you are interested in.")
      }
      Section {
        ForEach(SignUpData.Topic.allCases) { topic in
          Toggle(
            topic.rawValue,
            isOn: $model.signUpData.topics[contains: topic]
          )
        }
      }
    }
    .alert($model.alert)
    .navigationTitle("Topics")
    .toolbar {
      ToolbarItem {
        if !isEditingFromSummary {
          Button("Next") {
            model.nextButtonTapped()
          }
        } else {
          Button("Done") {
            model.doneButtonTapped()
          }
        }
      }
    }
    .interactiveDismissDisabled(model.signUpData.topics.isEmpty)
  }
}

extension Set {
  fileprivate subscript(contains element: Element) -> Bool {
    get { self.contains(element) }
    set {
      if newValue {
        self.insert(element)
      } else {
        self.remove(element)
      }
    }
  }
}

#Preview("Topics") {
  NavigationStack {
    TopicsStep(model: TopicsFeature(signUpData: SignUpData()).withAnchor())
  }
}

@Model
struct SummaryFeature: Sendable {
  @ModelContainer @CasePathable
  @dynamicMemberLookup
  enum Destination {
    case personalInfo(PersonalInfoFeature)
    case topics(TopicsFeature)
  }

  var destination: Destination?
  var signUpData: SignUpData

  func editPersonalInfoButtonTapped() {
    destination = .personalInfo(PersonalInfoFeature(signUpData: signUpData))
  }

  func editFavoriteTopicsButtonTapped() {
    destination = .topics(TopicsFeature(signUpData: signUpData))
  }

  func submitButtonTapped() {

  }

  func onActivate() {
    node.forEach(node.event(of: .onDone, fromType: TopicsFeature.self)) { _ in
      destination = nil
    }
  }
}

struct SummaryStep: View {
  @ObservedModel var model: SummaryFeature

  var body: some View {
    Form {
      Section {
        Text(model.signUpData.email)
        Text(String(repeating: "•", count: model.signUpData.password.count))
      } header: {
        Text("Required info")
      }

      Section {
        Text(model.signUpData.firstName)
        Text(model.signUpData.lastName)
        Text(model.signUpData.phoneNumber)
      } header: {
        HStack {
          Text("Personal info")
          Spacer()
          Button("Edit") {
            model.editPersonalInfoButtonTapped()
          }
          .font(.caption)
        }
      }

      Section {
        ForEach(model.signUpData.topics.sorted(by: { $0.rawValue < $1.rawValue })) { topic in
          Text(topic.rawValue)
        }
      } header: {
        HStack {
          Text("Favorite topics")
          Spacer()
          Button("Edit") {
            model.editFavoriteTopicsButtonTapped()
          }
          .font(.caption)
        }
      }

      Section {
        Button {
          model.submitButtonTapped()
        } label: {
          Text("Submit")
        }
      }
    }
    .navigationTitle("Summary")
    .sheet(item: $model.destination.personalInfo) { model in
      NavigationStack {
        PersonalInfoStep(model: model, isEditingFromSummary: true)
      }
      .presentationDetents([.medium])
    }
    .sheet(item: $model.destination.topics) { model in
      NavigationStack {
        TopicsStep(model: model, isEditingFromSummary: true)
      }
      .presentationDetents([.medium])
    }
  }
}

#Preview("Summary") {
  NavigationStack {
    SummaryStep(model: SummaryFeature(
      signUpData: SignUpData(
        email: "blob@pointfree.co",
        firstName: "Blob",
        lastName: "McBlob",
        password: "blob is awesome",
        passwordConfirmation: "blob is awesome",
        phoneNumber: "212-555-1234",
        topics: [
          .composableArchitecture,
          .concurrency,
          .modernSwiftUI
        ]
      )
    ).withAnchor())
  }
}
