import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var model: ListViewModel
    @Bindable private var app = AppSettings.shared
    @Bindable private var connection = ConnectionSettings.shared
    @Bindable private var speed = SpeedSettings.shared
    @Bindable private var leech = LeechGuard.shared
    @Bindable private var booster = BoosterSettings.shared
    @Bindable private var tunnel = TunnelService.shared
    @State private var updates = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow

    @State private var baseUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false
    @State private var pluginSource = ""

    @State private var leecherText = ""
    @State private var playerText = ""
    @State private var whitelistClientText = ""
    @State private var whitelistIPText = ""
    @State private var serverBans: [String] = []

    @State private var tunnelProfileText = ""
    @State private var startingTunnel = false

    private static let repositoryURL = URL(string: "https://github.com/Harshsanket/drift")!
    private static let issuesURL = URL(string: "https://github.com/Harshsanket/drift/issues")!

    static let appIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 128, height: 128)
        return image
    }()

    /// Verification-only: --screenshot-settings trims the form to the two
    /// feature cards (Connection Booster + Peer Protection) so captures
    /// show them without scrolling.
    private let screenshotMode =
        ProcessInfo.processInfo.arguments.contains("--screenshot-settings")

    var body: some View {
        Form {
            if !screenshotMode {
            Section("General") {
                HStack {
                    TextField("Default save destination", text: $app.defaultSavePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseFolder() }
                }
                Text("New torrents start in this folder; the Add sheet remembers your last choice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show menu bar status item", isOn: $app.showMenuBarItem)
                Toggle("Notify when a download completes", isOn: $app.completionNotifications)
                Toggle("RSS Feeds", isOn: $app.rssEnabled)
                Toggle("Statistics", isOn: $app.statsEnabled)
                Text("RSS adds a Feeds section to the sidebar; Statistics opens a full transfer-stats page. Turning either off hides it from the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                TextField("Web UI URL", text: $baseUrl)
                    .textFieldStyle(.roundedBorder)
                    .placeholder(when: baseUrl.isEmpty) {
                        Text("http://localhost:8080").foregroundStyle(.tertiary)
                    }
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)

                if let status = connection.testStatus {
                    HStack(spacing: 6) {
                        Image(systemName: status.isSuccess
                              ? "checkmark.circle.fill"
                              : "xmark.circle.fill")
                        Text(status.text)
                    }
                    .font(.caption)
                    .foregroundStyle(status.isSuccess ? Color.green : Color.red)
                }

                HStack {
                    Button(testing ? "Testing…" : "Test Connection") {
                        Task { await runTest() }
                    }
                    .disabled(testing)

                    Spacer()

                    Button("Save") {
                        connection.save(baseUrl: baseUrl, username: username, password: password)
                        password = ""
                        writeProbeLog("[settings] connection saved url=\(baseUrl)")
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(WebAPIEngine.url(from: baseUrl) == nil)
                }
            }
            }

            if !screenshotMode {
            Section("Transfer Speeds (server)") {
                speedField("Download limit (KiB/s)", value: $speed.downloadLimit)
                speedField("Upload limit (KiB/s)", value: $speed.uploadLimit)
                speedField("Alternative download limit (KiB/s)", value: $speed.altDownloadLimit)
                speedField("Alternative upload limit (KiB/s)", value: $speed.altUploadLimit)

                HStack {
                    Text("Apply writes these to the connected qBittorrent's "
                        + "transfer settings. 0 = unlimited.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply to server") {
                        NotificationCenter.default.post(name: .driftSpeedSettingsSaved, object: self)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!speed.loaded)
                }
            }

            Section("Search Plugins") {
                searchPluginsSection
            }
            }

            Section("Connection Booster") {
                Toggle("Enable Connection Booster", isOn: Binding(
                    get: { booster.enabled },
                    set: { booster.enabled = $0; booster.save() }
                ))
                Picker("Streams", selection: $booster.mode) {
                    ForEach(
                        BoosterSettings.StreamMode.allCases
                    ) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if booster.mode == .fixed {
                    Stepper(
                        "Fixed streams: \(booster.fixedStreams)",
                        value: $booster.fixedStreams,
                        in: 2...16
                    )
                }
                HStack {
                    Text("Slow mode cap (Mbps, 0 = off)")
                        .font(.callout)
                    Spacer()
                    TextField("", value: $booster.slowModeMbps, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Use cellular-dependent interfaces", isOn: $booster.allowCellular)
                Text("Torrent mode: boosts torrents you are downloading by fetching still-missing pieces in parallel from HTTP web seeds (and an optional mirror URL), verifying each piece against the .torrent hashes before writing, then rechecking. Only torrents that report HTTP web seeds can be boosted — the torrent row menu shows which. Legacy direct-URL fetches are no longer offered; older rows stay visible in the Downloads window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                .onChange(of: booster.mode) { persistBooster() }
                .onChange(of: booster.fixedStreams) { persistBooster() }
                .onChange(of: booster.slowModeMbps) { persistBooster() }
                .onChange(of: booster.allowCellular) { persistBooster() }
            }

            Section("Peer Protection") {
                peerProtectionSection
            }

            if !screenshotMode {
            Section("Updates") {
                updatesSection
            }

            Section("Tunnel") {
                tunnelSection
            }
            }

            if !screenshotMode {
            Section("Appearance") {
                Picker("Theme", selection: $app.appearance) {
                    ForEach(Appearance.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Power") {
                Toggle("Prevent idle sleep while transfers are active", isOn: $app.preventIdleSleep)
                Text("While enabled and transfers are actively moving data, this Mac will not enter idle sleep automatically. Display sleep, Apple-menu Sleep, and closing your MacBook lid are not affected. This protection exists only while this app is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                aboutSection
            }

            Section {
                HStack {
                    Spacer()
                    Text("a **Harsh Sanket** production")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $updatePromptVisible) {
            UpdatePromptSheet()
        }
        .defaultScrollAnchor(.top)
        .frame(width: 520, height: 540)
        .preferredColorScheme(app.appearance.colorScheme)
        .onAppear {
            baseUrl = connection.baseUrl
            username = connection.username
            leecherText = leech.config.leecherClients.joined(separator: "\n")
            playerText = leech.config.playerClients.joined(separator: "\n")
            whitelistClientText = leech.config.whitelistClients.joined(separator: "\n")
            whitelistIPText = leech.config.whitelistIPs.joined(separator: "\n")
            tunnelProfileText = Keychain.password(account: "tunnel.wireguard") ?? ""
            writeProbeLog("[settings] shown")
            WindowOpener.openSettings = { openWindow(id: "settings") }
            openWindow(id: "main")
            NotificationCenter.default.post(name: .driftSpeedSettingsRequested, object: self)
            if model.isConnected { model.loadSearchPlugins() }
            Task { serverBans = await leech.serverBans?() ?? [] }
        }
        .task {
            TunnelService.shared.refresh()
        }
    }

    @ViewBuilder
    private var peerProtectionSection: some View {
        Picker("Mode", selection: $leech.config.mode) {
            ForEach(LeechGuard.Mode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        Text(explainer(for: leech.config.mode))
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle("Ban known leecher clients", isOn: $leech.config.banLeecherClients)
        Toggle("Ban peers that never transfer", isOn: $leech.config.banIdleLeechers)
        if leech.config.banIdleLeechers {
            Stepper(
                "No-transfer timeout: \(leech.config.idleMinutes) min",
                value: $leech.config.idleMinutes,
                in: 5...120,
                step: 5
            )
        }
        Toggle("Ban unknown clients from China", isOn: $leech.config.banUnknownCountry)
        Toggle("Ban BitTorrent media players", isOn: $leech.config.banMediaPlayers)

        DisclosureGroup("Pattern lists & whitelist") {
            patternEditor("Leecher clients (one per line)", text: $leecherText)
            patternEditor("Media-player clients (one per line)", text: $playerText)
            patternEditor("Whitelist clients (one per line)", text: $whitelistClientText)
            patternEditor("Whitelist IPs or CIDR (e.g. 192.168.1.0/24)", text: $whitelistIPText)
        }

        HStack {
            Text("Rules apply live; Apply also persists them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Apply") {
                commitRuleEditors()
            }
            .buttonStyle(.borderedProminent)
        }

        if !leech.log.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Recent decisions")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("Clear") { leech.clearLog() }
                        .controlSize(.small)
                }
                ForEach(leech.log.prefix(5)) { entry in
                    let badge = entry.reason.hasPrefix("unbanned") ? "minus.circle"
                        : entry.reason.hasPrefix("unb") ? "minus.circle"
                        : "xmark.shield.fill"
                    HStack(spacing: 6) {
                        Image(systemName: badge)
                            .foregroundStyle(
                                entry.reason.contains("shadow") ? .secondary
                                    : entry.reason.hasPrefix("unbanned") ? .orange
                                    : DesignSystem.Palette.accent
                            )
                            .font(.caption2)
                        Text(entry.time, style: .time)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text("\(entry.ip) — \(entry.reason)\(entry.matched.isEmpty ? "" : " (\(entry.matched))")")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }

        DisclosureGroup("Server-banned IPs (\(serverBans.count))") {
            if serverBans.isEmpty {
                Text("None. (Requires an active connection.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(serverBans, id: \.self) { ip in
                    HStack {
                        Text(ip)
                            .monospaced()
                        Spacer()
                        Button("Remove") {
                            Task {
                                await leech.performUnban?([ip])
                                serverBans = await leech.serverBans?() ?? []
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            Button("Refresh") {
                Task { serverBans = await leech.serverBans?() ?? [] }
            }
            .controlSize(.small)
        }
    }

    private func explainer(for mode: LeechGuard.Mode) -> String {
        switch mode {
        case .off:
            "Detection is off. Manual bans from the Peers tab still work."
        case .shadow:
            "Decisions are logged for review, nothing is banned automatically yet."
        case .live:
            "Matching peers are banned server-side immediately (banned_IPs)."
        }
    }

    // MARK: - Search plugins

    @ViewBuilder
    private var searchPluginsSection: some View {
        Text("Search plugins are small Python scripts qBittorrent runs on the server — one per torrent site. Every enabled plugin is queried when you start a server search. Drift does not run plugins itself; the sidebar lists each installed plugin with its categories and site.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if model.searchPlugins.isEmpty {
            if model.searchPluginsBusy {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading plugins…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(model.isConnected
                     ? "No plugins installed yet. Paste a raw .py plugin URL below."
                     : "Connect to a server to see and manage its plugins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(model.searchPlugins) { plugin in
                searchPluginRow(plugin)
            }
        }

        HStack(spacing: 8) {
            TextField("Plugin .py URL (comma-separated for several)", text: $pluginSource)
                .textFieldStyle(.roundedBorder)
            Button("Install") {
                model.installSearchPlugins(from: pluginSource)
                pluginSource = ""
            }
            .disabled(
                pluginSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.searchPluginsBusy || !model.isConnected
            )
            .help("Installs a plugin, or updates it if the same plugin name is already installed")
        }

        HStack(spacing: 10) {
            Button("Refresh") {
                model.loadSearchPlugins()
            }
            .disabled(model.searchPluginsBusy || !model.isConnected)

            Button("Check for Updates") {
                model.updateSearchPlugins()
            }
            .disabled(model.searchPluginsBusy || !model.isConnected)
            .help("Ask qBittorrent to compare installed plugins with its update feed")

            if model.searchPluginsBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()
        }

        if let status = model.searchPluginsStatus {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Text("Official plugins are published as .py files in the qBittorrent search-plugins repository. Uninstalling removes the script from the server; disabling keeps it installed but excludes it from searches.")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private func searchPluginRow(_ plugin: SearchPlugin) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { plugin.enabled },
                set: { model.setSearchPluginEnabled(plugin, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(model.searchPluginsBusy)
            .help(plugin.enabled ? "Disable this plugin" : "Enable this plugin")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(plugin.fullName)
                        .font(.callout)
                        .lineLimit(1)
                    if !plugin.version.isEmpty {
                        Text("v\(plugin.version)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(plugin.categories.isEmpty
                     ? "All categories"
                     : plugin.categories.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(role: .destructive) {
                model.uninstallSearchPlugin(plugin)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.searchPluginsBusy)
            .help("Uninstall \(plugin.fullName)")
        }
    }

    // MARK: - Tunnel card

    @ViewBuilder
    private var tunnelSection: some View {
        Toggle("Route Drift traffic through the tunnel", isOn: $tunnel.enabled)

        HStack(spacing: 6) {
            Image(systemName: tunnelPhaseIcon)
            Text(tunnel.phase.label)
            if tunnel.phase == .up {
                Text("· \(tunnel.deviceName ?? "utun")")
                    .monospacedDigit()
                Text("↓\(Self.format(tunnel.receivedBytes)) ↑\(Self.format(tunnel.sentBytes))")
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(tunnelActionColor)
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .leading, spacing: 2) {
            Text("WireGuard or OpenVPN profile (paste a .conf or .ovpn)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $tunnelProfileText)
                .font(.caption)
                .monospaced()
                .frame(height: 96)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }

        HStack {
            Button("Save Profile") {
                tunnel.saveProfile(tunnelProfileText)
            }
            .disabled(tunnelProfileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()

            if tunnel.phase == .up {
                Button("Stop Tunnel") {
                    tunnel.stopTunnel()
                }
            } else {
                Button(startingTunnel ? "Starting…" : "Start Tunnel…") {
                    startingTunnel = true
                    Task {
                        await tcpTunnelStart()
                        startingTunnel = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(startingTunnel || !hasUsableProfile)
            }
        }

        Text("Only Drift's own traffic (Web API, Direct Downloads, update checks) is routed through the tunnel — a private utun interface is used inside this app alone; no system routes, DNS, or app-wide VPN is touched. While the tunnel is down, Drift refuses internet-bound requests instead of leaking. Starting requires your admin password once, to create the private interface. WireGuard profiles carry their interface address; OpenVPN profiles need a static `ifconfig` directive in the config (server-pushed addresses get a placeholder IP). For servers requiring auth-user-pass, include the credentials inline in the profile.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var tunnelPhaseIcon: String {
        switch tunnel.phase {
        case .up: "checkmark.circle.fill"
        case .down: "xmark.circle.fill"
        case .starting: "hourglass"
        default: "circle"
        }
    }

    private var tunnelActionColor: Color {
        switch tunnel.phase {
        case .up: .green
        case .down: .red
        default: .secondary
        }
    }

    /// Start needs either a freshly pasted profile or a stored one.
    private var hasUsableProfile: Bool {
        let fresh = !tunnelProfileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let stored = (Keychain.password(account: "tunnel.wireguard") ?? "").isEmpty == false
        return fresh || stored
    }

    private func tcpTunnelStart() async {
        tunnel.saveProfile(tunnelProfileText)
        await tunnel.startWithElevation()
    }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    private func patternEditor(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.caption)
                .frame(height: 56)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func commitRuleEditors() {
        leech.config.leecherClients = patternList(leecherText)
        leech.config.playerClients = patternList(playerText)
        leech.config.whitelistClients = patternList(whitelistClientText)
        leech.config.whitelistIPs = patternList(whitelistIPText)
        leech.save()
        writeProbeLog("[settings] peer protection applied mode=\(leech.config.mode.rawValue)")
    }

    private func persistBooster() {
        booster.save()
    }

    private func patternList(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @State private var integrityResult: IntegrityChecker.Result?
    @State private var integrityCheckRan = false
    @State private var updatePromptVisible = false

    /// Sparkle-backed update configuration. Nothing here talks to network
    /// until a feed URL exists and EdDSA verification is enabled by the
    /// embedded key — updates stay passive otherwise.
    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Appcast feed URL (appcast.xml)", text: $app.updateFeedURL)
                    .textFieldStyle(.roundedBorder)
                Button("Check") {
                    UpdateService.shared.check(userInitiated: true)
                    updatePromptVisible = true
                }
                .disabled(app.updateFeedURL.isEmpty)
                Button("Recheck integrity") {
                    integrityResult = IntegrityChecker.verifyRunningBundle()
                    integrityCheckRan = true
                }
                .help("Re-hash the running bundle against its release manifest")
            }

            Toggle("Install verified updates automatically", isOn: $app.updateAuto)

            Text("""
                Updates are only ever installed after an EdDSA signature \
                check against the release key (Ed25519, identical to \
                Sparkle's signing). With no feed configured the app checks \
                nothing and reports that honestly.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

            if integrityCheckRan, let integrityResult {
                HStack(spacing: 6) {
                    switch integrityResult {
                    case .verified:
                        Label("Bundle verified", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    case .manifestMissing:
                        Label("Unverified (dev build — no release manifest)", systemImage: "file.badge.questionmark")
                            .foregroundStyle(.secondary)
                    case .signatureMissing:
                        Label("Manifest found, detached signature missing", systemImage: "questionmark.key.fill")
                            .foregroundStyle(.orange)
                    case .tampered(let detail):
                        Label("Verification failed: \(detail)", systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(.red)
                    case .unavailable:
                        Label("Verification unavailable", systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Group {
                    if let icon = Self.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color(red: 0.10, green: 0.35, blue: 0.95),
                                         Color(red: 0.30, green: 0.72, blue: 1.00)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            .overlay(
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 23, weight: .heavy))
                                    .foregroundStyle(.white)
                            )
                    }
                }
                .frame(width: 52, height: 52)
                .shadow(color: Color(red: 0.10, green: 0.35, blue: 0.95).opacity(0.35),
                        radius: 6, y: 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Drift")
                            .font(.title2.weight(.bold))
                        Text("v\(updates.appVersion)")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    }
                    Text("An open-source qBittorrent client built for macOS, with an optional WireGuard tunnel.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                aboutButton("Star on GitHub", systemImage: "star", url: Self.repositoryURL)
                aboutButton("Report an Issue", systemImage: "ladybug", url: Self.issuesURL)
            }

            Text("Proudly made in Mumbai by **Harsh Sanket** · © 2026")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Thanks to the qBittorrent engine and its contributors — Drift is a native Mac interface for their Web API.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Text("Tunnel core: Partout (GPL-3.0). Update plumbing: Sparkle (MIT).")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                if updates.checking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Check for Updates") {
                    Task { await updates.check() }
                }
                .disabled(updates.checking)
                Spacer()
            }

            Toggle("Check for updates on launch", isOn: $updates.checkOnLaunchEnabled)
                .font(.caption)

            updateStatusRow
        }
        .padding(.vertical, 4)
    }

    private func aboutButton(_ title: String, systemImage: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: systemImage)
                .padding(.horizontal, 2)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var updateStatusRow: some View {
        switch updates.status {
        case .idle:
            EmptyView()
        case .upToDate:
            Label("You're running the latest version.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .available(let version, let url):
            HStack(spacing: 6) {
                Label("Version \(version) is available.", systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.green)
                Link("View Release", destination: url)
            }
            .font(.caption)
        case .noReleases:
            Label("No published releases yet.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func speedField(_ label: String, value: Binding<Int64>) -> some View {
        TextField(label, value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(
            fileURLWithPath: NSString(string: app.defaultSavePath).expandingTildeInPath
        )
        if panel.runModal() == .OK, let url = panel.url {
            app.defaultSavePath = url.path
        }
    }

    private func runTest() async {
        testing = true
        let effectivePassword = password.isEmpty ? connection.password : password
        await connection.test(baseUrl: baseUrl, username: username, password: effectivePassword)
        testing = false
    }
}

private extension View {
    func placeholder<Placeholder: View>(
        when condition: Bool,
        @ViewBuilder placeholder: () -> Placeholder
    ) -> some View {
        ZStack(alignment: .leading) {
            if condition { placeholder() }
            self
        }
    }
}
