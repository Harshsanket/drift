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

// MARK: - Titlebar leading: traffic lights, sidebar toggle, app title

/// Occupies the leading edge of the titlebar strip, directly after the native
/// traffic lights, matching Apple Music's continuous left section.
struct HeaderLeadingControls: View {
    @Binding var sidebarVisibility: NavigationSplitViewVisibility

    private var isSidebarVisible: Bool { sidebarVisibility != .detailOnly }

    var body: some View {
        HStack(spacing: 0) {
            // Reserve the traffic-light cluster without swallowing its clicks.
            Color.clear
                .frame(width: DesignSystem.Metrics.trafficLightInset)
                .allowsHitTesting(false)

            Button {
                sidebarVisibility = isSidebarVisible ? .detailOnly : .all
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(CapsuleIconButtonStyle())
            .help(isSidebarVisible ? "Hide sidebar" : "Show sidebar")
            .accessibilityLabel(isSidebarVisible ? "Hide sidebar" : "Show sidebar")

            Text("Drift")
                .font(.system(size: DesignSystem.Metrics.titleSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, DesignSystem.Metrics.titleLeading)
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
            // Add Torrent — always present.
            CapsuleIconButton(
                systemImage: "plus",
                title: "Add Torrent",
                help: "Add torrent (Phase 4)",
                action: {}
            )
            .disabled(true)

            TransportControls()

            FilterField(
                text: $model.searchText,
                isFocused: $filterFocused,
                width: fit.filterWidth
            )

            MoreOptionsMenu(model: model)

            if fit.showsInfoButton {
                CapsuleIconButton(
                    systemImage: model.detailsCollapsed ? "info.circle" : "info.circle.fill",
                    title: model.detailsCollapsed ? "Expand details" : "Collapse details",
                    action: { model.toggleDetails() }
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

    init(width: CGFloat) {
        switch width {
        case ..<440:
            filterWidth = 80
            showsInfoButton = false
        case ..<520:
            filterWidth = 100
            showsInfoButton = false
        case ..<680:
            filterWidth = 130
            showsInfoButton = true
        case ..<840:
            filterWidth = 160
            showsInfoButton = true
        default:
            filterWidth = 180
            showsInfoButton = true
        }
    }
}

// MARK: - Pause / Resume pair

/// A single compact capsule holding two independently interactive segments.
private struct TransportControls: View {
    var body: some View {
        HStack(spacing: 0) {
            segment(systemImage: "pause.fill", title: "Pause all", help: "Pause all (Phase 5)")
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: DesignSystem.Metrics.hairline, height: 13)
            segment(systemImage: "play.fill", title: "Resume all", help: "Resume all (Phase 5)")
        }
        .capsuleSurface()
        .clipShape(Capsule(style: .continuous))
    }

    private func segment(systemImage: String, title: String, help: String) -> some View {
        Button(action: {}) {
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
        .disabled(true)
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

// MARK: - Filter field

/// Separate, horizontally elongated search capsule with compact internal padding.
private struct FilterField: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let width: CGFloat

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
        .onTapGesture { isFocused = true }
    }
}

// MARK: - More options

/// Ellipsis menu kept as its own circular control. Still owns the details and
/// column toggles, so nothing becomes unreachable at narrow widths.
private struct MoreOptionsMenu: View {
    @Bindable var model: ListViewModel

    var body: some View {
        Menu {
            Toggle("Details Panel", isOn: Binding(
                get: { !model.detailsCollapsed },
                set: { newValue in
                    withAnimation(.spring(duration: 0.35)) {
                        model.detailsCollapsed = !newValue
                    }
                }
            ))

            Divider()

            Menu("Columns") {
                Toggle("Status", isOn: columnVisibility("status"))
                Toggle("Progress", isOn: columnVisibility("progress"))
                Toggle("Size", isOn: columnVisibility("size"))
                Toggle("DL", isOn: columnVisibility("downloadSpeed"))
                Toggle("UP", isOn: columnVisibility("uploadSpeed"))
                Toggle("ETA", isOn: columnVisibility("eta"))
                Toggle("Time", isOn: columnVisibility("timeActive"))
            }

            Divider()

            Button("Settings…") {}
                .disabled(true)
                .help("Settings (Phase 10)")
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
