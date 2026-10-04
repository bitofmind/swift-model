#if canImport(SwiftUI)
import Testing
@testable import SwiftModel

/// `ViewAccess` must store its `objectWillChange` publisher. A synthesized one, for an
/// `ObservableObject` with no `@Published` properties, is looked up in a process-wide
/// side table whose every lookup sweeps all live entries: with one `ViewAccess` per
/// `@ObservedModel` view, SwiftUI's per-update read cost grew with the number of views
/// (~370 µs each at 4,000).
struct ViewAccessPublisherTests {
    @Test func objectWillChangeIsAStoredProperty() {
        let access = ViewAccess()
        let stored = Mirror(reflecting: access).children.contains { $0.label == "objectWillChange" }
        #expect(stored)
        #expect(access.objectWillChange === access.objectWillChange)
    }
}
#endif
