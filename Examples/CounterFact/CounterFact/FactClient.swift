import Foundation
import Dependencies

nonisolated struct FactClient {
    var fetch: @Sendable (Int) async throws -> String
}

nonisolated extension FactClient: DependencyKey {
    static let liveValue = FactClient(
        fetch: { number in
            struct Response: Decodable { let fact: String }
            let (data, _) = try await URLSession.shared.data(from: URL(string: "https://catfact.ninja/fact")!)
            let response = try JSONDecoder().decode(Response.self, from: data)
            return "\(number) is a great number. Also: \(response.fact)"
        }
    )
}

extension DependencyValues {
    nonisolated var factClient: FactClient {
        get { self[FactClient.self] }
        set { self[FactClient.self] = newValue }
    }
}
