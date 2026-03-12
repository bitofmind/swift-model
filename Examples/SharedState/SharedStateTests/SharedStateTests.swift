import SwiftModel
import Testing
import SwiftUINavigation
@testable import SharedState

struct SharedStateTests {
  @Test func testTabSelection() async {
    let (model, tester) = SharedState().andTester()

    await tester.assert {
      model.currentTab == .counter
    }

    model.currentTab = .profile

    await tester.assert {
      model.currentTab == .profile
    }

    model.currentTab = .counter

    await tester.assert {
      model.currentTab == .counter
    }
  }

  @Test func testSharedCounts() async {
    let (model, tester) = SharedState().andTester()

    model.counter.incrementButtonTapped()

    await tester.assert {
      model.stats.count == 1
      model.stats.maxCount == 1
      model.stats.numberOfCounts == 1
    }

    model.counter.decrementButtonTapped()

    await tester.assert {
      model.stats.count == 0
      model.stats.minCount == 0
      model.stats.numberOfCounts == 2
    }

    model.profile.resetStatsButtonTapped()

    await tester.assert {
      model.stats.count == 0
      model.stats.maxCount == 0
      model.stats.minCount == 0
      model.stats.numberOfCounts == 0
    }
  }

  @Test func testAlert() async {
    let (model, tester) = SharedState().andTester()

    model.counter.isPrimeButtonTapped()

    await tester.assert {
      model.counter.alert == AlertState {
        TextState("👎 The number 0 is not prime :(")
      }
    }
  }

  @Test func testProfileReadsCounterStats() async {
    let (model, tester) = SharedState().andTester()

    // Increment via the counter tab — profile tab sees the same count
    // because both hold a reference to the same Stats model instance.
    model.counter.incrementButtonTapped()
    model.counter.incrementButtonTapped()
    model.counter.incrementButtonTapped()

    await tester.assert {
      model.counter.stats.count == 3
      model.counter.stats.maxCount == 3
      model.counter.stats.numberOfCounts == 3
      model.profile.stats.count == 3       // same model — no sync needed
      model.profile.stats.maxCount == 3
      model.profile.stats.numberOfCounts == 3
    }
  }
}
