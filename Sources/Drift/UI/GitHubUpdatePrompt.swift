import SwiftUI

/// Launch/prompt surface for GitHub-based updates (no Sparkle feed needed):
/// lets the user open the release page now or dismiss until the next check.
struct GitHubUpdatePrompt: View {
    @Environment(\.dismiss) private var dismiss
    private var updates = UpdateChecker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if updates.checking {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for updates…")
                }
            }
            switch updates.status {
            case .available(let version, let url):
                Text("Drift \(version) is available")
                    .font(.headline)
                Text("You are running v\(updates.appVersion). Download and install the new version now, or keep using this one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Download and Update") {
                        NSWorkspace.shared.open(url)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Later", role: .cancel) {
                        dismiss()
                    }
                }
                .padding(.top, 4)
            case .idle, .upToDate:
                Text("You are up to date.")
                    .font(.headline)
                Text("No newer release was found on GitHub.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Close", role: .cancel) { dismiss() }
            case .noReleases:
                Text("No releases yet")
                    .font(.headline)
                Text("The GitHub repository has no published releases.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Close", role: .cancel) { dismiss() }
            case .failed(let message):
                Text("Update check failed")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Try again") {
                        Task { await updates.check() }
                    }
                    Button("Close", role: .cancel) { dismiss() }
                }
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}
