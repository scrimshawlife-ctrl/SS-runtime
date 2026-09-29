import Testing
@testable import SurveillanceCore

/// Pins the angular convention shared by Camera fields, Captain emitters, and
/// boss telegraphs.
///
/// Headings are **clockwise-positive**: `Cordic.atan2Milli` returns
/// `circle - atan2CCW`, and `Cordic.headingUnit(θ)` is `(cos θ, −sin θ)`. So a
/// heading of 90000 travels toward −Y, not +Y.
///
/// SpriteKit measures angles counter-clockwise, so a renderer must draw a field
/// at screen angle `−heading`. Getting that sign wrong mirrors every field
/// across the X axis and shows surveillance coverage where there is none. Every
/// authored Camera in `civic-seam-arena-002` is off-axis, so the mirroring is
/// never a coincidental no-op.
@Suite(.serialized)
struct ConeOrientationTests {
    /// A point placed along the heading is inside the cone; its mirror is not.
    @Test(arguments: [20_000, 45_000, 135_000, 200_000, 315_000, 330_000])
    func coneOpensTowardTheHeadingNotItsMirror(headingMilli: Int) {
        let origin = VecI(x: 1_000, y: 1_000).asQ8
        let range = 260
        let halfField = 27_500

        let along = point(from: origin, headingMilli: headingMilli, distance: range / 2)
        let mirrored = point(from: origin, headingMilli: -headingMilli, distance: range / 2)

        #expect(
            Collision.pointInCone(
                origin: origin,
                point: along,
                headingMilli: headingMilli,
                halfFieldMilli: halfField,
                rangeUnits: range
            )
        )
        #expect(
            !Collision.pointInCone(
                origin: origin,
                point: mirrored,
                headingMilli: headingMilli,
                halfFieldMilli: halfField,
                rangeUnits: range
            )
        )
    }

    /// Heading 90000 travels toward −Y: angles advance clockwise.
    @Test func headingsAdvanceClockwise() {
        let east = Cordic.headingUnit(milliDegrees: 0)
        let quarter = Cordic.headingUnit(milliDegrees: 90_000)

        #expect(east.x > 0)
        #expect(abs(Int(east.y)) < abs(Int(east.x)) / 100)
        #expect(quarter.y < 0)
        #expect(abs(Int(quarter.x)) < abs(Int(quarter.y)) / 100)
    }

    /// `atan2Milli` inverts `headingUnit`, so a renderer can trust either.
    @Test(arguments: [0, 20_000, 45_000, 135_000, 200_000, 315_000, 330_000])
    func atan2InvertsHeadingUnit(headingMilli: Int) {
        let unit = Cordic.headingUnit(milliDegrees: headingMilli)
        let recovered = Cordic.atan2Milli(y: Int64(unit.y), x: Int64(unit.x))

        #expect(MilliDeg.absDelta(recovered, headingMilli) <= 60)
    }

    /// No authored Camera or Captain emitter is axis-aligned, so a mirrored
    /// render is always visibly wrong rather than coincidentally correct.
    @Test func everyAuthoredFieldIsSensitiveToMirroring() throws {
        let arena = try ArenaManifest.bundled()
        let headings = arena.cameraSockets.map(\.headingMilliDegrees)
            + arena.captainCameraEmitters.map(\.headingMilliDegrees)

        #expect(!headings.isEmpty)
        for heading in headings {
            let normalized = MilliDeg.normalize(heading)
            #expect(normalized != 0)
            #expect(normalized != 180_000)
        }
    }

    private func point(from origin: VecQ8, headingMilli: Int, distance: Int) -> VecQ8 {
        let unit = Cordic.headingUnit(milliDegrees: MilliDeg.normalize(headingMilli))
        return VecQ8(
            x: Q8(raw: origin.x.raw + Int64(unit.x) * Int64(distance) / Int64(Q8.scale)),
            y: Q8(raw: origin.y.raw + Int64(unit.y) * Int64(distance) / Int64(Q8.scale))
        )
    }
}
