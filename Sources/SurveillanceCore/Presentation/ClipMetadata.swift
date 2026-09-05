import Foundation

public struct ClipAnchor: Equatable, Hashable, Sendable {
    public var x: Int
    public var y: Int
}

public struct ClipRecord: Equatable, Sendable {
    public var clipId: String
    public var actorRole: String
    public var state: String
    public var directions: [String]
    public var frameIds: [String]
    public var framesPerSecond: Int
    public var loop: Bool
    public var anchor: ClipAnchor
    public var authoritativeEventMarker: String
    public var cancelWindows: [String]
    public var blendOrTransition: String
    public var reducedMotionClip: String
    public var audioCue: String
    public var vfxCue: String

    public var eventType: EventType? {
        ClipCatalog.eventType(forMarker: authoritativeEventMarker)
    }

    public var isTerminal: Bool {
        blendOrTransition == "terminal"
    }

    /// Direction subsets are authored; playback must not invent a facing by flipping another.
    public func frameIds(forDirection direction: String) -> [String] {
        if directions.isEmpty { return frameIds }
        let token = "_\(direction)_"
        return frameIds.filter { $0.contains(token) }
    }
}

public struct ClipCatalog: Equatable, Sendable {
    public var schemaVersion: String
    public var animationVersion: String
    public var clips: [ClipRecord]

    public static let requiredClipIds: [String] = [
        "player_idle", "player_move", "player_dodge", "player_recover",
        "player_hurt", "player_defeat", "player_extraction", "player_complete",
        "fogAnalyticsCloud_anticipate", "fogAnalyticsCloud_commit",
        "cableCarCorrelator_anticipate", "cableCarCorrelator_commit",
        "sutroSignalWitch_anticipate", "sutroSignalWitch_commit",
        "autonomousInformant_anticipate", "autonomousInformant_commit",
        "victorianVendor_anticipate", "victorianVendor_commit",
        // animation-civic-seam-001: the elite's clips map one-to-one onto the
        // authoritative state sequence in bosses.md.
        "improperSearchDaemon_pursuit", "improperSearchDaemon_queryTelegraph",
        "improperSearchDaemon_queryResolve", "improperSearchDaemon_dashTelegraph",
        "improperSearchDaemon_dash", "improperSearchDaemon_recover",
        "improperSearchDaemon_hurt", "improperSearchDaemon_defeat",
        "algorithmicModerate_commandPulse", "algorithmicModerate_sweep",
        "algorithmicModerate_targetedStrike", "algorithmicModerate_reinforcementCall",
        "algorithmicModerate_phaseTransition", "algorithmicModerate_stagger",
        "algorithmicModerate_defeat",
        "camera_operational_idle", "camera_hit", "camera_critical_enter",
        "camera_destroy", "camera_field_off", "camera_destroyed_idle"
    ]

    public static let fourDirections = ["n", "e", "s", "w"]
    public static let distinctEnemyAnticipateIds = [
        "fogAnalyticsCloud_anticipate",
        "cableCarCorrelator_anticipate",
        "sutroSignalWitch_anticipate",
        "autonomousInformant_anticipate",
        "victorianVendor_anticipate"
    ]

    public static func bundled() throws -> ClipCatalog {
        try ClipCatalogLoader.decode(SpecBundle.contract("clip-metadata-001"))
    }

    public var clipsById: [String: ClipRecord] {
        Dictionary(uniqueKeysWithValues: clips.map { ($0.clipId, $0) })
    }

    /// Event markers come only from declared clip metadata, never from frame filenames.
    public func eventType(forClipId clipId: String) -> EventType? {
        guard let clip = clipsById[clipId] else { return nil }
        return clip.eventType
    }

    public static func eventType(forMarker marker: String) -> EventType? {
        guard marker != "none" else { return nil }
        return EventType(rawValue: marker)
    }
}

public enum ClipMetadataError: Equatable, Sendable, Error {
    case invalidJSON
    case schemaVersion
    case missingKey(String)
    case unexpectedKey(String)
    case duplicateClipId(String)
    case missingRequiredClip(String)
    case invalidMarker(String)
    case markerMatchesFrameId(String)
    case directions(String)
    case reducedMotion(String)
    case cameraFieldOff
    case anchorDrift(String)
    case directionFrames(String)
    case cancelWindow(String)
    case terminalCancel(String)
}

