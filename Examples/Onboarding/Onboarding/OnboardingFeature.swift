import Foundation
import SwiftUI
import SwiftModel
import Dependencies

// MARK: - Local key (node-private transient state)

extension LocalKeys {
    /// Whether the user has already tapped "Continue" at least once on this step.
    /// Transient UI state — lives in node.local rather than stored model properties.
    var hasAttemptedSubmit: LocalStorage<Bool> { .init(defaultValue: false) }
}

// MARK: - CredentialsStepModel

@Model struct CredentialsStepModel: Sendable {

    enum Event: Sendable {
        case continued(email: String, password: String)
    }

    var email: String = ""
    var password: String = ""
    var confirmPassword: String = ""
    var emailError: String? = nil
    var passwordError: String? = nil

    @ModelDependency var signUpClient: SignUpClient

    func onActivate() {
        // Live re-validation on each field change, but only after the user has
        // attempted to continue (tracked via node.local so it's transient and
        // not part of the model's stored data).
        node.forEach(Observed { email }) { _ in
            guard node.local.hasAttemptedSubmit else { return }
            emailError = signUpClient.validateEmail(email)
        }
        node.forEach(Observed { password }) { _ in
            guard node.local.hasAttemptedSubmit else { return }
            passwordError = validatePasswordFields()
        }
        node.forEach(Observed { confirmPassword }) { _ in
            guard node.local.hasAttemptedSubmit else { return }
            passwordError = validatePasswordFields()
        }
    }

    func continueTapped() {
        node.local.hasAttemptedSubmit = true
        emailError = signUpClient.validateEmail(email)
        passwordError = validatePasswordFields()
        guard emailError == nil, passwordError == nil else { return }
        node.send(.continued(email: email, password: password))
    }

    private func validatePasswordFields() -> String? {
        if password.isEmpty { return "Password is required." }
        if password.count < 8 { return "Password must be at least 8 characters." }
        if password != confirmPassword { return "Passwords do not match." }
        return nil
    }
}

// MARK: - ProfileStepModel

@Model struct ProfileStepModel: Sendable {

    enum Event: Sendable {
        case continued(username: String, bio: String)
    }

    var username: String = ""
    var bio: String = ""
    var isCheckingAvailability: Bool = false
    var availabilityError: String? = nil

    @ModelDependency var signUpClient: SignUpClient

    func onActivate() {
        // Async username availability check on each keystroke.
        // cancelPrevious: true cancels any in-flight check when the user keeps typing,
        // so only the check for the most recently typed username completes.
        node.forEach(Observed { username }, cancelPrevious: true) { name in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else {
                isCheckingAvailability = false
                availabilityError = trimmed.isEmpty ? nil : "Username must be at least 3 characters."
                return
            }
            isCheckingAvailability = true
            defer { isCheckingAvailability = false }
            availabilityError = await signUpClient.checkUsernameAvailability(trimmed)
        }
    }

    func continueTapped() {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else {
            availabilityError = "Username must be at least 3 characters."
            return
        }
        // Don't advance while an availability check is pending or has found an error
        guard availabilityError == nil, !isCheckingAvailability else { return }
        node.send(.continued(username: trimmed, bio: bio))
    }
}

// MARK: - ReviewStepModel

@Model struct ReviewStepModel: Sendable {

    enum Event: Sendable {
        case accountCreated
    }

    let email: String
    let username: String
    let bio: String
    let password: String

    var isSubmitting: Bool = false
    var submitError: String? = nil

    @ModelDependency var signUpClient: SignUpClient

    func submitTapped() {
        node.task {
            isSubmitting = true
            submitError = nil
            defer { isSubmitting = false }
            try await signUpClient.createAccount(email, password, username)
            node.send(.accountCreated)
        } catch: { error in
            submitError = error.localizedDescription
        }
    }
}

// MARK: - SignUpModel

@Model struct SignUpModel: Sendable {

    // MARK: Always-live step models
    //
    // Both root models live here rather than inside the `path` array.
    // This mirrors how Standups stores StandupDetail in `standupsList` rather than
    // in the navigation path: the path is navigation state, not data storage.
    //
    // Consequence: entering credentials or a username, navigating away, and coming
    // back later never loses the typed data — the models are never deactivated until
    // the whole sign-up flow is dismissed.

    /// Root step. Always visible when path is empty.
    var credentialsModel = CredentialsStepModel()

    /// Profile step. Lives here so username/bio survive forward-and-back trips.
    var profileModel = ProfileStepModel()

    // MARK: Navigation path

    /// Empty = on credentials. `.profile` = on profile. `.profile + .review(m)` = on review.
    /// The path carries only navigation state; the live model data lives in the properties above.
    var path: [Step] = []

    var email: String = ""
    var password: String = ""
    var username: String = ""
    var isComplete: Bool = false

    @ModelContainer
    enum Step: Hashable, Identifiable, Sendable {
        /// Marker only — the actual model is `SignUpModel.profileModel`.
        case profile
        /// Review carries its model in the path because it is always recreated fresh
        /// from the captured credentials + profile data when the step is pushed.
        case review(ReviewStepModel)
    }

    // MARK: Activation

