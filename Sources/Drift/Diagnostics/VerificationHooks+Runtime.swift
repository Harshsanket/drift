// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Foundation

extension VerificationHooks {
    static func runtimeHooks(model: ListViewModel, arguments: [String]) {
        menu(model: model, arguments: arguments)
        power(arguments: arguments)
        bench(model: model, arguments: arguments)
        search(model: model, arguments: arguments)
    }

    // MARK: - Menu bar

    private static func menu(model: ListViewModel, arguments: [String]) {
        guard arguments.contains("--test-menu") else { return }
        Task { @MainActor in
            writeProbeLog("[menubar] hook start")
            await model.connectEngine()
            guard model.isConnected else {
                writeProbeLog("[menubar] skipped (connect failed)")
                return
            }
            AppSettings.shared.showMenuBarItem = true
            func sleepLineCount() -> Int {
                let text = (try? String(contentsOfFile: ProbeLog.fileURL?.path ?? "/dev/null")) ?? ""
                return text.components(separatedBy: "sleep ").count - 1
            }
            let stats = model.transferStats()
            writeProbeLog(
                "[menubar] snapshot down=\(model.globalDownloadSpeed)"
                    + " up=\(model.globalUploadSpeed)"
                    + " dl=\(stats.downloading) seed=\(stats.seeding)"
                    + " prog=\(Int((stats.progress * 100).rounded()))"
            )
            model.pauseAll()
            try? await Task.sleep(for: .seconds(3))
            writeProbeLog(
                "[menubar] after pause "
                    + model.torrents.map(\.status.rawValue).sorted()
                        .joined(separator: ",")
            )
            model.resumeAll()
            try? await Task.sleep(for: .seconds(3))
            writeProbeLog(
                "[menubar] after resume "
                    + model.torrents.map(\.status.rawValue).sorted()
                        .joined(separator: ",")
            )

            model.setWindowVisible(false)
            try? await Task.sleep(for: .seconds(8))
            writeProbeLog("[menubar] phase=summary")

            AppSettings.shared.showMenuBarItem = false
            let sleepBefore = sleepLineCount()
            try? await Task.sleep(for: .seconds(7))
            let sleepAfter = sleepLineCount()
            writeProbeLog(
                "[menubar] phase=suspended sleeps \(sleepBefore)->\(sleepAfter)"
            )

            AppSettings.shared.showMenuBarItem = true
            try? await Task.sleep(for: .seconds(5))
            writeProbeLog("[menubar] phase=re-enabled")

            model.setWindowVisible(true)
            try? await Task.sleep(for: .seconds(2))
            writeProbeLog("[menubar] sequence done")
        }
    }

    // MARK: - Power

    private static func power(arguments: [String]) {
        guard arguments.contains("--test-power") else { return }
        Task { @MainActor in
            let settings = AppSettings.shared
            let power = PowerManagementManager.shared
            writeProbeLog("[power] sequence start enabled=\(settings.preventIdleSleep ? "on" : "off")")
            try? await Task.sleep(for: .seconds(1))

            settings.preventIdleSleep = true
            try? await Task.sleep(for: .seconds(1))
            power.noteObservation(active: true)
            try? await Task.sleep(for: .seconds(1))
            power.noteObservation(active: true)
            writeProbeLog("[power] phase=held pmset-check-now")
            try? await Task.sleep(for: .seconds(4))

            settings.preventIdleSleep = false
            writeProbeLog("[power] phase=immediate-off done")
            try? await Task.sleep(for: .seconds(1))

            settings.preventIdleSleep = true
            try? await Task.sleep(for: .seconds(1))
            power.noteObservation(active: true)
            try? await Task.sleep(for: .seconds(1))
            power.noteObservation(active: true)
            power.noteObservation(active: false)
            writeProbeLog("[power] phase=waiting-inactivity-release")
            try? await Task.sleep(for: .seconds(40))
            writeProbeLog("[power] phase=inactivity-check pmset-check-now")

            settings.preventIdleSleep = false
            try? await Task.sleep(for: .seconds(1))
            writeProbeLog("[power] sequence done")
        }
    }

    // MARK: - Bench

    private static func bench(model: ListViewModel, arguments: [String]) {
        guard let idx = arguments.firstIndex(of: "--bench"),
              idx + 1 < arguments.count
        else { return }
        let mode = arguments[idx + 1]
        Task { @MainActor in
            writeProbeLog("[bench] mode=\(mode) start")
            await model.connectEngine()
            guard model.isConnected else {
                writeProbeLog("[bench] skipped (connect failed)")
                return
            }
            switch mode {
            case "active":
                AppSettings.shared.showMenuBarItem = true
                model.setWindowVisible(true)
            case "summary", "suspended", "power":
                AppSettings.shared.showMenuBarItem = mode != "suspended"
                if mode == "power" {
                    AppSettings.shared.preventIdleSleep = true
                }
                model.setWindowVisible(false)
                // Physically leave the screen too — otherwise the
                // occlusion probe sees the window and flips the tier
                // back to active.
                for window in NSApp.windows {
                    window.orderOut(nil)
                }
            default:
                writeProbeLog("[bench] unknown mode \(mode)")
                return
            }
            writeProbeLog("[bench] mode=\(mode) ready")
        }
    }

    // MARK: - Search

    private static func search(model: ListViewModel, arguments: [String]) {
        guard arguments.contains("--test-search") else { return }
        Task { @MainActor in
            writeProbeLog("[search] hook start")
            await model.connectEngine()
            for _ in 0..<80 {
                if model.isConnected { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            model.startSearch(pattern: "ubuntu")
            try? await Task.sleep(for: .seconds(4))
            writeProbeLog(
                "[search] results=\(model.searchResults.count) running=\(model.searchRunning) "
                    + model.searchResults.map(\.fileName).joined(separator: ";")
            )
            if let first = model.searchResults.first {
                model.downloadSearchResult(first)
                try? await Task.sleep(for: .seconds(1))
                writeProbeLog(
                    "[search] handoff sheet=\(model.showAddSheet) pending=\(model.pendingAddHandoff != nil)"
                )
                model.showAddSheet = false
                model.pendingAddHandoff = nil
            }
            model.clearSearchResults()
            writeProbeLog("[search] sequence done")
        }
    }
}
