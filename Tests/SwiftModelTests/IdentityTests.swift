import XCTest
import SwiftModel

final class IdentityTests: XCTestCase {
    
    func testImplicitId() {
        let model1 = ImplicitModel()
        let model2 = ImplicitModel()
        XCTAssertNotEqual(model1.id, model2.id)
    }

    func testExplicit() {
        let model1 = ExplicitModel(id: 1)
        let model2 = ExplicitModel(id: 2)
        XCTAssertNotEqual(model1.id, model2.id)

//        model1.id = model2.id
//        XCTAssertEqual(model1.id, model2.id)
    }
}

private struct APA {
    private var count = 47
}

extension APA {
    mutating func hej() { _ = \Self.count }
}


@Model
private struct ImplicitModel: Sendable {
}

@Model
private struct ExplicitModel: Sendable {
    private(set) var id: Int
}
