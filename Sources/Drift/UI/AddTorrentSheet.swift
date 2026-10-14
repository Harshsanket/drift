import SwiftUI
import UniformTypeIdentifiers

struct AddTorrentSheet: View {
    @Bindable var model: ListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var sourceText = ""
    @State private var sourceFile: URL?
    @AppStorage("addTorrent.destination") private var destination = "~/Downloads"
    @State private var showFileImporter = false
    @State private var showDestinationImporter = false

    private static var torrentType: UTType {
        UTType(filenameExtension: "torrent") ?? .data
    }

    private var trimmed: String {
        sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var textIsValid: Bool {
        let lower = trimmed.lowercased()
        return lower.hasPrefix("magnet:")
            || lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
    }

    private var showValidationError: Bool {
        !trimmed.isEmpty && !textIsValid && sourceFile == nil
    }

    private var canAdd: Bool {
        sourceFile != nil || (textIsValid && !trimmed.contains(where: \.isNewline))
    }

    private var destinationDisplay: String {
        NSString(string: destination).expandingTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Torrent")
                .font(.headline)

            TextField("magnet:?xt=… or https://…", text: $sourceText)
                .textFieldStyle(.roundedBorder)

            Text("Or choose a .torrent file")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                Text(sourceFile?.lastPathComponent ?? "No file selected")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(sourceFile == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Spacer()
                Button("Choose…") { showFileImporter = true }
            }

            Text("Destination")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(destinationDisplay)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { showDestinationImporter = true }
            }

            if showValidationError {
                Text("Not a valid magnet link or URL")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    let source: AddSource = sourceFile.map { .torrentFile($0) }
                        ?? .magnetOrURL(trimmed)
                    model.confirmAdd(source: source, savePath: destination)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 480)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [Self.torrentType],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                sourceFile = url
            }
        }
        .fileImporter(
            isPresented: $showDestinationImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                destination = url.path
            }
        }
    }
}
