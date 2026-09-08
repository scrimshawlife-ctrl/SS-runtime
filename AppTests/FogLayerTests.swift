import CoreGraphics
import Testing
@testable import SSRuntime
@testable import SurveillanceCore

/// `civic-seam-visual-direction.md` §7: fog is layered presentation, and no fog
/// state may conceal authoritative collision, lethal telegraphs, or required
/// Camera boundaries.
///
/// Nothing enforces that except where the two fog layers sit in the draw order,
/// which is one line each and easy to move by accident. These are the tests that
/// make moving them fail.
@Suite(.serialized)
@MainActor
struct FogLayerTests {
    /// Everything a player needs in order to survive draws above both hazes.
    @Test func fogNeverCoversACueThePlayerNeeds() {
        let mustStayAbove: [WorldRenderer.Layer] = [
            .cameraFields,   // required Camera boundaries
            .telegraphs,     // lethal telegraphs
            .mines,
            .actors,
            .projectiles,
            .markers,
            .extraction
        ]
        for layer in mustStayAbove {
            #expect(
                layer.rawValue > WorldRenderer.Layer.fogHigh.rawValue,
                "\(layer) draws under fogHigh, which §7 forbids"
            )
            #expect(
                layer.rawValue > WorldRenderer.Layer.fogLow.rawValue,
                "\(layer) draws under fogLow, which §7 forbids"
            )
        }
    }

    /// The low layer is a ground haze: it sits on the street and its dressing,
    /// and under anything solid — "reveals beams and tires/feet".
    @Test func theLowLayerIsAGroundHaze() {
        #expect(WorldRenderer.Layer.fogLow.rawValue > WorldRenderer.Layer.ground.rawValue)
        #expect(WorldRenderer.Layer.fogLow.rawValue > WorldRenderer.Layer.decorations.rawValue)
        #expect(WorldRenderer.Layer.fogLow.rawValue < WorldRenderer.Layer.solids.rawValue)
        // And below the upper layer, or they are not two layers.
        #expect(WorldRenderer.Layer.fogLow.rawValue < WorldRenderer.Layer.fogHigh.rawValue)
    }

    /// The high layer softens architecture, so it draws over solids — that is
    /// its whole job, and the reason the assertions above matter.
    @Test func theHighLayerSoftensArchitecture() {
        #expect(WorldRenderer.Layer.fogHigh.rawValue > WorldRenderer.Layer.solids.rawValue)
        #expect(WorldRenderer.Layer.fogHigh.rawValue > WorldRenderer.Layer.cameraHousings.rawValue)
    }

    /// Drift is a pure function of the authoritative tick, so two devices agree
    /// and a paused game holds still.
    @Test func driftIsDeterministicAndWraps() {
        let speed = WorldRenderer.fogHighDriftMilli
        #expect(WorldRenderer.fogOffset(tick: 0, speedMilli: speed) == 0)

        // Same tick, same offset, always.
        #expect(
            WorldRenderer.fogOffset(tick: 5_000, speedMilli: speed)
                == WorldRenderer.fogOffset(tick: 5_000, speedMilli: speed)
        )

        // Never escapes one tile, or the grid's margin stops covering the arena
        // and an edge appears.
        let tile = CGFloat(WorldRenderer.fogTileUnits)
        for tick in stride(from: UInt64(0), to: UInt64(40_000), by: 617) {
            let offset = WorldRenderer.fogOffset(tick: tick, speedMilli: speed)
            #expect(offset >= 0 && offset < tile)
        }
    }

    /// The layers move at different speeds, or there is no depth in having two.
    @Test func theTwoLayersDriftApart() {
        #expect(WorldRenderer.fogLowDriftMilli != WorldRenderer.fogHighDriftMilli)
        let tick: UInt64 = 900
        #expect(
            WorldRenderer.fogOffset(tick: tick, speedMilli: WorldRenderer.fogLowDriftMilli)
                != WorldRenderer.fogOffset(tick: tick, speedMilli: WorldRenderer.fogHighDriftMilli)
        )
    }
}
