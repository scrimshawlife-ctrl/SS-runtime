import Foundation
import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct ClipAlignmentTests {
    @Test func clipT605AnchorsStayStableAcrossRoleAndMirroredFacings() throws {
        let catalog = try ClipCatalog.bundled()
        let playerAnchors = Set(catalog.clips.filter { $0.actorRole == "player" }.map(\.anchor))
        let cameraAnchors = Set(catalog.clips.filter { $0.actorRole == "camera" }.map(\.anchor))
        let captainAnchors = Set(
            catalog.clips.filter { $0.actorRole == "algorithmicModerate" }.map(\.anchor)
        )
        let idle = try #require(catalog.clipsById["player_idle"])
        let east = idle.frameIds(forDirection: "e")
        let west = idle.frameIds(forDirection: "w")
        let eastCount = east.count
        let westCount = west.count
        let westUsesAuthoredW = west.allSatisfy { $0.contains("_w_") }
        let westIsNotFlippedEast = west != east
        #expect(playerAnchors == [ClipAnchor(x: 32, y: 56)])
        #expect(cameraAnchors == [ClipAnchor(x: 32, y: 88)])
        #expect(captainAnchors == [ClipAnchor(x: 48, y: 84)])
        #expect(eastCount == westCount)
        #expect(westUsesAuthoredW)
        #expect(westIsNotFlippedEast)
    }

    @Test func clipT605HeadingProjectsToFourAuthoredDirectionsWithoutMirroring() throws {
        let catalog = try ClipCatalog.bundled()
        let east = ClipAlignment.project(
            query: ClipPlaybackQuery(actorRole: "player", currentClipId: "player_move", headingMilli: 0),
            events: [],
            catalog: catalog
        )
        let south = ClipAlignment.project(
            query: ClipPlaybackQuery(actorRole: "player", currentClipId: "player_move", headingMilli: 90_000),
            events: [],
            catalog: catalog
        )
        let west = ClipAlignment.project(
            query: ClipPlaybackQuery(actorRole: "player", currentClipId: "player_move", headingMilli: 180_000),
            events: [],
            catalog: catalog
        )
        let north = ClipAlignment.project(
            query: ClipPlaybackQuery(actorRole: "player", currentClipId: "player_move", headingMilli: 270_000),
            events: [],
            catalog: catalog
        )
        let wrap = ClipAlignment.cardinalDirection(headingMilli: -1)
        let eastDir = east.direction
        let southDir = south.direction
        let westDir = west.direction
        let northDir = north.direction
        let westFramesAreW = west.frameIds.allSatisfy { $0.contains("_w_") }
        let mirrored = east.mirrored || west.mirrored
        let anchorsMatch = east.anchor == west.anchor
        #expect(eastDir == "e")
        #expect(southDir == "s")
        #expect(westDir == "w")
        #expect(northDir == "n")
        #expect(wrap == "e")
        #expect(westFramesAreW)
        #expect(mirrored == false)
        #expect(anchorsMatch)
    }

    @Test func clipT605HurtInterruptsLocomotionButNotDodge() throws {
        let catalog = try ClipCatalog.bundled()
        let hurt = AuthoritativeEvent(
            tick: 8,
            phase: 12,
            type: .playerDamaged,
            primary: EntityID(1),
            payload: ["amount": .integer(4)],
            insertion: 0
        )
        let fromIdle = ClipAlignment.project(
            query: ClipPlaybackQuery(actorRole: "player", currentClipId: "player_idle", headingMilli: 0),
            events: [hurt],
            catalog: catalog
        )
        let fromDodge = ClipAlignment.project(
            query: ClipPlaybackQuery(actorRole: "player", currentClipId: "player_dodge", headingMilli: 0),
            events: [hurt],
            catalog: catalog
        )
        let idleClip = fromIdle.clipId
        let idleInterrupted = fromIdle.interrupted
        let idleAligned = fromIdle.eventAligned
        let dodgeClip = fromDodge.clipId
        let dodgeInterrupted = fromDodge.interrupted
        #expect(idleClip == "player_hurt")
        #expect(idleInterrupted)
        #expect(idleAligned)
        #expect(dodgeClip == "player_dodge")
        #expect(dodgeInterrupted == false)
    }

    @Test func clipT605TerminalClipsRejectCancellationAndDefeatCancelsExtraction() throws {
        let catalog = try ClipCatalog.bundled()
        let death = AuthoritativeEvent(
            tick: 20,
            phase: 20,
            type: .runFailed,
            primary: EntityID(1),
            payload: [:],
            insertion: 0
        )
        let fromExtract = ClipAlignment.project(
            query: ClipPlaybackQuery(
                actorRole: "player",
                currentClipId: "player_extraction",
                headingMilli: 90_000
            ),
            events: [death],
            catalog: catalog
        )
        let fromDefeat = ClipAlignment.project(
            query: ClipPlaybackQuery(
                actorRole: "player",
                currentClipId: "player_defeat",
                headingMilli: 0
            ),
            events: [death],
            catalog: catalog
        )
        let extractClip = fromExtract.clipId
        let extractInterrupted = fromExtract.interrupted
        let defeatClip = fromDefeat.clipId
        let defeatInterrupted = fromDefeat.interrupted
        let complete = try #require(catalog.clipsById["player_complete"])
        #expect(extractClip == "player_defeat")
        #expect(extractInterrupted)
        #expect(defeatClip == "player_defeat")
        #expect(defeatInterrupted == false)
        #expect(complete.cancelWindows.isEmpty)
        #expect(complete.isTerminal)
    }

    /// D-072: the Informant's commit is its contact hit, so its marker is
    /// `playerDamaged`. The other four commits are state transitions and carry
    /// no marker at all.
    @Test func clipT605CommitAlignsToEventMarkerNotFrameId() throws {
        let catalog = try ClipCatalog.bundled()
        let hit = AuthoritativeEvent(
            tick: 12,
            phase: 11,
            type: .playerDamaged,
            payload: ["amount": .integer(6)],
            insertion: 0
        )
        let playback = ClipAlignment.project(
            query: ClipPlaybackQuery(
                actorRole: "autonomousInformant",
                currentClipId: "autonomousInformant_anticipate",
                headingMilli: 0
            ),
            events: [hit],
            catalog: catalog
        )
        let clipId = playback.clipId
        let aligned = playback.eventAligned
        let framesLookLikeEvent = playback.frameIds.contains("playerDamaged")
        let marker = catalog.eventType(forClipId: clipId)
        #expect(clipId == "autonomousInformant_commit")
        #expect(aligned)
        #expect(framesLookLikeEvent == false)
        #expect(marker == .playerDamaged)
        for role in ["fogAnalyticsCloud", "cableCarCorrelator", "sutroSignalWitch", "victorianVendor"] {
            #expect(catalog.eventType(forClipId: "\(role)_commit") == nil, "\(role)")
        }
    }

    @Test func clipT605CameraFieldOffStartsWithDestroyAndLocksHousing() throws {
        let catalog = try ClipCatalog.bundled()
        let destroyed = AuthoritativeEvent(
            tick: 4,
            phase: 10,
            type: .cameraDestroyed,
            primary: EntityID(4),
            payload: [
                "cameraId": .string("4"),
                "socketId": .string("cam-z02-a"),
                "projectileId": .string("1"),
                "wasDetecting": .bool(false)
            ],
            insertion: 0
        )
        let playback = ClipAlignment.project(
            query: ClipPlaybackQuery(
                actorRole: "camera",
                currentClipId: "camera_hit",
                headingMilli: 45_000
            ),
            events: [destroyed],
            catalog: catalog
        )
        let clipId = playback.clipId
        let fieldOff = playback.fieldOffClipId
        let direction = playback.direction
        let locked = playback.housingTransformLocked
        let mirrored = playback.mirrored
        let interrupted = playback.interrupted
        #expect(clipId == "camera_destroy")
        #expect(fieldOff == "camera_field_off")
        #expect(direction.isEmpty)
        #expect(locked)
        #expect(mirrored == false)
        #expect(interrupted)
    }

    @Test func clipCatalogRejectsAnchorDrift() throws {
        let json = try mutatedBundled { clips in
            if let index = clips.firstIndex(where: { ($0["clipId"] as? String) == "player_hurt" }) {
                clips[index]["anchor"] = ["x": 0, "y": 0]
            }
        }
        do {
            _ = try ClipCatalogLoader.decode(json)
            Issue.record("expected anchor drift")
        } catch ClipMetadataError.anchorDrift("player_hurt") {
        }
    }

    @Test func clipCatalogRejectsUnevenDirectionFrames() throws {
        let json = try mutatedBundled { clips in
            if let index = clips.firstIndex(where: { ($0["clipId"] as? String) == "player_idle" }) {
                clips[index]["frameIds"] = [
                    "actor_player_idle_n_01",
                    "actor_player_idle_e_01",
                    "actor_player_idle_s_01"
                ]
            }
        }
        do {
            _ = try ClipCatalogLoader.decode(json)
            Issue.record("expected direction frame failure")
        } catch ClipMetadataError.directionFrames("player_idle") {
        }
    }

    @Test func clipCatalogRejectsUnknownCancelWindow() throws {
        let json = try mutatedBundled { clips in
            clips[0]["cancelWindows"] = ["inventedInterrupt"]
        }
        do {
            _ = try ClipCatalogLoader.decode(json)
            Issue.record("expected cancel window failure")
        } catch ClipMetadataError.cancelWindow("player_idle") {
        }
    }

    @Test func clipCatalogRejectsTerminalCancelWindows() throws {
        let json = try mutatedBundled { clips in
            if let index = clips.firstIndex(where: { ($0["clipId"] as? String) == "player_defeat" }) {
                clips[index]["cancelWindows"] = ["hurt"]
            }
        }
        do {
            _ = try ClipCatalogLoader.decode(json)
            Issue.record("expected terminal cancel failure")
        } catch ClipMetadataError.terminalCancel("player_defeat") {
        }
    }

    private func mutatedBundled(_ mutate: (inout [[String: Any]]) -> Void) throws -> Data {
        var root = try JSONSerialization.jsonObject(with: SpecBundle.contract("clip-metadata-001")) as! [String: Any]
        var clips = root["clips"] as! [[String: Any]]
        mutate(&clips)
        root["clips"] = clips
        return try JSONSerialization.data(withJSONObject: root)
    }
}
