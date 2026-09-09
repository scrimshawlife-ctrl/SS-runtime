import Foundation
import Testing
@testable import SurveillanceCore

/// `visual-assets-001` §3a: environment art is optional, admitted per group,
/// and all-or-nothing within a group.
@Suite(.serialized)
struct EnvironmentLibraryTests {
    static func library(delivering ids: [String]) -> EnvironmentLibrary {
        let declared = [
            "env_ground_asphalt", "env_ground_sidewalk",
            "env_solid_01_residential_west", "env_solid_02_residential_north",
            "env_camera_municipal_dome"
        ]
        var paths: [String: String] = [:]
        for id in ids { paths[id] = "\(id)@1x.png" }
        return EnvironmentLibrary(declaredIds: declared, deliveredPaths: paths)
    }

    /// The rule that matters: a group with one missing asset is not used at all.
    ///
    /// Partial art is a legibility hazard rather than a partial improvement — a
    /// player cannot tell which grey rectangles are unfinished and which are
    /// meant to read as concrete.
    @Test func oneMissingAssetLeavesTheWholeGroupUnbacked() {
        let library = Self.library(delivering: ["env_ground_asphalt"])

        #expect(!library.isBacked(.ground))
        // Even the delivered one is withheld while its group is short.
        #expect(library.path(for: "env_ground_asphalt") == nil)
    }

    @Test func aCompleteGroupIsBacked() {
        let library = Self.library(delivering: ["env_ground_asphalt", "env_ground_sidewalk"])

        #expect(library.isBacked(.ground))
        #expect(library.path(for: "env_ground_asphalt") == "env_ground_asphalt@1x.png")
    }

    /// Groups are independent: complete ground does not license partial solids.
    @Test func groupsAreBackedIndependently() {
        let library = Self.library(delivering: [
            "env_ground_asphalt", "env_ground_sidewalk",
            "env_solid_01_residential_west"
        ])

        #expect(library.isBacked(.ground))
        #expect(!library.isBacked(.solid))
        #expect(library.path(for: "env_solid_01_residential_west") == nil)
    }

    @Test func nothingDeliveredMeansNothingBacked() {
        let library = Self.library(delivering: [])
        for group in EnvironmentLibrary.Group.allCases {
            #expect(!library.isBacked(group))
        }
    }

    /// A group the contract never declares is not "complete by vacuity".
    @Test func anEmptyGroupIsNotBacked() {
        let library = Self.library(delivering: [])
        #expect(library.ids(in: .motif).isEmpty)
        #expect(!library.isBacked(.motif))
    }

    /// The one place the solid naming convention lives. If this ever disagrees
    /// with the contract the solid falls back to blockout rather than drawing
    /// the wrong building.
    @Test func solidAssetIdsDeriveFromArenaSolidIds() {
        #expect(EnvironmentLibrary.solidAssetId(forSolidId: "solid-04-civic-west")
                == "env_solid_04_civic_west")
        #expect(EnvironmentLibrary.solidAssetId(forSolidId: "solid-13-phoenix-west")
                == "env_solid_13_phoenix_west")
    }

    /// Camera mounts are synthesised at runtime as `mount-<socket>` and have no
    /// authored art, so they must not resolve to a solid asset.
    @Test func runtimeMountSolidsHaveNoArt() {
        let library = Self.library(delivering: [
            "env_solid_01_residential_west", "env_solid_02_residential_north"
        ])
        let id = EnvironmentLibrary.solidAssetId(forSolidId: "mount-SOCKET-01")
        #expect(library.path(for: id) == nil)
    }

    @Test func coverageCountsOnlyDeclaredIds() {
        let library = Self.library(delivering: ["env_ground_asphalt", "not_declared_at_all"])
        #expect(library.coverage.backed == 1)
        #expect(library.coverage.total == 5)
    }
}

/// The contract has to name the environment, or admitted art is unreachable.
@Suite(.serialized)
struct EnvironmentContractTests {
    @Test func theContractNamesEveryArenaSolid() throws {
        let library = try EnvironmentLibrary.bundled()
        let arena = try ArenaManifest.bundled()

        for solid in arena.permanentSolids {
            let id = EnvironmentLibrary.solidAssetId(forSolidId: solid.id)
            #expect(library.declaredIds.contains(id), "no environment ID for \(solid.id)")
        }
    }

