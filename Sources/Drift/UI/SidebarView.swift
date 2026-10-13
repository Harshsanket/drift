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
    }
}
