import Foundation

/// A per-channel light multiplier, 0…1 per channel. A multiplier can tint or
/// darken a pixel and never brighten it: every channel factor is at most 1.
public struct CourtMultiplier: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// No light: the scene unchanged.
    public static let neutral = CourtMultiplier(red: 1, green: 1, blue: 1)

    /// Rec. 709 luma of the multiplier.
    public var luma: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    /// The largest channel factor. At most 1 means no channel brightens.
    public var maxChannel: Double { max(red, green, blue) }

    /// HSL-style saturation spread: the gap between the strongest and weakest
    /// channel.
    public var spread: Double { max(red, green, blue) - min(red, green, blue) }

    /// Saturation scaled to `fraction` about the multiplier's own luma. Every
    /// channel moves toward the luma, which lies between the channels, so a
    /// multiplier that never brightened still never brightens.
    public func saturation(_ fraction: Double) -> CourtMultiplier {
        let l = luma
        return CourtMultiplier(
            red: l + (red - l) * fraction,
            green: l + (green - l) * fraction,
            blue: l + (blue - l) * fraction
        )
    }

    /// Linear interpolation, `t` clamped to 0…1.
    public static func lerp(_ a: CourtMultiplier, _ b: CourtMultiplier, _ t: Double) -> CourtMultiplier {
        let t = max(0, min(1, t))
        // Weighted form, so both ends are exact: t = 0 is `a`, t = 1 is `b`.
        let u = 1 - t
        return CourtMultiplier(
            red: a.red * u + b.red * t,
            green: a.green * u + b.green * t,
            blue: a.blue * u + b.blue * t
        )
    }
}

/// One phase's court light: a multiplier at the screen centre and another at
/// its edges, blended radially.
public struct CourtPalette: Equatable, Sendable {
    public var center: CourtMultiplier
    public var edge: CourtMultiplier

    public init(center: CourtMultiplier, edge: CourtMultiplier) {
        self.center = center
        self.edge = edge
    }

    public static let neutral = CourtPalette(center: .neutral, edge: .neutral)

    public func saturation(_ fraction: Double) -> CourtPalette {
        CourtPalette(center: center.saturation(fraction), edge: edge.saturation(fraction))
    }

    public static func lerp(_ a: CourtPalette, _ b: CourtPalette, _ t: Double) -> CourtPalette {
        CourtPalette(center: .lerp(a.center, b.center, t), edge: .lerp(a.edge, b.edge, t))
    }
}

/// D-096 phase presentation (bosses.md § Phase presentation): each boss phase
/// lights the Authority Court differently, on the world layer (never the HUD),
/// crossfading over 1 s at a phase change. Presentation only: it reads the
/// snapshot and writes nothing back.
///
/// The light multiplies the scene, so it can only tint or darken; no channel
/// factor exceeds 1, which is the Lockdown tint's own ceiling (its multiplier
/// is `(1, 1 − a, 1 − a)`). Reduced Flash lowers every palette to 60%
/// saturation.
public enum CourtLighting {
    /// 1 s at 60 Hz.
    public static let crossfadeTicks: UInt64 = 60
    /// Reduced Flash keeps 60% of each palette's saturation.
    public static let reducedFlashSaturation = 0.60

    /// The four palettes, as specified (bosses.md § Phase presentation).
    public static func palette(_ phase: BossPhase) -> CourtPalette {
        switch phase {
        case .publicSafety:
            // Cool civic white-blue.
            CourtPalette(
                center: CourtMultiplier(red: 0.90, green: 0.95, blue: 1.00),
                edge: CourtMultiplier(red: 0.74, green: 0.84, blue: 1.00)
            )
        case .civilLiberties:
            // Amber.
            CourtPalette(
                center: CourtMultiplier(red: 1.00, green: 0.88, blue: 0.66),
                edge: CourtMultiplier(red: 0.92, green: 0.70, blue: 0.42)
            )
        case .temporarySafeguard:
            // Deep red.
            CourtPalette(
                center: CourtMultiplier(red: 1.00, green: 0.66, blue: 0.62),
                edge: CourtMultiplier(red: 0.78, green: 0.34, blue: 0.32)
            )
        case .independentReview:
            // Stark white with blue edges: the centre is left untinted (white
            // light that may not brighten), the edges go blue.
            CourtPalette(
                center: .neutral,
                edge: CourtMultiplier(red: 0.62, green: 0.76, blue: 1.00)
            )
        }
    }

