import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable private var app = AppSettings.shared
    @Bindable private var connection = ConnectionSettings.shared
    @Environment(\.openWindow) private var openWindow

    @State private var baseUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false

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
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 540)
        .preferredColorScheme(app.appearance.colorScheme)
        .onAppear {
            baseUrl = connection.baseUrl
            username = connection.username
            writeProbeLog("[settings] shown")
        }
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
