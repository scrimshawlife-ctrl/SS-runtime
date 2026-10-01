import Foundation
import Testing
@testable import SurveillanceCore

/// D-094 readability and finish pass: `animation.md` § 8b, `audio-haptics.md`
/// "On-screen captions (D-094)", `arena-layout.md` "Camera and viewport
/// framing" (arena `-004`). Presentation only: nothing here is a simulation
/// input.
@Suite(.serialized)
struct ReadabilityFinishTests {
    // MARK: - Viewport adoption

    @Test func arenaFourCarriesTheD094Viewport() throws {
        let arena = try ArenaManifest.bundled()
        #expect(arena.arenaVersion == "civic-seam-arena-004")
        #expect(ContractVersions.arena == "civic-seam-arena-004")
        #expect(arena.viewport.baselineWorldWidth == 704)
        #expect(arena.viewport.baselineWorldHeight == 326)
        #expect(arena.viewport.deadZoneWidth == 76)
        #expect(arena.viewport.deadZoneHeight == 50)
        #expect(arena.viewport.maximumLookAheadUnits == 76)
        #expect(ArenaReachability.viewportMatchesContract(arena))
    }

    @Test func presentationCameraShowsTheManifestViewport() throws {
        let arena = try ArenaManifest.bundled()
        #expect(PresentationCamera.visibleWidth == arena.viewport.baselineWorldWidth)
        #expect(PresentationCamera.visibleHeight == arena.viewport.baselineWorldHeight)
        #expect(PresentationCamera.lookAhead <= PresentationCamera.maxLookAhead)
        // The snapshot's camera keeps the whole view inside the arena.
        let snap = PresentationSnapshot(try Simulation.make(seed: 1).state)
        let bounds = snap.arenaBounds
        #expect(snap.camera.center.x - PresentationCamera.visibleWidth / 2 >= bounds.minX)
        #expect(snap.camera.center.y - PresentationCamera.visibleHeight / 2 >= bounds.minY)
        #expect(snap.camera.center.x + PresentationCamera.visibleWidth / 2 <= bounds.maxX)
        #expect(snap.camera.center.y + PresentationCamera.visibleHeight / 2 <= bounds.maxY)
    }

    /// The rules keep the pre-D-094 box, and the new view always lies inside
    /// it: offscreen to the rules is offscreen to the player.
    @Test func rulesViewportContainsTheCameraViewEverywhere() throws {
        let arena = try ArenaManifest.bundled()
        #expect(RulesViewport.width == 896 && RulesViewport.height == 414)
        let bounds = arena.boundsUnits
        let headings: [VecQ8] = [.zero, VecI(x: 1, y: 0).asQ8, VecI(x: -1, y: 0).asQ8, VecI(x: 0, y: 1).asQ8]
        for x in stride(from: bounds.minX, through: bounds.maxX, by: 32) {
            for y in stride(from: bounds.minY, through: bounds.maxY, by: 32) {
                for heading in headings {
                    let player = VecI(x: x, y: y)
                    let view = PresentationCamera.follow(player: player, heading: heading, bounds: bounds)
                    let rules = RulesViewport.box(player: player, heading: heading, bounds: bounds)
                    #expect(view.center.x - PresentationCamera.visibleWidth / 2 >= rules.minX)
                    #expect(view.center.x + PresentationCamera.visibleWidth / 2 <= rules.maxX)
                    #expect(view.center.y - PresentationCamera.visibleHeight / 2 >= rules.minY)
                    #expect(view.center.y + PresentationCamera.visibleHeight / 2 <= rules.maxY)
                }
            }
        }
    }

    @Test func spawnFairnessStillUsesTheRulesBox() throws {
        let arena = try ArenaManifest.bundled()
        let player = VecI(x: 1100, y: 700)
        let box = SpawnFairness.viewportBox(player: player.asQ8, heading: .zero, bounds: arena.boundsUnits)
        #expect(box.halfSize == VecI(x: 448, y: 207))
    }

    /// The tutorial hint's "on screen" test follows the new, smaller view.
    @Test func awarenessHintUsesTheNewView() throws {
        var snap = PresentationSnapshot(try Simulation.make(seed: 1).state)
        let centre = snap.camera.center
        var enemy = snap.player
        enemy.unaware = true
        // Inside the old 896 view but outside the new 704 view.
        enemy.x = centre.x + 400
        enemy.y = centre.y
        snap.enemies = [enemy]
        #expect(!AwarenessHintProjector.unawareEnemyOnScreen(snap))
        snap.enemies[0].x = centre.x + 340
        #expect(AwarenessHintProjector.unawareEnemyOnScreen(snap))
    }

