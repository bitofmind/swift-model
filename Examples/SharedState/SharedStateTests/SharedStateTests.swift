import SwiftModel
import Testing
import SwiftUINavigation
@testable import SharedState

@Suite(.modelTesting)
struct SharedStateTests {
  @Test func testTabSelection() async {
    let model = SharedState().withAnchor()

    await expect { model.currentTab == .counter }

    model.currentTab = .profile

    await expect { model.currentTab == .profile }

    model.currentTab = .counter

    await expect { model.currentTab == .counter }
  }

  @Test func testSharedCounts() async {
    let model = SharedState().withAnchor()

    model.counter.incrementButtonTapped()

    await expect {
      model.stats.count == 1
      model.stats.maxCount == 1
      model.stats.numberOfCounts == 1
    }

    model.counter.decrementButtonTapped()

    await expect {
      model.stats.count == 0
      model.stats.minCount == 0
      model.stats.numberOfCounts == 2
    }

    model.profile.resetStatsButtonTapped()

    await expect {
      model.stats.count == 0
      model.stats.maxCount == 0
      model.stats.minCount == 0
      model.stats.numberOfCounts == 0
    }
  }

  @Test func testAlert() async {
    let model = SharedState().withAnchor()

    model.counter.isPrimeButtonTapped()

    await expect {
      model.counter.alert == AlertState {
        TextState("👎 The number 0 is not prime :(")
      }
    }
  }

  @Test func testProfileReadsCounterStats() async {
    let model = SharedState().withAnchor()

    model.counter.incrementButtonTapped()
    model.counter.incrementButtonTapped()
    model.counter.incrementButtonTapped()

    await expect {
      model.counter.stats.count == 3
      model.counter.stats.maxCount == 3
      model.counter.stats.numberOfCounts == 3
      model.profile.stats.count == 3       // same model — no sync needed
      model.profile.stats.maxCount == 3
      model.profile.stats.numberOfCounts == 3
    }
  }
}
