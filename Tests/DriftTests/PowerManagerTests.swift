import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Drift

private final class MockAssertion: IOPMAssertionManaging, @unchecked Sendable {
    private(set) var created: [String] = []
    private(set) var released: [IOPMAssertionID] = []
    private var nextID: IOPMAssertionID = 1

    func create(name: String) -> IOPMAssertionID? {
        created.append(name)
        defer { nextID += 1 }
        return nextID
    }

    func release(_ id: IOPMAssertionID) {
        released.append(id)
    }
}

@MainActor
@Suite("PowerManagementManager", .serialized)
struct PowerManagerTests {
    /// Saves and restores the shared setting around a test body (the
    /// manager reads `AppSettings.shared.preventIdleSleep` directly).
    @MainActor
    private func withPrevention(
        _ enabled: Bool,
        _ body: (PowerManagementManager, MockAssertion) -> Void
    ) {
        let saved = AppSettings.shared.preventIdleSleep
        defer { AppSettings.shared.preventIdleSleep = saved }
        AppSettings.shared.preventIdleSleep = enabled
        let mock = MockAssertion()
        let manager = PowerManagementManager(assertion: mock)
        manager.settingsChanged()
        body(manager, mock)
        AppSettings.shared.preventIdleSleep = saved
        manager.settingsChanged()
    }

    @Test func neverAcquiresWhileDisabled() {
        withPrevention(false) { manager, mock in
            let t = Date(timeIntervalSince1970: 1_700_000_000)
            manager.noteObservation(active: true, now: t)
            manager.noteObservation(active: true, now: t.addingTimeInterval(1))
            #expect(!manager.isHeld)
            #expect(mock.created.isEmpty)
        }
    }

    @Test func acquireHysteresisAndSingleAssertion() {
        withPrevention(true) { manager, mock in
            let t = Date(timeIntervalSince1970: 1_700_000_000)
            manager.noteObservation(active: true, now: t)
            #expect(!manager.isHeld)
            manager.noteObservation(active: true, now: t.addingTimeInterval(1))
            #expect(manager.isHeld)
            #expect(mock.created.count == 1)
            #expect(mock.created.first == "com.harshsanket.drift.idle-sleep-prevention")
            for i in 2...5 {
                manager.noteObservation(
                    active: true, now: t.addingTimeInterval(Double(i))
                )
            }
            #expect(mock.created.count == 1)
            #expect(mock.released.isEmpty)
        }
    }

    @Test func inactiveObservationResetsAcquireProgress() {
        withPrevention(true) { manager, mock in
            let t = Date(timeIntervalSince1970: 1_700_000_000)
            manager.noteObservation(active: true, now: t)
            manager.noteObservation(active: false, now: t.addingTimeInterval(1))
            manager.noteObservation(active: true, now: t.addingTimeInterval(2))
            #expect(!manager.isHeld)
            manager.noteObservation(active: true, now: t.addingTimeInterval(3))
            #expect(manager.isHeld)
        }
    }

    @Test func inactivityReleaseThenNoReacquireWithoutActivity() {
        withPrevention(true) { manager, mock in
            let t = Date(timeIntervalSince1970: 1_700_000_000)
            manager.noteObservation(active: true, now: t)
            manager.noteObservation(active: true, now: t.addingTimeInterval(1))
            #expect(manager.isHeld)
            manager.evaluate(now: t.addingTimeInterval(32))
            #expect(!manager.isHeld)
            #expect(mock.released == [1])
            manager.evaluate(now: t.addingTimeInterval(40))
            #expect(mock.created.count == 1)
            #expect(!manager.isHeld)
        }
    }

    @Test func staleDataReleasesAssertion() {
        withPrevention(true) { manager, mock in
            let t = Date(timeIntervalSince1970: 1_700_000_000)
            manager.noteObservation(active: true, now: t)
            manager.noteObservation(active: true, now: t.addingTimeInterval(1))
            #expect(manager.isHeld)
            manager.evaluate(now: t.addingTimeInterval(100))
            #expect(!manager.isHeld)
            #expect(mock.released == [1])
        }
    }

    @Test func immediateReleaseOnDisable() {
        let saved = AppSettings.shared.preventIdleSleep
        defer {
            AppSettings.shared.preventIdleSleep = saved
        }
        AppSettings.shared.preventIdleSleep = true
        let mock = MockAssertion()
        let manager = PowerManagementManager(assertion: mock)
        manager.settingsChanged()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        manager.noteObservation(active: true, now: t)
        manager.noteObservation(active: true, now: t.addingTimeInterval(1))
        #expect(manager.isHeld)
        AppSettings.shared.preventIdleSleep = false
        manager.settingsChanged()
        #expect(!manager.isHeld)
        #expect(mock.released == [1])
    }
}
