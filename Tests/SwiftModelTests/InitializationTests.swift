import Testing
import SwiftModel
import Observation

struct InitializationTests {
    @Test func testMyModel() throws {
        let myModel = MyModel(id: 5, integer: 4)
        Task {
            let _ = MyModel(id: 5, integer: 4)
        }

        #expect(myModel.id == 5)
        #expect(myModel.integer == 4)
    }
}

@Model
private struct MyModel {
    let id: Int
    private(set) var integer: Int?
}
