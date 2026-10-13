import SwiftUI

@main
struct DriftApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Text("Drift")
                    .font(.largeTitle)
                Text("In development")
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 360, minHeight: 240)
        }
        .defaultSize(width: 960, height: 640)
    }
}
