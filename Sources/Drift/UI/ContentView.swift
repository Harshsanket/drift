import SwiftUI

struct ContentView: View {
    @Bindable var model: ListViewModel
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    @FocusState private var filterFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            VStack(spacing: 0) {
                TorrentListView(model: model)
                Divider()
                DetailsPanelView(model: model)
            }
        }
        .tint(DesignSystem.Palette.accent)
        .safeAreaInset(edge: .bottom) {
            StatusbarView(model: model)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: {}) {
                    Label("Add Torrent", systemImage: "plus")
                }
                .disabled(true)
                .help("Add torrent (Phase 4)")

                Button(action: {}) {
                    Label("Pause All", systemImage: "pause")
                }
                .disabled(true)
                .help("Pause all (Phase 5)")

                Button(action: {}) {
                    Label("Resume All", systemImage: "play")
                }
                .disabled(true)
                .help("Resume all (Phase 5)")

                Menu {
                    Toggle("Status", isOn: columnVisibilityBinding("status"))
                    Toggle("Progress", isOn: columnVisibilityBinding("progress"))
                    Toggle("Size", isOn: columnVisibilityBinding("size"))
                    Toggle("DL", isOn: columnVisibilityBinding("downloadSpeed"))
                    Toggle("UP", isOn: columnVisibilityBinding("uploadSpeed"))
                    Toggle("ETA", isOn: columnVisibilityBinding("eta"))
                } label: {
                    Image(systemName: "tablecells")
                }
                .help("Column visibility")

                HStack(spacing: DesignSystem.Spacing.xs) {
                    TextField("Filter", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .focused($filterFocused)
                    if !model.searchText.isEmpty {
                        Button {
                            model.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear filter")
                    }
                }

                Button {
                    model.detailsCollapsed.toggle()
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
                .help("Toggle details panel")
            }
        }
        .navigationTitle("Drift")
        .onChange(of: sidebarVisibility) { _, _ in
            filterFocused = false
        }
    }

    private func columnVisibilityBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.columnCustomization[visibility: id] != .hidden },
            set: { model.columnCustomization[visibility: id] = $0 ? .visible : .hidden }
        )
    }
}
