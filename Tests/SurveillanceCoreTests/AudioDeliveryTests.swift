import Foundation
import Testing
@testable import SurveillanceCore

/// `audio-haptics-001` delivery: which cues and music beds actually have files,
/// and what the runtime must do about the ones that do not.
@Suite(.serialized)
struct AudioDeliveryTests {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func presentation() throws -> [String: Any] {
        try JSONSerialization.jsonObject(
            with: SpecBundle.contract("presentation-assets-001")
        ) as! [String: Any]
    }

    /// Every music state named by the contract has a registered asset ID, so a
    /// delivered bed is reachable rather than unreachable by construction.
    @Test func everyMusicStateHasARegisteredAssetId() throws {
        let registered = Set(try presentation()["musicAssetIds"] as! [String])
        for state in [
            MusicState.explore, .observed, .lockdown, .boss, .extraction, .terminal
        ] {
            #expect(registered.contains("music_\(state.rawValue)"), "\(state.rawValue)")
        }
        #expect(registered.contains("ambience_civic_seam"))
    }

    /// Registered music IDs are reachable, which is what lets them ship.
    @Test func musicAssetIdsAreReachable() throws {
        let reachable = try RuntimeBundleFilter.reachableAssetIds()
        for id in try presentation()["musicAssetIds"] as! [String] {
            #expect(reachable.contains(id), "\(id)")
        }
    }

    /// A cue or bed is either delivered with a real file or planned. There is no
    /// third state, and nothing claims a file it does not have.
    @Test func everyAudioIdIsDeliveredOrPlanned() throws {
        let catalog = try AssetCatalog.bundled()
        let delivery = repoRoot()
            .appendingPathComponent("Sources/SurveillanceCore/Resources/RuntimeAssets")
        let ids = (try presentation()["audioEventIds"] as! [String])
            + (try presentation()["musicAssetIds"] as! [String])

        for id in ids {
            let entry = try #require(catalog.entries.first { $0.record.assetId == id }, "\(id)")
            switch entry.admissionDecision {
            case .adaptedAdmitted:
                let path = try #require(entry.record.runtimePath, "\(id)")
                #expect(
                    FileManager.default.fileExists(
                        atPath: delivery.appendingPathComponent(path).path
                    ),
                    "\(id) claims \(path) but no file is delivered"
                )
            case .plannedOriginal:
                #expect(entry.record.runtimePath == nil, "\(id)")
            case .originalAccepted:
                // An original that has been produced and delivered.
                let path = try #require(entry.record.runtimePath, "\(id)")
                #expect(
                    FileManager.default.fileExists(
                        atPath: delivery.appendingPathComponent(path).path
                    ),
                    "\(id) claims \(path) but no file is delivered"
                )
            case .excluded, .rejected, .sfCandidate:
                Issue.record("audio id \(id) is not admissible")
            }
        }
    }

    /// Coverage is what the record says it is: 13 of 24 event IDs backed.
    @Test func audioCoverageIsMeasurable() throws {
        let catalog = try AssetCatalog.bundled()
        let eventIds = Set(try presentation()["audioEventIds"] as! [String])
        let backed = catalog.entries
            .filter { $0.admissionDecision == .adaptedAdmitted }
            .map(\.record.assetId)
            .filter { eventIds.contains($0) }

        #expect(eventIds.count == 24)
        #expect(backed.count == 13)
    }

    /// One source may legitimately back several IDs — `sfx_upgrade_selected`
    /// covers all three upgrades — so the delivered file is shared, not copied.
    @Test func sharedSourcesShareOneDeliveredFile() throws {
        let catalog = try AssetCatalog.bundled()
        let upgrades = [
            "upgrade_selected_signalJammer",
            "upgrade_selected_ricochetPulse",
            "upgrade_selected_ghostStep"
        ]
        let paths = try upgrades.map { id -> String in
            let entry = try #require(catalog.entries.first { $0.record.assetId == id }, "\(id)")
            return try #require(entry.record.runtimePath, "\(id)")
        }
        #expect(Set(paths).count == 1)
    }

    /// Music beds never consume an effects voice.
    @Test func musicIsNotAnEffectCue() throws {
        let eventIds = Set(try presentation()["audioEventIds"] as! [String])
        for id in try presentation()["musicAssetIds"] as! [String] {
            #expect(!eventIds.contains(id), "\(id) must not also be an event cue")
        }
    }
}
