import SwiftModel
import SwiftUI
import SwiftUINavigation

// MARK: - Context Keys

extension ContextKeys {
    /// Set by SummaryFeature on its own node when it pushes an edit destination.
    /// Because propagation is `.environment`, all descendants of SummaryFeature —
    /// including PersonalInfoFeature and TopicsFeature inside `destination` —
    /// inherit the value without any constructor parameter being passed.
    /// Steps in the normal forward flow (children of SignUpFeature, not SummaryFeature)
    /// read the default `false`.
    var isEditing: ContextStorage<Bool> {
        .init(defaultValue: false, propagation: .environment)
    }
}

@Model
struct SignUpData {
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

// MARK: - SignUpFeature

@Model
struct SignUpFeature {
  // @ModelContainer synthesises Hashable (using model .id for associated values),
  // which is required by NavigationStack(path:).
  @ModelContainer @CasePathable
  @dynamicMemberLookup
  enum Path: Hashable {
    case basics(BasicsFeature)
    case personalInfo(PersonalInfoFeature)
    case summary(SummaryFeature)
    case topics(TopicsFeature)
  }

  var path: [Path] = []
  var signUpData: SignUpData

  func onActivate() {
    node.forEach(node.event(of: .onNext, fromType: TopicsFeature.self)) { _ in
      path.append(.summary(SummaryFeature(signUpData: signUpData)))
    }
    node.forEach(node.event(of: .onSubmit, fromType: SummaryFeature.self)) { _ in
      path = []
    }
  }
}

// MARK: - SignUpFlow view

struct SignUpFlow: View {
  @ObservedModel var model: SignUpFeature

  var body: some View {
    NavigationStack(path: $model.path) {
      Form {
        Section {
          Text("Welcome! Please sign up.")
          NavigationLink(
            "Sign up",
            value: SignUpFeature.Path.basics(BasicsFeature(signUpData: model.signUpData))
          )
        }
      }
      .navigationTitle("Sign up")
      .navigationDestination(for: SignUpFeature.Path.self) { path in
        switch path {
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
struct BasicsFeature {
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
          value: SignUpFeature.Path.personalInfo(PersonalInfoFeature(signUpData: model.signUpData))
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
struct PersonalInfoFeature {
  var signUpData: SignUpData

  /// True when this instance was pushed from the summary screen for editing.
  /// Read from context — set by SummaryFeature without threading it through
  /// the constructor.
  var isEditing: Bool { node.context.isEditing }
}

struct PersonalInfoStep: View {
  @ObservedModel var model: PersonalInfoFeature
  @Environment(\.dismiss) var dismiss

  var body: some View {
    Form {
      Section {
        TextField("First name", text: $model.signUpData.firstName)
        TextField("Last name", text: $model.signUpData.lastName)
        TextField("Phone number", text: $model.signUpData.phoneNumber)
      }
    }
    .navigationTitle(model.isEditing ? "Edit personal info" : "Personal info")
    .toolbar {
      ToolbarItem {
        if !model.isEditing {
          NavigationLink(
            "Next",
            value: SignUpFeature.Path.topics(TopicsFeature(signUpData: model.signUpData))
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
struct TopicsFeature {
  var alert: AlertState<Never>?
  var signUpData: SignUpData

  /// True when this instance was pushed from the summary screen for editing.
  var isEditing: Bool { node.context.isEditing }

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
    .navigationTitle(model.isEditing ? "Edit topics" : "Topics")
    .toolbar {
      ToolbarItem {
        if !model.isEditing {
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
struct SummaryFeature {
  @ModelContainer @CasePathable
  @dynamicMemberLookup
  enum Destination {
    case personalInfo(PersonalInfoFeature)
    case topics(TopicsFeature)
  }

  enum Event { case onSubmit }

  var destination: Destination?
  var signUpData: SignUpData

  func editPersonalInfoButtonTapped() {
    // Setting isEditing on this node propagates via .environment to all
    // descendants, including the PersonalInfoFeature inside `destination`.
    node.context.isEditing = true
    destination = .personalInfo(PersonalInfoFeature(signUpData: signUpData))
  }

  func editFavoriteTopicsButtonTapped() {
    node.context.isEditing = true
    destination = .topics(TopicsFeature(signUpData: signUpData))
  }

  func submitButtonTapped() {
    node.send(.onSubmit)
  }

  func onActivate() {
    node.forEach(node.event(of: .onDone, fromType: TopicsFeature.self)) { _ in
      destination = nil
      node.context.isEditing = false
    }
    // Reset isEditing whenever the sheet is dismissed (covers both Done button
    // and interactive dismissal via swipe/tap-outside).
    node.forEach(Observed(initial: false) { destination == nil }) { isNil in
      if isNil { node.context.isEditing = false }
    }
  }
}

struct SummaryStep: View {
  @ObservedModel var model: SummaryFeature

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        // Required info card
        SummaryCard(title: "Required info") {
          SummaryRow(label: "Email", value: model.signUpData.email)
          Divider()
          SummaryRow(label: "Password", value: String(repeating: "•", count: model.signUpData.password.count))
        }

        // Personal info card
        SummaryCard(title: "Personal info", editAction: model.editPersonalInfoButtonTapped) {
          SummaryRow(label: "First name", value: model.signUpData.firstName)
          Divider()
          SummaryRow(label: "Last name", value: model.signUpData.lastName)
          Divider()
          SummaryRow(label: "Phone", value: model.signUpData.phoneNumber)
        }

        // Topics card
        SummaryCard(title: "Favorite topics", editAction: model.editFavoriteTopicsButtonTapped) {
          let sorted = model.signUpData.topics.sorted(by: { $0.rawValue < $1.rawValue })
          if sorted.isEmpty {
            Text("None selected").foregroundStyle(.secondary)
          } else {
            ForEach(Array(sorted.enumerated()), id: \.element) { index, topic in
              if index > 0 { Divider() }
              Text(topic.rawValue)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }

        Button(action: model.submitButtonTapped) {
          Text("Submit")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.top, 8)
      }
      .padding()
    }
    .navigationTitle("Summary")
    .sheet(item: $model.destination.personalInfo) { model in
      NavigationStack {
        PersonalInfoStep(model: model)
      }
      .presentationDetents([.medium])
    }
    .sheet(item: $model.destination.topics) { model in
      NavigationStack {
        TopicsStep(model: model)
      }
      .presentationDetents([.medium])
    }
  }
}

private struct SummaryCard<Content: View>: View {
  let title: String
  var editAction: (() -> Void)? = nil
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(title)
          .font(.headline)
        Spacer()
        if let editAction {
          Button("Edit", action: editAction)
            .buttonStyle(.borderless)
            .font(.subheadline)
        }
      }
      content
    }
    .padding()
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct SummaryRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value).multilineTextAlignment(.trailing)
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
