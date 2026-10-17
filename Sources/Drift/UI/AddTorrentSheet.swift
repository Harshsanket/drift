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

    @State private var startTorrent = true
    @State private var skipChecking = false
    @State private var sequentialDownload = false
    @State private var firstLastPiecePriority = false
    @State private var autoManaged = true
    @State private var contentLayout: ContentLayout = .original
    @State private var selectedCategory: String?
    @State private var tagsText = ""

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

            Text("Torrent options")
                .font(.caption)
                .foregroundStyle(.secondary)

            optionsGrid

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
                    let tags = tagsText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    model.confirmAdd(
                        source: source,
                        options: AddOptions(
                            savePath: destination,
                            category: selectedCategory,
                            tags: tags,
                            startAutomatically: startTorrent,
                            skipChecking: skipChecking,
                            sequentialDownload: sequentialDownload,
                            firstLastPiecePriority: firstLastPiecePriority,
                            contentLayout: contentLayout,
                            autoManaged: autoManaged
                        )
                    )
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let handoff = model.pendingAddHandoff {
                switch handoff {
                case .magnetOrURL(let text):
                    sourceText = text
                case .torrentFile(let url):
                    sourceFile = url
                }
                model.pendingAddHandoff = nil
            }
        }
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

    private var optionsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("Category")
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("Category", selection: $selectedCategory) {
                        Text("—").tag(String?.none)
                        ForEach(model.categories) { category in
                            Text(category.name).tag(String?.some(category.name))
                        }
                    }
                    .labelsHidden()
                    Spacer()
                }
            }
            GridRow {
                Text("Tags")
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("comma, separated", text: $tagsText)
                        .textFieldStyle(.roundedBorder)
                    Spacer()
                }
            }
            GridRow {
                Text("Layout")
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("Content layout", selection: $contentLayout) {
                        ForEach(ContentLayout.allCases, id: \.self) { layout in
                            Text(layout.label).tag(layout)
                        }
                    }
                    .fixedSize()
                    Spacer()
                }
            }
            GridRow(alignment: .top) {
                Text("Toggles")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Start torrent", isOn: $startTorrent)
                    Toggle("Automatic torrent management", isOn: $autoManaged)
                    Toggle("Sequential download", isOn: $sequentialDownload)
                    Toggle("First & last piece priority", isOn: $firstLastPiecePriority)
                    Toggle("Skip hash check", isOn: $skipChecking)
                }
            }
        }
    }
}

extension ContentLayout {
    var label: String {
        switch self {
        case .original: "Automatic"
        case .subfolder: "Create subfolder"
        case .noSubfolder: "No subfolder"
        }
    }
}
