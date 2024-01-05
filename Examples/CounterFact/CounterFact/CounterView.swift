import Foundation
import SwiftUI
import SwiftModel
import Dependencies

@Model struct CounterModel: Sendable {
    fileprivate(set) var alert: Alert?
    private(set) var count: Int
    let onFact: @Sendable (Int, String) -> Void

    @Model struct Alert: Sendable {
        var message: String
        var title: String
    }

    func decrementTapped() {
        count -= 1
    }

    func incrementTapped() {
        count += 1
    }

    func factButtonTapped() {
        node.task {
            onFact(count, try await node.factClient.fetch(count))
        } catch: { _ in
            alert = Alert(message: "Couldn't load fact.", title: "Error")
        }
    }
}

struct CounterView: View {
    @ObservedModel var model: CounterModel

    var body: some View {
        VStack {
            HStack {
                Button("-") { model.decrementTapped() }
                Text("\(model.count)")
                Button("+") { model.incrementTapped() }

                Button("Fact") { model.factButtonTapped() }
            }
        }
        .alert(item: $model.alert) { alert in
          Alert(
            title: Text(alert.title),
            message: Text(alert.message)
          )
        }
    }
}

@Model struct CounterRowModel: Sendable {
    private(set) var counter: CounterModel
    let onRemove: @Sendable (Self) -> Void

    func removeButtonTapped() {
        onRemove(self)
    }
}

struct CounterRowView: View {
    @ObservedModel var model: CounterRowModel

    var body: some View {
        HStack {
            CounterView(model: model.counter)

            Spacer()

            Button("Remove") {
                model.removeButtonTapped()
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

@Model struct AppModel: Sendable {
    private(set) var counters: [CounterRowModel] = []
    private(set) var factPrompt: FactPromptModel?

    var sum: Int {
        counters.reduce(0) { $0 + $1.counter.count }
    }

    func addButtonTapped() {
        let counter = CounterModel(count: 0) { count, fact in
            factPrompt = FactPromptModel(count: count, fact: fact) {
                factPrompt = nil
            }
        }
        
        let row = CounterRowModel(counter: counter) { counter in
            counters.removeAll { [id = counter.id] in
                $0.id == id
            }
        }
            
        counters.append(row)
    }

    func factDismissTapped() {
        factPrompt = nil
    }
}

struct AppView: View {
    @ObservedModel var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                Text("Sum: \(model.sum)")

                ForEach(model.counters) { row in
                    CounterRowView(model: row)
                }
            }
            .animation(.default, value: model.counters.count)
            .navigationTitle("Counters")
            .toolbar {
                Button("Add") {
                    model.addButtonTapped()
                }
            }

            if let factPrompt = model.factPrompt {
                FactPromptView(model: factPrompt)
            }
        }
    }
}

@Model struct FactPromptModel: Sendable {
    let count: Int
    private(set) var fact: String
    private(set) var isLoading = false
    let onDismiss: @Sendable () -> Void

    func getAnotherFactButtonTapped() {
        node.task {
            isLoading = true
            defer { isLoading = false }
            fact = try await node.factClient.fetch(count)
        } catch: { _ in }
    }

    func dismissTapped() {
        onDismiss()
    }
}

struct FactPromptView: View {
    @ObservedModel var model: FactPromptModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "info.circle.fill")
                    Text("Fact")
                }
                .font(.title3.bold())

                if model.isLoading {
                    ProgressView()
                } else {
                    Text(model.fact)
                }
            }

            HStack(spacing: 12) {
                Button("Get another fact") {
                    model.getAnotherFactButtonTapped()
                }

                Button("Dismiss") {
                    model.dismissTapped()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 20)
        .padding()
    }
}

struct CounterView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AppView(model: AppModel().withAnchor())
        }
    }
}
