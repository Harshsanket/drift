import SwiftUI

struct PeersTabView: View {
    let rows: [PeerRow]
    var ban: ([PeerRow]) -> Void = { _ in }

    @State private var selection = Set<String>()

    private var selectedRows: [PeerRow] {
        rows.filter { selection.contains($0.id) }
    }

    var body: some View {
        if rows.isEmpty {
            DetailsEmptyState(title: "No peers connected", systemImage: "person.2.slash")
        } else {
            Table(rows, selection: $selection) {
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
                .width(min: 110, ideal: 140)

                TableColumn("Country") { row in
                    Text(row.country.isEmpty
                         ? "—"
                         : row.countryCode.isEmpty ? row.country : row.countryCode)
                        .foregroundStyle(.secondary)
                }
                .width(70)

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
                .width(75)

                TableColumn("DL") { row in
                    Text(DesignSystem.Format.speed(row.downSpeed))
                        .monospacedDigit()
                        .foregroundStyle(
                            row.downSpeed > 0 ? DesignSystem.Palette.downloading : .secondary
                        )
                }
                .width(85)

                TableColumn("UP") { row in
                    Text(DesignSystem.Format.speed(row.upSpeed))
                        .monospacedDigit()
                        .foregroundStyle(
                            row.upSpeed > 0 ? DesignSystem.Palette.seeding : .secondary
                        )
                }
                .width(85)

                TableColumn("Connection") { row in
                    Text(row.connection)
                        .foregroundStyle(.secondary)
                }
                .width(70)
            }
            .scrollContentBackground(.hidden)
            .frame(height: 190)
            .contextMenu {
                Button("Ban Permanently", systemImage: "person.fill.xmark") {
                    ban(selectedRows)
                }
                .disabled(selectedRows.isEmpty)
            }
            .help("Right-click to ban selected peers (server-side permanent IP ban)")
        }
    }
}
