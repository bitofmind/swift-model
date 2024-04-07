import SwiftModel
import SwiftUI
import SwiftUINavigation

@Model
struct CounterTab: Sendable {
  var alert: AlertState<Never>?
  var stats: Stats

  func decrementButtonTapped() {
    stats.decrement()
  }
     
  func incrementButtonTapped() {
    stats.increment()
  }

  func isPrimeButtonTapped() {
    alert = AlertState {
      TextState(
        isPrime(stats.count)
        ? "👍 The number \(stats.count) is prime!"
        : "👎 The number \(stats.count) is not prime :("
      )
    }
  }
}

struct CounterTabView: View {
  @ObservedModel var model: CounterTab

  var body: some View {
    Form {
      VStack(spacing: 16) {
        HStack {
          Button {
            model.decrementButtonTapped()
          } label: {
            Image(systemName: "minus")
          }

          Text("\(model.stats.count)")
            .monospacedDigit()

          Button {
            model.incrementButtonTapped()
          } label: {
            Image(systemName: "plus")
          }
        }

        Button("Is this prime?") { model.isPrimeButtonTapped() }
      }
    }
    .buttonStyle(.borderless)
    .navigationTitle("Shared State Demo")
    .alert($model.alert)
  }
}

@Model
struct ProfileTab: Sendable {
  var stats: Stats

  func resetStatsButtonTapped() {
    stats.reset()
  }
}

struct ProfileTabView: View {
  @ObservedModel var model: ProfileTab

  var body: some View {
    Form {
      Text("""
          This tab shows state from the previous tab, and it is capable of reseting all of the \
          state back to 0.

          This shows that it is possible for each screen to model its state in the way that makes \
          the most sense for it, while still allowing the state and mutations to be shared \
          across independent screens.
          """
      ).font(.caption)

      VStack(spacing: 16) {
        Text("Current count: \(model.stats.count)")
        Text("Max count: \(model.stats.maxCount)")
        Text("Min count: \(model.stats.minCount)")
        Text("Total number of count events: \(model.stats.numberOfCounts)")
        Button("Reset") { model.resetStatsButtonTapped() }
      }
    }
    .buttonStyle(.borderless)
    .navigationTitle("Profile")
  }
}

@Model
struct SharedState: Sendable {
  enum Tab { case counter, profile }

  var currentTab = Tab.counter
  var counter: CounterTab
  var profile: ProfileTab
  var stats: Stats
    
  init(
    currentTab: Tab = Tab.counter,
    stats: Stats = Stats()
  ) {
    _currentTab = currentTab
    _counter = CounterTab(stats: stats)
    _profile = ProfileTab(stats: stats)
    _stats = stats
  }

  func onActivate() {
    node.forEach(change(of: \.currentTab, initial: false)) { _ in
      stats.increment()
    }
  }
}

struct SharedStateView: View {
  @ObservedModel var model: SharedState

  var body: some View {
    TabView(selection: $model.currentTab) {
      NavigationStack {
        CounterTabView(model: model.counter)
      }
      .tag(SharedState.Tab.counter)
      .tabItem { Text("Counter") }

      NavigationStack {
        ProfileTabView(model: model.profile)
      }
      .tag(SharedState.Tab.profile)
      .tabItem { Text("Profile") }
    }
  }
}

@Model
struct Stats: Sendable, Equatable {
  private(set) var count = 0
  private(set) var maxCount = 0
  private(set) var minCount = 0
  private(set) var numberOfCounts = 0

  func increment() {
    node.transaction {
      count += 1
      numberOfCounts += 1
      maxCount = max(maxCount, count)
    }
  }

  func decrement() {
    node.transaction {
      count -= 1
      numberOfCounts += 1
      minCount = min(minCount, count)
    }
  }

  func reset() {
    node.transaction {
      count = 0
      maxCount = 0
      minCount = 0
      numberOfCounts = 0
    }
  }
}

/// Checks if a number is prime or not.
private func isPrime(_ p: Int) -> Bool {
  if p <= 1 { return false }
  if p <= 3 { return true }
  for i in 2...Int(sqrtf(Float(p))) {
    if p % i == 0 { return false }
  }
  return true
}

#Preview {
  SharedStateView(model: SharedState().withAnchor())
}
