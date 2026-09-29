import Foundation
import Testing
@testable import SurveillanceCore

/// D-088 game feel: `procedural-vfx-002`'s four big moments, the reduced
/// variants, the live effect pool, hit-stop, shake, the Blackout music drop,
/// and the proof that none of it reaches the simulation.
@Suite(.serialized)
struct GameFeelTests {
    // MARK: - Contract

    @Test func catalog002CarriesTheFourBigMoments() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        #expect(catalog.schemaVersion == "procedural-vfx-002")
        #expect(catalog.recipes.count == 14)
        let byId = catalog.recipesById
        let kill = try #require(byId["cameraDestroyed"])
        let blackout = try #require(byId["networkBlackout"])
        let phase = try #require(byId["bossPhaseBreak"])
        let heat = try #require(byId["heatReinforcements"])
        #expect(kill.eventTypes == [.cameraDestroyed])
        #expect(blackout.eventTypes == [.allCamerasDestroyed])
        #expect(phase.eventTypes == [.bossPhaseChanged])
        #expect(heat.eventTypes == [.waveStarted])
        #expect(kill.defaultVariant.hitStopMs == 50)
        #expect(phase.defaultVariant.hitStopMs == 90)
        #expect(catalog.hitStopCapMs(for: "bossPhaseBreak") == 90)
        #expect(catalog.hitStopCapMs(for: "cameraDestroyed") == 50)
        #expect(blackout.defaultVariant.lifetimeMs == 1500)
        #expect(blackout.reducedVariant.hitStopMs == 0)
        for recipe in catalog.recipes {
            #expect(!recipe.reducedVariant.screenShake, "\(recipe.id) shakes under Reduced Motion")
            #expect(!recipe.defaultVariant.fullScreenFlash && !recipe.reducedVariant.fullScreenFlash)
        }
    }

    @Test func bossPhaseBreakAboveTheCaptainCapFailsClosed() throws {
        let json = try mutated(recipe: "bossPhaseBreak") { $0["hitStopMs"] = 91 }
        #expect(throws: ProceduralVFXError.budget("bossPhaseBreak")) { try ProceduralVFXLoader.decode(json) }
    }

    @Test func cameraDestroyedTakesTheStandardCap() throws {
        let json = try mutated(recipe: "cameraDestroyed") { $0["hitStopMs"] = 60 }
        #expect(throws: ProceduralVFXError.budget("cameraDestroyed")) { try ProceduralVFXLoader.decode(json) }
    }

    @Test func blackoutShorterThanTheSpecifiedCascadeFailsClosed() throws {
        let json = try mutated(recipe: "networkBlackout") { $0["lifetimeMs"] = 1400 }
        #expect(throws: ProceduralVFXError.budget("networkBlackout")) { try ProceduralVFXLoader.decode(json) }
    }

    @Test func the001SchemaIsNoLongerAccepted() throws {
        var root = try JSONSerialization.jsonObject(with: SpecBundle.contract("procedural-vfx-002")) as! [String: Any]
        root["schemaVersion"] = "procedural-vfx-001"
        let json = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: ProceduralVFXError.schemaVersion) { try ProceduralVFXLoader.decode(json) }
    }

    // MARK: - Projection of the four new recipes

    @Test func cameraDestroyedProjectsShatterAndReducedCrack() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        let event = Self.event(.cameraDestroyed, primary: 42)
        var projector = VFXProjector()
        let standard = try #require(projector.project(tick: 5, events: [event], catalog: catalog).presentations.first)
        #expect(standard.recipeId == "cameraDestroyed")
        #expect(standard.language == "lensShatterAndSparkBurst")
        #expect(standard.particleCount == 10)
        #expect(standard.hitStopMs == 50)
        #expect(standard.screenShake)
        #expect(standard.sourceEntityId == EntityID(42))
        let reduced = try #require(
            projector.project(tick: 6, events: [event], catalog: catalog, settings: .reduced).presentations.first
        )
        #expect(reduced.language == "staticCrackAndFieldCut")
        #expect(reduced.particleCount == 0)
        #expect(reduced.hitStopMs == 50)
        #expect(!reduced.screenShake)
        #expect(reduced.reduced)
    }

    @Test func networkBlackoutCascadesInStableIdOrder() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        let ids: [UInt64] = [31, 7, 19, 3, 44, 12, 27, 8]
        let projection = projector.project(
            tick: 9,
            events: [Self.event(.allCamerasDestroyed, payload: ["destroyedCount": .integer(8), "totalCount": .integer(8)])],
            catalog: catalog,
            context: VFXProjectionContext(cameraIds: ids.map(EntityID.init))
        )
        let blackout = try #require(projection.presentations.first { $0.recipeId == "networkBlackout" })
        #expect(blackout.language == "fieldsCascadeOffAndSceneDim")
        #expect(blackout.label == "NETWORK BLACKOUT")
        #expect(blackout.hitStopMs == 50)
        #expect(!blackout.screenShake)
        #expect(blackout.cascade.map(\.cameraId.raw) == ids.sorted())
        let offsets = blackout.cascade.map(\.offsetMs)
        #expect(offsets.first == 0)
        #expect(offsets == offsets.sorted())
        #expect(Set(offsets).count == offsets.count)
        #expect(offsets.allSatisfy { $0 < 1500 })
    }

    @Test func networkBlackoutReducedIsAStaticBannerWithNoHitStop() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        let flashOnly = PresentationVFXSettings(reducedMotion: false, reducedFlash: true)
        let blackout = try #require(projector.project(
            tick: 9,
            events: [Self.event(.allCamerasDestroyed)],
            catalog: catalog,
            settings: flashOnly,
            context: VFXProjectionContext(cameraIds: [EntityID(2), EntityID(1)])
        ).presentations.first)
        #expect(blackout.language == "staticBlackoutBanner")
        #expect(blackout.hitStopMs == 0)
        #expect(blackout.label == "NETWORK BLACKOUT")
        #expect(blackout.reduced)
    }

    @Test func bossPhaseBreakSlamsThePhaseNameButNotOnActivation() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        let activation = Self.event(.bossPhaseChanged, primary: 90, payload: [
            "before": .null, "after": .string("publicSafety"), "remainingIntegrity": .integer(800)
        ])
        let onActivation = projector.project(tick: 1, events: [activation], catalog: catalog)
        #expect(onActivation.presentations.isEmpty)
        let change = Self.event(.bossPhaseChanged, primary: 90, payload: [
            "before": .string("publicSafety"), "after": .string("civilLiberties"), "remainingIntegrity": .integer(599)
        ])
        let slam = try #require(projector.project(tick: 2, events: [change], catalog: catalog).presentations.first)
        #expect(slam.recipeId == "bossPhaseBreak")
        #expect(slam.language == "phaseNameSlamAndRingRelease")
        #expect(slam.label == "CIVIL LIBERTIES")
        #expect(slam.hitStopMs == 90)
        #expect(slam.screenShake)
        let cut = try #require(
            projector.project(tick: 3, events: [change], catalog: catalog, settings: .reduced).presentations.first
        )
        #expect(cut.language == "phaseNameCutIn")
        #expect(cut.hitStopMs == 90)
        #expect(!cut.screenShake)
        #expect(VFXProjector.phaseTitle("independentReview") == "INDEPENDENT REVIEW")
    }

    /// D-083 heat is not on main (SS-runtime #101): the recipe is inert until
    /// a caller reports reinforcements.
    @Test func heatReinforcementsIsInertWithoutReinforcements() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        let wave = Self.event(.waveStarted, payload: ["encounterId": .string("M-A"), "waveId": .string("w1")])
        let unreinforced = projector.project(tick: 1, events: [wave], catalog: catalog)
        #expect(unreinforced.presentations.isEmpty)
        let reinforced = VFXProjectionContext(heatReinforcements: 2)
        let chevrons = try #require(
            projector.project(tick: 2, events: [wave], catalog: catalog, context: reinforced).presentations.first
        )
        #expect(chevrons.recipeId == "heatReinforcements")
        #expect(chevrons.language == "edgeChevronsTowardSpawnSockets")
        #expect(chevrons.hitStopMs == 0)
        let still = try #require(projector.project(
            tick: 3, events: [wave], catalog: catalog, settings: .reduced, context: reinforced
        ).presentations.first)
        #expect(still.language == "staticEdgeChevrons")
    }

    // MARK: - Pool

    @Test func poolRecyclesPastPoolSize() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        var pool = VFXPool(catalog: catalog)
        var evicted: [Int] = []
        for tick in 1...6 {
            let projection = projector.project(
                tick: UInt64(tick), events: [Self.event(.cameraDestroyed, primary: UInt64(tick))], catalog: catalog
            )
            evicted += pool.admit(projection.presentations, frame: UInt64(tick)).evicted
        }
        #expect(pool.liveCount("cameraDestroyed") == 4)
        #expect(evicted == [0, 1])
    }

    @Test func poolHoldsTheEmitterCeilingAcrossTicksAndKeepsBigMoments() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        var pool = VFXPool(catalog: catalog)
        let blackout = projector.project(
            tick: 1,
            events: [Self.event(.allCamerasDestroyed)],
            catalog: catalog,
            context: VFXProjectionContext(cameraIds: [EntityID(1)])
        )
        _ = pool.admit(blackout.presentations, frame: 1)
        for tick in 2...6 {
            var events: [AuthoritativeEvent] = []
            for index in 0..<6 {
                events.append(Self.event(.entityDied, primary: UInt64(100 + tick * 10 + index), insertion: index))
                events.append(Self.event(.entityDamaged, primary: UInt64(200 + tick * 10 + index), insertion: 6 + index))
            }
            let projection = projector.project(tick: UInt64(tick), events: events, catalog: catalog)
            _ = pool.admit(projection.presentations, frame: UInt64(tick))
            #expect(pool.live.count <= catalog.maxConcurrentEmitters)
            for recipe in catalog.recipes {
                #expect(pool.liveCount(recipe.id) <= recipe.poolSize)
            }
        }
        #expect(pool.liveCount("networkBlackout") == 1)
    }

    @Test func poolExpiresEffectsAfterTheirLifetime() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        var pool = VFXPool(catalog: catalog)
        let hit = projector.project(tick: 1, events: [Self.event(.entityDamaged, primary: 5)], catalog: catalog)
        _ = pool.admit(hit.presentations, frame: 10)
        // enemyHit lives 120 ms: 8 frames at 60 Hz.
        let early = pool.expire(frame: 17)
        let due = pool.expire(frame: 18)
        #expect(early.isEmpty)
        #expect(due == [0])
        #expect(pool.live.isEmpty)
    }

    // MARK: - Hit-stop and shake

    @Test func hitStopFramesStayInsideTheCaps() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        #expect(PresentationFrameRate.framesWithin(ms: 50) == 3)
        #expect(PresentationFrameRate.framesWithin(ms: 90) == 5)
        var projector = VFXProjector()
        var clock = HitStopClock()
        let change = Self.event(.bossPhaseChanged, primary: 90, payload: [
            "before": .string("publicSafety"), "after": .string("civilLiberties")
        ])
        let projection = projector.project(
            tick: 1, events: [Self.event(.entityDamaged, primary: 5), change], catalog: catalog
        )
        clock.admit(projection.presentations, catalog: catalog)
        // Same-tick impacts coalesce to the longest, never the sum.
        #expect(clock.remainingFrames == 5)
        var frozen = 0
        while clock.consumeFrame() { frozen += 1 }
        #expect(frozen == 5)
        #expect(clock.freezes == 1)
        #expect(!clock.isFrozen)
    }

    @Test func shakeIsBoundedCoalescedAndOffUnderReducedMotion() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        var shake = ScreenShake()
        let kill = projector.project(tick: 1, events: [Self.event(.cameraDestroyed, primary: 3)], catalog: catalog)
        for _ in 0..<20 {
            shake.admit(kill.presentations, reducedMotion: false)
            let offset = shake.advance()
            #expect((offset.x * offset.x + offset.y * offset.y).squareRoot() <= ScreenShake.maxAmplitude + 1e-9)
            #expect(shake.peak <= 4)
        }
        shake.admit(kill.presentations, reducedMotion: false)
        var frames = 0
        while shake.amplitude > 0 { _ = shake.advance(); frames += 1 }
        #expect(frames == ScreenShake.durationFrames)
        shake.admit(kill.presentations, reducedMotion: true)
        let still = shake.advance()
        #expect(still.x == 0 && still.y == 0)
        let reducedKill = projector.project(
            tick: 2, events: [Self.event(.cameraDestroyed, primary: 3)], catalog: catalog, settings: .reduced
        )
        shake.admit(reducedKill.presentations, reducedMotion: false)
        #expect(shake.amplitude == 0)
    }

    @Test func blackoutMusicDropDucksHoldsAndRestores() {
        #expect(BlackoutMusicDrop.gain(atSeconds: 0) == 1)
        #expect(abs(BlackoutMusicDrop.gain(atSeconds: 0.05) - 0.5) < 1e-9)
        #expect(BlackoutMusicDrop.gain(atSeconds: 0.1) == 0)
        #expect(BlackoutMusicDrop.gain(atSeconds: 1.09) == 0)
        #expect(abs(BlackoutMusicDrop.gain(atSeconds: 1.35) - 0.5) < 1e-9)
        #expect(BlackoutMusicDrop.gain(atSeconds: 1.6) == 1)
        #expect(BlackoutMusicDrop.cueDelaySeconds == 0.1)
        #expect(abs(BlackoutMusicDrop.totalSeconds - 1.6) < 1e-9)
    }

    // MARK: - A real Blackout, played

    /// The `blackout` debug scenario leaves one Camera in the line of fire; the
    /// weapon's kill publishes `cameraDestroyed` and `allCamerasDestroyed` in
    /// one tick, and the cascade covers every Camera in stable-ID order.
    @Test func playedBlackoutProjectsKillThenCascadeInIdOrder() throws {
        var sim = try Simulation.make(seed: 1)
        let seeded = sim.debug_seedScenario("blackout")
        #expect(seeded)
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        var found: VFXProjection?
        while sim.state.tick < 600, found == nil {
            let result = sim.step(command: .neutral(tick: sim.state.tick + 1))
            guard result.events.contains(where: { $0.type == .allCamerasDestroyed }) else { continue }
            found = projector.project(
                tick: result.tick,
                events: result.events,
                catalog: catalog,
                context: VFXProjectionContext(cameraIds: sim.state.cameras.map(\.entityId))
            )
        }
        let projection = try #require(found)
        let ids = projection.presentations.map(\.recipeId)
        #expect(ids.contains("cameraDestroyed"))
        #expect(ids.contains("networkBlackout"))
        let blackout = try #require(projection.presentations.first { $0.recipeId == "networkBlackout" })
        #expect(blackout.cascade.count == sim.state.cameras.count)
        #expect(blackout.cascade.map(\.cameraId) == sim.state.cameras.map(\.entityId).sorted())
        #expect(sim.state.networkBlackout)
    }

    // MARK: - Determinism

    /// Hit-stop, shake, and the pool never change the run. The same piloted
    /// run, driven once plainly and once through the app's frame loop with the
    /// VFX layer live (frozen frames skip the step), ends on the same tick,
    /// commands, digest, and receipt.
    @Test func hitStopNeverChangesTheDigestOrReceipt() throws {
        // The plain run is the T901 piloted run (seed 1, Ricochet Pulse,
        // competent), already driven once in this process without any VFX.
        let live = try #require(PacingProbeTests.pilotedRun)
        var replayed = try Simulation.make(seed: 1)
        for command in live.commands { replayed.step(command: command) }
        let plain = Drive(
            ticks: live.ticks,
            frames: live.ticks,
            frozenFrames: 0,
            freezes: 0,
            commands: live.commands,
            digest: live.digest,
            receipt: RunReceipt(replayed.state),
            sawBlackout: false
        )
        let felt = try Self.drive(seed: 1, upgrade: .ricochetPulse, feel: true)
        #expect(replayed.state.digest() == live.digest)
        #expect(felt.frozenFrames > 0)
        #expect(felt.frames == felt.ticks + UInt64(felt.frozenFrames))
        #expect(felt.ticks == plain.ticks)
        #expect(felt.commands == plain.commands)
        #expect(felt.digest == plain.digest)
        #expect(felt.receipt == plain.receipt)
        #expect(felt.receipt.canonical() == plain.receipt.canonical())
        print(
            "D088-HITSTOP ticks=\(felt.ticks) frames=\(felt.frames) frozen=\(felt.frozenFrames) "
                + "freezes=\(felt.freezes) stretch=\(Double(felt.frames) / Double(felt.ticks))"
        )
    }

    /// The same, through a Camera kill and Network Blackout.
    @Test func hitStopNeverChangesTheDigestThroughABlackout() throws {
        let plain = try Self.drive(seed: 1, upgrade: .signalJammer, feel: false, scenario: "blackout", ticks: 900)
        let felt = try Self.drive(seed: 1, upgrade: .signalJammer, feel: true, scenario: "blackout", ticks: 900)
        #expect(felt.sawBlackout && plain.sawBlackout)
        #expect(felt.frozenFrames > 0)
        #expect(felt.ticks == plain.ticks)
        #expect(felt.digest == plain.digest)
        #expect(felt.receipt == plain.receipt)
    }

    private struct Drive {
        var ticks: UInt64
        var frames: UInt64
        var frozenFrames: Int
        var freezes: Int
        var commands: [PlayerCommand]
        var digest: String
        var receipt: RunReceipt
        var sawBlackout: Bool
    }

    /// The app's frame loop (`GameScene.update`) in miniature: one display
    /// frame at a time, a frozen frame steps nothing, and the pilot decides
    /// only on frames that step.
    private static func drive(
        seed: UInt64,
        upgrade: UpgradeID,
        feel: Bool,
        scenario: String? = nil,
        ticks limit: UInt64 = PacingProbe.tickCeiling
    ) throws -> Drive {
        var sim = try Simulation.make(seed: seed)
        if let scenario { _ = sim.debug_seedScenario(scenario) }
        var pilot = ProbePilot(profile: .competent, arena: sim.state.arena)
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        var clock = HitStopClock()
        var shake = ScreenShake()
        var pool = VFXPool(catalog: catalog)
        var commands: [PlayerCommand] = []
        var frames: UInt64 = 0
        var sawBlackout = false
        while !sim.isTerminal, sim.state.tick < limit {
            frames += 1
            if feel, clock.consumeFrame() {
                _ = shake.advance()
                continue
            }
            let steer = pilot.command(PresentationSnapshot(sim.state))
            if pilot.stalled { break }
            let tick = sim.state.tick + 1
            let command = sim.state.upgrade.pending
                ? PlayerCommand(tick: tick, moveX: 0, moveY: 0, dodgePressed: false, upgradeChoiceIndex: upgrade.selectionIndex)
                : PlayerCommand(tick: tick, moveX: steer.moveX, moveY: steer.moveY, dodgePressed: steer.dodge)
            commands.append(command)
            let result = sim.step(command: command)
            if result.events.contains(where: { $0.type == .allCamerasDestroyed }) { sawBlackout = true }
            guard feel else { continue }
            let projection = projector.project(
                tick: result.tick,
                events: result.events,
                catalog: catalog,
                context: VFXProjectionContext(cameraIds: sim.state.cameras.map(\.entityId))
            )
            clock.admit(projection.presentations, catalog: catalog)
            shake.admit(projection.presentations, reducedMotion: false)
            _ = shake.advance()
            _ = pool.expire(frame: frames)
            _ = pool.admit(projection.presentations, frame: frames)
        }
        return Drive(
            ticks: sim.state.tick,
            frames: frames,
            frozenFrames: clock.frozenFrames,
            freezes: clock.freezes,
            commands: commands,
            digest: sim.state.digest(),
            receipt: RunReceipt(sim.state),
            sawBlackout: sawBlackout
        )
    }

    // MARK: - Helpers

    private static func event(
        _ type: EventType,
        primary: UInt64? = nil,
        payload: [String: CanonicalJSON] = [:],
        insertion: Int = 0
    ) -> AuthoritativeEvent {
        AuthoritativeEvent(
            tick: 1,
            phase: 10,
            type: type,
            primary: primary.map(EntityID.init),
            payload: payload,
            insertion: insertion
        )
    }

    private func mutated(recipe id: String, _ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var root = try JSONSerialization.jsonObject(with: SpecBundle.contract("procedural-vfx-002")) as! [String: Any]
        var recipes = root["recipes"] as! [[String: Any]]
        let index = recipes.firstIndex { $0["id"] as? String == id }!
        var variant = recipes[index]["default"] as! [String: Any]
        mutate(&variant)
        recipes[index]["default"] = variant
        root["recipes"] = recipes
        return try JSONSerialization.data(withJSONObject: root)
    }
}