enum ClipCatalogLoader {
    private static let catalogKeys: Set<String> = [
        "schemaVersion", "animationVersion", "clips"
    ]
    private static let clipKeys: Set<String> = [
        "clipId", "actorRole", "state", "directions", "frameIds",
        "framesPerSecond", "loop", "anchor", "authoritativeEventMarker",
        "cancelWindows", "blendOrTransition", "reducedMotionClip", "audioCue", "vfxCue"
    ]
    private static let fourDirectionRoles: Set<String> = [
        "player",
        "fogAnalyticsCloud",
        "cableCarCorrelator",
        "sutroSignalWitch",
        "autonomousInformant",
        "victorianVendor",
        "algorithmicModerate"
    ]

    static func decode(_ data: Data) throws -> ClipCatalog {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClipMetadataError.invalidJSON
        }
        if let unexpected = Set(root.keys).subtracting(catalogKeys).sorted().first {
            throw ClipMetadataError.unexpectedKey(unexpected)
        }
        guard root["schemaVersion"] as? String == "clip-metadata-001" else {
            throw ClipMetadataError.schemaVersion
        }
        guard root["animationVersion"] as? String == "animation-civic-seam-001" else {
            throw ClipMetadataError.schemaVersion
        }
        guard let rawClips = root["clips"] as? [[String: Any]], !rawClips.isEmpty else {
            throw ClipMetadataError.invalidJSON
        }

        var clips: [ClipRecord] = []
        var seen = Set<String>()
        for raw in rawClips {
            let clip = try decodeClip(raw)
            if !seen.insert(clip.clipId).inserted {
                throw ClipMetadataError.duplicateClipId(clip.clipId)
            }
            clips.append(clip)
        }

        let byId = Dictionary(uniqueKeysWithValues: clips.map { ($0.clipId, $0) })
        for required in ClipCatalog.requiredClipIds {
            guard byId[required] != nil else {
                throw ClipMetadataError.missingRequiredClip(required)
            }
        }
        for clip in clips {
            if clip.reducedMotionClip != clip.clipId, byId[clip.reducedMotionClip] == nil {
                throw ClipMetadataError.reducedMotion(clip.clipId)
            }
        }

