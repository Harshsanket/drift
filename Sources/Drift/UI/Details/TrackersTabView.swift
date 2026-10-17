import SwiftUI

struct TrackersTabView: View {
    @Bindable var model: ListViewModel
    let torrentID: String
    let rows: [TrackerRow]

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    model.requestAddTracker()
                } label: {
                    Label("Add tracker…", systemImage: "plus")
                }
                .disabled(!model.isConnected || torrentID.isEmpty)

                Button {
                    model.reannounceTrackers()
                } label: {
                    Label("Reannounce", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(!model.isConnected || torrentID.isEmpty)

                Spacer()
            }

            if rows.isEmpty {
                DetailsEmptyState(title: "No trackers", systemImage: "antenna.radiowaves.left.and.right")
            } else {
                Table(rows) {
                    TableColumn("URL") { row in
                        Text(row.url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contextMenu {
                                Button("Edit…") {
                                    model.requestEditTracker(row.url)
                                }
                                .disabled(!model.isConnected)
                                Button("Delete") {
                                    model.removeTrackers([row.url])
                                }
                                .disabled(!model.isConnected)
                            }
                    }
                    .width(min: 220, ideal: 340)

                    TableColumn("Status") { row in
                        Text(row.status)
                            .foregroundStyle(statusColor(row.status))
                    }
                    .width(130)

                    TableColumn("Peers") { row in
                        Text("\(row.peers)")
                            .monospacedDigit()
                    }
                    .width(60)

                    TableColumn("Seeds") { row in
                        Text("\(row.seeds)")
                            .monospacedDigit()
                    }
                    .width(60)

                    TableColumn("Leeches") { row in
                        Text("\(row.leeches)")
                            .monospacedDigit()
                    }
                    .width(70)

                    TableColumn("Downloaded") { row in
                        Text(DesignSystem.Format.size(row.downloaded))
                            .monospacedDigit()
                    }
                    .width(100)
                }
                .scrollContentBackground(.hidden)
                .frame(height: 178)
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "Working": DesignSystem.Palette.connectionOK
        case "Not working": DesignSystem.Palette.connectionDown
        default: .secondary
        }
    }
}
