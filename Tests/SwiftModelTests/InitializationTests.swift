import XCTest
import SwiftModel

final class InitializationTests: XCTestCase {
    func testMyModel() throws {
        let myModel = MyModel(id: 5, integer: 4)
        Task {
            let _ = MyModel(id: 5, integer: 4)
        }

        XCTAssertEqual(myModel.id, 5)
        XCTAssertEqual(myModel.integer, 4)
    }
}

@Model
private struct MyModel: Sendable {
    let id: Int
    private(set) var integer: Int?

    init(id: Int, integer: Int? = nil) {
        self.id = id
        self.integer = integer
    }
}
