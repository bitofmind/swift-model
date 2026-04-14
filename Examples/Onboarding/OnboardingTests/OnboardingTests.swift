import Testing
import Foundation
import SwiftModel
import Dependencies
@testable import Onboarding

// Path helper — avoid if-case inside await expect closures
extension SignUpModel.Step {
    var isProfile: Bool { if case .profile = self { true } else { false } }
    var isReview: Bool { if case .review = self { true } else { false } }
    // Note: profileModel lives on SignUpModel.profileModel, not in the path element.
    var reviewModel: ReviewStepModel? { if case .review(let m) = self { m } else { nil } }
}

// MARK: - SignUpModel tests
//
// These tests focus on navigation flow: state changes (email, path, isComplete) are inputs or
// incidental to the navigation logic, not the focus. Events are consumed internally by SignUpModel's
// own onActivate handlers (not by the test). Local state (hasAttemptedSubmit) is internal
// validation bookkeeping, not the subject of these navigation tests.

@Suite(.modelTesting(.removing([.state, .events, .local])) { $0.signUpClient = .previewValue })
struct SignUpTests {

    func makeModel(
        validateEmail: @escaping @Sendable (String) -> String? = { _ in nil },
        checkAvailability: @escaping @Sendable (String) async -> String? = { _ in nil },
        createAccount: @escaping @Sendable (String, String, String) async throws -> Void = { _, _, _ in }
    ) -> SignUpModel {
        SignUpModel().withAnchor {
            $0.signUpClient = SignUpClient(
                validateEmail: validateEmail,
                checkUsernameAvailability: checkAvailability,
                createAccount: createAccount
            )
        }
    }

    // MARK: Initial state

    @Test func initialState() async {
        let model = makeModel()
        await settle {
            model.path.isEmpty
            !model.isComplete
        }
    }

    // MARK: Credentials → Profile

    /// Valid credentials: CredentialsStepModel sends .continued(email:password:) via
    /// node.send(). SignUpModel receives it via node.event(fromType:) and pushes .profile
    /// onto the NavigationStack path.
    @Test func validCredentialsAdvancesToProfile() async {
        let model = makeModel()

        model.credentialsModel.email = "user@example.com"
        model.credentialsModel.password = "password123"
        model.credentialsModel.confirmPassword = "password123"
        model.credentialsModel.continueTapped()

        await expect {
            model.path.last?.isProfile == true
            model.email == "user@example.com"
        }
    }

    // MARK: Profile → Review

    @Test func validProfileAdvancesToReview() async {
        let model = makeModel()
        model.credentialsModel.email = "user@example.com"
        model.credentialsModel.password = "password123"
        model.credentialsModel.confirmPassword = "password123"
        model.credentialsModel.continueTapped()
        await expect(model.path.last?.isProfile == true)

        // profileModel lives on SignUpModel, not in the path — data is preserved on back navigation.
        model.profileModel.username = "swiftuser"
        model.profileModel.continueTapped()

        await expect {
            model.path.last?.isReview == true
            model.username == "swiftuser"
        }
    }

    // MARK: Full sign-up flow

    @Test func fullSignUpFlow() async throws {
        let model = makeModel()

        // Step 1: Credentials
        model.credentialsModel.email = "user@example.com"
        model.credentialsModel.password = "securepass"
        model.credentialsModel.confirmPassword = "securepass"
        model.credentialsModel.continueTapped()
        await expect(model.path.last?.isProfile == true)

        // Step 2: Profile — model lives on SignUpModel, not in the path
        model.profileModel.username = "newuser"
        model.profileModel.bio = "Hello, SwiftModel!"
        model.profileModel.continueTapped()
        await expect(model.path.last?.isReview == true)

        // Step 3: Review + Submit
        let reviewModel = try await require(model.path.last?.reviewModel)
        await expect {
            reviewModel.email == "user@example.com"
            reviewModel.username == "newuser"
        }
        reviewModel.submitTapped()
        await expect(model.isComplete)
    }

    // MARK: Back navigation — data preserved

