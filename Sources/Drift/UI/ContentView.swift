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
            TorrentListView(model: model)
        }
        .tint(DesignSystem.Palette.accent)
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .toolbar {
            ToolbarItem {
                Button(action: {}) {
                    Label("Add Torrent", systemImage: "plus")
                }
                .disabled(true)
                .padding(.horizontal, DesignSystem.Spacing.xs)
                .help("Add torrent (Phase 4)")
            }

            ToolbarItem {
                Button(action: {}) {
                    Label("Pause All", systemImage: "pause")
                }
                .disabled(true)
                .padding(.horizontal, DesignSystem.Spacing.xs)
                .help("Pause all (Phase 5)")
            }

            ToolbarItem {
                Button(action: {}) {
                    Label("Resume All", systemImage: "play")
                }
                .disabled(true)
                .padding(.horizontal, DesignSystem.Spacing.xs)
                .help("Resume all (Phase 5)")
            }

            ToolbarItem {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    TextField("Filter", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, 6)
                        .frame(width: 170)
                        .background {
                            Capsule()
                                .fill(.regularMaterial)
                            Capsule()
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        }
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
                .padding(.leading, DesignSystem.Spacing.xs)
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Menu {
                        Toggle("Details Panel", isOn: Binding(
                            get: { !model.detailsCollapsed },
                            set: { newValue in
                                withAnimation(.spring(duration: 0.35)) {
                                    model.detailsCollapsed = !newValue
                                }
                            }
                        ))

                        Divider()

                        Menu("Columns") {
                            Toggle("Status", isOn: columnVisibilityBinding("status"))
                            Toggle("Progress", isOn: columnVisibilityBinding("progress"))
                            Toggle("Size", isOn: columnVisibilityBinding("size"))
                            Toggle("DL", isOn: columnVisibilityBinding("downloadSpeed"))
                            Toggle("UP", isOn: columnVisibilityBinding("uploadSpeed"))
                            Toggle("ETA", isOn: columnVisibilityBinding("eta"))
                        }

                        Divider()

                        Button("Settings…") {}
                            .disabled(true)
                            .help("Settings (Phase 10)")
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .help("More options")

                    Button {
                        withAnimation(.spring(duration: 0.35)) {
                            model.detailsCollapsed.toggle()
                        }
                    } label: {
                        Image(systemName: model.detailsCollapsed ? "info.circle" : "info.circle.fill")
                    }
                    .help(model.detailsCollapsed ? "Expand details" : "Collapse details")
                }
            }
        }
        .navigationTitle("Drift")
        .onChange(of: sidebarVisibility) { _, _ in
            filterFocused = false
        }
        .onChange(of: filterFocused) { _, focused in
            if focused, sidebarVisibility == .detailOnly {
                filterFocused = false
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if !model.detailsCollapsed {
                DetailsPanelView(model: model)
                    .glassEffectTransition(.materialize)
                    .transition(.opacity)
            }

            StatusbarView(model: model)
        }
        .frame(maxWidth: .infinity)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: model.detailsCollapsed ? 12 : 14, style: .continuous)
        )
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.bottom, DesignSystem.Spacing.xs)
    }

    private func columnVisibilityBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.columnCustomization[visibility: id] != .hidden },
            set: { model.columnCustomization[visibility: id] = $0 ? .visible : .hidden }
        )
    }
}
