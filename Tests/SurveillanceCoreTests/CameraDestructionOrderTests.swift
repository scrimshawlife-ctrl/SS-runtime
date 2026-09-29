import Testing
@testable import SurveillanceCore

private struct CameraLayoutSnapshot: Equatable {
    var sockets: [String]
    var ids: [UInt64]
    var headings: [Int]
    var integrity: [Int]
}

private func cameraLayoutSnapshot(_ cameras: [SelectedCamera]) -> CameraLayoutSnapshot {
    CameraLayoutSnapshot(
        sockets: cameras.map(\.socketId),
        ids: cameras.map(\.entityId.raw),
        headings: cameras.map(\.headingMilliDegrees),
        integrity: cameras.map(\.integrity)
    )
}

private func mountBox(_ camera: SelectedCamera) -> (Int, Int, Int, Int) {
    let radius = camera.mountCollisionRadius
    return (
        camera.position.x - radius,
        camera.position.x + radius,
        camera.position.y - radius,
        camera.position.y + radius
    )
}

@Suite(.serialized)
struct CameraDestructionOrderTests {
    @Test func cameraCD003DestroyWhileDetectingOmitsContactDelta() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_keepOnlyCamera(at: 0, integrity: 1)
        let camera = sim.state.cameras[0]
        let px = camera.position.x
        let py = camera.position.y
        let ax = camera.targetAnchor.x.unitsTruncated
        let ay = camera.targetAnchor.y.unitsTruncated
        sim.testing_setPlayerPosition(
            VecI(x: px + (ax - px) * 3 / 2, y: py + (ay - py) * 3 / 2)
        )
        sim.testing_injectPulseHitting(camera: camera)
        _ = sim.step(command: .neutral(tick: 1))
        let integrity = sim.state.cameras[0].integrity
        let destroyed = sim.state.destructions.count
        let detecting = sim.state.destructions.first?.wasDetectingPlayer ?? false
        let exposure = sim.state.exposure.exposure
        let reason = sim.state.exposure.detectionState
        #expect(integrity == 0)
        #expect(destroyed == 1)
        #expect(detecting)
        // Contact from the destroyed Camera is stripped; only +150 Tamper remains (not 152).
        #expect(exposure == 150)
        #expect(reason == .hidden)
    }

    @Test func cameraCD004DestroyWhileNotDetectingStillTampers() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_keepOnlyCamera(at: 0, integrity: 1)
        let camera = sim.state.cameras[0]
        sim.testing_injectPulseHitting(camera: camera)
        _ = sim.step(command: .neutral(tick: 1))
        let integrity = sim.state.cameras[0].integrity
        let detecting = sim.state.destructions.first?.wasDetectingPlayer ?? true
        let exposure = sim.state.exposure.exposure
        let destroyed = sim.state.destructions.count
        #expect(integrity == 0)
        #expect(destroyed == 1)
        #expect(!detecting)
        #expect(exposure == 150)
    }

    @Test func cameraCD007DestroyAt950ClampsAndLockdown() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_keepOnlyCamera(at: 0, integrity: 1)
        sim.testing_setExposure(950)
        let camera = sim.state.cameras[0]
        sim.testing_injectPulseHitting(camera: camera)
        _ = sim.step(command: .neutral(tick: 1))
        let exposure = sim.state.exposure.exposure
        let lockdown = sim.state.exposure.lockdownEntered
        let state = sim.state.exposure.detectionState
        let destroyed = sim.state.destructions.count
        #expect(destroyed == 1)
        #expect(exposure == 1000)
        #expect(lockdown)
        #expect(state == .lockdown)
    }

    @Test func cameraCD010DeathTickStillRecordsTamper() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_keepOnlyCamera(at: 0, integrity: 1)
        sim.testing_setPlayerIntegrity(0)
        let camera = sim.state.cameras[0]
        sim.testing_injectPulseHitting(camera: camera)
        let result = sim.step(command: .neutral(tick: 1))
        let outcome = result.outcome
        let destroyed = sim.state.destructions.count
        let exposure = sim.state.exposure.exposure
        let reason = sim.state.failureReason
        #expect(outcome == .failure)
        #expect(reason == .playerDeath)
        #expect(destroyed == 1)
        #expect(exposure == 150)
    }

    @Test func cameraT410SurvivingContactThenTamperAddsBoth() {
        var state = ExposureState()
        let result = state.resolveTick(survivingContactCount: 1, tamperAmounts: [ExposureState.tamperSpike], signalJammer: false)
        #expect(result.contactDelta == 2)
        #expect(result.tamperApplied == ExposureState.tamperSpike)
        #expect(state.exposure == 152)
        #expect(result.reason == .cameraTamper)
    }

    @Test func cameraCD008HitDestroyedCameraIsIgnored() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_keepOnlyCamera(at: 0, integrity: 0)
        let camera = sim.state.cameras[0]
        sim.testing_injectPulseHitting(camera: camera)
        let hit = sim.step(command: .neutral(tick: 1))
        let integrity = sim.state.cameras[0].integrity
        let destroyed = sim.state.destructions.count
        let exposure = sim.state.exposure.exposure
        let events = hit.events.filter { $0.type == .cameraDestroyed }.count
        #expect(integrity == 0)
        #expect(destroyed == 0)
        #expect(exposure == 0)
        #expect(events == 0)
    }

    @Test func cameraCD009RestartRestoresOperationalAtFixedTransforms() throws {
        var sim = try Simulation.make(seed: 1)
        let original = cameraLayoutSnapshot(sim.state.cameras)
        sim.testing_keepOnlyCamera(at: 0, integrity: 1)
        sim.testing_injectPulseHitting(camera: sim.state.cameras[0])
        _ = sim.step(command: .neutral(tick: 1))
        let destroyedCount = sim.state.destructions.count
        let destroyedIntegrity = sim.state.cameras[0].integrity
        sim.restart()
        let restored = cameraLayoutSnapshot(sim.state.cameras)
        let restoredDestructions = sim.state.destructions.count
        let socketsMatch = restored.sockets == original.sockets
        let idsMatch = restored.ids == original.ids
        let headingsMatch = restored.headings == original.headings
        let operational = restored.integrity == Array(repeating: 3, count: 8)
        #expect(destroyedCount == 1)
        #expect(destroyedIntegrity == 0)
        #expect(socketsMatch)
        #expect(idsMatch)
        #expect(headingsMatch)
        #expect(operational)
        #expect(restoredDestructions == 0)
    }

    @Test func cameraT411DestroyedMountAndPoseStayFixedDuringRun() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_keepOnlyCamera(at: 0, integrity: 1)
        let before = sim.state.cameras[0]
        let x = before.position.x
        let y = before.position.y
        let heading = before.headingMilliDegrees
        let range = before.rangeUnits
        let mountBefore = mountBox(before)
        sim.testing_injectPulseHitting(camera: before)
        _ = sim.step(command: .neutral(tick: 1))
        for tick in 2...10 {
            _ = sim.step(command: .neutral(tick: UInt64(tick)))
        }
        let after = sim.state.cameras[0]
        let integrity = after.integrity
        let xAfter = after.position.x
        let yAfter = after.position.y
        let headingAfter = after.headingMilliDegrees
        let rangeAfter = after.rangeUnits
        let detecting = after.wasDetecting
        let damageable = after.isDamageable
        let mountAfter = mountBox(after)
        let stillPresent = sim.state.cameras.count
        let mountMatch = mountBefore == mountAfter
        #expect(integrity == 0)
        #expect(!damageable)
        #expect(!detecting)
        #expect(xAfter == x)
        #expect(yAfter == y)
        #expect(headingAfter == heading)
        #expect(rangeAfter == range)
        #expect(mountMatch)
        #expect(stillPresent == 8)
    }

    @Test func cameraCD012EighthDestructionCompletesNetworkBlackoutOnce() throws {
        var sim = try Simulation.make(seed: 1)
        var blackoutEvents = 0
        var destroyedCount = 0
        var totalCount = 0
        for index in 0..<8 {
            sim.testing_destroyCameraAtIndex(index)
            let result = sim.step(command: .neutral(tick: UInt64(index + 1)))
            let events = result.events.filter { $0.type == .allCamerasDestroyed }
            blackoutEvents += events.count
            if let event = events.first {
                destroyedCount = payloadInt(event, "destroyedCount")
                totalCount = payloadInt(event, "totalCount")
            }
        }
        let camera = sim.state.cameras[0]
        sim.testing_injectPulseHitting(camera: camera)
        let extra = sim.step(command: .neutral(tick: 9))
        let extraBlackout = extra.events.filter { $0.type == .allCamerasDestroyed }.count
        sim.testing_completeCombatGraph()
        _ = sim.step(command: .neutral(tick: 10))
        let destroyed = sim.state.destructions.count
        let blackout = sim.state.networkBlackout
        let armed = sim.state.extraction.armed
        let receipt = RunReceipt(sim.state)
        let receiptDestroyed = receipt.camerasDestroyed
        let receiptBlackout = receipt.networkBlackout
        let copy = HUDLayout.cameraObjectiveCopy(destroyed: receiptDestroyed, complete: receiptBlackout)
        #expect(blackoutEvents == 1)
        #expect(extraBlackout == 0)
        #expect(destroyedCount == 8)
        #expect(totalCount == 8)
        #expect(destroyed == 8)
        #expect(blackout)
        #expect(armed)
        #expect(receiptDestroyed == 8)
        #expect(receiptBlackout)
        #expect(copy == HUDLayout.networkBlackoutAccolade)
    }

    @Test func cameraCD014ExtractAtSevenRemainsIncomplete() throws {
        var sim = try Simulation.make(seed: 1)
        for index in 0..<7 {
            sim.testing_destroyCameraAtIndex(index)
            _ = sim.step(command: .neutral(tick: UInt64(index + 1)))
        }
        sim.testing_completeCombatGraph()
        _ = sim.step(command: .neutral(tick: 8))
        let extract = sim.state.arena.extraction.center
        sim.testing_setPlayerPosition(VecI(x: extract.x, y: extract.y))
        sim.testing_setExtractionRemaining(1)
        let result = sim.step(command: .neutral(tick: 9))
        let outcome = result.outcome
        let destroyed = sim.state.destructions.count
        let blackout = sim.state.networkBlackout
        let receipt = RunReceipt(sim.state)
        let receiptDestroyed = receipt.camerasDestroyed
        let receiptBlackout = receipt.networkBlackout
        let copy = HUDLayout.cameraObjectiveCopy(destroyed: receiptDestroyed, complete: receiptBlackout)
        #expect(outcome == .success)
        #expect(destroyed == 7)
        #expect(!blackout)
        #expect(receiptDestroyed == 7)
        #expect(!receiptBlackout)
        #expect(copy == "CAM 7/8")
    }

    @Test func cameraT414BlackoutWithoutCombatDoesNotArm() throws {
        var sim = try Simulation.make(seed: 1)
        for index in 0..<8 {
            sim.testing_destroyCameraAtIndex(index)
            _ = sim.step(command: .neutral(tick: UInt64(index + 1)))
        }
        let destroyed = sim.state.destructions.count
        let blackout = sim.state.networkBlackout
        let armed = sim.state.extraction.armed
        #expect(destroyed == 8)
        #expect(blackout)
        #expect(!armed)
    }

    @Test func cameraT414LockdownDoesNotBlockExtraction() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_setExposure(1000)
        sim.testing_completeCombatGraph()
        _ = sim.step(command: .neutral(tick: 1))
        let armed = sim.state.extraction.armed
        let exposure = sim.state.exposure.exposure
        let destroyed = sim.state.destructions.count
        #expect(armed)
        #expect(exposure == 1000)
        #expect(destroyed == 0)
    }

    @Test func cameraCD005SimultaneousFinalImpactsDestroyOnce() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_keepOnlyCamera(at: 0, integrity: 1)
        let camera = sim.state.cameras[0]
        sim.testing_injectPulseHitting(camera: camera)
        sim.testing_injectPulseHitting(camera: camera)
        let result = sim.step(command: .neutral(tick: 1))
        let destroyed = sim.state.destructions.count
        let exposure = sim.state.exposure.exposure
        let events = result.events.filter { $0.type == .cameraDestroyed }.count
        let integrity = sim.state.cameras[0].integrity
        #expect(destroyed == 1)
        #expect(events == 1)
        #expect(exposure == 150)
        #expect(integrity == 0)
    }

    @Test func cameraCD006RicochetDestroysTwoCamerasSameTick() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_selectUpgrade(.ricochetPulse)
        sim.testing_relocateCamera(at: 0, position: VecI(x: 200, y: 200), headingMilli: MilliDeg.right)
        sim.testing_relocateCamera(at: 1, position: VecI(x: 280, y: 200), headingMilli: MilliDeg.right)
        sim.testing_keepCameras([0, 1], integrity: 1)
        let first = sim.state.cameras[0]
        let id0 = first.entityId.raw
        let id1 = sim.state.cameras[1].entityId.raw
        sim.testing_injectPulseHitting(camera: first)
        let result = sim.step(command: .neutral(tick: 1))
        let destroyed = sim.state.destructions.count
        let exposure = sim.state.exposure.exposure
        let eventIds = result.events.filter { $0.type == .cameraDestroyed }.compactMap { $0.primaryEntityId?.raw }
        let ordered = [id0, id1].sorted()
        let eventsMatch = eventIds == ordered
        #expect(destroyed == 2)
        #expect(exposure == 300)
        #expect(eventIds.count == 2)
        #expect(eventsMatch)
    }

    @Test func cameraRicochetDoesNotRehitSurvivingSource() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_selectUpgrade(.ricochetPulse)
        sim.testing_relocateCamera(at: 0, position: VecI(x: 200, y: 200), headingMilli: MilliDeg.right)
        sim.testing_relocateCamera(at: 1, position: VecI(x: 280, y: 200), headingMilli: MilliDeg.right)
        sim.testing_keepCameras([0, 1], integrity: 3)
        let first = sim.state.cameras[0]
        sim.testing_injectPulseHitting(camera: first)
        _ = sim.step(command: .neutral(tick: 1))
        let integrity0 = sim.state.cameras[0].integrity
        let integrity1 = sim.state.cameras[1].integrity
        let destroyed = sim.state.destructions.count
        let exposure = sim.state.exposure.exposure
        #expect(integrity0 == 2)
        #expect(integrity1 == 2)
        #expect(destroyed == 0)
        #expect(exposure == 0)
    }
}

private func payloadInt(_ event: AuthoritativeEvent, _ key: String) -> Int {
    if case .integer(let value)? = event.payload[key] { return Int(value) }
    return 0
}
