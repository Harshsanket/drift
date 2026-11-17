import SwiftUI

enum SidebarWidthPreference: PreferenceKey {
    static let defaultValue: CGFloat = 210
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct SidebarView: View {
    @Bindable var model: ListViewModel

    var body: some View {
        List(selection: $model.statusFilter) {
            searchSection
            statusSection
            if model.showCategories { categoriesSection }
            if model.showTags { tagsSection }
            if AppSettings.shared.statsEnabled { toolsSection }
        }
        .listStyle(.sidebar)
        .focusable(false)
        .onChange(of: AppSettings.shared.statsEnabled) { _, enabled in
            if !enabled, model.showStatsPane {
                model.toggleStatsPane(false)
            }
        }
        .onChange(of: model.statusFilter) { _, _ in
            model.dismissSidebarPanes()
        }
        .simultaneousGesture(TapGesture().onEnded {
            model.collapseDetailsFromOutsideClick()
        })
        // Real translucency: the window is non-opaque (TransparentWindowAttachment)
        // and this blur samples what is behind it, so the wallpaper reads through.
        // The blur also reaches up behind the traffic lights so the material is
        // continuous through the titlebar strip.
        .scrollContentBackground(.hidden)
        .background {
            BehindWindowBlur()
                .ignoresSafeArea(edges: .top)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(key: SidebarWidthPreference.self, value: geo.size.width)
            }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        Section {
            searchRow(selected: model.showSearchPane) {
                model.toggleSearchPane(!model.showSearchPane)
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            ForEach(StatusFilter.sidebarCases) { filter in
                Label {
                    HStack {
                        Text(filter.label)
                        Spacer()
                        Text("\(model.count(for: filter))")
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                } icon: {
                    Image(systemName: filter.systemImage)
                        .foregroundStyle(filter.tint)
                }
                .tag(filter)
            }
        }
    }

    @ViewBuilder
    private var categoriesSection: some View {
        Section("Categories") {
            if model.categories.isEmpty {
                Text("No categories")
                    .foregroundStyle(.tertiary)
            }
            ForEach(model.categories) { category in
                organizerRow(
                    selected: model.activeCategory == .named(category.name),
                    label: category.name
                ) {
                    model.toggleCategoryFilter(.named(category.name))
                } menu: {
                    Button {
                        model.pendingText2 = category.savePath
                        model.activeDialog = .editCategory(name: category.name)
                    } label: {
                        Label("Edit…", systemImage: "pencil")
                    }
                    .disabled(!model.isConnected)
                    Button(role: .destructive) {
                        model.removeOrganizers(categoriesNames: [category.name])
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(!model.isConnected)
                }
            }
            organizerRow(
                selected: model.activeCategory == .uncategorized,
                label: "Uncategorized"
            ) {
                model.toggleCategoryFilter(.uncategorized)
            } menu: { EmptyView() }
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        Section("Tags") {
            if model.tags.isEmpty {
                Text("No tags")
                    .foregroundStyle(.tertiary)
            }
            ForEach(model.tags, id: \.self) { tag in
                organizerRow(
                    selected: model.activeTags.contains(tag),
                    label: tag
                ) {
                    model.toggleTagFilter(tag)
                } menu: {
                    Button(role: .destructive) {
                        model.removeOrganizers(tagNames: [tag])
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(!model.isConnected)
                }
            }
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        Section("Tools") {
            paneRow(
                "Statistics",
                systemImage: "chart.bar.doc.horizontal",
                selected: model.showStatsPane,
                help: "Transfer statistics"
            ) {
                model.toggleStatsPane(!model.showStatsPane)
            }
        }
    }

    /// The search entry is styled as a persistent, padded control rather than
    /// a bare row: unselected sidebars still show a resting background, so it
    /// reads as a search entry instead of a stray section title.
    private func searchRow(selected: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            Text("Search")
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            Spacer()
            if model.searchRunning {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected
                      ? Color.accentColor.opacity(0.28)
                      : Color.primary.opacity(0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(selected ? 0 : 0.06), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help("Search Jackett or Prowlarr")
    }

    private func paneRow(
        _ title: String,
        systemImage: String,
        selected: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.28))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(help)
    }


    private func organizerRow(
        selected: Bool,
        label: String,
        action: @escaping () -> Void,
        @ViewBuilder menu: () -> some View
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.28))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .contextMenu { menu() }
    }
}
