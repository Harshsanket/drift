import SwiftUI

struct SourcesTabView: View {
    @Bindable var model: ListViewModel
    let torrentID: String
    let rows: [WebSeedRow]

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button {
                    model.requestAddWebSeed()
                } label: {
                    Label("Add web seed…", systemImage: "plus")
                }
                .disabled(!model.isConnected || torrentID.isEmpty)

                Spacer()
            }

            if rows.isEmpty {
                DetailsEmptyState(title: "No web seeds", systemImage: "link")
            } else {
                Table(rows) {
                    TableColumn("URL") { row in
                        Text(row.url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contextMenu {
                                Button("Edit…") {
                                    model.requestEditWebSeed(row.url)
                                }
                                .disabled(!model.isConnected)
                                Button("Delete") {
                                    model.removeWebSeeds([row.url])
                                }
                                .disabled(!model.isConnected)
                            }
                    }
                }
                .scrollContentBackground(.hidden)
                .frame(height: 178)
            }
        }
    }
}
