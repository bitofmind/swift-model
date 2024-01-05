import Foundation
import Dependencies

struct FactClient {
    var fetch: @Sendable (Int) async throws -> String
}

extension FactClient: DependencyKey {
    static let liveValue = FactClient(
        fetch: { number in
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://numbersapi.com/\(number)")!)
            return String(decoding: data, as: UTF8.self)
        }
    )
}

extension DependencyValues {
    var factClient: FactClient {
        get { self[FactClient.self] }
        set { self[FactClient.self] = newValue }
    }
}