    /// Environment IDs reach the bundle filter. Without this, admitted
    /// environment art is excluded however correctly it was produced — the same
    /// gap `musicAssetIds` closed for music.
    @Test func environmentIdsAreRuntimeReachable() throws {
        let reachable = try RuntimeBundleFilter.reachableAssetIds()
        let library = try EnvironmentLibrary.bundled()

        #expect(!library.declaredIds.isEmpty)
        for id in library.declaredIds {
            #expect(reachable.contains(id), "\(id) is not runtime-reachable")
        }
    }

    /// `civic-seam-visual-direction.md` §7 names two fog layers, and the fog
    /// renderer (SS-runtime #78) draws them by asset ID. The presentation
    /// contract must declare those IDs — otherwise the renderer draws layers
    /// its own contract does not name, and the all-or-nothing fog group can
    /// never be backed. This is the renderer/contract agreement, asserted at
    /// the contract so a regression fails here rather than as missing fog.
    @Test func fogIDsResolveThroughThePresentationContract() throws {
        let presentation = try SpecBundle.contract("presentation-assets-001")
        let root = try #require(
            try JSONSerialization.jsonObject(with: presentation) as? [String: Any]
        )
        let environment = Set(root["environmentAssetIds"] as? [String] ?? [])
        #expect(environment.contains("env_fog_low"),
                "presentation-assets-001 does not declare env_fog_low")
        #expect(environment.contains("env_fog_high"),
                "presentation-assets-001 does not declare env_fog_high")

        // The two runtime consumers of that array must see the fog pair:
        // the library that decides whether the fog group is backed, and the
        // bundle filter that ships it.
        let library = try EnvironmentLibrary.bundled()
        #expect(library.ids(in: .fog) == ["env_fog_low", "env_fog_high"])
        let reachable = try RuntimeBundleFilter.reachableAssetIds()
        #expect(reachable.contains("env_fog_low"))
        #expect(reachable.contains("env_fog_high"))
    }
}

/// Camera housings: `camera-placement-001` assigns a family per mount, and the
/// renderer draws that family's art beneath the head clip.
@Suite(.serialized)
struct CameraHousingArtTests {
    /// The mapping is hand-written because the IDs are not a case conversion of
    /// the enum. A typo here would not fail anything loudly — the group would
    /// simply never be backed and every Camera would silently lose its housing,
    /// which is exactly the failure this asserts against.
    @Test func everyHousingFamilyNamesADeclaredAsset() throws {
        let presentation = try SpecBundle.contract("presentation-assets-001")
        let root = try #require(
            try JSONSerialization.jsonObject(with: presentation) as? [String: Any]
        )
        let declared = Set(root["environmentAssetIds"] as? [String] ?? [])
        #expect(!declared.isEmpty)

        for family in HousingFamily.allCases {
            let assetId = EnvironmentLibrary.cameraAssetId(for: family)
            #expect(
                declared.contains(assetId),
                "\(family.rawValue) maps to \(assetId), which the contract does not declare"
            )
        }
    }

    /// Distinct art per family is the whole point: placement varies the housing
    /// so mounts read as different institutions.
    @Test func familiesMapToDistinctAssets() {
        let ids = HousingFamily.allCases.map(EnvironmentLibrary.cameraAssetId(for:))
        #expect(Set(ids).count == ids.count)
    }

    /// Every declared `env_camera_` asset belongs to a family, so the bundle
    /// never carries a housing nothing can draw.
    @Test func noDeclaredHousingIsUnreachable() throws {
        let library = try EnvironmentLibrary.bundled()
        let reachable = Set(HousingFamily.allCases.map(EnvironmentLibrary.cameraAssetId(for:)))
        for id in library.ids(in: .camera) {
            #expect(reachable.contains(id), "\(id) is declared but no family maps to it")
        }
    }
}

