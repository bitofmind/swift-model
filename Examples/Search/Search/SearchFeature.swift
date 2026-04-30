import SwiftModel
import SwiftUI
import Dependencies
import AsyncAlgorithms

// MARK: - Sort option

enum SortOption: String, CaseIterable, Sendable {
    case stars = "Stars"
    case name  = "Name"
}

// MARK: - FilterModel

/// Filter / sort sheet presented as an enum destination.
///
/// Demonstrates:
/// - Enum child model (`@ModelContainer`)
/// - `observeModifications()` — autosave filter preferences on any property change
@Model struct FilterModel: Sendable {
    var sortBy: SortOption = .stars
    var language: String   = ""

    func onActivate() {
        // observeModifications(kinds: .properties) fires whenever a real property changes.
        // Skipping environment/preference noise keeps autosave from triggering on UI-only changes.
        // In a real app: node.userDefaults.saveFilterPreferences(sortBy, language)
        node.forEach(observeModifications(kinds: .properties)) { _ in
            print("[FilterModel] preferences changed — would autosave here")
        }
    }

    func clearLanguage() {
        language = ""
    }
}

// MARK: - SearchResultItem

/// A single search result. Loads its expanded detail asynchronously,
/// tied to the item's lifetime (deactivated when removed from the list).
///
/// Demonstrates:
/// - Per-item async loading with `node.task` tied to item lifetime
/// - Row expand/collapse as a stored property (contrast with `node.local` in Onboarding,
///   where step-scoped transient state is not part of the child model's own data)
@Model struct SearchResultItem: Sendable, Identifiable {
    let repo: Repo
    var detailLine: String? = nil
    var isExpanded: Bool    = false

    var id: Int { repo.id }

    func onActivate() {
        // Load a short summary line asynchronously. This task is cancelled
        // automatically if the item is removed from the results list.
        // Uses `node.continuousClock` so tests can inject `ImmediateClock` to
        // skip the delay — otherwise the 200 ms real sleep outlives fast tests.
        node.task {
            // Simulate a lightweight fetch (e.g. fetching README first line).
            try await node.continuousClock.sleep(for: .milliseconds(200))
            detailLine = repo.language.map { "Written in \($0)" }
                ?? "Language unknown"
        } catch: { _ in }
    }

    func toggleExpanded() {
        isExpanded.toggle()
    }
}

// MARK: - RepoDetailModel

/// Detail sheet for a repository.
///
/// Demonstrates optional child model — exists only while the sheet is open.
@Model struct RepoDetailModel: Sendable {
    let repo: Repo
}

// MARK: - SearchModel

/// Root search model.
///
/// Demonstrates:
/// - `node.task(id:)` / `node.forEach(Observed { query }, cancelPrevious: true)` — cancel-in-flight search.
///   Each new query value cancels the previous in-flight search task before starting the next.
///   Here `query` is debounced before searching, so the full `forEach(Observed { query }.debounce(...))` form is used.
/// - `withActivation` — attach additional setup (e.g. load trending repos on launch) without
///   modifying `onActivate()` directly. Used in previews and tests.
/// - Targeted `Observed(debug:)` — prints only when `query` or `results` change, not on every
///   model mutation. Contrast with `.withDebug()` on `AppModel` which covers everything.
/// - `FilterModel` as an optional child model (filter sheet; enum destinations shown in Onboarding)
/// - `RepoDetailModel` as an optional child (detail sheet)
@Model struct SearchModel: Sendable {
    var query:        String             = ""
    var results:      [SearchResultItem] = []
    var isSearching:  Bool               = false
    var errorMessage: String?            = nil
    var filter:       FilterModel?       = nil
    var detail:       RepoDetailModel?   = nil

    @ModelDependency var gitHubClient: GitHubClient

    func onActivate() {
        // Targeted debug: print only when the *results* count changes — not on every keystroke.
        // Observing `query` here would fire on every character typed; `results.count` only
        // fires when a search completes. Compare to `.withDebug()` on AppModel which prints everything.
        node.forEach(Observed(debug: .all) { results.count }) { _ in }

        // Debounce + cancel-in-flight: wait 300 ms after the last keystroke before
        // searching, then cancel any still-running previous search.
        // `node.continuousClock` is injected via Dependencies so tests can pass
        // `ImmediateClock()` to skip the wait without changing the model code.
        node.forEach(
            Observed { query }.debounce(for: .milliseconds(300), clock: AnyClock(node.continuousClock)),
            cancelPrevious: true
        ) { q in
            await search(for: q)
        }
    }

    // MARK: - Actions

    func filterButtonTapped() {
        filter = filter ?? FilterModel()
    }

    func filterDismissed() {
        if let f = filter { applyFilter(f) }
        filter = nil
    }

    func resultTapped(_ item: SearchResultItem) {
        detail = RepoDetailModel(repo: item.repo)
    }

