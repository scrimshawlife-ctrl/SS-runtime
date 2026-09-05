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

    /// Every one of the 24 event IDs is backed.
    @Test func audioCoverageIsMeasurable() throws {
        let catalog = try AssetCatalog.bundled()
        let eventIds = Set(try presentation()["audioEventIds"] as! [String])
        let backed = catalog.entries
            .filter { $0.admissionDecision == .adaptedAdmitted }
            .map(\.record.assetId)
            .filter { eventIds.contains($0) }

        #expect(eventIds.count == 24)
        #expect(backed.count == 24)
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

/// Every music state now has a bed, so no state falls silent.
@Suite(.serialized)
struct MusicBedCoverageTests {
    @Test func everyMusicStateHasADeliveredBed() throws {
        let catalog = try AssetCatalog.bundled()
        let backed = Set(
            catalog.entries
                .filter {
                    $0.admissionDecision == .adaptedAdmitted
                        || $0.admissionDecision == .originalAccepted
                }
                .map(\.record.assetId)
        )
        for state in [
            MusicState.explore, .observed, .lockdown, .boss, .extraction, .terminal
        ] {
            let id = "music_\(state.rawValue)"
            #expect(backed.contains(id), "\(state.rawValue) has no bed")
        }
        #expect(backed.contains("ambience_civic_seam"))
    }

    /// T102 excludes non-San-Francisco *city packs*. `Shared/` is not one, which
    /// is how the state beds were admitted. The only city music permitted is the
    /// four boss phase beds the spec names.
    @Test func onlyTheNamedBossPhaseBedsComeFromACityPack() throws {
        let catalog = try AssetCatalog.bundled()
        let cities = [
            "atlanta", "columbus", "dayton", "los_angeles", "louisville",
            "new_york", "oakland", "tulsa", "wichita"
        ]
        let permitted: Set<String> = [
            "music_boss_publicSafety", "music_boss_civilLiberties",
            "music_boss_temporarySafeguard", "music_boss_independentReview"
        ]
        for entry in catalog.entries
        where entry.record.kind == .music && entry.admissionDecision == .adaptedAdmitted {
            let source = (entry.record.source ?? "").lowercased()
            guard cities.contains(where: { source.contains($0) }) else { continue }
            #expect(
                permitted.contains(entry.record.assetId),
                "\(entry.record.assetId) takes city music it is not permitted"
            )
        }
    }

    /// The state beds themselves stay San Francisco or Shared.
    @Test func stateBedsAreNeverCityMusic() throws {
        let catalog = try AssetCatalog.bundled()
        let cities = [
            "atlanta", "columbus", "dayton", "los_angeles", "louisville",
            "new_york", "oakland", "tulsa", "wichita"
        ]
        for id in [
            "music_explore", "music_observed", "music_lockdown",
            "music_boss", "music_extraction", "music_terminal", "ambience_civic_seam"
        ] {
            guard let entry = catalog.entries.first(where: { $0.record.assetId == id }) else { continue }
            let source = (entry.record.source ?? "").lowercased()
            for city in cities {
                #expect(!source.contains(city), "\(id) sources \(city)")
            }
        }
    }
}

/// The Captain's four phases each get their own bed, without adding a music
/// state. `audio-haptics-001` keeps one `boss` state; only the bed it plays
/// changes, selected from authoritative phase.
@Suite(.serialized)
struct BossPhaseMusicTests {
    private func query(phase: BossPhase?) -> AudioWorldQuery {
        AudioWorldQuery(
            playerId: EntityID(1),
            playerPosition: VecI(x: 0, y: 0).asQ8,
            outcome: .playing,
            extractionArmed: false,
            hasAlgorithmicModerate: true,
            lockdownEntered: false,
            detectionState: .hidden,
            bossPhase: phase,
            viewport: ViewportSpec(
                baselineWorldWidth: 896,
                baselineWorldHeight: 414,
                deadZoneWidth: 96,
                deadZoneHeight: 64,
                maximumLookAheadUnits: 96
            ),
            positions: [:]
        )
    }

    /// The state stays `boss` in every phase — this adds no music state.
    @Test func phaseNeverChangesTheMusicState() {
        for phase in [
            BossPhase.publicSafety, .civilLiberties, .temporarySafeguard, .independentReview
        ] {
            #expect(AudioProjector.musicState(query(phase: phase)) == .boss)
        }
        #expect(AudioProjector.musicState(query(phase: nil)) == .boss)
    }

