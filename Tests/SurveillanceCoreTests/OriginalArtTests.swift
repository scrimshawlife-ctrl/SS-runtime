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

        for entry in try originals() where entry.record.kind == .sprite {
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

    /// Every standard enemy renders.
    @Test func everyStandardEnemyIsFullyBacked() throws {
        let library = try ClipFrameLibrary.bundled()
        let roles = [
            "fogAnalyticsCloud", "cableCarCorrelator", "sutroSignalWitch",
            "autonomousInformant", "victorianVendor"
        ]
        for clip in library.clips.values where roles.contains(clip.actorRole) {
            for direction in clip.directions {
                #expect(
                    library.isBacked(clipId: clip.clipId, direction: direction),
                    "\(clip.clipId) [\(direction)] is not backed"
                )
            }
        }
    }

    /// Partial coverage stays honest: a short clip is not backed, and must not
    /// borrow a frame to look complete.
    @Test func shortClipsRemainUnbacked() throws {
        let library = try ClipFrameLibrary.bundled()
        for clipId in [
            "player_idle",
            "algorithmicModerate_narrowTailoring",
            "algorithmicModerate_temporaryOrder",
            "algorithmicModerate_independentReview"
        ] {
            let clip = try #require(library.clip(clipId), "\(clipId)")
            for direction in clip.directions {
                #expect(
                    !library.isBacked(clipId: clipId, direction: direction),
                    "\(clipId) [\(direction)] reports backed while short"
                )
            }
        }
    }

    /// Overall coverage, so a regression in the pipeline is visible as a number.
    @Test func coverageIsWhatTheRecordSays() throws {
        let library = try ClipFrameLibrary.bundled()
        let coverage = library.coverage
        #expect(coverage.total == 588)
        #expect(coverage.backed == 492)
    }
}
