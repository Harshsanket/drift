import SwiftUI

// MARK: - Shared chrome surface

/// The single Liquid Glass surface shared by every piece of window chrome, so
/// the header and the floating status bar read as one design. This is the
/// system material, so it adapts to the appearance, the window's active state
/// and the Reduce Transparency setting on its own.
extension View {
    func capsuleSurface() -> some View {
        glassEffect(.regular, in: Capsule(style: .continuous))
    }
}

/// Shared style for the circular header controls: uniform hit target, subtle
/// hover fill, pressed highlight and a dimmed disabled state.
struct CapsuleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CapsuleIconButtonBody(configuration: configuration)
    }
}

private struct CapsuleIconButtonBody: View {
    let configuration: CapsuleIconButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: DesignSystem.Metrics.iconSize, weight: .medium))
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .frame(
                width: DesignSystem.Metrics.controlHeight,
                height: DesignSystem.Metrics.controlHeight
            )
            .background {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(highlight))
            }
            .capsuleSurface()
            .contentShape(Capsule(style: .continuous))
            .onHover { hovering in
                guard isEnabled else { return }
                isHovering = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var highlight: Double {
        guard isEnabled else { return 0 }
        if configuration.isPressed { return 0.16 }
        return isHovering ? 0.09 : 0
    }
}

/// A single circular control in the header.
struct CapsuleIconButton: View {
    let systemImage: String
    let title: String
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(CapsuleIconButtonStyle())
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

// MARK: - Titlebar leading: traffic lights

/// Occupies the leading edge of the titlebar strip, directly after the native
/// traffic lights. The sidebar is permanent, so there is no toggle here, and
/// the app title lives above the torrent table's first columns instead.
struct HeaderLeadingControls: View {
    var body: some View {
        HStack(spacing: 0) {
            // Reserve the traffic-light cluster without swallowing its clicks.
            Color.clear
                .frame(width: DesignSystem.Metrics.trafficLightInset)
                .allowsHitTesting(false)
        }
        .frame(height: DesignSystem.Metrics.headerHeight)
    }
}

// MARK: - Titlebar trailing: separated action controls

/// The ChatGPT-style action cluster: each control owns its own translucent
/// capsule, and only Pause/Resume share one container as a logical pair.
struct HeaderTrailingControls: View {
    @Bindable var model: ListViewModel
    /// Width of the titlebar row, used to keep the controls responsive.
    let availableWidth: CGFloat
    @FocusState.Binding var filterFocused: Bool

    var body: some View {
        let fit = HeaderFit(width: availableWidth)
        HStack(spacing: DesignSystem.Metrics.controlGap) {
            // Add Torrent — disabled until a connection exists: adds go to
            // qBittorrent, so there is nothing to add to while disconnected.
            CapsuleIconButton(
                systemImage: "plus",
                title: "Add Torrent",
                help: model.isConnected
                    ? "Add torrent"
                    : "Connect to qBittorrent first",
                action: { model.showAddSheet = true }
            )
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!model.isConnected)

            TransportControls(model: model)

            PrivacyChip(widthBudget: fit.privacyBudget)

            FilterField(
                text: $model.searchText,
                isFocused: $filterFocused,
                width: fit.filterWidth,
                collapseDetails: { model.collapseDetailsFromOutsideClick() }
            )

            MoreOptionsMenu(model: model)

            if fit.showsInfoButton {
                CapsuleIconButton(
                    systemImage: model.detailsCollapsed ? "info.circle" : "info.circle.fill",
                    title: model.detailsCollapsed ? "Expand details" : "Collapse details",
                    action: {
                        writeProbeLog("[ui] header info button")
                        model.toggleDetails()
                    }
                )
            }
        }
        .padding(.trailing, DesignSystem.Metrics.headerTrailing)
        .frame(height: DesignSystem.Metrics.headerHeight)
    }
}

/// Chooses how much room the header actions take as the window narrows.
/// The filter field stays available at every width; the secondary details
/// toggle folds back into the existing More Options menu when space runs out.
struct HeaderFit {
    let filterWidth: CGFloat
    let showsInfoButton: Bool
    let privacyBudget: CGFloat

    init(width: CGFloat) {
        switch width {
        case ..<440:
            filterWidth = 80
            showsInfoButton = false
            privacyBudget = 96
        case ..<520:
            filterWidth = 100
            showsInfoButton = false
            privacyBudget = 112
        case ..<680:
            filterWidth = 130
            showsInfoButton = true
            privacyBudget = 132
        case ..<840:
            filterWidth = 160
            showsInfoButton = true
            privacyBudget = 152
        default:
            filterWidth = 180
            showsInfoButton = true
            privacyBudget = 172
        }
    }
}

// MARK: - Pause / Resume pair

/// A single compact capsule holding two independently interactive segments.
private struct TransportControls: View {
    let model: ListViewModel

    var body: some View {
        HStack(spacing: 0) {
            segment(
                systemImage: "pause.fill",
                title: "Pause all",
                help: "Pause all",
                enabled: model.canPauseAll
            ) {
                model.pauseAll()
            }
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: DesignSystem.Metrics.hairline, height: 13)
            segment(
                systemImage: "play.fill",
                title: "Resume all",
                help: "Resume all",
                enabled: model.canResumeAll
            ) {
                model.resumeAll()
            }
        }
        .capsuleSurface()
        .clipShape(Capsule(style: .continuous))
    }

    private func segment(
        systemImage: String,
        title: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: DesignSystem.Metrics.iconSize, weight: .medium))
                .frame(
                    width: DesignSystem.Metrics.controlHeight,
                    height: DesignSystem.Metrics.controlHeight
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportSegmentStyle())
        .help(help)
        .accessibilityLabel(title)
        .disabled(!enabled)
    }
}

