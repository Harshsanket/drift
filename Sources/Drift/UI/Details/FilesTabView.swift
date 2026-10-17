import SwiftUI

struct FilesTabView: View {
    let rows: [FileRow]
    var onPriority: (FileRow, FilePriority) -> Void = { _, _ in }

    var body: some View {
        if rows.isEmpty {
            DetailsEmptyState(title: "No files", systemImage: "folder")
        } else {
            Table(rows) {
                TableColumn("Name") { row in
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 200, ideal: 300)

                TableColumn("Size") { row in
                    Text(DesignSystem.Format.size(row.size))
                        .monospacedDigit()
                }
                .width(90)

                TableColumn("Progress") { row in
                    Text(DesignSystem.Format.percent(row.progress))
                        .monospacedDigit()
                }
                .width(80)

                TableColumn("Priority") { row in
                    Menu {
                        ForEach(FilePriority.allCases, id: \.self) { priority in
                            Button {
                                onPriority(row, priority)
                            } label: {
                                if priority == row.priority {
                                    Label(priority.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(priority.rawValue)
                                }
                            }
                        }
                    } label: {
                        Text(row.priority.rawValue)
                            .font(.caption)
                            .padding(.horizontal, DesignSystem.Spacing.xs)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                            .foregroundStyle(row.priority == .ignored ? .tertiary : .secondary)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .width(90)
            }
            .scrollContentBackground(.hidden)
            .frame(height: 190)
        }
    }
}
