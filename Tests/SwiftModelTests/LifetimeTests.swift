import Testing
import AsyncAlgorithms
@testable import SwiftModel
import Observation

struct LifetimeTests {
    @Test func testPropertyLifetime() {
        let i = Child(count: 4711)
        #expect(i.count == 4711)
        i.count += 1
        #expect(i.count == 4712)

        let a = i.withAnchor()
        #expect(a.count == 4712)
        i.count += 10
        a.count += 1

        #expect(i.count == 4723)
        #expect(a.count == 4723)

        let fi = i.frozenCopy
        let fa = a.frozenCopy

        #expect(fi.count == 4723)
        #expect(fa.count == 4723)

        i.count += 1
        a.count += 1

        #expect(fi.count == 4723)
        #expect(fa.count == 4723)

        withKnownIssue {
            fi.count += 1
        }

        withKnownIssue {
            fa.count += 1
        }
    }

    @Test func testChildLifetime() {
        let i = Parent(child: Child(count: 25))
        #expect(i.child.count == 25)
        i.child.count += 1

        let a = i.withAnchor()
        #expect(a.child.count == 26)
        i.child.count += 10
        a.child.count += 1

        #expect(i.child.count == 37)
        #expect(a.child.count == 37)

        i.child = Child(count: 100)
        #expect(i.child.count == 100)

        a.child = Child(count: 120)
        #expect(a.child.count == 120)

        let fi = i.frozenCopy
        let fa = a.frozenCopy

        withKnownIssue {
            fi.child = Child(count: 2)
        }

        withKnownIssue {
            fa.child = Child(count: 3)
        }

        i.child = a.child

        a.child = i.child

        withKnownIssue {
            i.child = fi.child
        }

        withKnownIssue {
            a.child = fa.child
        }
    }

    @Test func testChildrenLifetime() {
        let i = Parent(children: [Child(count: 25)])
        #expect(i.children[0].count == 25)
        i.children[0].count += 1

        let a = i.withAnchor()
        #expect(a.children[0].count == 26)
        i.children[0].count += 10
        a.children[0].count += 1

        #expect(i.children[0].count == 37)
        #expect(a.children[0].count == 37)

        i.children[0] = Child(count: 100)
        #expect(i.children[0].count == 100)

        a.children[0] = Child(count: 120)
        #expect(a.children[0].count == 120)

        let fi = i.frozenCopy
        let fa = a.frozenCopy

        withKnownIssue {
            fi.children[0] = Child(count: 2)
        }

        withKnownIssue {
            fa.children[0] = Child(count: 3)
        }

        i.children[0] = a.children[0]

        a.children[0] = i.children[0]

        withKnownIssue {
            i.children[0] = fi.children[0]
        }

        withKnownIssue {
            a.children[0] = fa.children[0]
        }
    }
}

@ModelContainer private enum Cases {
    case count(Int)
    case child(Child)
    case children([Child])
}

@Model private struct Parent {
    var child: Child = Child(count: 0)
    var children: [Child] = []
    var cases: Cases?
}

@Model
private struct Child {
    var count: Int
    var leaf: Leaf? = nil
}

@Model
private struct Leaf { }
