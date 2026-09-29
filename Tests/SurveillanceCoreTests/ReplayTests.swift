import Foundation
import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct ReplayTests {
    @Test func unknownReplayIdentityFailsBeforeTickOne() throws {
        let json = """
        {"schemaVersion":"runtime-kernel-001","rulesetVersion":"unknown","contentVersion":"civic-seam-content-002","arenaVersion":"civic-seam-arena-002","seed":1,"commands":[]}
        """.data(using: .utf8)!
        let result = ReplayEnvelope.load(json: json)
        guard case .failure(.incompatibleIdentity) = result else {
            Issue.record("expected incompatible identity")
            return
        }
    }

    @Test func duplicateCommandTickIsRejected() throws {
        let json = """
        {"schemaVersion":"runtime-kernel-001","rulesetVersion":"ss-rules-004","contentVersion":"civic-seam-content-004","arenaVersion":"civic-seam-arena-003","seed":1,"commands":[{"tick":1,"moveX":0,"moveY":0,"dodgePressed":false},{"tick":1,"moveX":0,"moveY":0,"dodgePressed":false}]}
        """.data(using: .utf8)!
        let result = ReplayEnvelope.load(json: json)
        guard case .failure(.duplicateCommandTick(1)) = result else {
            Issue.record("expected duplicate tick")
            return
        }
    }

    @Test func smokeReplayLoadsAndExecutes() throws {
        let data = SpecBundle.fixture("replay-smoke-001")
        let envelope = try ReplayEnvelope.load(json: data).get()
        #expect(envelope.seed == 1)
        #expect(envelope.commands.count == 5)
        let executed = Simulation.execute(envelope)
        guard case .success(let result) = executed else {
            Issue.record("smoke replay failed to execute")
            return
        }
        #expect(result.tick >= 5)
        #expect(result.digest.count == 64)
    }

    @Test func restartRestoresInitialAuthoritativeState() throws {
        var sim = try Simulation.make(seed: 7)
        let initial = sim.state.digest()
        _ = sim.step(command: PlayerCommand(tick: 1, moveX: 32767, moveY: 0, dodgePressed: false))
        #expect(sim.state.digest() != initial)
        sim.restart()
        #expect(sim.state.digest() == initial)
        #expect(sim.state.cameras.allSatisfy { $0.integrity == 3 })
    }
}
