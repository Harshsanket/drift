import SwiftUI

struct SourcesTabView: View {
    let rows: [WebSeedRow]

    var body: some View {
        if rows.isEmpty {
            DetailsEmptyState(title: "No web seeds", systemImage: "link")
        } else {
            Table(rows) {
                TableColumn("URL") { row in
                    Text(row.url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .scrollContentBackground(.hidden)
            .frame(height: 190)
        }
    }
}