        try validateCameraFieldOff(byId)
        try validateActorDirections(clips)
        try validateDistinctEnemyAnticipation(byId)
        try validateStableAnchors(clips)
        try validateDirectionFrames(clips)
        try validateCancelWindows(clips)
        return ClipCatalog(
            schemaVersion: "clip-metadata-001",
            animationVersion: "animation-civic-seam-001",
            clips: clips
        )
    }

    private static func decodeClip(_ raw: [String: Any]) throws -> ClipRecord {
        let extra = Set(raw.keys).subtracting(clipKeys)
        if let unexpected = extra.sorted().first {
            throw ClipMetadataError.unexpectedKey(unexpected)
        }
        for key in clipKeys {
            guard raw[key] != nil else { throw ClipMetadataError.missingKey(key) }
        }
        guard let clipId = raw["clipId"] as? String, !clipId.isEmpty,
              let actorRole = raw["actorRole"] as? String, !actorRole.isEmpty,
              let state = raw["state"] as? String, !state.isEmpty,
              let directions = raw["directions"] as? [String],
              let frameIds = raw["frameIds"] as? [String], !frameIds.isEmpty,
              let fps = intValue(raw["framesPerSecond"]), fps > 0,
              let loop = raw["loop"] as? Bool,
              let anchorObject = raw["anchor"] as? [String: Any],
              let anchorX = intValue(anchorObject["x"]),
              let anchorY = intValue(anchorObject["y"]),
              let marker = raw["authoritativeEventMarker"] as? String, !marker.isEmpty,
              let cancelWindows = raw["cancelWindows"] as? [String],
              let blend = raw["blendOrTransition"] as? String, !blend.isEmpty,
              let reduced = raw["reducedMotionClip"] as? String, !reduced.isEmpty,
              let audio = raw["audioCue"] as? String, !audio.isEmpty,
              let vfx = raw["vfxCue"] as? String, !vfx.isEmpty
        else {
            throw ClipMetadataError.invalidJSON
        }
        if frameIds.contains(where: { $0.isEmpty }) {
            throw ClipMetadataError.invalidJSON
        }
        if marker != "none", EventType(rawValue: marker) == nil {
            throw ClipMetadataError.invalidMarker(clipId)
        }
        if frameIds.contains(marker) {
            throw ClipMetadataError.markerMatchesFrameId(clipId)
        }
        return ClipRecord(
            clipId: clipId,
            actorRole: actorRole,
            state: state,
            directions: directions,
            frameIds: frameIds,
            framesPerSecond: fps,
            loop: loop,
            anchor: ClipAnchor(x: anchorX, y: anchorY),
            authoritativeEventMarker: marker,
            cancelWindows: cancelWindows,
            blendOrTransition: blend,
            reducedMotionClip: reduced,
            audioCue: audio,
            vfxCue: vfx
        )
    }

    private static func validateCameraFieldOff(_ byId: [String: ClipRecord]) throws {
        guard let fieldOff = byId["camera_field_off"],
              let destroy = byId["camera_destroy"]
        else { return }
        guard fieldOff.authoritativeEventMarker == EventType.cameraDestroyed.rawValue,
              destroy.authoritativeEventMarker == EventType.cameraDestroyed.rawValue,
              fieldOff.blendOrTransition == "immediateOnEvent",
              !fieldOff.cancelWindows.contains("camera_destroy")
        else {
            throw ClipMetadataError.cameraFieldOff
        }
    }

    private static func validateActorDirections(_ clips: [ClipRecord]) throws {
        for clip in clips {
            if clip.actorRole == "camera" {
                if !clip.directions.isEmpty {
                    throw ClipMetadataError.directions(clip.clipId)
                }
                continue
            }
            if fourDirectionRoles.contains(clip.actorRole),
               clip.directions != ClipCatalog.fourDirections
            {
                throw ClipMetadataError.directions(clip.clipId)
            }
        }
    }

    private static func validateDistinctEnemyAnticipation(_ byId: [String: ClipRecord]) throws {
        var states: [String] = []
        for id in ClipCatalog.distinctEnemyAnticipateIds {
            guard let clip = byId[id] else {
                throw ClipMetadataError.missingRequiredClip(id)
            }
            states.append(clip.state)
        }
        if Set(states).count != states.count {
            throw ClipMetadataError.missingRequiredClip("distinctEnemyAnticipate")
        }
    }

    private static func validateStableAnchors(_ clips: [ClipRecord]) throws {
        var byRole: [String: ClipAnchor] = [:]
        for clip in clips {
            if let seen = byRole[clip.actorRole], seen != clip.anchor {
                throw ClipMetadataError.anchorDrift(clip.clipId)
            }
            byRole[clip.actorRole] = clip.anchor
        }
    }

    private static func validateDirectionFrames(_ clips: [ClipRecord]) throws {
        for clip in clips {
            if clip.directions.isEmpty {
                if clip.frameIds.contains(where: { !$0.contains("_none_") }) {
                    throw ClipMetadataError.directionFrames(clip.clipId)
                }
                continue
            }
            var counts: [Int] = []
            var assigned = 0
            for direction in clip.directions {
                let frames = clip.frameIds(forDirection: direction)
                if frames.isEmpty {
                    throw ClipMetadataError.directionFrames(clip.clipId)
                }
                counts.append(frames.count)
                assigned += frames.count
            }
            if Set(counts).count != 1 || assigned != clip.frameIds.count {
                throw ClipMetadataError.directionFrames(clip.clipId)
            }
        }
    }

    private static func validateCancelWindows(_ clips: [ClipRecord]) throws {
        let clipIds = Set(clips.map(\.clipId))
        var statesByRole: [String: Set<String>] = [:]
        for clip in clips {
            statesByRole[clip.actorRole, default: []].insert(clip.state)
        }
        for clip in clips {
            if clip.isTerminal, !clip.cancelWindows.isEmpty {
                throw ClipMetadataError.terminalCancel(clip.clipId)
            }
            let states = statesByRole[clip.actorRole] ?? []
            for window in clip.cancelWindows {
                let known = clipIds.contains(window)
                    || states.contains(window)
                    || ClipAlignment.interruptTokens.contains(window)
                if !known {
                    throw ClipMetadataError.cancelWindow(clip.clipId)
                }
            }
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
