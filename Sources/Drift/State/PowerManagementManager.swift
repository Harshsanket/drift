import Foundation
import IOKit.pwr_mgt
import os

protocol IOPMAssertionManaging {
    func create(name: String) -> IOPMAssertionID?
    func release(_ id: IOPMAssertionID)
}

struct SystemIOPMAssertion: IOPMAssertionManaging {
    func create(name: String) -> IOPMAssertionID? {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(255),
            name as CFString,
            &assertionID
        )
        return result == kIOReturnSuccess ? assertionID : nil
    }

    func release(_ id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }
}

@MainActor
final class PowerManagementManager {
    static let shared = PowerManagementManager()

    private let assertion: IOPMAssertionManaging
    private let logger = Logger(subsystem: "com.harshsanket.drift", category: "power")
    private var assertionID: IOPMAssertionID?
    private var consecutiveActive = 0
    private var armed = false
    private var lastActiveObservation: Date?
    private var lastObservation: Date?
    private var watchTask: Task<Void, Never>?

    static let acquireThreshold = 2
    static let inactivityRelease: TimeInterval = 30
    static let freshnessLimit: TimeInterval = 60
    static let watchInterval: TimeInterval = 5

    init(assertion: IOPMAssertionManaging = SystemIOPMAssertion()) {
        self.assertion = assertion
    }

    var isEnabled: Bool { AppSettings.shared.preventIdleSleep }

    var isHeld: Bool { assertionID != nil }

    func settingsChanged() {
        writeProbeLog("[power] prevention=\(isEnabled ? "on" : "off")")
        if isEnabled {
            startWatch()
        } else {
            watchTask?.cancel()
            watchTask = nil
            release(reason: "disabled")
            armed = false
            consecutiveActive = 0
            lastActiveObservation = nil
            lastObservation = nil
        }
        evaluate()
    }

    func noteObservation(active: Bool, now: Date = .now) {
        lastObservation = now
        if active {
            consecutiveActive += 1
            lastActiveObservation = now
            if consecutiveActive >= Self.acquireThreshold {
                armed = true
            }
            if !isHeld {
                writeProbeLog("[power] observation active=true n=\(consecutiveActive)")
            }
        } else {
            consecutiveActive = 0
        }
        evaluate(now: now)
    }

    func evaluate(now: Date = .now) {
        guard isEnabled else { return }

        let fresh = lastObservation.map { now.timeIntervalSince($0) < Self.freshnessLimit } ?? false
        let inactiveLongEnough = lastActiveObservation.map {
            now.timeIntervalSince($0) >= Self.inactivityRelease
        } ?? true

        if isHeld {
            if !fresh || inactiveLongEnough {
                release(reason: inactiveLongEnough ? "inactive" : "stale")
                armed = false
            }
        } else if armed && fresh && !inactiveLongEnough {
            let name = "com.harshsanket.drift.idle-sleep-prevention"
            if let id = assertion.create(name: name) {
                assertionID = id
                writeProbeLog("[power] assertion created id=\(id)")
                logger.log(level: .info, "power.assertion.create id=\(id, privacy: .public)")
            } else {
                writeProbeLog("[power] assertion create FAILED")
                logger.log(level: .error, "power.assertion.create failed")
            }
        }
    }

    private func release(reason: String) {
        guard let id = assertionID else { return }
        assertionID = nil
        assertion.release(id)
        writeProbeLog("[power] assertion released (\(reason))")
        logger.log(level: .info, "power.assertion.release reason=\(reason, privacy: .public)")
    }

    private func startWatch() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchInterval))
                if Task.isCancelled { return }
                self?.evaluate()
            }
        }
    }
}