    func onActivate() {
        // Credentials → profile: capture email + password, push profile marker
        node.forEach(node.event(fromType: CredentialsStepModel.self)) { event, _ in
            if case .continued(let e, let p) = event {
                email = e
                password = p
                if path.last?.isProfile != true {
                    path.append(.profile)
                }
            }
        }

        // Profile → review: capture username + bio, push review step
        node.forEach(node.event(fromType: ProfileStepModel.self)) { event, _ in
            if case .continued(let u, let b) = event {
                username = u
                path.append(.review(ReviewStepModel(email: email, username: u, bio: b, password: password)))
            }
        }

        // Review → complete: mark flow as done
        node.forEach(node.event(fromType: ReviewStepModel.self)) { event, _ in
            if case .accountCreated = event {
                isComplete = true
            }
        }
    }

    // MARK: Actions

    func startOver() {
        email = ""
        password = ""
        username = ""
        isComplete = false
        path = []
        credentialsModel = CredentialsStepModel()
        profileModel = ProfileStepModel()
    }

    // MARK: Deep links

    /// Handles `signup://step/profile` and `signup://step/review`.
    func handleURL(_ url: URL) {
        guard url.scheme == "signup", url.host == "step" else { return }
        switch url.lastPathComponent {
        case "profile":
            path = [.profile]
        case "review":
            path = [
                .profile,
                .review(ReviewStepModel(email: email, username: username, bio: "", password: password))
            ]
        default:
            path = []
        }
    }
}

// MARK: - Helpers

extension SignUpModel.Step {
    var isProfile: Bool { if case .profile = self { true } else { false } }
    var isReview: Bool { if case .review = self { true } else { false } }
    var reviewModel: ReviewStepModel? { if case .review(let m) = self { m } else { nil } }
}

// MARK: - Views

struct SignUpView: View {
    @ObservedModel var model: SignUpModel

    var body: some View {
        if model.isComplete {
            CompletionView(username: model.username, onStartOver: model.startOver)
        } else {
            NavigationStack(path: $model.path) {
                CredentialsStepView(model: model.credentialsModel)
                    .navigationDestination(for: SignUpModel.Step.self) { step in
                        switch step {
                        case .profile:
                            // The profile model lives in SignUpModel, not in the path.
                            // This preserves typed data when the user navigates away and back.
                            ProfileStepView(model: model.profileModel)
                        case .review(let m):
                            ReviewStepView(model: m)
                        }
                    }
            }
            .onOpenURL { model.handleURL($0) }
        }
    }
}

// MARK: CredentialsStepView

struct CredentialsStepView: View {
    @ObservedModel var model: CredentialsStepModel

    var body: some View {
        Form {
            Section {
                TextField("Email address", text: $model.email)
                    .autocorrectionDisabled()
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
#endif
                if let error = model.emailError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("Step 1 of 3 — Account credentials")
            }

            Section {
                SecureField("Password", text: $model.password)
                SecureField("Confirm password", text: $model.confirmPassword)
                if let error = model.passwordError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } footer: {
                Text("Password must be at least 8 characters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Continue") {
                    model.continueTapped()
                }
            }
        }
        .navigationTitle("Create Account")
    }
}

// MARK: ProfileStepView

struct ProfileStepView: View {
    @ObservedModel var model: ProfileStepModel

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Username", text: $model.username)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                    if model.isCheckingAvailability {
                        ProgressView()
                    }
                }
                if let error = model.availabilityError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("Step 2 of 3 — Your profile")
            }

            Section {
                TextField("Bio (optional)", text: $model.bio, axis: .vertical)
                    .lineLimit(3...)
            }

            Section {
                Button("Continue") {
                    model.continueTapped()
                }
                .disabled(model.isCheckingAvailability || model.availabilityError != nil)
            }
        }
        .navigationTitle("Your Profile")
        // NavigationStack provides the Back button automatically
    }
}

// MARK: ReviewStepView

struct ReviewStepView: View {
    @ObservedModel var model: ReviewStepModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Email", value: model.email)
                LabeledContent("Username", value: "@\(model.username)")
                LabeledContent("Password", value: "••••••••")
                if !model.bio.isEmpty {
                    LabeledContent("Bio") {
                        Text(model.bio)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Step 3 of 3 — Review and confirm")
            }

            if let error = model.submitError {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if model.isSubmitting {
                    HStack {
                        Spacer()
                        ProgressView("Creating account…")
                        Spacer()
                    }
                } else {
                    Button("Create Account") {
                        model.submitTapped()
                    }
                }
            }
        }
        .navigationTitle("Review")
        // NavigationStack provides the Back button automatically
    }
}

// MARK: CompletionView

struct CompletionView: View {
    let username: String
    let onStartOver: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Welcome, @\(username)!", systemImage: "person.circle.fill")
        } description: {
            Text("Your account has been created successfully.")
        } actions: {
            Button("Sign up with a different account", action: onStartOver)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Previews

#Preview("Credentials step") {
    SignUpView(model: SignUpModel()
        .withAnchor())
}

#Preview("Profile step") {
    NavigationStack {
        ProfileStepView(model: ProfileStepModel()
            .withAnchor())
    }
}

#Preview("Review step") {
    NavigationStack {
        ReviewStepView(model: ReviewStepModel(
            email: "user@example.com",
            username: "swiftuser",
            bio: "Swift developer",
            password: "secret"
        ).withAnchor())
    }
}