    /// The key advantage of NavigationStack path over an enum step:
    /// popping (back) does not destroy the credentials model.
    /// Data entered in step 1 survives a round-trip to step 2 and back.
    @Test func backFromProfilePreservesCredentials() async {
        let model = makeModel()
        model.credentialsModel.email = "user@example.com"
        model.credentialsModel.password = "password123"
        model.credentialsModel.confirmPassword = "password123"
        model.credentialsModel.continueTapped()
        await expect(model.path.last?.isProfile == true)

        // Simulate the NavigationStack back button popping the path
        model.path.removeLast()
        await expect {
            model.path.isEmpty
            // Credentials are still intact — no re-entry needed
            model.credentialsModel.email == "user@example.com"
        }
    }

    /// The key regression test: going back from profile to credentials and then forward again
    /// must NOT clear the username that was already typed.
    @Test func backAndForwardPreservesProfileData() async {
        let model = makeModel()

        // Advance to credentials → profile
        model.credentialsModel.email = "user@example.com"
        model.credentialsModel.password = "password123"
        model.credentialsModel.confirmPassword = "password123"
        model.credentialsModel.continueTapped()
        await expect(model.path.last?.isProfile == true)

        // Type a username on the profile step
        model.profileModel.username = "swiftuser"

        // Go back to credentials
        model.path.removeLast()
        await expect(model.path.isEmpty)

        // Go forward again — profileModel is still alive, username is intact
        model.credentialsModel.continueTapped()
        await expect {
            model.path.last?.isProfile == true
            // profileModel is still alive, username is intact
            model.profileModel.username == "swiftuser"
        }
    }

    @Test func backFromReviewReturnsToProfile() async {
        let model = makeModel()
        model.credentialsModel.email = "user@example.com"
        model.credentialsModel.password = "password123"
        model.credentialsModel.confirmPassword = "password123"
        model.credentialsModel.continueTapped()
        await expect(model.path.last?.isProfile == true)

        model.profileModel.username = "user123"
        model.profileModel.continueTapped()
        await expect(model.path.last?.isReview == true)

        // Simulate back
        model.path.removeLast()
        await expect(model.path.last?.isProfile == true)
    }

    // MARK: Deep link

    @Test func deepLinkJumpsToProfileStep() async {
        let model = makeModel()
        model.handleURL(URL(string: "signup://step/profile")!)
        await expect(model.path.last?.isProfile == true)
    }

    @Test func deepLinkPreservesExistingEmail() async {
        let model = makeModel()
        // Simulate the user already having completed credentials
        model.email = "pre@example.com"

        model.handleURL(URL(string: "signup://step/profile")!)
        await expect {
            model.path.last?.isProfile == true
            // Email set before the deep link is still there
            model.email == "pre@example.com"
        }
    }

    // MARK: Start over

    @Test func startOverResetsFlow() async {
        let model = makeModel()
        model.credentialsModel.email = "user@example.com"
        model.credentialsModel.password = "password123"
        model.credentialsModel.confirmPassword = "password123"
        model.credentialsModel.continueTapped()
        await expect(model.path.last?.isProfile == true)

        model.startOver()
        await expect {
            model.path.isEmpty
            model.credentialsModel.email == ""
            model.email == ""
        }
    }
}

// MARK: - CredentialsStepModel tests
//
// Validation behaviour: state changes on email/password input fields are input noise —
// the interesting assertions are the error properties and probe calls.
// Events are sent by continueTapped() and consumed by probes in the tests below, so
// removing .events avoids duplicating the assertion via didSend().
// Tests install node.forEach(event(fromType:)) listeners — these tasks run for the full
// test lifetime and are test infrastructure, not effects under test.
// Local state (hasAttemptedSubmit) is internal to the model's validation bookkeeping.

@Suite(.modelTesting(.removing([.state, .events, .local, .tasks])))
struct CredentialsStepModelTests {

    func makeModel(
        validateEmail: @escaping @Sendable (String) -> String? = { _ in nil }
    ) -> CredentialsStepModel {
        CredentialsStepModel().withAnchor {
            $0.signUpClient = SignUpClient(
                validateEmail: validateEmail,
                checkUsernameAvailability: { _ in nil },
                createAccount: { _, _, _ in }
            )
        }
    }

    // MARK: Valid credentials send event

