import SwiftUI

struct PeersTabView: View {
    let rows: [PeerRow]

    var body: some View {
        if rows.isEmpty {
            DetailsEmptyState(title: "No peers connected", systemImage: "person.2.slash")
        } else {
            Table(rows) {
                TableColumn("IP") { row in
                    Text(row.ip)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .width(min: 130, ideal: 150)

                TableColumn("Client") { row in
                    Text(row.client)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .width(min: 120, ideal: 150)

                TableColumn("Flags") { row in
                    Text(row.flags)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
                .width(55)

                TableColumn("Progress") { row in
                    Text(DesignSystem.Format.percent(row.progress))
                        .monospacedDigit()
                }
                .width(80)

                TableColumn("DL") { row in
                    Text(DesignSystem.Format.speed(row.downSpeed))
                        .monospacedDigit()
                        .foregroundStyle(
                            row.downSpeed > 0 ? DesignSystem.Palette.downloading : .secondary
                        )
                }
                .width(90)

                TableColumn("UP") { row in
                    Text(DesignSystem.Format.speed(row.upSpeed))
                        .monospacedDigit()
                        .foregroundStyle(
                            row.upSpeed > 0 ? DesignSystem.Palette.seeding : .secondary
                        )
                }
                .width(90)

                TableColumn("Connection") { row in
                    Text(row.connection)
                        .foregroundStyle(.secondary)
                }
                .width(80)
            }
            .frame(height: 190)
        }
    }
}
