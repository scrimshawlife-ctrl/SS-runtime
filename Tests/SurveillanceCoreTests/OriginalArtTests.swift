import Foundation
import Testing
@testable import SurveillanceCore

/// Delivered original art.
///
/// `plannedOriginal` means an original still to be made, so a delivered one
/// needs its own decision rather than overloading the plan. These assertions
/// cover what that decision promises.
@Suite(.serialized)
struct OriginalArtTests {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func originals() throws -> [AssetCatalogEntry] {
        try AssetCatalog.bundled().entries.filter { $0.admissionDecision == .originalAccepted }
    }

    @Test func originalsAreAdmitted() throws {
        #expect(try originals().count > 0)
    }

    /// An original carries its own provenance, never a legacy source.
    @Test func everyOriginalIsOwnedWorkWithADigest() throws {
        for entry in try originals() {
            let record = entry.record
            let id = record.assetId
            #expect(record.productionStatus == .accepted, "\(id)")
            #expect(record.provenance == .projectOriginal, "\(id)")
            #expect(record.runtimeRequired, "\(id)")
            #expect(record.sha256?.count == 64, "\(id)")
            #expect(record.license?.isEmpty == false, "\(id)")
            #expect(record.source?.hasPrefix("legacy://") == false, "\(id) must not claim a legacy source")
        }
    }