    /// CredentialsStepModel sends .continued(email:password:) via node.send() when credentials are valid.
    @Test func sendsEventOnValidCredentials() async {
        let probe = TestProbe("continued event")
        let model = makeModel()

        model.node.forEach(model.node.event(fromType: CredentialsStepModel.self)) { event, _ in
            if case .continued(let email, _) = event {
                probe.call(email)
            }
        }

        model.email = "user@example.com"
        model.password = "password123"
        model.confirmPassword = "password123"
        model.continueTapped()

        await expect { probe.wasCalled(with: "user@example.com") }
    }

    // MARK: Invalid email blocks continuation

    @Test func invalidEmailBlocksContinuation() async {
        let probe = TestProbe("continued event")
        let model = makeModel(validateEmail: { e in
            e.contains("@") ? nil : "Enter a valid email address."
        })

        model.node.forEach(model.node.event(fromType: CredentialsStepModel.self)) { _, _ in
            probe.call("event")
        }

        model.email = "notanemail"
        model.password = "password123"
        model.confirmPassword = "password123"
        model.continueTapped()

        await expect {
            model.emailError != nil
            !probe.wasCalled(with: "event")
        }
    }

    // MARK: Password mismatch blocks continuation

    @Test func passwordMismatchBlocksContinuation() async {
        let probe = TestProbe("continued event")
        let model = makeModel()

        model.node.forEach(model.node.event(fromType: CredentialsStepModel.self)) { _, _ in
            probe.call("event")
        }

        model.email = "user@example.com"
        model.password = "password123"
        model.confirmPassword = "different456"
        model.continueTapped()

        await expect {
            model.passwordError != nil
            !probe.wasCalled(with: "event")
        }
    }

    // MARK: Live validation after first submit attempt

    /// After continueTapped() sets node.local.hasAttemptedSubmit = true,
    /// each subsequent field change triggers automatic re-validation.
    @Test func liveValidationAfterFirstSubmit() async {
        let model = makeModel(validateEmail: { e in
            e.contains("@") ? nil : "Enter a valid email address."
        })

        // First submit with invalid email — error appears
        model.email = "notanemail"
        model.password = "password123"
        model.confirmPassword = "password123"
        model.continueTapped()
        await expect(model.emailError != nil)

        // Fix the email — error clears automatically (live re-validation)
        model.email = "valid@example.com"
        await expect(model.emailError == nil)
    }
}

// MARK: - ProfileStepModel tests
//
// Availability-check behaviour: username field changes drive async network calls;
// state changes on username are input and isCheckingAvailability is a transient loading flag.
// Events are consumed via probes, so .events is also removed to avoid duplication.
// sendsEventOnValidUsername installs a node.forEach(event(fromType:)) listener — a
// long-lived test-infrastructure task that runs for the full test duration.

@Suite(.modelTesting(.removing([.state, .events, .local, .tasks])))
struct ProfileStepModelTests {

    // MARK: Username availability check

    /// cancelPrevious: true means the most recent check wins. Taken usernames show an error.
    @Test func usernameAvailabilityCheck() async {
        let model = ProfileStepModel().withAnchor {
            $0.signUpClient = SignUpClient(
                validateEmail: { _ in nil },
                checkUsernameAvailability: { u in
                    u == "taken" ? "Username 'taken' is already taken." : nil
                },
                createAccount: { _, _, _ in }
            )
        }

        model.username = "taken"
        await expect(model.availabilityError != nil)

        model.username = "available"
        await expect(model.availabilityError == nil)
    }

    // MARK: Short username shows inline error without hitting the network

    @Test func shortUsernameShowsInlineError() async {
        let model = ProfileStepModel().withAnchor {
            $0.signUpClient = .previewValue
        }

        model.username = "ab"
        await expect(model.availabilityError != nil)
        model.username = ""
        await expect(model.availabilityError == nil)
    }

    // MARK: Sends event when username is valid and available

    @Test func sendsEventOnValidUsername() async {
        let probe = TestProbe("continued event")
        let model = ProfileStepModel().withAnchor {
            $0.signUpClient = .previewValue
        }

        model.node.forEach(model.node.event(fromType: ProfileStepModel.self)) { event, _ in
            if case .continued(let username, _) = event {
                probe.call(username)
            }
        }

        model.username = "swiftdev"
        model.continueTapped()

        await expect { probe.wasCalled(with: "swiftdev") }
    }
}
