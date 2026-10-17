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
            Section("Status") {
                ForEach(StatusFilter.allCases) { filter in
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

            if model.showCategories {
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
                    } menu: {}
                }
            }

            if model.showTags {
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
        }
        .listStyle(.sidebar)
        .focusable(false)
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
