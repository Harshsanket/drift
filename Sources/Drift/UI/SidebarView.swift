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
                    Text("No categories")
                        .foregroundStyle(.tertiary)
                }
            }

            if model.showTags {
                Section("Tags") {
                    Text("No tags")
                        .foregroundStyle(.tertiary)
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
}
