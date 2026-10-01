import Foundation
import Testing
@testable import SurveillanceCore

/// D-101 HUD (hud-tutorial.md UI-009 to UI-011).
@Suite(.serialized)
struct QuietApproachPresentationTests {
    @Test func ui009TheTagShowsAtRunStart() throws {
        let sim = try Simulation.make(seed: 1)
        var projector = QuietApproachProjector()
        let frame = projector.project(tick: 0, events: [], state: sim.state)
        #expect(frame.tagVisible)
        #expect(frame.caption == nil)
    }

    @Test func ui010LosingItRemovesTheTagWithACaption() throws {
        var sim = try Simulation.make(seed: 1)
        var projector = QuietApproachProjector()
        _ = projector.project(tick: 0, events: [], state: sim.state)
        sim.testing_setExposure(450)
        let result = sim.step(command: .neutral(tick: 1))
        let frame = projector.project(tick: result.tick, events: result.events, state: sim.state)
        #expect(!frame.tagVisible)
        #expect(frame.caption == "QUIET APPROACH LOST")
        // Shown for the 2.5 s caption time, then gone; never shown again.
        let later = projector.project(tick: result.tick + QuietApproachProjector.visibleTicks, events: [], state: sim.state)
        #expect(later.caption == nil)
        #expect(!later.tagVisible)
    }

    @Test func ui011ThePayoutCaptionNamesTheRestoredIntegrity() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeMobAndEliteGraph()
        let trigger = try #require(sim.state.arena.encounterTriggers.first { ($0.encounterId ?? $0.id) == "algorithmicModerate" })
        sim.testing_setPlayerPosition(trigger.aabb.center)
        sim.testing_setPlayerIntegrity(40)
        var projector = QuietApproachProjector()
        _ = projector.project(tick: 0, events: [], state: sim.state)
        let result = sim.step(command: .neutral(tick: 1))
        #expect(result.events.contains { $0.type == .bossActivated })
        let frame = projector.project(tick: result.tick, events: result.events, state: sim.state)
        #expect(frame.caption == "QUIET APPROACH • INTEGRITY 90")
        #expect(!frame.tagVisible, "paid out: the caption replaces the tag")
    }

    /// A run already past activation when the projector starts (a seeded
    /// boss scenario) shows no tag either.
    @Test func noTagOnceTheBossIsUpEvenWithoutTheActivationEvent() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeMobAndEliteGraph()
        let trigger = try #require(sim.state.arena.encounterTriggers.first { ($0.encounterId ?? $0.id) == "algorithmicModerate" })
        sim.testing_setPlayerPosition(trigger.aabb.center)
        _ = sim.step(command: .neutral(tick: 1))
        #expect(sim.state.exposure.quietApproach)
        var projector = QuietApproachProjector()
        let frame = projector.project(tick: 2, events: [], state: sim.state)
        #expect(!frame.tagVisible)
    }

    @Test func aLostApproachHasNoPayoutCaption() throws {
        var sim = try Simulation.make(seed: 1)
        sim.testing_completeMobAndEliteGraph()
        sim.testing_setQuietApproach(false)
        let trigger = try #require(sim.state.arena.encounterTriggers.first { ($0.encounterId ?? $0.id) == "algorithmicModerate" })
        sim.testing_setPlayerPosition(trigger.aabb.center)
        var projector = QuietApproachProjector()
        _ = projector.project(tick: 0, events: [], state: sim.state)
        let result = sim.step(command: .neutral(tick: 1))
        let frame = projector.project(tick: result.tick, events: result.events, state: sim.state)
        #expect(frame.caption == nil)
        #expect(!frame.tagVisible)
    }

    @Test func theRowsDoNotOverlapTheLayoutTable() {
        let tag = QuietApproachProjector.tagRect
        let label = HUDLayout.detectionLabel()
        // Anchors are top-left: the tag sits clear of the label's right edge.
        #expect(tag.x >= label.x + label.width)
        #expect(tag.y == label.y)
        let caption = QuietApproachProjector.captionRect
        let boss = HUDLayout.bossIntegrity()
        #expect(caption.y >= boss.y + boss.height)
        #expect(caption.y + caption.height <= HUDLayout.extractionCountdown().y)
        #expect(caption.y >= HeatCaptionProjector.referenceRect.y + HeatCaptionProjector.referenceRect.height)
    }
}
