import SwiftUI

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

            Section("Categories") {
                Text("No categories")
                    .foregroundStyle(.tertiary)
            }

            Section("Tags") {
                Text("No tags")
                    .foregroundStyle(.tertiary)
            }
        }
        .listStyle(.sidebar)
        .focusable(false)
        // Keeps the frosted sidebar material: the split view supplies the native
        // `NSGlassEffectView` column background, and this adds the system
        // `.ultraThinMaterial` vibrancy on top so the wallpaper reads through
        // and the sidebar stays light rather than a flat dark panel.
        .scrollContentBackground(.hidden)
        .background(.ultraThinMaterial)
    }
}