    /// The palette drawn for `phase` under the Reduced Flash setting.
    public static func palette(_ phase: BossPhase, reducedFlash: Bool) -> CourtPalette {
        let base = palette(phase)
        return reducedFlash ? base.saturation(reducedFlashSaturation) : base
    }

    /// The light drawn `ticksSinceChange` ticks after the light target moved
    /// from `from` to `to` (nil: no light), linear over `crossfadeTicks`.
    public static func blended(
        from: BossPhase?,
        to: BossPhase?,
        ticksSinceChange: UInt64,
        reducedFlash: Bool
    ) -> CourtPalette {
        let a = from.map { palette($0, reducedFlash: reducedFlash) } ?? .neutral
        let b = to.map { palette($0, reducedFlash: reducedFlash) } ?? .neutral
        let t = Double(min(ticksSinceChange, crossfadeTicks)) / Double(crossfadeTicks)
        return .lerp(a, b, t)
    }
}

/// Tracks the court light across snapshots: the phase it is heading for,
/// the light that was on screen when the change began, and the tick it began.
/// A presentation-side tracker, so the snapshot stays unchanged.
public struct CourtLightTracker: Equatable, Sendable {
    public private(set) var target: BossPhase?
    public private(set) var changedAt: UInt64 = 0
    public private(set) var fadeFrom: CourtPalette = .neutral
    public private(set) var shown: CourtPalette = .neutral

    public init() {}

    /// Observes this frame's live boss phase (nil when no boss is alive) and
    /// returns the light to draw. A change starts a 1 s linear fade from
    /// whatever is on screen, so a change during a fade never jumps.
    public mutating func update(phase: BossPhase?, tick: UInt64, reducedFlash: Bool) -> CourtPalette {
        if phase != target {
            fadeFrom = shown
            target = phase
            changedAt = tick
        }
        let elapsed = tick >= changedAt ? tick - changedAt : 0
        let goal = target.map { CourtLighting.palette($0, reducedFlash: reducedFlash) } ?? .neutral
        let t = Double(min(elapsed, CourtLighting.crossfadeTicks)) / Double(CourtLighting.crossfadeTicks)
        shown = .lerp(fadeFrom, goal, t)
        return shown
    }

    public mutating func reset() {
        self = CourtLightTracker()
    }
}

/// D-096 countdown ring (bosses.md § Phase presentation): every boss telegraph
/// draws a ring that closes over the telegraph's duration, so the moment of
/// resolution reads without counting. Reduced Motion keeps the ring and drops
/// the pulse.
public enum TelegraphRing {
    /// Ring radius, in world units, when the telegraph starts.
    public static let startRadius = 72.0
    /// Ring radius on the resolve tick.
    public static let endRadius = 18.0
    /// Stroke width in world units.
    public static let lineWidth = 3.0
    /// The pulse runs over the final third of the telegraph.
    public static let pulseFromFraction = 2.0 / 3.0
    /// One pulse every 12 ticks. It swells the stroke's width and alpha; it
    /// never flashes the scene.
    public static let pulsePeriodTicks = 12
    /// Peak extra stroke width of the pulse, in world units.
    public static let pulseExtraWidth = 2.0

    public struct Frame: Equatable, Sendable {
        /// Ring radius in world units.
        public var radius: Double
        /// Closed fraction, 0 at the first telegraph tick, 1 on resolve.
        public var progress: Double
        public var lineWidth: Double
        /// Stroke alpha.
        public var alpha: Double
    }

    /// Only the boss's own telegraphs get a ring (bosses.md: "every boss
    /// telegraph").
    public static func applies(to telegraph: TelegraphShape, bossId: EntityID?) -> Bool {
        guard let bossId else { return false }
        return telegraph.ownerId == bossId
    }

    /// The ring for a telegraph with `remainingTicks` of `totalTicks` left.
    public static func frame(remainingTicks: Int, totalTicks: Int, reducedMotion: Bool) -> Frame {
        let total = max(1, totalTicks)
        let remaining = max(0, min(total, remainingTicks))
        let progress = Double(total - remaining) / Double(total)
        let radius = startRadius + (endRadius - startRadius) * progress
        var width = lineWidth
        var alpha = 0.55 + 0.45 * progress
        if !reducedMotion, progress >= pulseFromFraction {
            let phase = Double(remaining % pulsePeriodTicks) / Double(pulsePeriodTicks)
            let wave = 0.5 - 0.5 * cos(2 * Double.pi * phase)
            width += pulseExtraWidth * wave
            alpha = min(1, alpha + 0.15 * wave)
        }
        return Frame(radius: radius, progress: progress, lineWidth: width, alpha: alpha)
    }
}
