import Testing
@testable import SurveillanceCore

/// T700 — protected upgrade selection (FR-034, `upgrades.md` §Selection).
///
/// `ContractVectorTests` UP-001–UP-003 already pin the frozen clock and the
/// invalid-index rejection, but they open selection through
/// `testing_armUpgradeSelection`, so the real opening path and the
/// neutral-movement clause were never exercised. These close that gap:
///
/// - selection opens from genuine M-A completion, through `step`;
/// - the choices map to the specified order (Jammer, Ricochet, Ghost Step);
/// - a valid index is still refused unless movement is neutral and Dodge is
///   not pressed — "one index 0–2 and neutral movement";
/// - a missing index is refused without consuming a tick;
/// - an accepted choice applies and consumes exactly one tick.
@Suite(.serialized)
struct ProtectedUpgradeSelectionTests {
    private func command(tick: UInt64, x: Int = 0, y: Int = 0, dodge: Bool = false, choice: UInt8?) -> PlayerCommand {
        PlayerCommand(tick: tick, moveX: Int16(x), moveY: Int16(y), dodgePressed: dodge, upgradeChoiceIndex: choice)
    }

    /// Drive the real M-A completion branch and return the pending simulation.
    private func simulationPendingFromRealMACompletion() throws -> Simulation {
        var sim = try Simulation.make(seed: 1)
        sim.testing_primeEncounterForCompletion("M-A")
        #expect(!sim.state.upgrade.pending, "priming must not open selection by itself")
        let result = sim.step(command: nil)
        #expect(result.events.contains { $0.type == .mobEncounterCompleted })
        return sim
    }

    @Test func selectionOpensFromGenuineMACompletion() throws {
        let sim = try simulationPendingFromRealMACompletion()
        #expect(sim.state.encounters["M-A"]?.completed == true)
        #expect(sim.state.upgrade.pending)
        #expect(sim.state.upgrade.selected == nil)
        #expect(sim.state.outcome == .upgradeSelectionPending)
    }

    @Test func choicesMapToTheSpecifiedOrder() {
        #expect(UpgradeID.from(index: 0) == .signalJammer)
        #expect(UpgradeID.from(index: 1) == .ricochetPulse)
        #expect(UpgradeID.from(index: 2) == .ghostStep)
        #expect(UpgradeID.from(index: 3) == nil)
        for upgrade in UpgradeID.allCases {
            #expect(UpgradeID.from(index: upgrade.selectionIndex) == upgrade)
        }
    }

    @Test func clockIsFrozenWhileSelectionIsOpen() throws {
        var sim = try simulationPendingFromRealMACompletion()
        let tick = sim.state.tick
        let digest = sim.state.digest()
        for _ in 0..<600 { _ = sim.step(command: nil) }
        #expect(sim.state.tick == tick)
        #expect(sim.state.digest() == digest)
    }

    @Test(arguments: [(1, 0), (0, 1), (-32767, 0), (0, -1)])
    func validIndexWithMovementIsRefused(x: Int, y: Int) throws {
        var sim = try simulationPendingFromRealMACompletion()
        let tick = sim.state.tick
        let digest = sim.state.digest()
        let result = sim.step(command: command(tick: tick + 1, x: x, y: y, choice: 0))
        #expect(result.outcome == .upgradeSelectionPending)
        #expect(sim.state.upgrade.pending)
        #expect(sim.state.upgrade.selected == nil)
        #expect(sim.state.tick == tick)
        #expect(sim.state.digest() == digest)
    }

    @Test func validIndexWithDodgeIsRefused() throws {
        var sim = try simulationPendingFromRealMACompletion()
        let tick = sim.state.tick
        let digest = sim.state.digest()
        _ = sim.step(command: command(tick: tick + 1, dodge: true, choice: 1))
        #expect(sim.state.upgrade.pending)
        #expect(sim.state.upgrade.selected == nil)
        #expect(sim.state.tick == tick)
        #expect(sim.state.digest() == digest)
    }

    @Test func missingIndexIsRefusedWithoutConsumingATick() throws {
        var sim = try simulationPendingFromRealMACompletion()
        let tick = sim.state.tick
        let digest = sim.state.digest()
        _ = sim.step(command: command(tick: tick + 1, choice: nil))
        #expect(sim.state.upgrade.pending)
        #expect(sim.state.tick == tick)
        #expect(sim.state.digest() == digest)
    }

    @Test(arguments: UpgradeID.allCases)
    func acceptedChoiceAppliesAndConsumesExactlyOneTick(upgrade: UpgradeID) throws {
        var sim = try simulationPendingFromRealMACompletion()
        let tick = sim.state.tick
        let result = sim.step(command: command(tick: tick + 1, choice: upgrade.selectionIndex))
        #expect(sim.state.upgrade.selected == upgrade)
        #expect(!sim.state.upgrade.pending)
        #expect(sim.state.outcome == .playing)
        #expect(result.tick == tick + 1)
        #expect(sim.state.tick == tick + 1)
    }
}
