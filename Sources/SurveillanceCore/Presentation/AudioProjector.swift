import Foundation

public enum MusicState: String, Equatable, Sendable {
    case explore
    case observed
    case lockdown
    case boss
    case extraction
    case terminal
}

public enum HapticPattern: String, Equatable, Sendable {
    case none
    case light
    case warning
    case rigid
    case heavy
    case success
}

public struct PresentationAudioSettings: Equatable, Sendable, Codable {
    public var effectsEnabled: Bool
    public var hapticsEnabled: Bool
    public var musicEnabled: Bool
    public var reducedSensory: Bool

    public init(
        effectsEnabled: Bool = true,
        hapticsEnabled: Bool = true,
        musicEnabled: Bool = true,
        reducedSensory: Bool = false
    ) {
        self.effectsEnabled = effectsEnabled
        self.hapticsEnabled = hapticsEnabled
        self.musicEnabled = musicEnabled
        self.reducedSensory = reducedSensory
    }

    public static let enabled = PresentationAudioSettings()
    public static let disabled = PresentationAudioSettings(
        effectsEnabled: false,
        hapticsEnabled: false,
        musicEnabled: false
    )
}

public struct ProjectedCue: Equatable, Sendable {
    public var audioId: String
    public var haptic: HapticPattern
    public var caption: String
    public var priority: Int
    public var consumesEffectVoice: Bool
    public var sourceEntityId: EntityID?
    public var sector: Int?
    public var sequence: Int
    public var variant: Int?
}

public struct AudioProjection: Equatable, Sendable {
    public var cues: [ProjectedCue]
    public var musicState: MusicState
    public var captions: [String]

    public init(cues: [ProjectedCue], musicState: MusicState, captions: [String]) {
        self.cues = cues
        self.musicState = musicState
        self.captions = captions
    }

    public static let silent = AudioProjection(cues: [], musicState: .explore, captions: [])
}

/// Compact read model for cue projection. `project` must not take `WorldState` by value:
/// macOS 15 Swift Testing workers SIGBUS when that large struct is copied into this entry point.
public struct AudioWorldQuery: Equatable, Sendable {
    public var playerId: EntityID
    public var playerPosition: VecQ8
    public var outcome: RunOutcome
    public var extractionArmed: Bool
    public var hasAlgorithmicModerate: Bool
    public var lockdownEntered: Bool
    public var detectionState: DetectionState
    public var viewport: ViewportSpec
    public var positions: [EntityID: VecQ8]

    public init(
        playerId: EntityID,
        playerPosition: VecQ8,
        outcome: RunOutcome,
        extractionArmed: Bool,
        hasAlgorithmicModerate: Bool,
        lockdownEntered: Bool,
        detectionState: DetectionState,
        viewport: ViewportSpec,
        positions: [EntityID: VecQ8] = [:]
    ) {
        self.playerId = playerId
        self.playerPosition = playerPosition
        self.outcome = outcome
        self.extractionArmed = extractionArmed
        self.hasAlgorithmicModerate = hasAlgorithmicModerate
        self.lockdownEntered = lockdownEntered
        self.detectionState = detectionState
        self.viewport = viewport
        self.positions = positions
    }

    public static func from(_ state: WorldState) -> AudioWorldQuery {
        var positions: [EntityID: VecQ8] = [state.player.id: state.player.position]
        for enemy in state.enemies {
            positions[enemy.id] = enemy.position
        }
        for camera in state.cameras {
            positions[camera.entityId] = camera.position.asQ8
        }
        return AudioWorldQuery(
            playerId: state.player.id,
            playerPosition: state.player.position,
            outcome: state.outcome,
            extractionArmed: state.extraction.armed,
            hasAlgorithmicModerate: state.enemies.contains {
                $0.alive && $0.archetype == .algorithmicModerate
            },
            lockdownEntered: state.exposure.lockdownEntered,
            detectionState: state.exposure.detectionState,
            viewport: state.arena.viewport,
            positions: positions
        )
    }
}

public struct AudioProjector: Equatable, Sendable {
    public var lastWeaponVoiceTick: UInt64?
    public var lastPlayerDamageTick: UInt64?
    public var lastDisplayedCountdown: Int?
    public var captionHistory: [String]
    public var nextSequence: Int

    public init() {
        lastWeaponVoiceTick = nil
        lastPlayerDamageTick = nil
        lastDisplayedCountdown = nil
        captionHistory = []
        nextSequence = 0
    }

    public mutating func reset() {
        self = AudioProjector()
    }