/// The Camera mount collides but is never drawn as a blockout.
@Suite(.serialized)
struct CameraMountSolidTests {
    /// The renderer skips mount solids by prefix. If `liveSolids` ever stopped
    /// using the shared constant, the renderer would go back to drawing a black
    /// rectangle over every Camera and nothing else would complain.
    @Test func everyMountSolidCarriesTheSharedPrefix() throws {
        let sim = try Simulation.make(seed: 42)
        let state = sim.state
        #expect(!state.cameras.isEmpty)

        let ids = state.liveSolids.map(\.id)
        for camera in state.cameras {
            #expect(ids.contains(camera.mountSolidId))
            #expect(camera.mountSolidId.hasPrefix(SelectedCamera.mountSolidPrefix))
        }

        // Authored arena solids must not be caught by that prefix, or skipping
        // mounts would silently stop drawing real buildings.
        for solid in state.arena.solidsForCollision {
            #expect(!solid.id.hasPrefix(SelectedCamera.mountSolidPrefix))
        }
    }

    /// The snapshot carries the family, so the renderer can pick the art.
    @Test func snapshotCamerasCarryTheirHousingFamily() throws {
        let sim = try Simulation.make(seed: 42)
        let snap = PresentationSnapshot(sim.state)
        #expect(!snap.cameras.isEmpty)
        for camera in snap.cameras {
            #expect(camera.housingFamily != nil)
        }
        // The Captain emitter borrows the struct for cone geometry only.
        #expect(snap.captainField?.housingFamily == nil)
    }
}

/// Declared and shipped is not the same as drawn.
///
/// `RuntimeBundleFilter` unions the ID lists the contracts name, so anything
/// `presentation-assets-001` declares is "reachable" *by construction* — the
/// filter cannot tell the difference between art the renderer draws and art
/// nobody wired up. `env_camera_*` sat in the bundle unused for exactly that
/// reason and no test noticed.
///
/// This closes the gap one level up: every declared environment asset must have
/// a route to the screen, and the ones deliberately staged ahead of the work
/// that will use them have to be named here rather than merely absent.
@Suite(.serialized)
struct EnvironmentAssetsAreDrawnTests {
    /// Motif sheets produced under T509 that no surface exists for yet.
    ///
    /// They are frontal elevations for building façades, which arrive with T508
    /// and T802. Placing them flat on the ground is what the decoration pass
    /// already tried and backed out. They ship because T509 required them
    /// produced and the bundle filter ships what the contract declares; this
    /// list is the record that it is a decision and not an oversight.
    static let stagedForFacadeWork: Set<String> = [
        "env_motif_repair",
        "env_motif_counter_signal",
        "env_motif_broadcast_glyph"
    ]

    @Test func everyDeclaredEnvironmentAssetHasARouteToTheScreen() throws {
        let library = try EnvironmentLibrary.bundled()
        let arena = try ArenaManifest.bundled()

        let placed = Set(arena.placedDecorations.map(\.assetId))
        let solids = Set(arena.permanentSolids.map { EnvironmentLibrary.solidAssetId(forSolidId: $0.id) })
        let housings = Set(HousingFamily.allCases.map(EnvironmentLibrary.cameraAssetId(for:)))

        for id in library.declaredIds {
            if Self.stagedForFacadeWork.contains(id) { continue }
            // Ground tiles are chosen per zone by the renderer, and the fog
            // layers are a whole-arena presentation pass (renderFog, gated by
            // the all-or-nothing fog group) — for both, the group itself is the
            // route rather than any one placement.
            if id.hasPrefix(EnvironmentLibrary.Group.ground.rawValue)
                || id.hasPrefix(EnvironmentLibrary.Group.fog.rawValue)
            { continue }

            #expect(
                placed.contains(id) || solids.contains(id) || housings.contains(id),
                "\(id) ships but nothing draws it: place it, map it, or stage it explicitly"
            )
        }
    }

    /// The staged list must not rot. If one of these is placed later, this fails
    /// and whoever placed it removes it from the list deliberately.
    @Test func stagedAssetsAreStillUnplaced() throws {
        let arena = try ArenaManifest.bundled()
        let placed = Set(arena.placedDecorations.map(\.assetId))
        for id in Self.stagedForFacadeWork {
            #expect(!placed.contains(id), "\(id) is placed now — drop it from stagedForFacadeWork")
        }
    }
}
