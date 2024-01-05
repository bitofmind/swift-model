import XCTest
import AsyncAlgorithms
@testable import SwiftModel

final class LifetimeTests: XCTestCase {
    func testPropertyLifetime() {
        let i = Child(count: 4711)
        XCTAssertEqual(i.count, 4711)
        i.count += 1
        XCTAssertEqual(i.count, 4712)

        let a = i.withAnchor()
        XCTAssertEqual(a.count, 4712)
        i.count += 10
        a.count += 1

        XCTAssertEqual(i.count, 4722)
        XCTAssertEqual(a.count, 4713)

        let fi = i.frozenCopy
        let fa = a.frozenCopy

        XCTAssertEqual(fi.count, 4722)
        XCTAssertEqual(fa.count, 4713)

        i.count += 1
        a.count += 1

        XCTAssertEqual(fi.count, 4722)
        XCTAssertEqual(fa.count, 4713)

        XCTExpectFailure {
            fi.count += 1
        }

        XCTExpectFailure {
            fa.count += 1
        }
    }

    func testChildLifetime() {
        let i = Parent(child: Child(count: 25))
        XCTAssertEqual(i.child.count, 25)
        i.child.count += 1

        let a = i.withAnchor()
        XCTAssertEqual(a.child.count, 26)
        i.child.count += 10
        a.child.count += 1

        XCTAssertEqual(i.child.count, 36)
        XCTAssertEqual(a.child.count, 27)

        i.child = Child(count: 100)
        XCTAssertEqual(i.child.count, 100)

        a.child = Child(count: 120)
        XCTAssertEqual(a.child.count, 120)

        let fi = i.frozenCopy
        let fa = a.frozenCopy

        XCTExpectFailure {
            fi.child = Child(count: 2)
        }

        XCTExpectFailure {
            fa.child = Child(count: 3)
        }

        XCTExpectFailure {
            i.child = a.child
        }

        a.child = i.child

        XCTExpectFailure {
            i.child = fi.child
        }

        XCTExpectFailure {
            a.child = fa.child
        }
    }

    func testChildrenLifetime() {
        let i = Parent(children: [Child(count: 25)])
        XCTAssertEqual(i.children[0].count, 25)
        i.children[0].count += 1

        let a = i.withAnchor()
        XCTAssertEqual(a.children[0].count, 26)
        i.children[0].count += 10
        a.children[0].count += 1

        XCTAssertEqual(i.children[0].count, 36)
        XCTAssertEqual(a.children[0].count, 27)

        i.children[0] = Child(count: 100)
        XCTAssertEqual(i.children[0].count, 100)

        a.children[0] = Child(count: 120)
        XCTAssertEqual(a.children[0].count, 120)

        let fi = i.frozenCopy
        let fa = a.frozenCopy

        XCTExpectFailure {
            fi.children[0] = Child(count: 2)
        }

        XCTExpectFailure {
            fa.children[0] = Child(count: 3)
        }

        XCTExpectFailure {
            i.children[0] = a.children[0]
        }

        a.children[0] = i.children[0]

        XCTExpectFailure {
            i.children[0] = fi.children[0]
        }

        XCTExpectFailure {
            a.children[0] = fa.children[0]
        }
    }
}

@ModelContainer private enum Cases {
    case count(Int)
    case child(Child)
    case children([Child])
}

@Model private struct Parent: Sendable {
    var child: Child = Child(count: 0)
    var children: [Child] = []
    var cases: Cases?
}

@Model
private struct Child: Sendable {
    var count: Int
    var leaf: Leaf? = nil
}

@Model
private struct Leaf: Sendable { }
