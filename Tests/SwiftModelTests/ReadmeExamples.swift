// ReadmeExamples.swift
//
// Compilation check for README.md and forum post code snippets.
// These types are not meant to be executed — they exist only to catch
// compile errors in documentation examples as the library evolves.
//
// When you change a README example, update this file to match.
// Type names are prefixed with "Readme" to avoid conflicts with other test files.

import Dependencies
import Observation
import SwiftModel

// MARK: - Shared stub types

private struct Repo: Sendable, Identifiable, Equatable {
    let id: Int
    let name: String
    static let mocks: [Repo] = [Repo(id: 1, name: "swift")]
}

private struct GitHubClient: Sendable {
    var search: @Sendable (_ query: String) async throws -> [Repo]
    static let live = GitHubClient(search: { _ in [] })
}

extension GitHubClient: DependencyKey {
    static let liveValue = GitHubClient.live
}

extension DependencyValues {
    fileprivate var gitHubClient: GitHubClient {
        get { self[GitHubClient.self] }
        set { self[GitHubClient.self] = newValue }
    }
}

// MARK: - README hero / "Define a model": @Model struct SearchModel

// Corresponds to the opening snippet and "Define a model" section of README.md.

@Model private struct ReadmeSearchModel {
    var query   = ""
    var results: [Repo] = []

    func onActivate() {
        // Cancel-in-flight: each new query cancels the previous search.
        // No stored Task. No [weak self]. Cancelled automatically when removed.
        node.forEach(Observed { query }, cancelPrevious: true) { q in
            results = (try? await node.gitHubClient.search(q)) ?? []
        }
    }
}

// MARK: - README "Why @Model?": @Observable class SearchModel

// Corresponds to the @Observable comparison snippet in the "Why @Model?" section.
// Note: under Swift 6 with project-level main actor isolation (the default in new projects),
// deinit can't access searchTask without nonisolated(unsafe), and async closures
// need Task { @MainActor [weak self] in ... }. This version compiles as a library target.

// @unchecked Sendable suppresses the Swift 6 data race warning from Task { [weak self] in ... }
// so this file compiles in the library target. In an app target with main actor isolation
// the class would be @MainActor by default, requiring nonisolated(unsafe) on searchTask for deinit.
@Observable private final class ReadmeObservableSearchModel: @unchecked Sendable {
    var query = "" { didSet { scheduleSearch() } }
    var results: [Repo] = []
    private var searchTask: Task<Void, Never>?

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in   // forget this → retain cycle
            guard !Task.isCancelled, let self else { return }
            self.results = (try? await GitHubClient.live.search(self.query)) ?? []
        }
    }
    deinit { searchTask?.cancel() }          // forget this → tasks outlive the view
}