    public mutating func project(
        tick: UInt64,
        events: [AuthoritativeEvent],
        world: AudioWorldQuery,
        settings: PresentationAudioSettings = .enabled
    ) -> AudioProjection {
        var candidates: [ProjectedCue] = []
        let cameraHits = events.filter { $0.type == .cameraIntegrityChanged }
        let destroyed = events.filter { $0.type == .cameraDestroyed }
        let cameraIDsHit = Set(cameraHits.compactMap { payloadString($0, "cameraId") })

        appendWeapon(tick: tick, events: events, into: &candidates)
        appendImpacts(events: events, playerId: world.playerId, cameraIDsHit: cameraIDsHit, into: &candidates)
        appendPlayerDamage(tick: tick, events: events, into: &candidates)
        appendDodge(events: events, into: &candidates)
        appendCameraHits(cameraHits, into: &candidates)
        appendCameraDestructions(destroyed, into: &candidates)
        appendDetection(events: events, into: &candidates)
        appendLockdown(events: events, into: &candidates)
        appendUpgrade(events: events, into: &candidates)
        appendBossAndElite(events: events, into: &candidates)
        appendExtraction(events: events, into: &candidates)
        appendTerminal(events: events, into: &candidates)

        for index in candidates.indices {
            candidates[index].sequence = nextSequence
            nextSequence += 1
            if let id = candidates[index].sourceEntityId {
                candidates[index].sector = sector(
                    from: world.playerPosition,
                    to: world.positions[id],
                    viewport: world.viewport
                )
            }
            if !settings.hapticsEnabled {
                candidates[index].haptic = .none
            }
        }

        let voices = stealVoices(candidates.filter(\.consumesEffectVoice))
        for cue in voices where !cue.caption.isEmpty {
            captionHistory.append(cue.caption)
        }
        if captionHistory.count > 8 {
            captionHistory.removeFirst(captionHistory.count - 8)
        }

        return AudioProjection(
            cues: settings.effectsEnabled ? voices : [],
            musicState: Self.musicState(world),
            captions: captionHistory
        )
    }

    public static func musicState(_ world: AudioWorldQuery) -> MusicState {
        if world.outcome == .success || world.outcome == .failure || world.outcome == .invalid {
            return .terminal
        }
        if world.extractionArmed { return .extraction }
        if world.hasAlgorithmicModerate { return .boss }
        if world.lockdownEntered { return .lockdown }
        if world.detectionState != .hidden { return .observed }
        return .explore
    }

    private mutating func appendWeapon(
        tick: UInt64,
        events: [AuthoritativeEvent],
        into candidates: inout [ProjectedCue]
    ) {
        let fired = events.contains { $0.type == .weaponFired }
        guard fired else { return }
        if let last = lastWeaponVoiceTick, tick >= last, tick - last < 6 { return }
        lastWeaponVoiceTick = tick
        candidates.append(
            cue("weapon_civic_pulse", haptic: .none, caption: "Civic Pulse", priority: 6, entity: nil)
        )
    }

    private func appendImpacts(
        events: [AuthoritativeEvent],
        playerId: EntityID,
        cameraIDsHit: Set<String>,
        into candidates: inout [ProjectedCue]
    ) {
        var hits: [(damage: Int64, id: EntityID)] = []
        for event in events where event.type == .projectileHit || event.type == .entityDamaged {
            let target = payloadString(event, event.type == .projectileHit ? "targetEntityId" : "entityId")
                ?? event.secondaryEntityId?.decimalString
                ?? event.primaryEntityId?.decimalString
            guard let target, target != playerId.decimalString else { continue }
            if cameraIDsHit.contains(target) { continue }
            let damage = payloadInt(event, event.type == .projectileHit ? "appliedDamage" : "amount") ?? 0
            let id = event.secondaryEntityId ?? event.primaryEntityId ?? EntityID(0)
            if let existing = hits.firstIndex(where: { $0.id.decimalString == target }) {
                if damage > hits[existing].damage {
                    hits[existing] = (damage, id)
                } else if damage == hits[existing].damage, id < hits[existing].id {
                    hits[existing] = (damage, id)
                }
            } else {
                hits.append((damage, id))
            }
        }
        hits.sort {
            if $0.damage != $1.damage { return $0.damage > $1.damage }
            return $0.id < $1.id
        }
        for hit in hits.prefix(2) {
            candidates.append(
                cue("impact_enemy", haptic: .none, caption: "Impact", priority: 6, entity: hit.id)
            )
        }
    }

