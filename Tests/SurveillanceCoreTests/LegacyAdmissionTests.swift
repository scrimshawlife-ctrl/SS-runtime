import Foundation
import Testing
@testable import SurveillanceCore

/// `legacy-admission.md` §Bounded visual and audio admission.
///
/// Admission is the one route by which a legacy file may enter the bundle, so
/// each clause of the admission test gets an assertion here. The casting rule
/// is the load-bearing one: LC-007 records that the legacy enemies and boss are
/// not this game's cast, and nothing may quietly walk that back.
@Suite(.serialized)
struct LegacyAdmissionTests {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func admitted() throws -> [AssetCatalogEntry] {
        try AssetCatalog.bundled().entries.filter { $0.admissionDecision == .adaptedAdmitted }
    }

    @Test func somethingIsActuallyAdmitted() throws {
        #expect(try admitted().count > 0)
    }

    /// Clause 2: a per-asset record with complete, verifiable provenance.
    @Test func everyAdmittedAssetCarriesCompleteProvenance() throws {
        for entry in try admitted() {
            let record = entry.record
            let id = record.assetId
            #expect(record.productionStatus == .accepted, "\(id)")
            #expect(record.provenance == .adaptedLegacy, "\(id)")
            #expect(record.runtimeRequired, "\(id)")
            #expect(record.sha256?.count == 64, "\(id)")
            #expect(record.license?.isEmpty == false, "\(id)")
            #expect(record.runtimePath?.isEmpty == false, "\(id)")
            // Source names the frozen commit, not a working tree or another repo.
            let source = try #require(record.source, "\(id)")
            #expect(source.hasPrefix("legacy://"), "\(id)")
            #expect(source.hasSuffix("@\(LegacyEvidence.commit)"), "\(id)")
        }
    }

