import Foundation
import Dependencies

// MARK: - Domain types

nonisolated struct Repo: Sendable, Identifiable, Equatable {
    let id: Int
    let name: String
    let fullName: String
    let description: String?
    let starCount: Int
    let language: String?
    let owner: String
    let htmlURL: URL
}

// MARK: - Dependency

/// A client for searching GitHub repositories.
nonisolated struct GitHubClient: Sendable {
    var search: @Sendable (_ query: String) async throws -> [Repo]
}

// MARK: - Errors

enum GitHubError: Error, LocalizedError {
    case rateLimited
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "GitHub API rate limit reached. Wait a minute and try again."
        case .httpError(let code):
            return "GitHub returned an unexpected error (HTTP \(code))."
        }
    }
}

nonisolated extension GitHubClient: DependencyKey {
    static let liveValue = GitHubClient(
        search: { query in
            guard !query.isEmpty else { return [] }
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            let url = URL(string: "https://api.github.com/search/repositories?q=\(encoded)&per_page=20&sort=stars")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw http.statusCode == 403 ? GitHubError.rateLimited : GitHubError.httpError(http.statusCode)
            }
            return try JSONDecoder().decode(SearchResponse.self, from: data).items.map(Repo.init)
        }
    )

    static let previewValue = GitHubClient(
        search: { query in
            try await Task.sleep(for: .milliseconds(150))
            guard !query.isEmpty else { return Repo.mocks }
            return Repo.mocks.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                || ($0.description?.localizedCaseInsensitiveContains(query) == true)
            }
        }
    )
}

extension DependencyValues {
    nonisolated var gitHubClient: GitHubClient {
        get { self[GitHubClient.self] }
        set { self[GitHubClient.self] = newValue }
    }
}

// MARK: - Codable helpers (private)

private nonisolated struct SearchResponse: Decodable {
    let items: [RepoItem]
}

private nonisolated struct RepoItem: Decodable {
    let id: Int
    let name: String
    let full_name: String
    let description: String?
    let stargazers_count: Int
    let language: String?
    let owner: OwnerItem
    let html_url: String
}

private nonisolated struct OwnerItem: Decodable {
    let login: String
}

private nonisolated extension Repo {
    init(_ item: RepoItem) {
        self.init(
            id: item.id,
            name: item.name,
            fullName: item.full_name,
            description: item.description,
            starCount: item.stargazers_count,
            language: item.language,
            owner: item.owner.login,
            htmlURL: URL(string: item.html_url)!
        )
    }
}

// MARK: - Mock data

nonisolated extension Repo {
    static let mocks: [Repo] = [
        Repo(id: 1, name: "swift", fullName: "apple/swift",
             description: "The Swift Programming Language", starCount: 66_900,
             language: "C++", owner: "apple",
             htmlURL: URL(string: "https://github.com/apple/swift")!),
        Repo(id: 2, name: "swift-model", fullName: "acumen-ai/swift-model",
             description: "A composable model framework for SwiftUI", starCount: 1_400,
             language: "Swift", owner: "acumen-ai",
             htmlURL: URL(string: "https://github.com/acumen-ai/swift-model")!),
        Repo(id: 3, name: "swift-dependencies", fullName: "pointfreeco/swift-dependencies",
             description: "A dependency management library for Swift and SwiftUI", starCount: 1_900,
             language: "Swift", owner: "pointfreeco",
             htmlURL: URL(string: "https://github.com/pointfreeco/swift-dependencies")!),
        Repo(id: 4, name: "swift-composable-architecture", fullName: "pointfreeco/swift-composable-architecture",
             description: "A library for building applications with composable state management", starCount: 12_400,
             language: "Swift", owner: "pointfreeco",
             htmlURL: URL(string: "https://github.com/pointfreeco/swift-composable-architecture")!),
        Repo(id: 5, name: "vapor", fullName: "vapor/vapor",
             description: "Server-side Swift web framework", starCount: 24_100,
             language: "Swift", owner: "vapor",
             htmlURL: URL(string: "https://github.com/vapor/vapor")!),
        Repo(id: 6, name: "Alamofire", fullName: "Alamofire/Alamofire",
             description: "Elegant HTTP Networking in Swift", starCount: 41_000,
             language: "Swift", owner: "Alamofire",
             htmlURL: URL(string: "https://github.com/Alamofire/Alamofire")!),
    ]
}
