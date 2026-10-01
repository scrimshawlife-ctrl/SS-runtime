import CoreGraphics
import SpriteKit
import Testing
@testable import SSRuntime
@testable import SurveillanceCore

/// D-096 phase presentation on screen (bosses.md § Phase presentation): the
/// court light lights the world and never the HUD, only tints or darkens,
/// crossfades over 1 s, and desaturates under Reduced Flash; every boss
/// telegraph draws a countdown ring that closes over its duration and holds
/// still under Reduced Motion.
@Suite(.serialized)
@MainActor
struct BossCourtPresentationTests {
    /// A snapshot with the boss installed, optionally mid-telegraph.
    private static func bossSnapshot(telegraph remaining: Int? = nil) throws -> PresentationSnapshot {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeMobAndEliteGraph()
        sim.testing_installBoss()
        if let remaining { sim.testing_beginBossTelegraph(.safetyRationale, remaining: remaining) }
        return PresentationSnapshot(sim.state)
    }

    @Test func courtLightSitsOnTheWorldLayerAndNeverTheHUD() {
        let court = BossCourtRenderer()
        #expect(court.lightNode.blendMode == .multiply, "multiplies, so it can only tint or darken")
        #expect(court.lightNode.shader != nil)
        #expect(BossCourtRenderer.lightZ > VFXRenderer.worldZ)
        #expect(BossCourtRenderer.lightZ > CGFloat(WorldRenderer.Layer.allCases.map(\.rawValue).max() ?? 0))
        #expect(BossCourtRenderer.lightZ < VFXRenderer.screenZ)
        #expect(BossCourtRenderer.lightZ < 1000, "the HUD root sits at 1000")
    }

    @Test func noBossNoLight() throws {
        let court = BossCourtRenderer()
        court.update(PresentationSnapshot(try Simulation.make(seed: 1).state), settings: .standard)
        #expect(court.lightNode.isHidden)
        #expect(court.palette == .neutral)
        #expect(court.ringFrames.isEmpty)
    }

    @Test func lightFadesInOverOneSecondAndHoldsThePhasePalette() throws {
        let court = BossCourtRenderer()
        var snap = try Self.bossSnapshot()
        let phase = try #require(snap.boss?.phase)
        let start = snap.tick
        court.update(snap, settings: .standard)
        #expect(court.palette == .neutral, "the fade starts from no light")
        snap.tick = start + 30
        court.update(snap, settings: .standard)
        #expect(court.palette != .neutral && court.palette != CourtLighting.palette(phase))
        #expect(!court.lightNode.isHidden)
        snap.tick = start + 60
        court.update(snap, settings: .standard)
        #expect(court.palette == CourtLighting.palette(phase))
        let maxChannel = [court.palette.center, court.palette.edge].map(\.maxChannel).max() ?? 2
        #expect(maxChannel <= 1, "never brighter than the Lockdown tint's ceiling")
    }

    @Test func everyPhaseHasItsOwnLightAndCrossfadesOverOneSecond() throws {
        let court = BossCourtRenderer()
        var snap = try Self.bossSnapshot()
        var seen: [BossPhase: CourtPalette] = [:]
        for phase in BossPhase.receiptOrder {
            let before = court.palette
            snap.boss?.phase = phase
            court.update(snap, settings: .standard)
            #expect(court.palette == before, "a phase change starts from the light on screen")
            snap.tick += CourtLighting.crossfadeTicks / 2
            court.update(snap, settings: .standard)
            #expect(court.palette != CourtLighting.palette(phase), "still fading at 0.5 s")
            snap.tick += CourtLighting.crossfadeTicks / 2
            court.update(snap, settings: .standard)
            #expect(court.palette == CourtLighting.palette(phase), "settled at 1 s")
            seen[phase] = court.palette
        }
        #expect(Set(seen.values.map { "\($0)" }).count == 4)
    }

    @Test func reducedFlashDrawsTheSixtyPercentPalette() throws {
        let court = BossCourtRenderer()
        var snap = try Self.bossSnapshot()
        let phase = try #require(snap.boss?.phase)
        let settings = PresentationVFXSettings(reducedMotion: false, reducedFlash: true)
        court.update(snap, settings: settings)
        snap.tick += 60
        court.update(snap, settings: settings)
        #expect(court.palette == CourtLighting.palette(phase, reducedFlash: true))
    }

    @Test func bossTelegraphDrawsAClosingRing() throws {
        let court = BossCourtRenderer()
        let early = try Self.bossSnapshot(telegraph: 40)
        court.update(early, settings: .standard)
        let telegraph = try #require(early.telegraphs.first)
        let first = try #require(court.ringFrames[telegraph.key])
        let node = court.ringLayer.childNode(withName: BossCourtRenderer.ringPrefix + telegraph.key)
        #expect(node != nil)
        #expect(node?.position == CGPoint(x: telegraph.x, y: telegraph.y))

        let late = try Self.bossSnapshot(telegraph: 2)
        court.update(late, settings: .standard)
        let lateTelegraph = try #require(late.telegraphs.first)
        let second = try #require(court.ringFrames[lateTelegraph.key])
        #expect(second.radius < first.radius, "the ring closes toward resolve")

        // The telegraph resolves: its ring goes with it.
        court.update(try Self.bossSnapshot(), settings: .standard)
        #expect(court.ringFrames.isEmpty)
        #expect(court.ringLayer.children.isEmpty)
    }

    @Test func reducedMotionKeepsTheRingWithoutAPulse() throws {
        let reduced = PresentationVFXSettings(reducedMotion: true, reducedFlash: false)
        var widths: Set<Double> = []
        for remaining in 1...10 {
            let court = BossCourtRenderer()
            let snap = try Self.bossSnapshot(telegraph: remaining)
            court.update(snap, settings: reduced)
            let telegraph = try #require(snap.telegraphs.first)
            let frame = try #require(court.ringFrames[telegraph.key], "the ring stays")
            widths.insert(frame.lineWidth)
        }
        #expect(widths == [TelegraphRing.lineWidth])
    }

    @Test func ringLayerSitsJustAboveTheTelegraphs() {
        let court = BossCourtRenderer()
        #expect(court.ringLayer.zPosition > CGFloat(WorldRenderer.Layer.telegraphs.rawValue))
        #expect(court.ringLayer.zPosition < CGFloat(WorldRenderer.Layer.mines.rawValue))
    }
}
