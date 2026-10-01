import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct GrayscaleSystemsTests {
    @Test func exposureEX004SixtyTicksNoRecoveryYet() {
        var state = ExposureState(exposure: 300, detectionState: .observed, noContactTicks: 0)
        for _ in 0..<60 {
            _ = state.resolveTick(survivingContactCount: 0, tamperAmounts: [], signalJammer: false)
        }
        #expect(state.exposure == 300)
        #expect(state.noContactTicks == 60)
    }

    @Test func exposureEX007TamperWithoutContact() {
        var state = ExposureState(exposure: 190, detectionState: .hidden)
        let result = state.resolveTick(survivingContactCount: 0, tamperAmounts: [100], signalJammer: false)
        #expect(result.contactDelta == 0)
        #expect(state.exposure == 290)
        #expect(state.detectionState == .observed)
    }

    @Test func exposureEX008TwoTampersLockdownOnce() {
        var state = ExposureState(exposure: 850, detectionState: .hunted)
        let result = state.resolveTick(survivingContactCount: 0, tamperAmounts: [100, 100], signalJammer: false)
        #expect(state.exposure == 1000)
        #expect(state.detectionState == .lockdown)
        #expect(result.lockdownEnteredThisTick)
    }

    @Test func exposureEX009LockdownIgnoresRecovery() {
        var state = ExposureState(exposure: 1000, detectionState: .lockdown, lockdownEntered: true)
        for _ in 0..<80 {
            _ = state.resolveTick(survivingContactCount: 0, tamperAmounts: [], signalJammer: false)
        }
        #expect(state.exposure == 1000)
        #expect(state.detectionState == .lockdown)
    }

    @Test func exposureEX010SingleStateJumpEvent() {
        var state = ExposureState()
        let result = state.resolveTick(survivingContactCount: 0, tamperAmounts: [100, 100, 100, 100, 100, 100, 100], signalJammer: false)
        #expect(result.stateBefore == .hidden)
        #expect(result.stateAfter == .hunted || result.stateAfter == .lockdown)
        #expect(state.exposure >= 700)
    }

    @Test func playerPC002DiagonalDoesNotExceedMaxSpeed() {
        let end = IsolatedKernel.move(ticks: 60, moveX: PlayerCommand.axisMaximum, moveY: PlayerCommand.axisMaximum)
        let distance = IsolatedKernel.distanceUnits(VecI(x: 256, y: 256).asQ8, end)
        #expect(distance >= 239 && distance <= 240)
    }

    @Test func playerPC003HalfMagnitude() {
        let end = IsolatedKernel.move(ticks: 60, moveX: 16_384, moveY: 0)
        #expect(end.x.unitsTruncated == 376)
        #expect(end.y.unitsTruncated == 256)
    }

    @Test func playerPC005DodgeAtMostNinetySix() {
        let (player, _) = IsolatedKernel.dodgeOnce()
        #expect(player.position.x.unitsTruncated <= 256 + 96)
        #expect(player.position.x.unitsTruncated >= 256 + 90)
    }

    @Test func playerPC007RejectedDodgeDuringCooldown() {
        #expect(IsolatedKernel.rejectedDodgeDuringCooldown() == 1)
    }

    @Test func cameraCD002TwoImpactsRemainCritical() {
        let result = IsolatedKernel.cameraIntegrity(impacts: 2)
        #expect(result.integrity == 1)
        #expect(result.tamper == 0)
        #expect(result.destructions == 0)
    }

    @Test func hudUI001ReferenceAnchors() {
        #expect(HUDLayout.stick(handedness: .right).x == 104)
        #expect(HUDLayout.dodge(handedness: .right).width == 88)
        #expect(HUDLayout.pause().meetsTouchTarget)
    }

    @Test func hudUI002HandednessMirrorsOnlyStickAndDodge() {
        #expect(HUDLayout.stick(handedness: .left).x == 740)
        #expect(HUDLayout.dodge(handedness: .left).x == 84)
        #expect(HUDLayout.pause().x == 806)
    }

    @Test func hudUI006ExtractionSecondsCeil() {
        #expect(HUDLayout.extractionSeconds(300) == 5)
        #expect(HUDLayout.extractionSeconds(1) == 1)
        #expect(HUDLayout.extractionSeconds(0) == 0)
    }

    @Test func cameraT413CounterHiddenUntilDamageThenAccolade() {
        let hidden = HUDLayout.cameraObjectiveVisible(destroyed: 0, damaged: false)
        let afterDamage = HUDLayout.cameraObjectiveVisible(destroyed: 0, damaged: true)
        let afterDestroy = HUDLayout.cameraObjectiveVisible(destroyed: 1, damaged: true)
        let partial = HUDLayout.cameraObjectiveCopy(destroyed: 7, complete: false)
        let complete = HUDLayout.cameraObjectiveCopy(destroyed: 8, complete: true)
        #expect(!hidden)
        #expect(afterDamage)
        #expect(afterDestroy)
        #expect(partial == "CAM 7/8")
        #expect(complete == HUDLayout.networkBlackoutAccolade)
        #expect(HUDLayout.networkBlackoutAccolade == "NETWORK BLACKOUT 8/8")
        #expect(HUDLayout.cameraObjectiveTotal == 8)
    }

    /// BO-002 (D-090): boss HP 1600/1200/1199/800/799/400/399/1, against the
    /// bands `combat-content-006` authors (`boss.phases[].minHp`), not a
    /// table in code.
    @Test func bossPhaseBO002HealthBands() {
        let content = CombatContent.bundled()
        #expect(content.bossHP == 1600)
        #expect(content.bossPhaseBands.minHp == [1200, 800, 400, 1])
        let bands = content.bossPhaseBands
        #expect(bands.phase(hp: 1600) == .publicSafety)
        #expect(bands.phase(hp: 1200) == .publicSafety)
        #expect(bands.phase(hp: 1199) == .civilLiberties)
        #expect(bands.phase(hp: 800) == .civilLiberties)
        #expect(bands.phase(hp: 799) == .temporarySafeguard)
        #expect(bands.phase(hp: 400) == .temporarySafeguard)
        #expect(bands.phase(hp: 399) == .independentReview)
        #expect(bands.phase(hp: 1) == .independentReview)
    }

    /// BO-002 through the runtime: a boss whose Integrity is set to each band
    /// edge enters that band's phase from its own content-driven bands.
    @Test func bossPhaseBO002RuntimeUsesContentBands() {
        let bands = CombatContent.bundled().bossPhaseBands
        for (hp, phase) in [(1199, BossPhase.civilLiberties), (799, .temporarySafeguard), (399, .independentReview)] {
            var runtime = BossRuntime(bands: bands)
            #expect(runtime.syncPhase(hp: hp)?.after == phase)
        }
        var runtime = BossRuntime(bands: bands)
        #expect(runtime.syncPhase(hp: 1200) == nil, "1200 is still Public Safety")
    }

    /// BO-003's intent (one batch across two thresholds is one transition),
    /// at the D-090 scale: 1220 -> 780 skips Civil Liberties. The spec row
    /// still reads 610 -> 390, which under the 1600 bands starts and ends in
    /// different phases than it names.
    @Test func bossBO003BatchSkipsToTemporarySafeguard() {
        var runtime = BossRuntime(bands: CombatContent.bundled().bossPhaseBands)
        _ = runtime.syncPhase(hp: 1220)
        let transition = runtime.syncPhase(hp: 780)
        #expect(transition?.before == .publicSafety)
        #expect(transition?.after == .temporarySafeguard)
        #expect(runtime.recoveryRemaining == 45)
    }

    @Test func observationPulsePublicSafetyRoundsHalfAway() {
        #expect(IntMath.divHalfAway(10 * 105, 100) == 11)
        #expect(IntMath.divHalfAway(11 * 75, 100) == 8)
    }

    @Test func projectilePoolRejectsBeyondCeiling() {
        var pool = ProjectilePool(capacity: 2)
        let proto = ProjectileBody(
            id: EntityID(1),
            ownerId: EntityID(1),
            kind: .civicPulse,
            position: .zero,
            previous: .zero,
            velocity: .zero,
            radius: 4,
            damage: 10,
            cameraDamage: 1,
            age: 1,
            lifetime: 45,
            distanceTravelledQ8: 0,
            maxTravelQ8: 100,
            hitEntityIds: [],
            alive: true
        )
        let first = pool.checkout(proto)
        #expect(first)
        var second = proto
        second.id = EntityID(2)
        let secondOk = pool.checkout(second)
        #expect(secondOk)
        var third = proto
        third.id = EntityID(3)
        let thirdOk = pool.checkout(third)
        #expect(!thirdOk)
        #expect(pool.liveCount == 2)
    }

    @Test func tutorialT0CompletesAfterNinetySixUnits() {
        var tutorial = TutorialState()
        tutorial.noteDisplacement(96)
        #expect(tutorial.phase == .field)
        #expect(tutorial.copy == "CAMERA FIELDS RAISE EXPOSURE")
    }

    @Test func tutorialLockdownPreemptsCopy() {
        var tutorial = TutorialState()
        tutorial.lockdownPreempts = true
        #expect(tutorial.copy == "LOCKDOWN")
    }
}