    // MARK: - Captions

    private static func cue(_ id: String, _ caption: String, priority: Int, sequence: Int = 0) -> ProjectedCue {
        ProjectedCue(
            audioId: id,
            haptic: .none,
            caption: caption,
            priority: priority,
            consumesEffectVoice: true,
            sourceEntityId: nil,
            sector: nil,
            sequence: sequence,
            variant: nil
        )
    }

    @Test func safetyClassFollowsTheD094List() {
        for id in ["player_damage", "daemon_query", "daemon_dash", "boss_telegraph_temporaryOrder",
                   "exposure_state_up", "lockdown_enter", "extraction_armed", "extraction_reset", "extraction_tick"] {
            #expect(CaptionClass.of(cueId: id) == .safety, "\(id)")
        }
        for id in ["weapon_civic_pulse", "impact_enemy", "player_dodge", "camera_hit_01", "camera_critical",
                   "camera_destroy", "camera_field_off", "camera_network_tamper", "network_blackout",
                   "upgrade_selected_ghostStep", "boss_phase_civilLiberties", "boss_defeated", "run_success", "player_death"] {
            #expect(CaptionClass.of(cueId: id) == .routine, "\(id)")
        }
    }

    @Test func atMostThreeCaptionsShowAndSafetyComesFirst() {
        var board = CaptionBoard()
        board.ingest(tick: 10, cues: [
            Self.cue("weapon_civic_pulse", "Civic Pulse", priority: 6, sequence: 0),
            Self.cue("impact_enemy", "Impact", priority: 6, sequence: 1),
            Self.cue("player_dodge", "Dodge", priority: 7, sequence: 2),
            Self.cue("camera_hit_01", "Camera hit", priority: 6, sequence: 3)
        ])
        board.ingest(tick: 11, cues: [
            Self.cue("player_damage", "Player damaged", priority: 5, sequence: 4),
            Self.cue("lockdown_enter", "Lockdown", priority: 3, sequence: 5)
        ])
        let all = board.visible(at: 12, setting: .all)
        #expect(all.count == CaptionBoard.maxVisible)
        #expect(all.filter { $0.captionClass == .safety }.map(\.text).sorted() == ["Lockdown", "Player damaged"])
        // Oldest first, newest at the bottom.
        #expect(all.map(\.sequence) == all.map(\.sequence).sorted())
    }

    @Test func importantIsTheDefaultAndShowsSafetyOnly() {
        #expect(PresentationSettings.defaults.captions == .important)
        var board = CaptionBoard()
        board.ingest(tick: 1, cues: [
            Self.cue("weapon_civic_pulse", "Civic Pulse", priority: 6),
            Self.cue("exposure_state_up", "Detection observed", priority: 3)
        ])
        #expect(board.visible(at: 1, setting: .important).map(\.text) == ["Detection observed"])
        #expect(board.visible(at: 1, setting: .all).count == 2)
        #expect(board.visible(at: 1, setting: .off).isEmpty)
    }

    @Test func aCaptionShowsForTwoAndAHalfSeconds() {
        var board = CaptionBoard()
        board.ingest(tick: 100, cues: [Self.cue("lockdown_enter", "Lockdown", priority: 3)])
        #expect(CaptionBoard.visibleTicks == 150)
        #expect(board.visible(at: 100 + 149, setting: .important).count == 1)
        #expect(board.visible(at: 100 + 150, setting: .important).isEmpty)
    }

    @Test func aRepeatedCaptionRestartsRatherThanStacks() {
        var board = CaptionBoard()
        board.ingest(tick: 1, cues: [Self.cue("player_damage", "Player damaged", priority: 5)])
        board.ingest(tick: 100, cues: [Self.cue("player_damage", "Player damaged", priority: 5)])
        let shown = board.visible(at: 200, setting: .important)
        #expect(shown.count == 1)
        #expect(shown.first?.tick == 100)
    }

    @Test func captionsArriveWithEffectsOff() {
        var projector = AudioProjector()
        let world = AudioWorldQuery(
            playerId: EntityID(1),
            playerPosition: VecI(x: 0, y: 0).asQ8,
            outcome: .playing,
            extractionArmed: false,
            hasAlgorithmicModerate: false,
            lockdownEntered: true,
            detectionState: .lockdown,
            viewport: try! ArenaManifest.bundled().viewport
        )
        let event = AuthoritativeEvent(tick: 5, phase: 0, type: .lockdownEntered, insertion: 0)
        let projection = projector.project(tick: 5, events: [event], world: world, settings: .disabled)
        #expect(projection.cues.isEmpty)
        #expect(projection.captionCues.map(\.audioId) == ["lockdown_enter"])
    }

