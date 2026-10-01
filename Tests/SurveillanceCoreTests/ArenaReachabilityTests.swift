import Foundation
import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct ArenaReachabilityTests {
    @Test func arenaAR006CriticalPathAndSpawnAlley() throws {
        let arena = try ArenaManifest.bundled()
        #expect(ArenaReachability.geometryInBounds(arena))
        #expect(ArenaReachability.viewportMatchesContract(arena))
        #expect(ArenaReachability.spawnAlleyProtected(arena))
        #expect(ArenaReachability.consecutiveZonesConnected(arena))
        #expect(ArenaReachability.diagonalSpine(arena))
        // Pinned civic-seam-arena-004.json; do not rewrite coordinates (SS-specs authority).
        #expect(
            ArenaReachability.authoredSolidOverlaps(arena) == [
                "gate gate-mb-forward overlaps mb-05",
                "socket:ma-02 in solid-04-civic-west",
                "socket:mb-02 in solid-06-service-yard-a",
                "socket:mc-08 in solid-09-grid-island-a"
            ]
        )
        // D-087 moved cam-z02-d off the kiosk corner: no socket's field origin
        // or target anchor lies inside a permanent solid any more.
        #expect(ArenaReachability.fieldOriginsInsideSolids(arena) == [])
        let anchorsInSolids = arena.cameraSockets.filter { socket in
            let anchor = CameraPlacement.targetAnchor(socket: socket, geometry: arena.standardCameraGeometry)
            return arena.permanentSolids.contains { solid in
                let box = solid.aabb
                return Int64(box.minX) * Q8.scale <= anchor.x.raw && anchor.x.raw <= Int64(box.maxX) * Q8.scale
                    && Int64(box.minY) * Q8.scale <= anchor.y.raw && anchor.y.raw <= Int64(box.maxY) * Q8.scale
            }
        }.map(\.socketId)
        #expect(anchorsInSolids == [])
    }

    @Test func arenaAR005ClosedMAGateLeavesEscapeAperture() throws {
        let arena = try ArenaManifest.bundled()
        let ma = ArenaReachability.maEscapeOpen(arena)
        let maBack = ArenaReachability.escapeApertureOpen(arena, encounter: "M-A")
        let mbBack = ArenaReachability.escapeApertureOpen(arena, encounter: "M-B")
        let mcBack = ArenaReachability.escapeApertureOpen(arena, encounter: "M-C")
        #expect(ma)
        #expect(maBack)
        #expect(mbBack)
        #expect(mcBack)
    }

    @Test func arenaAR007BossCorridorRemainsOneHundredNinetyTwoWide() throws {
        let arena = try ArenaManifest.bundled()
        #expect(ArenaReachability.bossCorridorClear(arena))
    }

    @Test func arenaLayoutDocumentsBossGateSidestep() throws {
        let arena = try ArenaManifest.bundled()
        #expect(ArenaReachability.extractionReachable(arena, bossGateClosed: false))
        // Pinned civic-seam-arena-004.json leaves a 64-unit gap beside gate-boss-extraction
        // (2048,384) half (96,16) vs phoenix solids. SS-specs is authority; do not widen the gate.
        #expect(ArenaReachability.extractionReachable(arena, bossGateClosed: true))
    }

    @Test func arenaAR010ManifestJSONRoundTrip() throws {
        let data = SpecBundle.contract("civic-seam-arena-004")
        let object = try JSONSerialization.jsonObject(with: data)
        let first = try #require(CanonicalJSON.parse(object))
        let encoded = first.serialize()
        let secondObject = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        let second = try #require(CanonicalJSON.parse(secondObject))
        #expect(first.serialize() == second.serialize())
        #expect(first.sha256Hex() == second.sha256Hex())

        let arena = try ArenaLoader.decodeAndValidate(data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let roundTrip = try encoder.encode(arena)
        let again = try ArenaLoader.decodeAndValidate(roundTrip)
        #expect(again == arena)
    }

    @Test func arenaAR009LethalDamageBeatsExtractionSuccess() {
        #expect(IsolatedKernel.extractionVersusDeath(integrity: 0, remainingAfterTick: 0) == .failure)
        #expect(IsolatedKernel.extractionVersusDeath(integrity: 1, remainingAfterTick: 0) == .success)
        #expect(IsolatedKernel.extractionVersusDeath(integrity: 1, remainingAfterTick: 1) == .playing)
    }
}
