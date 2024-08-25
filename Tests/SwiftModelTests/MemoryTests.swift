import XCTest
@testable import SwiftModel

final class MemoryTests: XCTestCase {
    func testParent() throws {
        weak var parentRef: Context<Parent>.Reference?
        do {
            let parent = Parent().withAnchor()

            parentRef = parent.context?.reference
            XCTAssertNotNil(parentRef)
        }
        XCTAssertNil(parentRef)
    }

    func testParentChild() throws {
        weak var parentRef: Context<Parent>.Reference?
        weak var childRef: Context<Child>.Reference?
        do {
            let parent = Parent().withAnchor()

            parentRef = parent.context?.reference
            XCTAssertNotNil(parentRef)

            parent.child = Child { } mutableCallback: { }
            childRef = parent.child?.context?.reference
            XCTAssertNotNil(childRef)

        }
        XCTAssertNil(parentRef)
        XCTAssertNil(childRef)
    }

    func testParentChildBackReference() {
        weak var parentRef: Context<Parent>.Reference?
        weak var childRef: Context<Child>.Reference?
        weak var parentContext: Context<Parent>?
        weak var childContext: Context<Child>?
        weak var modelAccess: ModelAccess?
        do {
            let access = MemoryAccess(useWeakReference: true)
            modelAccess = access
            let (parent, anchor) = Parent().withAccess(access).andAnchor()

            parentRef = parent.context?.reference
            XCTAssertNotNil(parentRef)
            parentContext = parent.context
            XCTAssertNotNil(parentContext)

            parent.child = Child {
                _ = parent
            } mutableCallback: {
                _ = parent
            }
            childRef = parent.child?.context?.reference
            XCTAssertNotNil(childRef)
            childContext = parent.child?.context
            XCTAssertNotNil(childContext)

            let _ = anchor
        }
        XCTAssertNil(parentRef)
        XCTAssertNil(childRef)
        XCTAssertNil(parentContext)
        XCTAssertNil(childContext)
        XCTAssertNil(modelAccess)
    }

    func testCallbackToSelf() {
        weak var childRef: Context<Child>.Reference?
        weak var objectRef: Object?
        do {
            let (child, anchor) = Child(callback: {}, mutableCallback: {}).andAnchor()

            child.mutableCallback = {
                child.callback()
                _ = child.object
            }
            childRef = child.reference
            XCTAssertNotNil(childRef)

            objectRef = child.object
            XCTAssertNotNil(objectRef)

            let _ = anchor
        }
        XCTAssertNil(childRef)
        XCTAssertNil(objectRef)
    }

    func testCallbackToSelfInBox() {
        weak var childRef: Context<Child>.Reference?
        weak var objectRef: Object?
        do {

            // Use model without self of back reference as root.
            let parent = Parent(child: Child(callback: {}, mutableCallback: {})).withAnchor()
            let child = parent.child!

            child.mutableCallback = {
                child.callback()
                _ = child.object
            }
            childRef = child.reference
            XCTAssertNotNil(childRef)

            objectRef = child.object
            XCTAssertNotNil(objectRef)

            let _ = parent
        }
        XCTAssertNil(childRef)
        XCTAssertNil(objectRef)
    }

    func testReplaceAnchor() {
        weak var childRef: Context<Child>.Reference?
        weak var objectRef: Object?
        do {
            var (child, anchor) = Child(callback: {}, mutableCallback: {}).andAnchor()
            child.mutableCallback = { [child] in
                child.callback()
                _ = child.object
            }
            childRef = child.reference
            XCTAssertNotNil(childRef)

            objectRef = child.object
            XCTAssertNotNil(objectRef)

            // Replace
            let _ = anchor
            (child, anchor) = Child(callback: {}, mutableCallback: {}).andAnchor()

            XCTAssertNil(childRef)
            XCTAssertNil(objectRef)

            childRef = child.reference
            XCTAssertNotNil(childRef)

            objectRef = child.object
            XCTAssertNotNil(objectRef)

            let _ = anchor
        }
        XCTAssertNil(childRef)
        XCTAssertNil(objectRef)
    }
}

@Model
private struct Parent: Sendable {
    var child: Child?
}

@Model
private struct Child: Sendable {
    let callback: @Sendable () -> Void
    var mutableCallback: @Sendable () -> Void
    let object = Object()
}

private final class Object: @unchecked Sendable {
    deinit {
        print()
    }
}

private class MemoryAccess: ModelAccess, @unchecked Sendable {
    override var shouldPropagateToChildren: Bool { true }
}


