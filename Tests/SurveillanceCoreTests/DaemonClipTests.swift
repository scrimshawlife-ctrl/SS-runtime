import Foundation
import Testing
@testable import SurveillanceCore

/// `animation.md` §1: "Animation communicates authoritative state. It may
/// anticipate, emphasize, and settle an event, but it MUST NOT invent timing."
///
/// The Improper Search Daemon's clips are the sharpest case, because every one
/// of its states has an exact tick length in `bosses.md`. A clip that runs
/// longer or shorter than its state either cuts a telegraph short — the elite's
/// only warning — or leaves a frozen frame after the state has moved on.
@Suite(.serialized)
struct DaemonClipTests {
    private func library() throws -> ClipFrameLibrary { try ClipFrameLibrary.bundled() }

    /// bosses.md §Improper Search Daemon state sequence.
    private static let stateTicks: [String: Int] = [
        "improperSearchDaemon_queryTelegraph": 45,
        "improperSearchDaemon_dashTelegraph": 36,
        "improperSearchDaemon_dash": 30,
        "improperSearchDaemon_recover": 60
    ]

    @Test func daemonHasClips() throws {
        let clips = try library().clips.values.filter { $0.actorRole == "improperSearchDaemon" }
        #expect(clips.count == 8)
    }

    /// Each timed clip lasts exactly as long as the state it presents.
    @Test func clipDurationsEqualAuthoritativeStateDurations() throws {
        let library = try library()
        for (clipId, ticks) in Self.stateTicks {
            let clip = try #require(library.clip(clipId), "\(clipId)")
            let expectedMilliseconds = ticks * 1000 / 60
            let actualMilliseconds =
                clip.framesPerDirection * 1000 / clip.framesPerSecond
            #expect(
                actualMilliseconds == expectedMilliseconds,
                "\(clipId): \(actualMilliseconds)ms for a \(ticks)-tick state (\(expectedMilliseconds)ms)"
            )
        }
    }

    /// The two telegraphs must be separable before commit, so they may not
    /// share a cadence or an audio cue.
    @Test func theTwoTelegraphsAreDistinguishable() throws {
        let library = try library()
        let query = try #require(library.clip("improperSearchDaemon_queryTelegraph"))
        let dash = try #require(library.clip("improperSearchDaemon_dashTelegraph"))
        #expect(query.framesPerSecond != dash.framesPerSecond)
    }

    /// Telegraph clips carry the `audio-haptics-001` cues that already exist for
    /// them; nothing else in the contract referenced those IDs before.
    @Test func telegraphsCarryTheirAudioCues() throws {
        let raw = try JSONSerialization.jsonObject(
            with: SpecBundle.contract("clip-metadata-001")
        ) as! [String: Any]
        let clips = raw["clips"] as! [[String: Any]]
        func cue(_ id: String) -> String? {
            clips.first { $0["clipId"] as? String == id }?["audioCue"] as? String
        }
        #expect(cue("improperSearchDaemon_queryTelegraph") == "daemon_query")
        #expect(cue("improperSearchDaemon_dashTelegraph") == "daemon_dash")

        let audioIds = Set(
            (try JSONSerialization.jsonObject(
                with: SpecBundle.contract("presentation-assets-001")
            ) as! [String: Any])["audioEventIds"] as! [String]
        )
        #expect(audioIds.contains("daemon_query"))
        #expect(audioIds.contains("daemon_dash"))
    }

    /// Every actor that can appear in a run now has clips. The elite was the
    /// only one that did not, so it could never be anything but a blockout.
    @Test func everyPlayableActorRoleHasClips() throws {
        let roles = Set(try library().clips.values.map(\.actorRole))
        for role in [
            "player", "camera",
            "fogAnalyticsCloud", "cableCarCorrelator", "sutroSignalWitch",
            "autonomousInformant", "victorianVendor",
            "improperSearchDaemon", "algorithmicModerate"
        ] {
            #expect(roles.contains(role), "\(role) has no clips")
        }
    }

    /// The elite's sprite box keeps the ratio the other actors use, so its
    /// anchor sits on the same ground line.
    @Test func daemonAnchorMatchesItsSpriteBox() throws {
        let clip = try #require(try library().clip("improperSearchDaemon_pursuit"))
        let box = ActorSilhouette.queryApertures.spriteBox
        #expect(box.width == 80 && box.height == 80)
        #expect(clip.anchor.x == box.width / 2)
        // Player 56/64 and Captain 84/96 both sit at 0.875 of box height.
        #expect(clip.anchor.y == box.height * 7 / 8)
    }
}