    @Test func savedSettingsWithoutCaptionsStillDecode() throws {
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PresentationSettings(tutorialsEnabled: false))) as! [String: Any]
        legacy.removeValue(forKey: "captions")
        legacy.removeValue(forKey: "ghostEnabled")
        let decoded = try JSONDecoder().decode(PresentationSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.captions == .important)
        #expect(decoded.tutorialsEnabled == false, "stored choices survive")

        legacy["captions"] = "subtitlesForEverything"
        let unknown = try JSONDecoder().decode(PresentationSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(unknown.captions == .important)

        let round = try JSONDecoder().decode(
            PresentationSettings.self,
            from: JSONEncoder().encode(PresentationSettings(captions: .off))
        )
        #expect(round.captions == .off)
        // Captions are not receipt metadata.
        #expect(PresentationSettings(captions: .off).receiptMetadata == PresentationSettings().receiptMetadata)
    }

    // MARK: - Fog

    private static func fogSnapshot(tick: UInt64, enemyOffset: Int?, unaware: Bool = false) throws -> PresentationSnapshot {
        var snap = PresentationSnapshot(try Simulation.make(seed: 1).state)
        snap.tick = tick
        snap.enemies = []
        if let enemyOffset {
            var enemy = snap.player
            enemy.x = snap.camera.center.x + enemyOffset
            enemy.y = snap.camera.center.y
            enemy.unaware = unaware
            snap.enemies = [enemy]
        }
        return snap
    }

    @Test func fogThinsToHalfOverHalfASecondWhileAnAwareEnemyIsOnScreen() throws {
        var fog = FogThinning()
        #expect(fog.update(try Self.fogSnapshot(tick: 0, enemyOffset: 100)) == 1)
        let midway = fog.update(try Self.fogSnapshot(tick: 15, enemyOffset: 100))
        #expect(midway < 1 && midway > FogThinning.thinnedOpacity)
        #expect(fog.update(try Self.fogSnapshot(tick: 30, enemyOffset: 100)) == FogThinning.thinnedOpacity)
        #expect(fog.update(try Self.fogSnapshot(tick: 90, enemyOffset: 100)) == FogThinning.thinnedOpacity)
        // The enemy leaves: the fog eases back over the same half second.
        #expect(fog.update(try Self.fogSnapshot(tick: 105, enemyOffset: nil)) < 1)
        #expect(fog.update(try Self.fogSnapshot(tick: 120, enemyOffset: nil)) == 1)
    }

    @Test func unawareOrOffscreenEnemiesLeaveTheFogAlone() throws {
        var fog = FogThinning()
        _ = fog.update(try Self.fogSnapshot(tick: 0, enemyOffset: 100, unaware: true))
        #expect(fog.update(try Self.fogSnapshot(tick: 60, enemyOffset: 100, unaware: true)) == 1)
        // Inside the old 896 view, outside the 704 one.
        #expect(fog.update(try Self.fogSnapshot(tick: 120, enemyOffset: 400)) == 1)
    }

    @Test func fogHoldsStillWhenTheTickDoesNot() throws {
        var fog = FogThinning()
        _ = fog.update(try Self.fogSnapshot(tick: 10, enemyOffset: 100))
        let held = fog.update(try Self.fogSnapshot(tick: 10, enemyOffset: 100))
        #expect(held == 1, "pause and hit-stop advance no ticks")
    }

    // MARK: - Lockdown tint

    @Test func lockdownTintPulsesSixToTenPercentEveryTwoSeconds() {
        #expect(LockdownTint.periodTicks == 120)
        #expect(LockdownTint.opacity(tick: 50, detection: .hunted, reducedFlash: false, reducedMotion: false) == nil)
        let base = LockdownTint.opacity(tick: 0, detection: .lockdown, reducedFlash: false, reducedMotion: false)!
        let peak = LockdownTint.opacity(tick: 60, detection: .lockdown, reducedFlash: false, reducedMotion: false)!
        let next = LockdownTint.opacity(tick: 120, detection: .lockdown, reducedFlash: false, reducedMotion: false)!
        #expect(abs(base - 0.06) < 1e-9)
        #expect(abs(peak - 0.10) < 1e-9)
        #expect(abs(next - 0.06) < 1e-9)
        for tick in UInt64(0)..<240 {
            let value = LockdownTint.opacity(tick: tick, detection: .lockdown, reducedFlash: false, reducedMotion: false)!
            #expect(value >= 0.06 - 1e-9 && value <= 0.10 + 1e-9)
        }
    }

    @Test func reducedFlashAndReducedMotionHoldASteadySixPercent() {
        for tick in UInt64(0)..<240 {
            #expect(LockdownTint.opacity(tick: tick, detection: .lockdown, reducedFlash: true, reducedMotion: false) == 0.06)
            #expect(LockdownTint.opacity(tick: tick, detection: .lockdown, reducedFlash: false, reducedMotion: true) == 0.06)
        }
    }

    @Test func lockdownTintNeverBrightens() {
        for opacity in [0.0, 0.06, 0.08, 0.10, 1.0] {
            let m = LockdownTint.multiplier(opacity: opacity)
            #expect(m.red <= 1 && m.green <= 1 && m.blue <= 1)
            #expect(m.red >= 0 && m.green >= 0 && m.blue >= 0)
        }
        let tint = LockdownTint.multiplier(opacity: 0.06)
        #expect(tint.red == 1 && abs(tint.green - 0.94) < 1e-9 && abs(tint.blue - 0.94) < 1e-9)
    }

    // MARK: - Gates

    @Test func gateArtFillsTheCollisionBoxExactly() throws {
        let arena = try ArenaManifest.bundled()
        #expect(!arena.gates.isEmpty)
        for gate in arena.gates {
            let box = gate.aabb
            for viewer in [VecI(x: box.center.x - 300, y: box.center.y - 300), VecI(x: box.center.x + 300, y: box.center.y + 300)] {
                let layout = GateBarrier.layout(box: box, viewer: viewer, textureAspect: 128.0 / 48.0)
                let area = layout.tiles.reduce(0.0) { $0 + $1.width * $1.height }
                #expect(abs(area - Double(box.halfSize.x * 4 * box.halfSize.y)) < 1e-6, "\(gate.id)")
                #expect(abs((layout.tiles.map(\.minX).min() ?? 0) - Double(box.minX)) < 1e-9)
                #expect(abs((layout.tiles.map(\.maxX).max() ?? 0) - Double(box.maxX)) < 1e-9)
                #expect(abs((layout.tiles.map(\.minY).min() ?? 0) - Double(box.minY)) < 1e-9)
                #expect(abs((layout.tiles.map(\.maxY).max() ?? 0) - Double(box.maxY)) < 1e-9)
                // The strip lies inside the box, on the long side facing the viewer.
                #expect(layout.strip.minX >= Double(box.minX) - 1e-9 && layout.strip.maxX <= Double(box.maxX) + 1e-9)
                #expect(layout.strip.minY >= Double(box.minY) - 1e-9 && layout.strip.maxY <= Double(box.maxY) + 1e-9)
                let towards = layout.vertical ? viewer.x - box.center.x : viewer.y - box.center.y
                #expect(layout.openFace == (towards < 0 ? -1 : 1))
            }
        }
    }

    @Test func snapshotNamesEveryGate() throws {
        let state = try Simulation.make(seed: 1).state
        let snap = PresentationSnapshot(state)
        #expect(snap.gateIds == Set(state.arena.gates.map(\.id)))
        // Closed gates are live solids; open ones are not.
        for gate in state.gates {
            #expect(snap.solidIds.contains(gate.id) == gate.closed)
        }
    }

    // MARK: - Actor contrast

    @Test func actorContrastValues() {
        #expect(ActorContrast.shadowOpacity == 0.35)
        let size = ActorContrast.shadowSize(radius: PlayerBody.radiusUnits)
        #expect(size.width == 1.4 * 2 * Double(PlayerBody.radiusUnits))
        #expect(!ActorContrast.dashed(.player) && ActorContrast.dashed(.enemy))
        let player = ActorContrast.outlineColour(.player)
        let enemy = ActorContrast.outlineColour(.enemy)
        #expect(player.blue >= player.red, "cool")
        #expect(enemy.red > enemy.green && enemy.green > enemy.blue, "warm red-orange")
        // Shape, not only colour: the enemy pattern has gaps, the Player's none.
        let row = (0..<20).map { ActorContrast.outlinePixelOn(x: $0, y: 0, faction: .enemy) }
        #expect(row.contains(false) && row.contains(true))
        #expect((0..<20).allSatisfy { ActorContrast.outlinePixelOn(x: $0, y: 0, faction: .player) })
    }
}
