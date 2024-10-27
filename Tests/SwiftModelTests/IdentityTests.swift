import Testing
import SwiftModel
import Observation

struct IdentityTests {
    @Test func testImplicitId() {
        let model1 = ImplicitModel()
        let model2 = ImplicitModel()
        #expect(model1.id != model2.id)
    }

    @Test func testExplicit() {
        let model1 = ExplicitModel(id: 1)
        let model2 = ExplicitModel(id: 2)
        #expect(model1.id != model2.id)
    }
}

private struct APA {
    private var count = 47
}

extension APA {
    mutating func hej() { _ = \Self.count }
}

@Model
private struct ImplicitModel {
}

@Model
private struct ExplicitModel {
    private(set) var id: Int
}