    func detailDismissed() {
        detail = nil
    }

    // MARK: - Private

    private func search(for q: String) async {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            isSearching = false
            return
        }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let repos = try await gitHubClient.search(trimmed)
            results = repos.map { SearchResultItem(repo: $0) }
        } catch is CancellationError {
            // Cancelled by a newer query — do nothing; next search takes over.
        } catch {
            // Keep last results visible so the user can still see what was there.
            // Surface the error (e.g. rate limit) instead of silently clearing.
            errorMessage = error.localizedDescription
        }
    }

    private func applyFilter(_ filter: FilterModel) {
        var sorted = results
        switch filter.sortBy {
        case .stars: sorted.sort { $0.repo.starCount > $1.repo.starCount }
        case .name:  sorted.sort { $0.repo.name < $1.repo.name }
        }
        let lang = filter.language.trimmingCharacters(in: .whitespaces).lowercased()
        if !lang.isEmpty {
            sorted = sorted.filter { $0.repo.language?.lowercased() == lang }
        }
        results = sorted
    }
}

// MARK: - AppModel

/// Root application model. Owns SearchModel and handles URL-based deep links.
@Model struct AppModel: Sendable {
    var search = SearchModel()

    /// Handle a deep link URL such as `githubsearch://search?q=swift`
    func handleURL(_ url: URL) {
        guard url.host() == "search",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let q = components.queryItems?.first(where: { $0.name == "q" })?.value
        else { return }
        search.query = q
    }
}

// MARK: - Views

struct AppView: View {
    @ObservedModel var model: AppModel

    var body: some View {
        SearchView(model: model.search)
            .onOpenURL { model.handleURL($0) }
    }
}

struct SearchView: View {
    @ObservedModel var model: SearchModel

    var body: some View {
        NavigationStack {
            Group {
                if model.results.isEmpty && !model.isSearching && !model.query.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else if model.results.isEmpty && model.query.isEmpty {
                    ContentUnavailableView(
                        "Search GitHub",
                        systemImage: "magnifyingglass",
                        description: Text("Enter a query to find repositories")
                    )
                } else {
                    List(model.results) { item in
                        SearchResultRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { model.resultTapped(item) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("GitHub Search")
            .searchable(text: $model.query, prompt: "Search repositories…")
            .overlay(alignment: .center) {
                if model.isSearching {
                    ProgressView()
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .overlay(alignment: .bottom) {
                if let message = model.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: model.errorMessage)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.filterButtonTapped()
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(item: $model.filter) { filter in
                FilterSheet(filter: filter, onDismiss: model.filterDismissed)
                    .presentationDetents([.medium])
            }
            .sheet(item: $model.detail) { detail in
                RepoDetailView(model: detail, onDismiss: model.detailDismissed)
                    .frame(minWidth: 360, minHeight: 280)
            }
        }
    }
}

private struct SearchResultRow: View {
    @ObservedModel var item: SearchResultItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.repo.fullName)
                        .font(.headline)
                    if let lang = item.repo.language {
                        Label(lang, systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Label("\(item.repo.starCount.formatted())", systemImage: "star")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Expand/collapse toggle — state stored in node.local, not in the parent
                Button {
                    item.toggleExpanded()
                } label: {
                    Image(systemName: item.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if item.isExpanded {
                Group {
                    if let desc = item.repo.description {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let detail = item.detailLine {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
        .animation(.default, value: item.isExpanded)
    }
}

private struct FilterSheet: View {
    @ObservedModel var filter: FilterModel
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Sort by") {
                    Picker("Sort", selection: $filter.sortBy) {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Language") {
                    HStack {
                        TextField("e.g. Swift", text: $filter.language)
                        if !filter.language.isEmpty {
                            Button("Clear", action: filter.clearLanguage)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Filter & Sort")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }
}

private struct RepoDetailView: View {
    @ObservedModel var model: RepoDetailModel
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Owner",    value: model.repo.owner)
                    LabeledContent("Stars",    value: model.repo.starCount.formatted())
                    if let lang = model.repo.language {
                        LabeledContent("Language", value: lang)
                    }
                }

                if let desc = model.repo.description {
                    Section("Description") {
                        Text(desc)
                    }
                }

                Section {
                    Link("View on GitHub", destination: model.repo.htmlURL)
                }
            }
            .navigationTitle(model.repo.name)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Default") {
    AppView(model: AppModel().withAnchor())
}

#Preview("Pre-populated") {
    // withActivation injects extra setup after onActivate() without touching onActivate() itself.
    // Here we pre-fill results so the preview opens in a populated state.
    AppView(model: AppModel()
        .withActivation { app in
            app.search.results = Repo.mocks.map { SearchResultItem(repo: $0) }
            app.search.query   = "swift"
        }
        .withAnchor()
    )
}
