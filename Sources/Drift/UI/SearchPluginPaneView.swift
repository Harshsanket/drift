import SwiftUI

/// Detail pane for a server-side search plugin. Plugins are Python scripts
/// qBittorrent runs to query one torrent indexer; this page shows what the
/// installed plugin can search, where it points, and lets the user enable,
/// disable, update, or uninstall it.
struct SearchPluginPaneView: View {
    @Bindable var model: ListViewModel
    let plugin: SearchPlugin

    @State private var confirmingUninstall = false

    private var siteURL: URL? {
        guard let url = URL(string: plugin.siteURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                capabilities
                management
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .alert("Uninstall \(plugin.fullName)?", isPresented: $confirmingUninstall) {
            Button("Uninstall", role: .destructive) {
                model.uninstallSearchPlugin(plugin)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The plugin script is removed from the server. You can install it again at any time from its source URL.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.10, green: 0.35, blue: 0.95),
                             Color(red: 0.30, green: 0.72, blue: 1.00)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "globe")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(plugin.fullName)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !plugin.version.isEmpty {
                        Text("v\(plugin.version)")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text("Server search plugin · \(plugin.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Enabled", isOn: Binding(
                get: { plugin.enabled },
                set: { model.setSearchPluginEnabled(plugin, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .disabled(model.searchPluginsBusy)
            .help("Only enabled plugins are used when a search starts.")
        }
    }

    private var capabilities: some View {
        GroupBox("What it does") {
            VStack(alignment: .leading, spacing: 10) {
                Text("When you run a server search, qBittorrent runs this Python plugin on the server. The plugin queries \(plugin.fullName) and returns torrent names, sizes, seeders, and download links; Drift only displays those results and hands your choice back to qBittorrent.")
                    .fixedSize(horizontal: false, vertical: true)

                if plugin.categories.isEmpty {
                    Text("The plugin reports no specific categories, so it is used for all searches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Used for these search categories:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(plugin.categories.joined(separator: "  ·  "))
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.quaternary)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let siteURL {
                    Link(destination: siteURL) {
                        Label(plugin.siteURL, systemImage: "safari")
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private var management: some View {
        GroupBox("Manage") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if model.searchPluginsBusy {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    Button("Open Search…") {
                        model.toggleSearchPane(true)
                    }
                    .disabled(!model.isConnected)

                    Button("Check for Updates") {
                        model.updateSearchPlugins()
                    }
                    .disabled(model.searchPluginsBusy || !model.isConnected)
                    .help("Ask qBittorrent to compare all installed plugins with its update feed")

                    Button("Uninstall", role: .destructive) {
                        confirmingUninstall = true
                    }
                    .disabled(model.searchPluginsBusy || !model.isConnected)
                }

                if let status = model.searchPluginsStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Disabling keeps the plugin installed but excludes it from searches. Uninstalling deletes the script on the server.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }
}