/// Hover/pressed fill for a segment inside the shared capsule. Square edges are
/// clipped away by the capsule, so the highlight reads as a native segment.
private struct TransportSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TransportSegment(configuration: configuration)
    }
}

private struct TransportSegment: View {
    let configuration: TransportSegmentStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .background { Color.primary.opacity(highlight) }
            .onHover { hovering in
                guard isEnabled else { return }
                isHovering = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var highlight: Double {
        guard isEnabled else { return 0 }
        if configuration.isPressed { return 0.16 }
        return isHovering ? 0.09 : 0
    }
}

// MARK: - Privacy chip

/// Tunnel privacy surface: a small shield capsule showing the current leak
/// state. Clicking it runs a fresh privacy check. The chip only appears once
/// privacy has a story to tell (tunnel up / down / detection trouble), and
/// stays out of the way at very narrow widths.
struct PrivacyChip: View {
    let widthBudget: CGFloat
    @State private var isRunning = false

    var body: some View {
        let narrow = widthBudget < 110
        HStack(spacing: 5) {
            Image(systemName: IPLeakProbe.shared.state.systemImage)
                .font(.system(size: 11, weight: .semibold))
            if !narrow {
                Text(IPLeakProbe.shared.state.shortLabel)
                    .font(.system(size: 11, weight: .medium))
            }
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, narrow ? 9 : 10)
        .frame(height: DesignSystem.Metrics.controlHeight)
        .capsuleSurface()
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { runCheck() }
        .help(IPLeakProbe.shared.state.detail)
        .accessibilityLabel("Privacy check: \(IPLeakProbe.shared.state.shortLabel)")
    }

    private func runCheck() {
        guard !isRunning else { return }
        isRunning = true
        let phase = TunnelService.shared.phase
        Task { @MainActor in
            await IPLeakProbe.shared.runLiveCheck(phase: phase)
            isRunning = false
        }
    }
}

// MARK: - Filter field

/// Separate, horizontally elongated search capsule with compact internal padding.
private struct FilterField: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let width: CGFloat
    var collapseDetails: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DesignSystem.Metrics.searchIconSize, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DesignSystem.Metrics.searchIconSize))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: DesignSystem.Metrics.controlHeight)
        .capsuleSurface()
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.8 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            isFocused = true
            collapseDetails()
        }
    }
}

// MARK: - More options

/// Ellipsis menu kept as its own circular control. Still owns the details and
/// column toggles, so nothing becomes unreachable at narrow widths.
private struct MoreOptionsMenu: View {
    @Bindable var model: ListViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Toggle("Details Panel", isOn: Binding(
                get: { !model.detailsCollapsed },
                set: { newValue in
                    if newValue == model.detailsCollapsed {
                        model.toggleDetails()
                    }
                }
            ))

            Divider()

            Toggle("Show Categories", isOn: $model.showCategories)
            Toggle("Show Tags", isOn: $model.showTags)

            Divider()

            Menu("Columns") {
                Toggle("Status", isOn: columnVisibility("status"))
                Toggle("Progress", isOn: columnVisibility("progress"))
                Toggle("Size", isOn: columnVisibility("size"))
                Toggle("DL", isOn: columnVisibility("downloadSpeed"))
                Toggle("UP", isOn: columnVisibility("uploadSpeed"))
                Toggle("ETA", isOn: columnVisibility("eta"))
                Toggle("Time", isOn: columnVisibility("timeActive"))
                Toggle("Category", isOn: columnVisibility("category"))
                Toggle("Tags", isOn: columnVisibility("tags"))
                Toggle("Ratio", isOn: columnVisibility("ratio"))
                Toggle("Added", isOn: columnVisibility("addedOn"))
                Toggle("Seeds", isOn: columnVisibility("seeds"))
                Toggle("Peers", isOn: columnVisibility("peers"))
                Toggle("Availability", isOn: columnVisibility("availability"))
                Toggle("Downloaded", isOn: columnVisibility("downloaded"))
                Toggle("Uploaded", isOn: columnVisibility("uploaded"))
                Toggle("Save Path", isOn: columnVisibility("savePath"))
            }

            Divider()

            Toggle(
                "Alternative Speed Limits",
                isOn: Binding(
                    get: { model.altSpeedsActive },
                    set: { _ in model.toggleAltSpeeds() }
                )
            )
            .disabled(!model.isConnected)

            Divider()

            Button {
                model.toggleSearchPane(true)
            } label: {
                Label("Server Search…", systemImage: "magnifyingglass")
            }
            .help("Search through server plugins")
            .disabled(!model.isConnected)

            Button {
                openWindow(id: "downloads")
            } label: {
                Label("Direct Downloads…", systemImage: "arrow.down.to.line.compact")
            }
            .help("Accelerated direct downloads")

            Divider()

            Button {
                openWindow(id: "settings")
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .help("Settings")

            Button {
                model.showConnectionSheet = true
            } label: {
                Label("Connection…", systemImage: "network")
            }
            .help("Connection settings")
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(CapsuleIconButtonStyle())
        .menuIndicator(.hidden)
        .help("More options")
        .accessibilityLabel("More options")
    }

    private func columnVisibility(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.columnCustomization[visibility: id] != .hidden },
            set: { model.columnCustomization[visibility: id] = $0 ? .visible : .hidden }
        )
    }
}
