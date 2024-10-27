import Testing
@testable import SwiftModel
import Observation

struct MemoryTests {
    @Test func testParent() async {
        weak var parentRef: Context<Parent>.Reference?
        do {
            let parent = Parent().withAnchor()

            parentRef = parent.context?.reference
            #expect(parentRef != nil)
        }

        await parentRef.waitUntilNil()

        #expect(parentRef == nil)
    }

    @Test func testParentChild() async {
        weak var parentRef: Context<Parent>.Reference?
        weak var childRef: Context<Child>.Reference?
        do {
            let parent = Parent().withAnchor()

            parentRef = parent.context?.reference
            #expect(parentRef != nil)

            parent.child = Child { } mutableCallback: { }
            childRef = parent.child?.context?.reference
            #expect(childRef != nil)
        }

        await parentRef.waitUntilNil()

        #expect(parentRef == nil)
        #expect(childRef == nil)
    }

    @Test func testParentChildBackReference() async {
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
            #expect(parentRef != nil)
            parentContext = parent.context
            #expect(parentContext != nil)

            parent.child = Child {
                _ = parent
            } mutableCallback: {
                _ = parent
            }
            childRef = parent.child?.context?.reference
            #expect(childRef != nil)
            childContext = parent.child?.context
            #expect(childContext != nil)

            let _ = anchor
        }

        await parentRef.waitUntilNil()

        #expect(parentRef == nil)
        #expect(childRef == nil)
        #expect(parentContext == nil)
        #expect(childContext == nil)
        #expect(modelAccess == nil)
    }

    @Test func testCallbackToSelf() async {
        weak var childRef: Context<Child>.Reference?
        weak var objectRef: Object?
        do {
            let (child, anchor) = Child(callback: {}, mutableCallback: {}).andAnchor()

            child.mutableCallback = {
                child.callback()
                _ = child.object
            }
            childRef = child.reference
            #expect(childRef != nil)

            objectRef = child.object
            #expect(objectRef != nil)

            let _ = anchor
        }

        await childRef.waitUntilNil()

        #expect(childRef == nil)
        #expect(objectRef == nil)
    }

    @Test func testCallbackToSelfInBox() async {
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
            #expect(childRef != nil)

            objectRef = child.object
            #expect(objectRef != nil)

            let _ = parent
        }

        await childRef.waitUntilNil()

        #expect(childRef == nil)
        #expect(objectRef == nil)
    }

    @Test func testReplaceAnchor() async {
        weak var childRef: Context<Child>.Reference?
        weak var objectRef: Object?
        do {
            var (child, anchor) = Child(callback: {}, mutableCallback: {}).andAnchor()
            child.mutableCallback = { [child] in
                child.callback()
                _ = child.object
            }
            childRef = child.reference
            #expect(childRef != nil)

            objectRef = child.object
            #expect(objectRef != nil)

            // Replace
            let _ = anchor
            (child, anchor) = Child(callback: {}, mutableCallback: {}).andAnchor()

            await childRef.waitUntilNil()

            #expect(childRef == nil)
            #expect(objectRef == nil)

            childRef = child.reference
            #expect(childRef != nil)

            objectRef = child.object
            #expect(objectRef != nil)

            let _ = anchor
        }

        await childRef.waitUntilNil()

        #expect(childRef == nil)
        #expect(objectRef == nil)
    }
}

@Model
private struct Parent {
    var child: Child?
}

@Model
private struct Child {
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


