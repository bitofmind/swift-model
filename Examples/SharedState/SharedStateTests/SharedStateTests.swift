import SwiftModel
import XCTest
import SwiftUINavigation
@testable import SharedState

final class SharedStateTests: XCTestCase {
  func testTabSelection() async {
    let (model, tester) = SharedState().andTester()
    let stats = Stats()

    model.currentTab = .profile
    stats.increment()
   
    await tester.assert {
      model.currentTab == .profile
      model.counter.stats == stats
    }

    model.currentTab = .counter
    stats.increment()

    await tester.assert {
      model.currentTab == .counter
      model.counter.stats == stats
    }
  }

  func testSharedCounts() async {
    let (model, tester) = SharedState().andTester()
    let stats = Stats()

    model.counter.incrementButtonTapped()
    stats.increment()

    await tester.assert {
      model.stats == stats
    }

    model.counter.decrementButtonTapped()
    stats.decrement()

    await tester.assert {
      model.stats == stats
    }

    model.profile.resetStatsButtonTapped()
    stats.reset()

    await tester.assert {
      model.stats == stats
    }
  }

  func testAlert() async {
    let (model, tester) = SharedState().andTester()

    model.counter.isPrimeButtonTapped()

    await tester.assert {
      model.counter.alert == AlertState {
        TextState("👎 The number 0 is not prime :(")
      }
    }
  }
}
