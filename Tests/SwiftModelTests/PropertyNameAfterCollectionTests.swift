import Testing
@testable import SwiftModel

/// Exhaustivity reports name a property by counting the model's visited properties
/// and indexing its `Mirror` labels. Collections of models are visited through
/// `visitCollection` / `visitContainerCollection`, which `IndexVisitor` didn't count,
/// so every property after one was reported under the name of the property before
/// it: a write to `afterItems` read as `PNRoot.items: 0 → 1`.
@Suite(.modelTesting)
struct PropertyNameAfterCollectionTests {

    @Test func propertyAfterModelArrayIsNamed() async {
        let root = PNRoot(items: [PNItem(id: 1)], paths: [.item(PNItem(id: 2))]).withAnchor()
        root.afterItems = 1
        await withKnownIssue {
            await expect(root.items.count == 1)
        } matching: { issue in
            issue.description.contains("PNRoot.afterItems: 0 → 1")
        }
    }

    @Test func propertyAfterModelContainerCollectionIsNamed() async {
        let root = PNRoot(items: [PNItem(id: 1)], paths: [.item(PNItem(id: 2))]).withAnchor()
        root.afterPaths = "x"
        await withKnownIssue {
            await expect(root.items.count == 1)
        } matching: { issue in
            issue.description.contains(#"PNRoot.afterPaths: "" → "x""#)
        }
    }
}

@Model private struct PNItem: Identifiable {
    var id: Int
}

@ModelContainer private enum PNPath: Identifiable, Sendable {
    case item(PNItem)

    var id: Int {
        switch self {
        case let .item(item): item.id
        }
    }
}

@Model private struct PNRoot {
    var items: [PNItem]
    var afterItems = 0
    var paths: ContiguousArray<PNPath>
    var afterPaths = ""
}
