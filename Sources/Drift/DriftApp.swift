import SwiftUI

@main
struct DriftApp: App {
    @State private var model: ListViewModel

    init() {
        let model = ListViewModel()
        _model = State(initialValue: model)
        StatusItemController.shared.install(model: model)
        UpdateChecker.shared.checkIfDueOnLaunch()
    }

    var body: some Scene {
        Window("Drift", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 700)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.presented)

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .defaultSize(width: 520, height: 460)
        .windowResizability(.contentSize)
    }
}