    private mutating func appendPlayerDamage(
        tick: UInt64,
        events: [AuthoritativeEvent],
        into candidates: inout [ProjectedCue]
    ) {
        let damaged = events.filter { $0.type == .playerDamaged }
        guard !damaged.isEmpty else { return }
        if let last = lastPlayerDamageTick, tick >= last, tick - last < 15 { return }
        lastPlayerDamageTick = tick
        candidates.append(
            cue(
                "player_damage",
                haptic: .light,
                caption: "Player damaged",
                priority: 5,
                entity: damaged[0].secondaryEntityId
            )
        )
    }

    private func appendDodge(events: [AuthoritativeEvent], into candidates: inout [ProjectedCue]) {
        guard events.contains(where: { $0.type == .dodgeStarted }) else { return }
        candidates.append(cue("player_dodge", haptic: .light, caption: "Dodge", priority: 7, entity: nil))
    }

    private func appendCameraHits(_ hits: [AuthoritativeEvent], into candidates: inout [ProjectedCue]) {
        var seen = Set<String>()
        for event in hits {
            let id = payloadString(event, "cameraId") ?? event.primaryEntityId?.decimalString ?? ""
            if seen.contains(id) { continue }
            seen.insert(id)
            let after = payloadInt(event, "after") ?? 0
            let entity = event.primaryEntityId
            if after == 2 {
                candidates.append(cue("camera_hit_01", haptic: .light, caption: "Camera hit", priority: 6, entity: entity))
            } else if after == 1 {
                candidates.append(cue("camera_hit_02", haptic: .light, caption: "Camera hit", priority: 6, entity: entity))
                candidates.append(cue("camera_critical", haptic: .warning, caption: "Camera critical", priority: 4, entity: entity))
            }
        }
    }

    /// T610 / `camera-destruction.md` §13: each destroy emits `camera_destroy`
    /// then `camera_field_off` on the same tick so field-off audio cannot wait
    /// on the destruction clip. One `camera_network_tamper` covers the batch.
    private func appendCameraDestructions(_ destroyed: [AuthoritativeEvent], into candidates: inout [ProjectedCue]) {
        for event in destroyed {
            candidates.append(
                cue(
                    "camera_destroy",
                    haptic: .rigid,
                    caption: "Camera destroyed",
                    priority: 4,
                    entity: event.primaryEntityId
                )
            )
            candidates.append(
                cue(
                    "camera_field_off",
                    haptic: .none,
                    caption: "Camera field off",
                    priority: 4,
                    entity: event.primaryEntityId
                )
            )
        }
        if !destroyed.isEmpty {
            let variant = min(3, destroyed.count)
            candidates.append(
                cue(
                    "camera_network_tamper",
                    haptic: .rigid,
                    caption: variant >= 3 ? "Network tamper 3+" : "Network tamper \(variant)",
                    priority: 4,
                    entity: nil,
                    variant: variant
                )
            )
        }
    }

    private func appendDetection(events: [AuthoritativeEvent], into candidates: inout [ProjectedCue]) {
        let changes = events.filter { $0.type == .detectionStateChanged }
        guard let last = changes.last else { return }
        let before = payloadString(last, "before").flatMap(DetectionState.init(rawValue:))
        let after = payloadString(last, "after").flatMap(DetectionState.init(rawValue:))
        guard let before, let after, rank(after) > rank(before) else { return }
        candidates.append(
            cue("exposure_state_up", haptic: .warning, caption: "Detection \(after.rawValue)", priority: 3, entity: nil)
        )
    }

    private func appendLockdown(events: [AuthoritativeEvent], into candidates: inout [ProjectedCue]) {
        guard events.contains(where: { $0.type == .lockdownEntered }) else { return }
        candidates.append(cue("lockdown_enter", haptic: .heavy, caption: "Lockdown", priority: 3, entity: nil))
    }

    private func appendUpgrade(events: [AuthoritativeEvent], into candidates: inout [ProjectedCue]) {
        guard let event = events.first(where: { $0.type == .upgradeSelected }) else { return }
        let id = payloadString(event, "upgradeId") ?? UpgradeID.signalJammer.rawValue
        candidates.append(
            cue("upgrade_selected_\(id)", haptic: .success, caption: "Upgrade selected", priority: 7, entity: nil)
        )
    }

