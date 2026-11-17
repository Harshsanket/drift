import SwiftUI

/// Asked when a torrent has no usable HTTP web seed. A piece booster cannot
/// invent bytes; the user must point it at a direct HTTP(S) mirror.
struct BoostSourceSheet: View {
    @Bindable var model: ListViewModel

    private var mirrorIsValid: Bool {
        let text = model.boostMirrorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        return url.host != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Boost \(model.boostTarget?.name ?? "torrent")")
                .font(.headline)
            Text("This torrent has no HTTP web seed. Paste a direct HTTP(S) mirror of the torrent's files. Drift fetches missing pieces in parallel, verifies every piece against the .torrent SHA-1, writes them, then rechecks the torrent.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://mirror.example/file.iso", text: $model.boostMirrorText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if mirrorIsValid { model.confirmBoostMirror() } }
            Text("A mirror must serve the exact file bytes for this torrent. Without a web seed or mirror, no HTTP booster can accelerate it — libtorrent's peer engine is already doing the only possible work.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelBoostMirror() }
                    .keyboardShortcut(.cancelAction)
                Button("Boost") { model.confirmBoostMirror() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!mirrorIsValid)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
