import Testing
@testable import Drift

@Suite("Transfer activity classification")
struct TransferActivityTests {
    @Test func speedsPrimary() {
        let dl = WebAPIEngine.transferActivity(dl: 1, up: 0, states: [])
        let up = WebAPIEngine.transferActivity(dl: 0, up: 1, states: [])
        let both = WebAPIEngine.transferActivity(dl: 1_500_000, up: 340_000, states: [])
        #expect(dl)
        #expect(up)
        #expect(both)
    }

    @Test func activeStatesSecondary() {
        let active = ["downloading", "forcedDL", "metaDL", "uploading", "forcedUP"]
        var results: [Bool] = []
        for state in active {
            results.append(WebAPIEngine.transferActivity(dl: 0, up: 0, states: [state]))
        }
        #expect(results.allSatisfy { $0 })
        #expect(results.count == active.count)
    }

    @Test func inactiveStatesExcluded() {
        let inactive = ["stalledUP", "stalledDL", "queuedDL", "queuedUP", "stoppedDL",
                        "stoppedUP", "error", "missingFiles", "checkingUP", "moving"]
        var results: [Bool] = []
        for state in inactive {
            results.append(WebAPIEngine.transferActivity(dl: 0, up: 0, states: [state]))
        }
        #expect(results.allSatisfy { !$0 })
        let empty = WebAPIEngine.transferActivity(dl: 0, up: 0, states: [])
        #expect(!empty)
    }

    @Test func speedWinsOverInactiveState() {
        let active = WebAPIEngine.transferActivity(dl: 5, up: 0, states: ["stoppedDL"])
        #expect(active)
    }
}
