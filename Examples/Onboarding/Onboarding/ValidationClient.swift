import Foundation
import SwiftModel
import Dependencies

// MARK: - SignUpClient

/// A dependency that handles account validation and creation.
///
/// The live implementation makes real (or simulated) network requests;
/// tests and previews swap in a controlled fake.
struct SignUpClient: Sendable {
    /// Returns an error message if the email format is invalid, or nil if valid.
    var validateEmail: @Sendable (String) -> String?

    /// Returns an error message if the username is unavailable, or nil if it's free.
    /// This is an async operation — in production it would call a server.
    var checkUsernameAvailability: @Sendable (String) async -> String?

    /// Creates the account. Throws on network failure.
    var createAccount: @Sendable (_ email: String, _ password: String, _ username: String) async throws -> Void
}

extension SignUpClient: DependencyKey {
    static let liveValue = SignUpClient(
        validateEmail: { email in
            let trimmed = email.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return "Email is required." }
            let parts = trimmed.split(separator: "@")
            guard parts.count == 2, parts[1].contains(".") else {
                return "Enter a valid email address."
            }
            return nil
        },
        checkUsernameAvailability: { username in
            // Simulate a server-side uniqueness check
            try? await Task.sleep(for: .milliseconds(500))
            let taken = ["admin", "swift", "apple", "test", "swiftmodel"]
            return taken.contains(username.lowercased())
                ? "Username '\(username)' is already taken."
                : nil
        },
        createAccount: { _, _, _ in
            // Simulate account creation latency
            try? await Task.sleep(for: .seconds(1))
        }
    )

    static let previewValue = SignUpClient(
        validateEmail: { _ in nil },
        checkUsernameAvailability: { _ in nil },
        createAccount: { _, _, _ in }
    )
}

extension DependencyValues {
    var signUpClient: SignUpClient {
        get { self[SignUpClient.self] }
        set { self[SignUpClient.self] = newValue }
    }
}
