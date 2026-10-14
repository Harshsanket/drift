import SwiftUI

struct ConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var baseUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false

    private let settings = ConnectionSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection")
                .font(.headline)

            Text("Web UI URL")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("http://localhost:8080", text: $baseUrl)
                .textFieldStyle(.roundedBorder)

            Text("Username")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("admin", text: $username)
                .textFieldStyle(.roundedBorder)

            Text("Password")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            if let status = settings.testStatus {
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

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    settings.save(baseUrl: baseUrl, username: username, password: password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(WebAPIEngine.url(from: baseUrl) == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            baseUrl = settings.baseUrl
            username = settings.username
        }
    }

    private func runTest() async {
        testing = true
        let effectivePassword = password.isEmpty ? settings.password : password
        await settings.test(baseUrl: baseUrl, username: username, password: effectivePassword)
        testing = false
    }
}
