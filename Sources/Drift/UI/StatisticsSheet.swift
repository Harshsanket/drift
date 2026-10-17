import SwiftUI

struct StatisticsSheet: View {
    @Bindable var model: ListViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Statistics")
                .font(.headline)

            if let stats = model.statistics {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: DesignSystem.Spacing.lg,
                    verticalSpacing: DesignSystem.Spacing.xs
                ) {
                    row("Downloaded this session") {
                        Text(DesignSystem.Format.size(stats.received))
                    }
                    row("Uploaded this session") {
                        Text(DesignSystem.Format.size(stats.sent))
                    }
                    row("Wasted this session") {
                        Text(DesignSystem.Format.size(stats.wasted))
                    }
                    row("Downloaded (all time)") {
                        Text(DesignSystem.Format.size(stats.receivedAllTime))
                    }
                    row("Uploaded (all time)") {
                        Text(DesignSystem.Format.size(stats.sentAllTime))
                    }
                    row("Global share ratio") {
                        Text(String(format: "%.2f", stats.globalRatio))
                    }
                    row("Free space on server") {
                        Text(DesignSystem.Format.size(max(0, stats.freeSpaceOnDisk)))
                    }
                }
            } else {
                Text("Start a connection to collect transfer statistics.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Refresh") {
                    model.statistics = nil
                    model.refresh()
                }
                .disabled(!model.isConnected)
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder
    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            value()
                .monospacedDigit()
        }
    }
}