    private func appendBossAndElite(events: [AuthoritativeEvent], into candidates: inout [ProjectedCue]) {
        for event in events where event.type == .bossAttackStarted {
            let attack = payloadString(event, "attackId") ?? ""
            let audioId: String
            let caption: String
            if attack.contains("query") {
                audioId = "daemon_query"
                caption = "Query telegraph"
            } else if attack.contains("dash") {
                audioId = "daemon_dash"
                caption = "Dash telegraph"
            } else {
                audioId = "boss_telegraph_\(attack)"
                caption = "Boss telegraph"
            }
            candidates.append(cue(audioId, haptic: .warning, caption: caption, priority: 2, entity: event.primaryEntityId))
        }
        if events.contains(where: { $0.type == .bossPhaseChanged }) {
            if let event = events.last(where: { $0.type == .bossPhaseChanged }),
               let after = payloadString(event, "after")
            {
                candidates.append(
                    cue("boss_phase_\(after)", haptic: .heavy, caption: "Policy phase", priority: 2, entity: nil)
                )
            }
        }
        if events.contains(where: { $0.type == .bossDefeated }) {
            candidates.append(cue("boss_defeated", haptic: .success, caption: "Authority defeated", priority: 2, entity: nil))
        }
        if events.contains(where: { $0.type == .allCamerasDestroyed }) {
            candidates.append(cue("network_blackout", haptic: .success, caption: "Network Blackout 8/8", priority: 4, entity: nil))
        }
    }

    private mutating func appendExtraction(events: [AuthoritativeEvent], into candidates: inout [ProjectedCue]) {
        if events.contains(where: { $0.type == .extractionArmed }) {
            candidates.append(cue("extraction_armed", haptic: .success, caption: "Phoenix Steps open", priority: 2, entity: nil))
        }
        if events.contains(where: { $0.type == .extractionReset }) {
            candidates.append(cue("extraction_reset", haptic: .warning, caption: "Extraction reset", priority: 2, entity: nil))
        }
        if let event = events.last(where: { $0.type == .extractionCountdownChanged }),
           let remaining = payloadInt(event, "remainingTicks")
        {
            let displayed = Int((remaining + 59) / 60)
            if lastDisplayedCountdown != displayed, remaining > 0 {
                lastDisplayedCountdown = displayed
                candidates.append(
                    cue("extraction_tick", haptic: .light, caption: "Extraction \(displayed)", priority: 7, entity: nil)
                )
            }
        }
    }

    private func appendTerminal(events: [AuthoritativeEvent], into candidates: inout [ProjectedCue]) {
        if events.contains(where: { $0.type == .runSucceeded }) {
            candidates.append(cue("run_success", haptic: .success, caption: "Run complete", priority: 2, entity: nil))
        }
        if events.contains(where: { $0.type == .runFailed }) {
            candidates.append(cue("player_death", haptic: .heavy, caption: "Player down", priority: 1, entity: nil))
        }
    }

    private func stealVoices(_ cues: [ProjectedCue]) -> [ProjectedCue] {
        var remaining = cues
        while remaining.count > 8 {
            let lowest = remaining.map(\.priority).max()!
            let oldest = remaining
                .enumerated()
                .filter { $0.element.priority == lowest }
                .min { $0.element.sequence < $1.element.sequence }!
            remaining.remove(at: oldest.offset)
        }
        return remaining
    }

    private func cue(
        _ id: String,
        haptic: HapticPattern,
        caption: String,
        priority: Int,
        entity: EntityID?,
        variant: Int? = nil
    ) -> ProjectedCue {
        ProjectedCue(
            audioId: id,
            haptic: haptic,
            caption: caption,
            priority: priority,
            consumesEffectVoice: true,
            sourceEntityId: entity,
            sector: nil,
            sequence: 0,
            variant: variant
        )
    }

    private func rank(_ state: DetectionState) -> Int {
        switch state {
        case .hidden: 0
        case .observed: 1
        case .tracked: 2
        case .hunted: 3
        case .lockdown: 4
        }
    }

    private func payloadString(_ event: AuthoritativeEvent, _ key: String) -> String? {
        if case .string(let value)? = event.payload[key] { return value }
        return nil
    }

    private func payloadInt(_ event: AuthoritativeEvent, _ key: String) -> Int64? {
        if case .integer(let value)? = event.payload[key] { return value }
        return nil
    }

    private func sector(from player: VecQ8, to source: VecQ8?, viewport: ViewportSpec) -> Int? {
        guard let source else { return nil }
        let dx = source.x.unitsTruncated - player.x.unitsTruncated
        let dy = source.y.unitsTruncated - player.y.unitsTruncated
        let offscreen = abs(dx) > viewport.baselineWorldWidth / 2 || abs(dy) > viewport.baselineWorldHeight / 2
        guard offscreen else { return nil }
        let milli = Cordic.atan2Milli(y: Int64(dy), x: Int64(dx))
        return MilliDeg.normalize(milli) / 45_000
    }
}
