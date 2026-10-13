import SwiftUI

struct ContentView: View {
    @Bindable var model: ListViewModel

    var body: some View {
        NavigationSplitView {
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

                TextField("Filter", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                Button {
                    model.detailsCollapsed.toggle()
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
                .help("Toggle details panel")
            }
        }
        .navigationTitle("Drift")
    }
}