    /// Clause 1, the casting rule. LC-007 says the legacy enemies and boss are
    /// REWRITE, so no admitted asset may back a Civic Seam enemy, the Improper
    /// Search Daemon, or the Algorithmic Moderate.
    @Test func noAdmittedAssetBacksTheCanonicalCast() throws {
        let forbiddenRoles = [
            "fogAnalyticsCloud", "cableCarCorrelator", "sutroSignalWitch",
            "autonomousInformant", "victorianVendor",
            "improperSearchDaemon", "algorithmicModerate"
        ]
        for entry in try admitted() {
            for role in forbiddenRoles {
                #expect(
                    !entry.record.assetId.contains(role),
                    "\(entry.record.assetId) backs cast role \(role)"
                )
            }
            // And no legacy guard or boss file may be the source.
            let source = entry.record.source ?? ""
            #expect(!source.contains("/guard_"), "\(entry.record.assetId)")
            #expect(!source.contains("/boss_"), "\(entry.record.assetId)")
        }
    }

    /// T102 still excludes non-San-Francisco *packs*. The amendment admits
    /// individual cues only, so the boundary is asserted in three parts: no
    /// pack asset may come from another city, no admitted asset ID may carry a
    /// city name, and the exception set is exactly what the spec names.
    @Test func onlyNamedSingleCuesComeFromAnotherCity() throws {
        let otherCities = [
            "atlanta", "columbus", "dayton", "los_angeles", "louisville",
            "new_york", "oakland", "tulsa", "wichita"
        ]
        // The spec names three single cues and the four boss phase beds.
        let permittedCues: Set<String> = ["daemon_dash", "boss_defeated", "extraction_reset"]
        let permittedBeds: Set<String> = [
            "music_boss_publicSafety", "music_boss_civilLiberties",
            "music_boss_temporarySafeguard", "music_boss_independentReview"
        ]

        for entry in try admitted() {
            let id = entry.record.assetId
            let source = (entry.record.source ?? "").lowercased()
            let fromAnotherCity = otherCities.contains { source.contains($0) }

            // A city name never reaches an asset ID, so nothing on screen or in
            // a receipt names another city.
            for city in otherCities {
                #expect(!id.lowercased().contains(city), "\(id) carries a city name")
            }
            guard fromAnotherCity else { continue }

            #expect(
                permittedCues.contains(id) || permittedBeds.contains(id),
                "\(id) is not an admitted non-SF asset"
            )
            let file = source.split(separator: "/").last.map(String.init) ?? ""
            if permittedCues.contains(id) {
                // Cues are single sfx_/stinger_ files, never packs.
                #expect(
                    file.hasPrefix("sfx_") || file.hasPrefix("stinger_"),
                    "\(id) sources \(file), which is not a single cue"
                )
            } else {
                // The only city music permitted is a boss phase loop.
                #expect(file.contains("boss_phase"), "\(id) sources \(file)")
            }
            // City ambience and run loops are never admitted.
            #expect(!file.hasPrefix("amb_"), "\(id) sources city ambience")
            #expect(!file.contains("run_loop"), "\(id) sources a city run loop")
        }
    }

    /// No environment or sprite asset may come from another city at all.
    @Test func noVisualAssetComesFromAnotherCity() throws {
        let otherCities = [
            "atlanta", "columbus", "dayton", "los_angeles", "louisville",
            "new_york", "oakland", "tulsa", "wichita"
        ]
        for entry in try admitted() where entry.record.kind == .sprite || entry.record.kind == .ui {
            let source = (entry.record.source ?? "").lowercased()
            for city in otherCities {
                #expect(!source.contains(city), "\(entry.record.assetId) sources \(city)")
            }
        }
    }

    /// Clause 3: delivered frames sit in the authored sprite box, not at legacy
    /// pixel dimensions.
    @Test func admittedSpritesUseAuthoredBoxes() throws {
        let visual = try JSONSerialization.jsonObject(
            with: SpecBundle.contract("visual-language-001")
        ) as! [String: Any]
        let boxes = visual["spriteBoxes"] as! [String: Any]
        let player = boxes["playerAndStandardEnemy"] as! [String: Int]
        let camera = boxes["cameraPole"] as! [String: Int]

        for entry in try admitted() where entry.record.kind == .sprite {
            let dimensions = try #require(entry.record.dimensions, "\(entry.record.assetId)")
            let expected = entry.record.assetId.hasPrefix("actor_camera_") ? camera : player
            #expect(dimensions.width == expected["width"], "\(entry.record.assetId)")
            #expect(dimensions.height == expected["height"], "\(entry.record.assetId)")
        }
    }

    /// A record that claims a delivered file must have one, named legally.
    @Test func everyAdmittedFileExistsAndIsNamedLegally() throws {
        let delivery = repoRoot()
            .appendingPathComponent("Sources/SurveillanceCore/Resources/RuntimeAssets")
        for entry in try admitted() {
            let path = try #require(entry.record.runtimePath)
            #expect(!path.contains("/"), "\(entry.record.assetId) must be a bare filename")
            let url = delivery.appendingPathComponent(path)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "missing delivered file for \(entry.record.assetId): \(path)"
            )
            if path.hasSuffix(".png") {
                #expect(AssetIntake.isValidDeliveryPNGName(path), "\(path)")
            }
        }
    }

    /// Admitted assets ship; nothing else does.
    @Test func admittedAssetsReachTheBundleProjection() throws {
        let catalog = try AssetCatalog.bundled()
        let reachable = try RuntimeBundleFilter.reachableAssetIds()
        let projection = RuntimeBundleFilter.project(catalog: catalog, reachable: reachable)
        let bundled = Set(projection.bundleAssetIds)

        for entry in try admitted() {
            #expect(bundled.contains(entry.record.assetId), "\(entry.record.assetId)")
        }
        for entry in catalog.entries
        where entry.admissionDecision == .rejected || entry.admissionDecision == .excluded {
            #expect(!bundled.contains(entry.record.assetId), "\(entry.record.assetId)")
        }
    }

    /// Partial coverage is legal and observable, not silent.
    @Test func clipCoverageIsPartialAndMeasurable() throws {
        let catalog = try AssetCatalog.bundled()
        let frames = try RuntimeBundleFilter.reachableClipFrameIds(
            clipJSON: SpecBundle.contract("clip-metadata-001")
        )
        let backed = Set(
            catalog.entries
                .filter {
                    ($0.admissionDecision == .adaptedAdmitted
                        || $0.admissionDecision == .originalAccepted)
                        && $0.record.kind == .sprite
                }
                .map(\.record.assetId)
        )
        // 588: 564 after the Daemon vocabulary, plus 24 from pinning the
        // Captain attack clips to their telegraph windows.
        #expect(frames.count == 588)
        // 129 admitted legacy sprites plus delivered originals: every frame.
        #expect(backed.count == 588)
        #expect(backed.isSubset(of: frames))
        // Every camera frame is backed; the cast roles are entirely unbacked.
        let cameraFrames = frames.filter { $0.hasPrefix("actor_camera_") }
        #expect(cameraFrames.allSatisfy { backed.contains($0) })
        // The Captain is fully backed, attacks included.
        #expect(frames.filter { $0.contains("algorithmicModerate") }.allSatisfy { backed.contains($0) })
    }

    /// A record may not point back into the evidence tree.
    @Test func noAdmittedAssetShipsFromArtSources() throws {
        for entry in try admitted() {
            #expect(entry.record.runtimePath?.hasPrefix("ArtSources/") == false)
        }
    }
}
