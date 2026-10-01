import Foundation
import Testing
@testable import SurveillanceCore

/// D-096 Captain Court climax (bosses.md § Captain Court threshold, § Phase
/// presentation; BO-020, BO-021; `combat-content-005`).
@Suite(.serialized)
struct CourtClimaxTests {
    /// A run with the mob and elite graph complete and the Player standing in
    /// the boss trigger at `integrity`, stepped once: the boss activates on
    /// that tick.
    private static func activateBoss(playerIntegrity integrity: Int) throws -> (Simulation, TickResult) {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeMobAndEliteGraph()
        let trigger = try #require(sim.state.arena.encounterTriggers.first {
            ($0.encounterId ?? $0.id) == "algorithmicModerate"
        })
        sim.testing_setPlayerPosition(trigger.aabb.center)
        sim.testing_setPlayerIntegrity(integrity)
        let result = sim.step(command: .neutral(tick: 1))
        return (sim, result)
    }

    @Test func bo020BossActivationRaisesPlayerFrom40To90() throws {
        let (sim, result) = try Self.activateBoss(playerIntegrity: 40)
        let activation = try #require(result.events.first { $0.type == .bossActivated })
        #expect(activation.phase == 16)
        #expect(sim.state.player.integrity == 90)
        #expect(sim.state.player.integrityRestored == 50)
        // A restore, not damage: no damage booked, no damage event.
        #expect(sim.state.player.damageTaken == 0)
        #expect(!result.events.contains { $0.type == .playerDamaged })
    }

    @Test func bo021BossActivationLeaves120Unchanged() throws {
        let (sim, result) = try Self.activateBoss(playerIntegrity: 120)
        #expect(result.events.contains { $0.type == .bossActivated })
        #expect(sim.state.player.integrity == 120)
        #expect(sim.state.player.integrityRestored == 0)
    }

    @Test func thresholdAppliesOnlyOnTheActivationTick() throws {
        var (sim, _) = try Self.activateBoss(playerIntegrity: 40)
        sim.testing_setPlayerIntegrity(30)
        _ = sim.step(command: .neutral(tick: 2))
        #expect(sim.state.player.integrity <= 30)
        #expect(sim.state.player.integrityRestored == 50)
    }

    @Test func receiptRecordsTheRestoreApartFromDamage() throws {
        let (sim, _) = try Self.activateBoss(playerIntegrity: 40)
        let receipt = RunReceipt(sim.state)
        #expect(receipt.integrityRestored == 50)
        #expect(receipt.damageTaken == 0)
        let serialized = receipt.canonical().serialize()
        #expect(serialized.contains("\"integrityRestored\":50"))
        #expect(serialized.contains("\"damageTaken\":0"))
    }

    @Test func receiptRestoreIsZeroWithoutTheBoss() throws {
        let sim = try Simulation.make(seed: 1)
        let receipt = RunReceipt(sim.state)
        #expect(receipt.integrityRestored == 0)
        #expect(receipt.canonical().serialize().contains("\"integrityRestored\":0"))
    }

    @Test func bossSpawnsWithTenDpsContact() throws {
        let (sim, _) = try Self.activateBoss(playerIntegrity: 150)
        let boss = try #require(sim.state.enemies.first { $0.archetype == .algorithmicModerate })
        #expect(boss.contactDps == 10)
    }

    // MARK: Court lighting

    @Test func everyPaletteOnlyTintsOrDarkens() {
        for phase in BossPhase.receiptOrder {
            for reduced in [false, true] {
                let palette = CourtLighting.palette(phase, reducedFlash: reduced)
                for m in [palette.center, palette.edge] {
                    // Never brighter than the Lockdown tint, whose multiplier
                    // never exceeds 1 in any channel.
                    #expect(m.maxChannel <= 1.0 + 1e-12, "\(phase) reduced=\(reduced)")
                    #expect(min(m.red, m.green, m.blue) > 0, "\(phase)")
                }
            }
        }
        let lockdownPeak = LockdownTint.multiplier(opacity: LockdownTint.peakOpacity)
        #expect(max(lockdownPeak.red, lockdownPeak.green, lockdownPeak.blue) == 1)
    }

    @Test func palettesMatchTheirNamedLight() {
        let safety = CourtLighting.palette(.publicSafety)
        #expect(safety.edge.blue > safety.edge.red)
        let amber = CourtLighting.palette(.civilLiberties)
        #expect(amber.edge.red > amber.edge.green && amber.edge.green > amber.edge.blue)
        let red = CourtLighting.palette(.temporarySafeguard)
        #expect(red.edge.red > red.edge.green * 2)
        let review = CourtLighting.palette(.independentReview)
        #expect(review.center == .neutral)
        #expect(review.edge.blue > review.edge.red)
        let all = BossPhase.receiptOrder.map(CourtLighting.palette)
        #expect(Set(all.map { "\($0)" }).count == 4)
    }

    @Test func reducedFlashLowersSaturationTo60Percent() {
        for phase in BossPhase.receiptOrder {
            let base = CourtLighting.palette(phase)
            let reduced = CourtLighting.palette(phase, reducedFlash: true)
            for (b, r) in [(base.center, reduced.center), (base.edge, reduced.edge)] {
                #expect(abs(r.spread - 0.6 * b.spread) < 1e-9, "\(phase)")
                #expect(abs(r.luma - b.luma) < 1e-9, "\(phase)")
            }
        }
        #expect(CourtLighting.reducedFlashSaturation == 0.60)
    }

    @Test func crossfadeTakesOneSecond() {
        #expect(CourtLighting.crossfadeTicks == 60)
        let a = CourtLighting.palette(.publicSafety)
        let b = CourtLighting.palette(.civilLiberties)
        let start = CourtLighting.blended(from: .publicSafety, to: .civilLiberties, ticksSinceChange: 0, reducedFlash: false)
        let mid = CourtLighting.blended(from: .publicSafety, to: .civilLiberties, ticksSinceChange: 30, reducedFlash: false)
        let end = CourtLighting.blended(from: .publicSafety, to: .civilLiberties, ticksSinceChange: 60, reducedFlash: false)
        let after = CourtLighting.blended(from: .publicSafety, to: .civilLiberties, ticksSinceChange: 600, reducedFlash: false)
        #expect(start == a)
        #expect(end == b)
        #expect(after == b)
        #expect(abs(mid.edge.green - (a.edge.green + b.edge.green) / 2) < 1e-12)
    }

    @Test func trackerFadesInOnActivationAndBetweenPhases() {
        var tracker = CourtLightTracker()
        #expect(tracker.update(phase: nil, tick: 10, reducedFlash: false) == .neutral)
        #expect(tracker.update(phase: .publicSafety, tick: 100, reducedFlash: false) == .neutral)
        #expect(tracker.update(phase: .publicSafety, tick: 160, reducedFlash: false) == CourtLighting.palette(.publicSafety))
        _ = tracker.update(phase: .civilLiberties, tick: 400, reducedFlash: false)
        let half = tracker.update(phase: .civilLiberties, tick: 430, reducedFlash: false)
        #expect(half == CourtPalette.lerp(CourtLighting.palette(.publicSafety), CourtLighting.palette(.civilLiberties), 0.5))
        #expect(tracker.update(phase: .civilLiberties, tick: 460, reducedFlash: false) == CourtLighting.palette(.civilLiberties))
        // Boss defeated: the light fades back out.
        _ = tracker.update(phase: nil, tick: 900, reducedFlash: false)
        #expect(tracker.update(phase: nil, tick: 960, reducedFlash: false) == .neutral)
    }

    @Test func trackerChangeMidFadeNeverJumps() {
        var tracker = CourtLightTracker()
        _ = tracker.update(phase: .publicSafety, tick: 0, reducedFlash: false)
        let shown = tracker.update(phase: .publicSafety, tick: 20, reducedFlash: false)
        let next = tracker.update(phase: .civilLiberties, tick: 20, reducedFlash: false)
        #expect(next == shown)
    }

    @Test func trackerUsesReducedPalettes() {
        var tracker = CourtLightTracker()
        _ = tracker.update(phase: .temporarySafeguard, tick: 0, reducedFlash: true)
        #expect(tracker.update(phase: .temporarySafeguard, tick: 60, reducedFlash: true)
            == CourtLighting.palette(.temporarySafeguard, reducedFlash: true))
    }

    // MARK: Countdown rings

    @Test func ringClosesOverTheTelegraphDuration() {
        let first = TelegraphRing.frame(remainingTicks: 45, totalTicks: 45, reducedMotion: false)
        let last = TelegraphRing.frame(remainingTicks: 0, totalTicks: 45, reducedMotion: false)
        #expect(first.radius == TelegraphRing.startRadius)
        #expect(first.progress == 0)
        #expect(last.radius == TelegraphRing.endRadius)
        #expect(last.progress == 1)
        var previous = Double.infinity
        for remaining in stride(from: 45, through: 0, by: -1) {
            let frame = TelegraphRing.frame(remainingTicks: remaining, totalTicks: 45, reducedMotion: true)
            #expect(frame.radius < previous)
            previous = frame.radius
        }
    }

    @Test func ringPulsesOnlyWithoutReducedMotion() {
        var widths: Set<Double> = []
        var reducedWidths: Set<Double> = []
        for remaining in 0...14 {
            widths.insert(TelegraphRing.frame(remainingTicks: remaining, totalTicks: 45, reducedMotion: false).lineWidth)
            let reduced = TelegraphRing.frame(remainingTicks: remaining, totalTicks: 45, reducedMotion: true)
            reducedWidths.insert(reduced.lineWidth)
            // Reduced Motion keeps the ring itself, closing as usual.
            let full = TelegraphRing.frame(remainingTicks: remaining, totalTicks: 45, reducedMotion: false)
            #expect(reduced.radius == full.radius)
        }
        #expect(widths.count > 1)
        #expect(reducedWidths == [TelegraphRing.lineWidth])
        // No pulse before the final third.
        let early = TelegraphRing.frame(remainingTicks: 40, totalTicks: 45, reducedMotion: false)
        #expect(early.lineWidth == TelegraphRing.lineWidth)
    }

    @Test func ringsAreDrawnOnlyForTheBossTelegraphs() throws {
        let (sim, _) = try Self.activateBoss(playerIntegrity: 150)
        var armed = sim
        armed.testing_beginBossTelegraph(.safetyRationale, remaining: 30)
        let snap = PresentationSnapshot(armed.state)
        let boss = try #require(snap.boss)
        let telegraph = try #require(snap.telegraphs.first)
        #expect(TelegraphRing.applies(to: telegraph, bossId: boss.id))
        #expect(!TelegraphRing.applies(to: telegraph, bossId: nil))
        #expect(!TelegraphRing.applies(to: telegraph, bossId: EntityID(boss.id.raw + 1)))
    }
}
