import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable private var app = AppSettings.shared
    @Bindable private var connection = ConnectionSettings.shared
    @Bindable private var speed = SpeedSettings.shared
    private var updates = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow

    @State private var baseUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false

    private static let repositoryURL = URL(string: "https://github.com/Harshsanket/drift")!
    private static let issuesURL = URL(string: "https://github.com/Harshsanket/drift/issues")!

    static let appIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 128, height: 128)
        return image
    }()

    var body: some View {
        Form {
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
        .formStyle(.grouped)
        .defaultScrollAnchor(.top)
        .frame(width: 520, height: 540)
        .preferredColorScheme(app.appearance.colorScheme)
        .onAppear {
            baseUrl = connection.baseUrl
            username = connection.username
            writeProbeLog("[settings] shown")
            WindowOpener.openSettings = { openWindow(id: "settings") }
            openWindow(id: "main")
            NotificationCenter.default.post(name: .driftSpeedSettingsRequested, object: self)
        }
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
                    Text("An open-source qBittorrent client built for macOS.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                aboutButton("Star on GitHub", systemImage: "star", url: Self.repositoryURL)
                aboutButton("Report an Issue", systemImage: "ladybug", url: Self.issuesURL)
            }

            Text("Proudly made in Mumbai by **Harsh Sanket**.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Thanks to the qBittorrent engine and its contributors — Drift is a native Mac interface for their Web API.")
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
