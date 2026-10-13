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
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.bottom, DesignSystem.Spacing.xs)
        }
        .toolbar {
            ToolbarItem {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button(action: {}) {
                        Label("Add Torrent", systemImage: "plus")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(true)
                    .help("Add torrent (Phase 4)")

                    Button(action: {}) {
                        Label("Pause All", systemImage: "pause")
                    }
                    .buttonStyle(.glass)
                    .disabled(true)
                    .help("Pause all (Phase 5)")

                    Button(action: {}) {
                        Label("Resume All", systemImage: "play")
                    }
                    .buttonStyle(.glass)
                    .disabled(true)
                    .help("Resume all (Phase 5)")
                }
            }

            ToolbarItem {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    TextField("Filter", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 170)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, 6)
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
                .padding(.leading, DesignSystem.Spacing.lg)
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Details Panel", isOn: Binding(
                        get: { !model.detailsCollapsed },
                        set: { model.detailsCollapsed = !$0 }
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
                    Image(systemName: "ellipsis.circle")
                }
                .help("More options")
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

    private func columnVisibilityBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.columnCustomization[visibility: id] != .hidden },
            set: { model.columnCustomization[visibility: id] = $0 ? .visible : .hidden }
        )
    }
}
