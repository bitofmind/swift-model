import Testing
import Foundation
import SwiftModel
import Dependencies
@testable import Search

// MARK: - SearchModel tests
//
// State changes (query, isSearching, results) are input noise or transient loading flags —
// the focus is on async behaviour, cancel-in-flight, and probe calls. Tasks and probes
// remain exhaustive; only .state is removed.

@Suite(.modelTesting(.removing(.state)))
struct SearchTests {

    // MARK: Cancel-in-flight

    /// Demonstrates the cancel-in-flight pattern: two rapid queries are submitted,
    /// but only the later query's result lands because the earlier one is cancelled.
    /// `ImmediateClock` makes the debounce fire instantly so both queries proceed
    /// to the network layer, where the first is cancelled by `cancelPrevious: true`.
    @Test func cancelInFlight() async {
        let model = SearchModel().withAnchor {
            $0.continuousClock = ImmediateClock()
            $0.gitHubClient.search = { query in
                return Repo.mocks.filter { $0.owner.localizedCaseInsensitiveContains(query) }
            }
        }

        // Submit two queries in rapid succession. With ImmediateClock the debounce
        // typically coalesces both into just "vapor". If under heavy parallel load
        // both are emitted, cancelPrevious cancels the "apple" task and the "vapor"
        // search overwrites any transient results.
        model.query = "apple"
        model.query = "vapor"

        // Only "vapor" results should land
        await expect {
            !model.results.isEmpty
            model.results.allSatisfy { $0.repo.owner == "vapor" }
        }
    }

    // MARK: TestProbe for network dependency

    /// Shows how to use TestProbe to verify the client was called with the right query.
    @Test func searchCallsClientWithQuery() async {
        let probe = TestProbe("search query")
        let model = SearchModel().withAnchor {
            $0.continuousClock = ImmediateClock()
            $0.gitHubClient.search = { query in
                probe.call(query)   // record the query
                return []
            }
        }

        model.query = "alamofire"
        await expect {
            probe.wasCalled(with: "alamofire")
        }
    }

    // MARK: Initial state

    /// settle() skips past activation side effects (the initial empty-query search),
    /// then we assert the model is idle and empty.
    @Test func initialState() async {
        let model = SearchModel().withAnchor {
            $0.continuousClock = ImmediateClock()
            $0.gitHubClient.search = { _ in return [] }
        }
        await settle {
            model.results.isEmpty
            !model.isSearching
        }
    }

    // MARK: Filter sorting

    /// Verifies that applying a sort filter reorders the existing results.
    @Test func filterSortsByName() async {
        let model = SearchModel().withAnchor {
            $0.continuousClock = ImmediateClock()
            $0.gitHubClient.search = { _ in Repo.mocks }
        }

        model.query = "swift"
        await expect(!model.results.isEmpty)

        // Open filter, set sort to name, dismiss
        model.filterButtonTapped()
        model.filter?.sortBy = .name
        model.filterDismissed()

        // Results should now be sorted alphabetically by name
        let names = model.results.map(\.repo.name)
        #expect(names == names.sorted())
    }

    // MARK: Empty query clears results

    @Test func emptyQueryClearsResults() async {
        let model = SearchModel().withAnchor {
            $0.continuousClock = ImmediateClock()
            $0.gitHubClient.search = { _ in Repo.mocks }
        }

        model.query = "swift"
        await expect(!model.results.isEmpty)

        model.query = ""
        await expect(model.results.isEmpty)
    }

    // MARK: Deep link

    /// AppModel.handleURL sets the search query from a URL.
    @Test func deepLinkSetsQuery() async {
        let model = AppModel().withAnchor {
            $0.continuousClock = ImmediateClock()
            $0.gitHubClient.search = { _ in [] }
        }

        model.handleURL(URL(string: "githubsearch://search?q=vapor")!)
        await expect(model.search.query == "vapor")
    }

    // MARK: withActivation

    /// withActivation lets callers inject extra setup after onActivate() without
    /// modifying SearchModel itself. Here we pre-set the query so the search fires
    /// automatically during activation — useful for testing pre-populated states.
    @Test(.modelTesting(.removing(.tasks))) func withActivationPrePopulatesResults() async {
        let model = SearchModel()
            .withActivation { $0.query = "swift" }
            .withAnchor {
                $0.continuousClock = ImmediateClock()
                $0.gitHubClient.search = { _ in Repo.mocks }
            }

        await expect(!model.results.isEmpty)
    }
}

// MARK: - FilterModel tests
//
// FilterModel uses observeModifications(kinds: .properties) to autosave on any property change,
// creating tasks that the test doesn't need to track. State changes (sortBy, language) are incidental.

@Suite(.modelTesting(.removing(.state)))
struct FilterModelTests {

    /// FilterModel uses observeModifications() to detect any property change.
    @Test func initialFilterState() async {
        let filter = FilterModel().withAnchor()
        await settle {
            filter.sortBy == .stars
            filter.language == ""
        }
    }

    @Test func clearLanguage() async {
        let filter = FilterModel().withAnchor()
        filter.language = "Swift"
        filter.clearLanguage()
        await expect(filter.language == "")
    }
}

// MARK: - SearchResultItem tests

@Suite(.modelTesting)
struct SearchResultItemTests {

    @Test func perItemDetailLoadsAfterActivation() async {
        let item = SearchResultItem(repo: Repo.mocks[0]).withAnchor {
            $0.continuousClock = ImmediateClock()
        }
        // After activation, the async task should populate detailLine
        await expect(item.detailLine != nil)
    }

    @Test func toggleExpanded() async {
        let item = SearchResultItem(repo: Repo.mocks[0]).withAnchor {
            $0.continuousClock = ImmediateClock()
        }
        // settle() lets the detailLine task complete and resets the exhaustivity baseline
        await settle()
        item.toggleExpanded()
        await expect(item.isExpanded)
        item.toggleExpanded()
        await expect(!item.isExpanded)
    }
}
