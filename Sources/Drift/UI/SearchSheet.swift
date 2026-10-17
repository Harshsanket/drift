import SwiftUI

/// Server-plugin search, presented as a sheet. Starts the plugin job, polls
/// for results, and offers Download/Clear actions.
struct SearchSheet: View {
    @Bindable var model: ListViewModel

    @State private var pattern = ""
    @FocusState private var patternFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search pattern (all enabled plugins)", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .focused($patternFocused)
                    .onSubmit { model.startSearch(pattern: pattern) }

                if model.searchRunning {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 4)
                    Button("Stop") {
                        model.stopSearch()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Search") {
                        model.startSearch(pattern: pattern)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)

            Divider()

            if model.searchRunning || !model.searchResults.isEmpty {
                resultTable
            } else {
                VStack {
                    Text("Search the connected qBittorrent through its plugins; results land here as they arrive.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 720, height: 480)
        .onAppear {
            pattern = model.searchQuery
            if !pattern.isEmpty { model.startSearch(pattern: pattern) }
        }
    }

    private var resultTable: some View {
        Table(model.searchResults) {
            TableColumn("Name") { result in
                Text(result.fileName).lineLimit(1)
            }
            TableColumn("Engine") { result in
                Text(result.engineName).lineLimit(1)
            }
            TableColumn("Size") { result in
                Text(ByteCountFormatter.string(fromByteCount: result.fileSize, countStyle: .binary))
            }
            TableColumn("Seeds") { result in
                Text(result.seeders.description)
            }
            TableColumn("Leechers") { result in
                Text(result.leechers.description)
            }
            TableColumn("Site") { result in
                Text(result.siteURL).lineLimit(1)
            }
            TableColumn("") { result in
                Button("Download") {
                    model.downloadSearchResult(result)
                }
                .controlSize(.small)
            }
            .width(84)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(
                    "\(model.searchResults.count) result\(model.searchResults.count == 1 ? "" : "s")"
                        + (model.searchRunning ? " · still running" : "")
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Clear") {
                    model.clearSearchResults()
                }
                .buttonStyle(.bordered)
                .disabled(model.searchResults.isEmpty && !model.searchRunning)

                Button("Done") {
                    if model.searchRunning { model.stopSearch() }
                    model.showSearchPane = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity)
    }
}
