import SwiftModel
import SwiftUI
import SwiftUINavigation

// MARK: - CounterTab

@Model
struct CounterTab {
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
    ScrollView {
      VStack(spacing: 24) {
        // Counter stepper
        HStack(spacing: 20) {
          Button {
            model.decrementButtonTapped()
          } label: {
            Image(systemName: "minus.circle.fill")
              .imageScale(.large)
          }
          Text("\(model.stats.count)")
            .font(.title.monospacedDigit())
            .frame(minWidth: 40, alignment: .center)
          Button {
            model.incrementButtonTapped()
          } label: {
            Image(systemName: "plus.circle.fill")
              .imageScale(.large)
          }
        }
        .buttonStyle(.borderless)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

        // Stats card
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
          GridRow {
            Text("Max").foregroundStyle(.secondary)
            Text("\(model.stats.maxCount)").monospacedDigit()
          }
          GridRow {
            Text("Min").foregroundStyle(.secondary)
            Text("\(model.stats.minCount)").monospacedDigit()
          }
          GridRow {
            Text("Total events").foregroundStyle(.secondary)
            Text("\(model.stats.numberOfCounts)").monospacedDigit()
          }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

        Button("Check if \(model.stats.count) is prime") {
          model.isPrimeButtonTapped()
        }
        .buttonStyle(.bordered)
      }
      .padding()
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Counter")
    .alert($model.alert)
  }
}

// MARK: - ProfileTab

@Model
struct ProfileTab {
  var stats: Stats

  func resetStatsButtonTapped() {
    stats.reset()
  }
}

struct ProfileTabView: View {
  @ObservedModel var model: ProfileTab

  var body: some View {
    VStack(spacing: 24) {
      Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
        GridRow {
          Text("Count").foregroundStyle(.secondary)
          Text("\(model.stats.count)").monospacedDigit().bold()
        }
        GridRow {
          Text("Max").foregroundStyle(.secondary)
          Text("\(model.stats.maxCount)").monospacedDigit()
        }
        GridRow {
          Text("Min").foregroundStyle(.secondary)
          Text("\(model.stats.minCount)").monospacedDigit()
        }
        GridRow {
          Text("Events").foregroundStyle(.secondary)
          Text("\(model.stats.numberOfCounts)").monospacedDigit()
        }
      }
      .padding()
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

      Button("Reset", role: .destructive) { model.resetStatsButtonTapped() }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle("Profile")
  }
}

// MARK: - SharedState (root)

@Model
struct SharedState {
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

// MARK: - Stats

@Model
struct Stats: Equatable {
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

// MARK: - Helpers

/// Checks if a number is prime or not.
private func isPrime(_ p: Int) -> Bool {
  if p <= 1 { return false }
  if p <= 3 { return true }
  for i in 2...Int(sqrtf(Float(p))) {
    if p % i == 0 { return false }
  }
  return true
}

#Preview("Main") {
  SharedStateView(model: SharedState().withAnchor())
}

#Preview("Profile") {
  NavigationStack {
    ProfileTabView(model: ProfileTab(stats: Stats()).withAnchor())
  }
}
