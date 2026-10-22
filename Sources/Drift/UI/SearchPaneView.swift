import SwiftUI

/// Full-pane server search. Unlike the old sheet, it lives in the detail
/// column so results, the query bar, and the footer never overlap and the
/// sidebar stays interactive while a search runs.
struct SearchPaneView: View {
    @Bindable var model: ListViewModel
    @Environment(\.openWindow) private var openWindow

    @State private var pattern = ""
    @FocusState private var patternFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            content
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            pattern = model.searchQuery
            if pattern.isEmpty {
                patternFocused = true
            }
            if !model.searchPluginsLoaded {
                model.loadSearchPlugins()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Server Search")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.searchRunning {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Manage Plugins…") {
                openWindow(id: "settings")
            }
            .buttonStyle(.bordered)
            .help("Enable, install, update, or remove search plugins")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var headerSubtitle: String {
        if model.searchRunning {
            return "Searching every enabled plugin on the server…"
        }
        guard model.searchPluginsLoaded else {
            return "Searches every enabled plugin on the server."
        }
        let enabled = model.searchPlugins.filter(\.enabled).count
        switch enabled {
        case 0: return "No plugins are enabled — install or enable one in Settings."
        case 1: return "1 enabled plugin"
        default: return "\(enabled) enabled plugins"
        }
    }

    // MARK: - Query bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search pattern (all enabled plugins)", text: $pattern)
                .textFieldStyle(.roundedBorder)
                .focused($patternFocused)
                .onSubmit(submit)

            if model.searchRunning {
                Button("Stop") {
                    model.stopSearch()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Search", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        pattern.trimmingCharacters(in: .whitespaces).isEmpty
                            || !model.isConnected
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func submit() {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.startSearch(pattern: trimmed)
    }

    // MARK: - Results

    @ViewBuilder
    private var content: some View {
        if model.searchRunning || !model.searchResults.isEmpty {
            resultTable
        } else if let notice = model.searchNotice {
            emptyState(icon: "magnifyingglass", text: notice)
        } else {
            emptyState(
                icon: "globe",
                text: "Search the connected qBittorrent through its plugins; results land here as they arrive."
            )
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
        .contextMenu(forSelectionType: SearchResult.self) { selection in
            searchResultMenu(selection)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func searchResultMenu(_ selection: Set<SearchResult>) -> some View {
        if let result = selection.first {
            Button("Download") { model.downloadSearchResult(result) }
            Button("Copy Title") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.fileName, forType: .string)
            }
            Button("Open Page") {
                if let url = URL(string: result.siteURL),
                   let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .padding(.top, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(
                "\(model.searchResults.count) result\(model.searchResults.count == 1 ? "" : "s")"
                    + (model.searchRunning ? " · still running" : "")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            Spacer()

            Button("Clear") {
                model.clearSearchResults()
            }
            .buttonStyle(.bordered)
            .disabled(model.searchResults.isEmpty && !model.searchRunning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
