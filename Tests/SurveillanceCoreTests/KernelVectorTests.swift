import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct KernelVectorTests {
    @Test func exposureEX001OneCameraHundredTicks() {
        var state = ExposureState()
        for _ in 0..<100 {
            _ = state.resolveTick(survivingContactCount: 1, tamperAmounts: [], signalJammer: false)
        }
        #expect(state.exposure == 200)
        #expect(state.detectionState == .observed)
    }

    @Test func exposureEX005RecoveryOnSixtyFirstTick() {
        var state = ExposureState(exposure: 300, detectionState: .observed, noContactTicks: 0)
        for _ in 0..<61 {
            _ = state.resolveTick(survivingContactCount: 0, tamperAmounts: [], signalJammer: false)
        }
        #expect(state.exposure == 298)
        #expect(state.noContactTicks == 61)
    }

    @Test func exposureEX002ThreeCamerasOneTick() {
        var state = ExposureState()
        let result = state.resolveTick(survivingContactCount: 3, tamperAmounts: [], signalJammer: false)
        #expect(result.contactDelta == 4)
    }

    @Test func exposureEX003EightCamerasCapsAtFive() {
        var state = ExposureState()
        let result = state.resolveTick(survivingContactCount: 8, tamperAmounts: [], signalJammer: false)
        #expect(result.contactDelta == 5)
    }

    @Test func upgradeUP004SignalJammerContactDeltas() {
        // The un-jammed baseline, asserted first on purpose: 1/2/4 could equally
        // be produced by a wrong aggregation and a wrong modifier cancelling
        // each other out, and the vector alone would not notice.
        //
        // `exposure.md`: contactDelta = n == 0 ? 0 : min(5, 2 + n - 1). The cap
        // is why the third case is +4 rather than +8 — eight Cameras and five
        // Cameras are the same fight before the Jammer touches it.
        #expect(ExposureState.contactDelta(cameraCount: 1, signalJammer: false) == 2)
        #expect(ExposureState.contactDelta(cameraCount: 2, signalJammer: false) == 3)
        #expect(ExposureState.contactDelta(cameraCount: 8, signalJammer: false) == 5)

        #expect(ExposureState.contactDelta(cameraCount: 1, signalJammer: true) == 1)
        #expect(ExposureState.contactDelta(cameraCount: 2, signalJammer: true) == 2)
        #expect(ExposureState.contactDelta(cameraCount: 8, signalJammer: true) == 4)

        // No contact is no delta, jammed or not. The "minimum 1" floor applies
        // to a positive delta; it is not a licence to invent one.
        #expect(ExposureState.contactDelta(cameraCount: 0, signalJammer: true) == 0)
    }

    /// The aggregation being right is only half of UP-004: a tick has to apply
    /// it. `upgrades.md` puts the modifier after aggregation and before Tamper,
    /// so this pins that `resolveTick` reads the flag rather than merely
    /// offering a correct static to nobody.
    @Test func upgradeUP004JammedDeltaIsWhatATickApplies() {
        var jammed = ExposureState(exposure: 100, detectionState: .hidden)
        let withJammer = jammed.resolveTick(
            survivingContactCount: 1, tamperAmounts: [], signalJammer: true
        )
        #expect(withJammer.contactDelta == 1)
        #expect(jammed.exposure == 101)

        var plain = ExposureState(exposure: 100, detectionState: .hidden)
        let without = plain.resolveTick(
            survivingContactCount: 1, tamperAmounts: [], signalJammer: false
        )
        #expect(without.contactDelta == 2)
        #expect(plain.exposure == 102)
    }

    @Test func playerPC001FullRightSixtyTicks() {
        let end = IsolatedKernel.moveFullRight(ticks: 60)
        #expect(end.x.unitsTruncated == 496)
        #expect(end.y.unitsTruncated == 256)
    }

    @Test func combatCB002EqualDistancePrefersLowerID() {
        let id = IsolatedKernel.lowestTarget(candidates: [
            (id: 11, distSq: 4096),
            (id: 7, distSq: 4096)
        ])
        #expect(id == 7)
    }

    @Test func cameraCD001ThreeImpactsDestroyOnce() {
        let result = IsolatedKernel.cameraIntegrity(impacts: 3)
        #expect(result.integrity == 0)
        #expect(result.tamper == 100)
        #expect(result.destructions == 1)
    }

    @Test func arenaAR008ExtractionLeaveResets() {
        let result = IsolatedKernel.extractCycle(insideTicks: 299, leave: true, reenter: true)
        #expect(result.afterLeave == 300)
        #expect(result.afterReenter == 299)
    }

    @Test func cameraT414PredicateOmitsCameraBlackoutExposureAndUpgrade() {
        let complete = EncounterDirector.extractionArmed(
            mobAComplete: true, mobBComplete: true, mobCComplete: true,
            eliteDefeated: true, bossDefeated: true, playerAlive: true, runFailed: false
        )
        let missingMobA = EncounterDirector.extractionArmed(
            mobAComplete: false, mobBComplete: true, mobCComplete: true,
            eliteDefeated: true, bossDefeated: true, playerAlive: true, runFailed: false
        )
        let missingElite = EncounterDirector.extractionArmed(
            mobAComplete: true, mobBComplete: true, mobCComplete: true,
            eliteDefeated: false, bossDefeated: true, playerAlive: true, runFailed: false
        )
        let missingBoss = EncounterDirector.extractionArmed(
            mobAComplete: true, mobBComplete: true, mobCComplete: true,
            eliteDefeated: true, bossDefeated: false, playerAlive: true, runFailed: false
        )
        let playerDead = EncounterDirector.extractionArmed(
            mobAComplete: true, mobBComplete: true, mobCComplete: true,
            eliteDefeated: true, bossDefeated: true, playerAlive: false, runFailed: false
        )
        let runFailed = EncounterDirector.extractionArmed(
            mobAComplete: true, mobBComplete: true, mobCComplete: true,
            eliteDefeated: true, bossDefeated: true, playerAlive: true, runFailed: true
        )
        #expect(complete)
        #expect(!missingMobA)
        #expect(!missingElite)
        #expect(!missingBoss)
        #expect(!playerDead)
        #expect(!runFailed)
    }
}
