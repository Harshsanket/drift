import SwiftUI

/// Splash-level decision surface for updates: nothing auto-installs
/// silently; the user explicitly picks "Update now" (which hands off to
/// Sparkle's verified download + install flow) or "Later" (re-asks once per
/// session).
struct UpdatePromptSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch UpdateService.shared.state {
            case .available(let version):
                Text("Drift \(version) is ready")
                    .font(.headline)
                Text("""
                    A verified update is available. The package is \
                    checked with the release key before anything runs.
                    """)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Update now") {
                        UpdateService.shared.install()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Later", role: .cancel) {
                        dismiss()
                    }
                }
                .padding(.top, 4)
            case .checking:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for updates…")
                }
                Button("Later", role: .cancel) { dismiss() }
            case .idle, .none:
                Text("You are up to date.")
                    .font(.headline)
                Text("Sparkle found no newer verified update on the configured feed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Close", role: .cancel) { dismiss() }
            case .error(let message):
                Text("Update check failed")
                    .font(.headline)
                Text(message.isEmpty ? "Unknown error." : message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Try again") {
                        UpdateService.shared.check(userInitiated: true)
                    }
                    Button("Close", role: .cancel) { dismiss() }
                }
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}
