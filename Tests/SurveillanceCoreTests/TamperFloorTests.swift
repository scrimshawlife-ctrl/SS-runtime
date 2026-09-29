import Testing
@testable import SurveillanceCore

/// D-084 Tamper floor: recovery never takes Exposure below
/// `150 × Cameras destroyed this run`; the floor never raises Exposure.
@Suite(.serialized)
struct TamperFloorTests {
    /// EX-011: 3 Cameras destroyed, Exposure 500, 200 no-contact ticks: stops
    /// at 450 and never goes below.
    @Test func exposureEX011RecoveryStopsAtTheFloor() {
        var state = ExposureState(exposure: 500, detectionState: .tracked)
        var lowest = Int.max
        for _ in 0..<200 {
            _ = state.resolveTick(survivingContactCount: 0, tamperAmounts: [], signalJammer: false, destroyedCameras: 3)
            lowest = min(lowest, state.exposure)
        }
        #expect(state.exposure == 450)
        #expect(lowest == 450)
        #expect(state.detectionState == .tracked)
        // Without the floor the same ticks recover to 220: the floor is what stops it.
        var unfloored = ExposureState(exposure: 500, detectionState: .tracked)
        for _ in 0..<200 {
            _ = unfloored.resolveTick(survivingContactCount: 0, tamperAmounts: [], signalJammer: false)
        }
        #expect(unfloored.exposure == 220)
    }

    /// EX-012: 1 Camera destroyed, Exposure 120 (below the floor), no contact:
    /// recovery does not apply and Exposure is not raised to 150.
    @Test func exposureEX012FloorNeverRaisesExposure() {
        var state = ExposureState(exposure: 120, detectionState: .hidden, noContactTicks: 100)
        let resolution = state.resolveTick(
            survivingContactCount: 0, tamperAmounts: [], signalJammer: false, destroyedCameras: 1
        )
        #expect(state.exposure == 120)
        #expect(resolution.after == resolution.before)
        #expect(resolution.stateAfter == resolution.stateBefore)
    }

    /// The floor limits recovery only: contact and Tamper still add on top.
    @Test func exposureTamperFloorAddsNothingToASpike() {
        var state = ExposureState(exposure: 300, detectionState: .observed)
        _ = state.resolveTick(survivingContactCount: 0, tamperAmounts: [100], signalJammer: false, destroyedCameras: 3)
        #expect(state.exposure == 400)
    }

    /// Through the simulation: after one destruction (+150 Tamper, D-086),
    /// Exposure raised to 400 recovers only to the 150 floor; with no Camera
    /// destroyed the same Exposure recovers to zero.
    @Test(arguments: [true, false])
    func exposureTamperFloorThroughTheSimulation(destroy: Bool) throws {
        var sim = try Simulation.make(seed: 1)
        // Every other Camera is out of play, so no field touches the Player.
        sim.testing_keepOnlyCamera(at: 0, integrity: destroy ? 1 : 0)
        if destroy {
            sim.testing_injectPulseHitting(camera: sim.state.cameras[0])
        }
        _ = sim.step(command: .neutral(tick: 1))
        #expect(sim.state.exposure.exposure == (destroy ? 150 : 0))
        sim.testing_setExposure(400)
        #expect(sim.state.destructions.count == (destroy ? 1 : 0))
        for _ in 0..<300 {
            _ = sim.step(command: .neutral(tick: sim.state.tick + 1))
        }
        #expect(sim.state.exposure.exposure == (destroy ? 150 : 0))
    }
}
