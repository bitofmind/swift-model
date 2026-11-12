import Testing
@testable import SwiftModel

/// `AnyContext.rootPaths` is cached and invalidated by structure stamps. After each kind of
/// structural change, the cached result must equal a fresh computation, or test reports
/// would name the wrong property.
struct RootPathsCacheTests {
    @Test func cachedPathsFollowEveryStructuralChange() {
        let (host, anchor) = PathHost(items: [PathItem(id: 1), PathItem(id: 2)]).returningAnchor()
        defer { withExtendedLifetime(anchor) {} }

        func check(_ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
            var contexts: [AnyContext] = []
            for item in host.items {
                contexts.append(item.context!)
                contexts.append(item.leaf.context!)
            }
            if let child = host.child { contexts.append(child.context!) }
            if let other = host.other { contexts.append(other.context!) }
            for context in contexts {
                let cached = context.rootPaths
                #expect(cached == context.rootPaths, comment, sourceLocation: sourceLocation)  // a cache hit
                #expect(cached == context._uncachedRootPaths, comment, sourceLocation: sourceLocation)
            }
        }

        check("initial")
        host.items.append(PathItem(id: 3))
        check("after append")
        host.items.reverse()
        check("after reorder")
        host.items.remove(at: 1)
        check("after remove")
        host.items.insert(PathItem(id: 4), at: 0)
        check("after insert at front")

        host.child = PathLeaf()
        check("child added")
        let moved = host.child!
        host.other = moved
        host.child = nil
        check("child moved to another property")
        host.items[0].leaf = PathLeaf(value: 7)
        check("nested child replaced")
    }

    @Test func removedModelGetsAFreshPath() {
        let (host, anchor) = PathHost(items: [PathItem(id: 1), PathItem(id: 2)]).returningAnchor()
        defer { withExtendedLifetime(anchor) {} }
        let removed = host.items[0]
        let context = removed.context!
        let before = context.rootPaths
        host.items.remove(at: 0)
        #expect(context.rootPaths == context._uncachedRootPaths)
        #expect(context.rootPaths != before)
    }
}

@Model private struct PathHost {
    var items: [PathItem] = []
    var child: PathLeaf? = nil
    var other: PathLeaf? = nil
}

@Model private struct PathItem: Identifiable {
    let id: Int
    var leaf = PathLeaf()
}

@Model private struct PathLeaf {
    var value = 0
}
