import SwiftUI

@main
struct DriftApp: App {
    @State private var model: ListViewModel

    init() {
        let model = ListViewModel()
        _model = State(initialValue: model)
        StatusItemController.shared.install(model: model)
        // Supply-chain self-check: when a release manifest is embedded,
        // verify the bundle at launch. Dev builds (no manifest) report
        // `manifestMissing` without raising a fuss.
        let integrity = IntegrityChecker.verifyRunningBundle()
        switch integrity {
        case .verified:
            writeProbeLog("[integrity] bundle verified at launch")
        case .manifestMissing:
            writeProbeLog("[integrity] no release manifest (dev build)")
        case .signatureMissing:
            writeProbeLog("[integrity] manifest present but signature missing")
        case .tampered(let detail):
            writeProbeLog("[integrity] TAMPERED: \(detail)")
        case .unavailable(let reason):
            writeProbeLog("[integrity] verification unavailable: \(reason)")
        }
        UpdateService.shared.start()
        // GitHub launch check, gated by the About-card toggle: prompts are
        // always user-decided (Download and Update / Later), never silent.
        Task { @MainActor in
            await UpdateChecker.shared.checkOnLaunch()
        }
    }

    var body: some Scene {
        Window("Drift", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 700)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.presented)

        Window("Settings", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 520, height: 460)
        .windowResizability(.contentSize)

        Window("Downloads", id: "downloads") {
            DownloadCenterView()
        }
        .windowResizability(.contentSize)
    }
}
