import Testing
@testable import SurveillanceCore

/// T301 — the 36 × 24-cell baseline arena with seven canonical zones
/// (`arena-layout.md` §Coordinate system and §Zone progression).
///
/// `ArenaAndSimulationTests` already asserts the grid and `zones.count == 7`.
/// A count cannot tell seven canonical zones from seven arbitrary ones, so this
/// pins each zone's id, order, and exact trigger rectangle to the table in the
/// specification, and the grid to its 64-unit cell.
@Suite struct CanonicalArenaZonesTests {
    /// Verbatim from `arena-layout.md` §Zone progression: id, center, half-size.
    static let specifiedZones: [(id: String, cx: Int, cy: Int, hx: Int, hy: Int)] = [
        ("Z-01", 224, 256, 160, 192),
        ("Z-02", 576, 448, 256, 256),
        ("Z-03", 1024, 640, 256, 256),
        ("Z-04", 1376, 1088, 288, 320),
        ("Z-05", 1728, 832, 256, 256),
        ("Z-06", 2048, 640, 192, 256),
        ("Z-07", 2048, 224, 192, 128),
    ]

    @Test func gridIs36By24SixtyFourUnitCells() throws {
        let arena = try ArenaManifest.bundled()
        #expect(arena.cellSizeUnits == 64)
        #expect(arena.gridSizeCells.width == 36)
        #expect(arena.gridSizeCells.height == 24)
        #expect(arena.boundsUnits.minX == 0)
        #expect(arena.boundsUnits.minY == 0)
        #expect(arena.boundsUnits.maxX == 36 * 64)
        #expect(arena.boundsUnits.maxY == 24 * 64)
    }

    @Test func zonesAreTheSevenCanonicalZonesInOrder() throws {
        let arena = try ArenaManifest.bundled()
        #expect(arena.zones.map(\.id) == Self.specifiedZones.map(\.id))
        for (zone, spec) in zip(arena.zones, Self.specifiedZones) {
            #expect(zone.center == VecI(x: spec.cx, y: spec.cy), "\(spec.id) center")
            #expect(zone.halfSize == VecI(x: spec.hx, y: spec.hy), "\(spec.id) half-size")
        }
    }

    @Test func everyZoneLiesInsideTheArena() throws {
        let arena = try ArenaManifest.bundled()
        for zone in arena.zones {
            #expect(zone.center.x - zone.halfSize.x >= arena.boundsUnits.minX, "\(zone.id)")
            #expect(zone.center.y - zone.halfSize.y >= arena.boundsUnits.minY, "\(zone.id)")
            #expect(zone.center.x + zone.halfSize.x <= arena.boundsUnits.maxX, "\(zone.id)")
            #expect(zone.center.y + zone.halfSize.y <= arena.boundsUnits.maxY, "\(zone.id)")
        }
    }
}
