import SwiftUI

@main
struct DriftApp: App {
    @State private var model = ListViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 700)
        .windowStyle(.hiddenTitleBar)

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .defaultSize(width: 520, height: 460)
        .windowResizability(.contentSize)
    }
}
