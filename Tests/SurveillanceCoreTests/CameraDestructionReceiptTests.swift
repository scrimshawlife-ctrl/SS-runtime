import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct CameraDestructionReceiptTests {
    @Test func receiptT707SummaryReflectsPartialBlackout() throws {
        var sim = try Simulation.make(seed: 1)
        for index in 0..<7 {
            sim.testing_destroyCameraAtIndex(index)
            _ = sim.step(command: .neutral(tick: UInt64(index + 1)))
        }
        let receipt = RunReceipt(sim.state)
        let summary = receipt.cameraDestructionSummary
        #expect(summary.camerasDestroyed == 7)
        #expect(summary.objectiveDestroyed == 7)
        #expect(summary.objectiveTotal == 8)
        #expect(!summary.objectiveComplete)
        #expect(summary.tamperExposureApplied == 1000)
        #expect(receipt.networkBlackout == false)
        #expect(receipt.canonical().serialize().contains("\"cameraObjective\""))
        #expect(receipt.canonical().serialize().contains("\"tamperExposureApplied\":1000"))
    }

    @Test func receiptT707SummaryReflectsCompleteBlackout() throws {
        var sim = try Simulation.make(seed: 1)
        for index in 0..<8 {
            sim.testing_destroyCameraAtIndex(index)
            _ = sim.step(command: .neutral(tick: UInt64(index + 1)))
        }
        let receipt = RunReceipt(sim.state)
        let summary = receipt.cameraDestructionSummary
        #expect(summary.camerasDestroyed == 8)
        #expect(summary.objectiveComplete)
        #expect(summary.tamperExposureApplied == 1000)
        #expect(receipt.networkBlackout)
    }

    @Test func receiptT707DestructionEntriesOrderedByTickThenCameraId() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_destroyCameraAtIndex(0)
        _ = sim.step(command: .neutral(tick: 1))
        sim.testing_destroyCameraAtIndex(1)
        _ = sim.step(command: .neutral(tick: 2))
        let receipt = RunReceipt(sim.state)
        #expect(receipt.destructions.count == 2)
        #expect(receipt.destructions[0].tick == 1)
        #expect(receipt.destructions[1].tick == 2)
        #expect(receipt.destructions[0].cameraId < receipt.destructions[1].cameraId)
    }

    @Test func receiptT707DestructionEntryIncludesSourceAndLockdownFields() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_keepOnlyCamera(at: 0, integrity: 1)
        sim.testing_injectPulseHitting(camera: sim.state.cameras[0])
        _ = sim.step(command: .neutral(tick: 1))
        let receipt = RunReceipt(sim.state)
        #expect(receipt.destructions.count == 1)
        #expect(receipt.destructions[0].source == "baseProjectile")
        let canonicalEntries = receipt.canonical().serialize()
        #expect(canonicalEntries.contains("\"source\":\"baseProjectile\""))
        #expect(canonicalEntries.contains("\"triggeredLockdown\""))
    }

    @Test func receiptT707DamagedNotDestroyedCamerasCounted() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_keepOnlyCamera(at: 0, integrity: 2)
        sim.testing_injectPulseHitting(camera: sim.state.cameras[0])
        _ = sim.step(command: .neutral(tick: 1))
        let receipt = RunReceipt(sim.state)
        #expect(receipt.cameraDestructionSummary.camerasDamaged == 1)
        #expect(receipt.cameraDestructionSummary.camerasDestroyed == 0)
        #expect(receipt.destructions.isEmpty)
    }

    @Test func receiptT707ER005FailureRetainsOrderedDestructionEntries() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_keepOnlyCamera(at: 0, integrity: 1)
        sim.testing_setPlayerIntegrity(0)
        sim.testing_injectPulseHitting(camera: sim.state.cameras[0])
        _ = sim.step(command: .neutral(tick: 1))
        let receipt = RunReceipt(sim.state)
        #expect(receipt.outcome == .failure)
        #expect(receipt.destructions.count == 1)
        #expect(receipt.destructions[0].exposureAfter == 150)
        #expect(receipt.cameraDestructionSummary.tamperExposureApplied == 150)
    }
}