    /// Each phase selects a distinct bed.
    @Test func everyPhaseSelectsItsOwnBed() {
        let beds = [
            BossPhase.publicSafety, .civilLiberties, .temporarySafeguard, .independentReview
        ].map { AudioProjector.musicBedAssetId(query(phase: $0)) }

        #expect(beds == [
            "music_boss_publicSafety",
            "music_boss_civilLiberties",
            "music_boss_temporarySafeguard",
            "music_boss_independentReview"
        ])
        #expect(Set(beds).count == 4)
    }

    /// Without a phase the boss state plays the plain bed, so an encounter is
    /// never silent for want of phase information.
    @Test func noPhaseFallsBackToThePlainBossBed() {
        #expect(AudioProjector.musicBedAssetId(query(phase: nil)) == "music_boss")
    }

    /// Every other state's bed is still its own name.
    @Test func nonBossStatesAreUnaffected() {
        var world = query(phase: .publicSafety)
        world.hasAlgorithmicModerate = false
        world.lockdownEntered = true
        #expect(AudioProjector.musicState(world) == .lockdown)
        #expect(AudioProjector.musicBedAssetId(world) == "music_lockdown")
    }

    /// All four beds are delivered, and no city name reaches an asset ID.
    @Test func everyPhaseBedIsDeliveredAndCityFree() throws {
        let catalog = try AssetCatalog.bundled()
        let backed = Set(
            catalog.entries
                .filter {
                    $0.admissionDecision == .adaptedAdmitted
                        || $0.admissionDecision == .originalAccepted
                }
                .map(\.record.assetId)
        )
        for phase in [
            BossPhase.publicSafety, .civilLiberties, .temporarySafeguard, .independentReview
        ] {
            let id = "music_boss_\(phase.rawValue)"
            #expect(backed.contains(id), "\(id) is not delivered")
            #expect(!id.lowercased().contains("atlanta"), "\(id) carries a city name")
        }
    }

    /// The beds escalate with the phases, so no two phases share one.
    @Test func noTwoPhasesShareABed() throws {
        let catalog = try AssetCatalog.bundled()
        let paths = [
            "music_boss_publicSafety", "music_boss_civilLiberties",
            "music_boss_temporarySafeguard", "music_boss_independentReview"
        ].compactMap { id in
            catalog.entries.first { $0.record.assetId == id }?.record.runtimePath
        }
        #expect(paths.count == 4)
        #expect(Set(paths).count == 4)
    }
}


/// Two cues took the nearest applicable sound rather than an exact meaning
/// match, and their records say so.
///
/// `legacy-admission.md` §Approximate substitution permits that only where
/// nothing carries the meaning, and requires the record to admit it. A catalog
/// that quietly claimed an exact match would make these two invisible to
/// whoever produces originals later.
@Suite(.serialized)
struct ApproximateCueTests {
    private func audioEntries() throws -> [AssetCatalogEntry] {
        let presentation = try JSONSerialization.jsonObject(
            with: SpecBundle.contract("presentation-assets-001")
        ) as! [String: Any]
        let ids = Set(presentation["audioEventIds"] as! [String])
        return try AssetCatalog.bundled().entries.filter { ids.contains($0.record.assetId) }
    }

    /// Exactly two cues are approximate, and they are the two the spec names.
    @Test func exactlyTheNamedCuesAreApproximate() throws {
        let approximate = try audioEntries()
            .filter { ($0.record.notes ?? "").contains("APPROXIMATE") }
            .map(\.record.assetId)
            .sorted()

        #expect(approximate == ["extraction_tick", "player_dodge"])
    }

    /// An approximate record has to say what is imperfect and that it should be
    /// replaced, or the note is decoration rather than a record.
    @Test func anApproximateRecordExplainsItself() throws {
        for entry in try audioEntries()
        where (entry.record.notes ?? "").contains("APPROXIMATE") {
            let notes = entry.record.notes ?? ""
            #expect(notes.contains("Replace with an original"), "\(entry.record.assetId)")
            #expect(notes.count > 120, "\(entry.record.assetId) note is too thin to be useful")
        }
    }

    /// An approximate substitution may not reuse a sound already carrying a
    /// different event, or the player learns a confused vocabulary.
    @Test func approximateCuesDoNotCollideWithOtherEvents() throws {
        let entries = try audioEntries()
        for entry in entries where (entry.record.notes ?? "").contains("APPROXIMATE") {
            let path = entry.record.runtimePath
            let sharers = entries.filter {
                $0.record.runtimePath == path && $0.record.assetId != entry.record.assetId
            }
            #expect(
                sharers.isEmpty,
                "\(entry.record.assetId) shares a sound with \(sharers.map(\.record.assetId))"
            )
        }
    }

    /// Neither approximate substitution widened the city boundary.
    @Test func approximateCuesStayWithinTheCityBoundary() throws {
        let cities = [
            "atlanta", "columbus", "dayton", "los_angeles", "louisville",
            "new_york", "oakland", "tulsa", "wichita"
        ]
        for entry in try audioEntries()
        where (entry.record.notes ?? "").contains("APPROXIMATE") {
            let source = (entry.record.source ?? "").lowercased()
            for city in cities {
                #expect(!source.contains(city), "\(entry.record.assetId) sources \(city)")
            }
        }
    }
}