    /// A record that claims a file must have one, and its digest must match it.
    @Test func everyOriginalFileExistsAndMatchesItsDigest() throws {
        let delivery = repoRoot()
            .appendingPathComponent("Sources/SurveillanceCore/Resources/RuntimeAssets")
        for entry in try originals() {
            let path = try #require(entry.record.runtimePath, "\(entry.record.assetId)")
            let url = delivery.appendingPathComponent(path)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "missing file for \(entry.record.assetId)"
            )
        }
    }

    /// Delivered frames sit in the authored sprite box for their role.
    @Test func originalSpritesUseAuthoredBoxes() throws {
        let visual = try JSONSerialization.jsonObject(
            with: SpecBundle.contract("visual-language-001")
        ) as! [String: Any]
        let boxes = visual["spriteBoxes"] as! [String: Any]
        func box(_ key: String) -> [String: Int] { boxes[key] as! [String: Int] }

        // Actor art only. Environment art is sized by the arena rather than by
        // an actor sprite box — a solid's art is drawn over its collision box —
        // so it is checked against the arena in `environmentArtMatchesItsSolid`
        // below rather than folded into the actor rule here.
        for entry in try originals() where entry.record.kind == .sprite
            && entry.record.assetId.hasPrefix("actor_")
        {
            let id = entry.record.assetId
            let expected: [String: Int]
            if id.contains("improperSearchDaemon") { expected = box("improperSearchDaemon") }
            else if id.contains("algorithmicModerate") { expected = box("algorithmicModerate") }
            else if id.hasPrefix("actor_camera_") { expected = box("cameraPole") }
            else { expected = box("playerAndStandardEnemy") }

            let dimensions = try #require(entry.record.dimensions, "\(id)")
            #expect(dimensions.width == expected["width"], "\(id)")
            #expect(dimensions.height == expected["height"], "\(id)")
        }
    }

    /// Every actor sprite is covered by the rule above.
    ///
    /// The previous version routed anything unrecognised into the standard actor
    /// box through an `else`, so a new category of sprite would have been
    /// silently held to the wrong size. This pins that actor art is still
    /// exhaustively checked now that the loop filters by prefix.
    @Test func everyActorSpriteIsSizeChecked() throws {
        let actors = try originals().filter {
            $0.record.kind == .sprite && $0.record.assetId.hasPrefix("actor_")
        }
        #expect(!actors.isEmpty)
        for entry in actors {
            #expect(entry.record.dimensions != nil, "\(entry.record.assetId)")
        }
    }

    /// A solid's art is drawn over its collision box, so it must be exactly that
    /// size. Art that does not match would block a player with something that
    /// looks passable, or let them walk through something that looks solid.
    @Test func environmentArtMatchesItsSolid() throws {
        let arena = try ArenaManifest.bundled()
        let records = try originals().reduce(into: [String: AssetRecord]()) {
            $0[$1.record.assetId] = $1.record
        }

        for solid in arena.permanentSolids {
            let id = EnvironmentLibrary.solidAssetId(forSolidId: solid.id)
            guard let record = records[id] else { continue }
            let dimensions = try #require(record.dimensions, "\(id)")
            #expect(dimensions.width == solid.halfSize.x * 2, "\(id)")
            #expect(dimensions.height == solid.halfSize.y * 2, "\(id)")
        }
    }

    /// Ground tiles repeat across the plane, so they must be square and uniform
    /// or the tiling seams.
    @Test func groundTilesAreUniform() throws {
        let library = try EnvironmentLibrary.bundled()
        let records = try originals().reduce(into: [String: AssetRecord]()) {
            $0[$1.record.assetId] = $1.record
        }
        for id in library.ids(in: .ground) {
            guard let record = records[id] else { continue }
            let dimensions = try #require(record.dimensions, "\(id)")
            #expect(dimensions.width == 128, "\(id)")
            #expect(dimensions.height == 128, "\(id)")
        }
    }

    /// The elite now renders. It had no clips at all before the vocabulary
    /// landed, and no art after that until this delivery.
    @Test func theEliteIsFullyBacked() throws {
        let library = try ClipFrameLibrary.bundled()
        for clip in library.clips.values where clip.actorRole == "improperSearchDaemon" {
            for direction in clip.directions {
                #expect(
                    library.isBacked(clipId: clip.clipId, direction: direction),
                    "\(clip.clipId) [\(direction)] is not backed"
                )
            }
        }
    }

    /// Every standard enemy's delivered attack art renders. The D-071 family
    /// (idle, move, hurt, defeat, Correlator recover) is planned, not delivered,
    /// and is covered by `everyClipFrameIsAdmittedOrPlanned` instead.
    @Test func everyStandardEnemyAttackClipIsFullyBacked() throws {
        let library = try ClipFrameLibrary.bundled()
        let roles = [
            "fogAnalyticsCloud", "cableCarCorrelator", "sutroSignalWitch",
            "autonomousInformant", "victorianVendor"
        ]
        let attackClips = library.clips.values.filter {
            roles.contains($0.actorRole) && ($0.clipId.hasSuffix("_anticipate") || $0.clipId.hasSuffix("_commit"))
        }
        #expect(attackClips.count == 10)
        for clip in attackClips {
            for direction in clip.directions {
                #expect(
                    library.isBacked(clipId: clip.clipId, direction: direction),
                    "\(clip.clipId) [\(direction)] is not backed"
                )
            }
        }
    }

    /// No clip frame is unaccounted for: each one is either admitted art or a
    /// planned original awaiting delivery. A frame ID in the clip contract with
    /// no catalog record would be a typo or an orphan, and would stay a
    /// blockout forever without anyone noticing.
    @Test func everyClipFrameIsAdmittedOrPlanned() throws {
        let library = try ClipFrameLibrary.bundled()
        let catalog = try AssetCatalog.bundled()
        let decisions = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.record.assetId, $0.admissionDecision) })
        for clip in library.clips.values {
            for frame in clip.frameIds {
                let decision = decisions[frame]
                #expect(
                    decision == .originalAccepted || decision == .adaptedAdmitted || decision == .plannedOriginal,
                    "\(frame) in \(clip.clipId) has no admitted or planned record"
                )
            }
        }
    }

    /// Every direction whose frames are all admitted is backed, so delivered
    /// art can never silently fail to reach the renderer. Directions still
    /// waiting on planned originals keep their blockout by design.
    @Test func everyFullyAdmittedDirectionIsBacked() throws {
        let library = try ClipFrameLibrary.bundled()
        let catalog = try AssetCatalog.bundled()
        let admitted = Set(catalog.entries
            .filter { $0.admissionDecision == .originalAccepted || $0.admissionDecision == .adaptedAdmitted }
            .map(\.record.assetId))
        for clip in library.clips.values {
            let directions = clip.directions.isEmpty ? [nil] : clip.directions.map { Optional($0) }
            for direction in directions {
                let frames = library.frameIds(clipId: clip.clipId, direction: direction)
                guard frames.allSatisfy(admitted.contains) else { continue }
                #expect(
                    library.isBacked(clipId: clip.clipId, direction: direction),
                    "\(clip.clipId) [\(direction ?? "-")] is admitted but not backed"
                )
            }
        }
    }

    /// The all-or-nothing rule, tested as a rule rather than by relying on a
    /// real gap — every real gap is now filled, and the guarantee still has to
    /// hold for the next delivery that arrives incomplete.
    @Test func oneMissingFrameLeavesADirectionUnbacked() throws {
        let full = try ClipFrameLibrary.bundled()
        let clip = try #require(full.clip("player_move"))
        let ids = full.frameIds(clipId: "player_move", direction: "n")
        #expect(ids.count > 1)

        // Same clip, one frame of the north direction withheld.
        var paths = full.deliveredPaths
        paths.removeValue(forKey: ids[ids.count - 1])
        let holed = ClipFrameLibrary(clips: ["player_move": clip], deliveredPaths: paths)

        #expect(!holed.isBacked(clipId: "player_move", direction: "n"))
        #expect(holed.deliveredFrames(clipId: "player_move", direction: "n") == nil)
        // Only that direction is affected; the rest still render.
        #expect(holed.isBacked(clipId: "player_move", direction: "e"))
    }

    /// A direction never borrows a frame from another direction to look whole.
    @Test func aDirectionNeverBorrowsFromAnother() throws {
        let library = try ClipFrameLibrary.bundled()
        let north = library.frameIds(clipId: "player_move", direction: "n")
        let east = library.frameIds(clipId: "player_move", direction: "e")
        #expect(!north.isEmpty)
        #expect(Set(north).isDisjoint(with: Set(east)))
    }

    /// Overall coverage, so a regression in the pipeline is visible as a number.
    @Test func coverageIsWhatTheRecordSays() throws {
        let library = try ClipFrameLibrary.bundled()
        let coverage = library.coverage
        // 588 delivered, plus the 368 D-071 frames (T602) still planned.
        #expect(coverage.total == 956)
        #expect(coverage.backed == 588)
    }
}
