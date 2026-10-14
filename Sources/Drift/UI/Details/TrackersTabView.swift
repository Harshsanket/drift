import SwiftUI

struct TrackersTabView: View {
    let rows: [TrackerRow]

    var body: some View {
        if rows.isEmpty {
            DetailsEmptyState(title: "No trackers", systemImage: "antenna.radiowaves.left.and.right")
        } else {
            Table(rows) {
                TableColumn("URL") { row in
                    Text(row.url)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
            .frame(height: 190)
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
