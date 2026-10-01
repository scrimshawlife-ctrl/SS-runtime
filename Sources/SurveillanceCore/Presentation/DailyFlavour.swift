import Foundation

/// `run-shell.md` § 10.3 (D-099): each UTC day's look, from its day key.
///
/// Presentation only. It is derived from the same SplitMix64 mix as § 10.1
/// with salt 0, reads no clock (the caller passes the day), and nothing here
/// enters the digest or the receipt.
public struct DailyFlavour: Equatable, Sendable {
    public enum Grade: String, CaseIterable, Equatable, Sendable {
        case clear = "CLEAR"
        case overcast = "OVERCAST"
        case goldenHour = "GOLDEN HOUR"
        case nightShift = "NIGHT SHIFT"
    }

    /// § 10.3 headlines, in authored order.
    public static let headlines = [
        "FOG ADVISORY IN EFFECT",
        "NEW CAMERAS APPROVED OVERNIGHT",
        "CIVIC SEAM REOPENS AFTER REVIEW",
        "TEMPORARY ORDER EXTENDED",
        "QUIET HOURS ENFORCED",
        "TRANSIT PATROL DOUBLED",
        "INDEPENDENT REVIEW SCHEDULED",
        "PUBLIC SAFETY NOTICE POSTED",
        "NETWORK MAINTENANCE TONIGHT",
        "PHOENIX STEPS LIGHTS RESTORED",
        "CURFEW RUMOURS DENIED",
        "OBSERVATION WEEK BEGINS"
    ]

    /// § 10.3 fog density, percent of authored opacity.
    public static let fogPercents = [80, 100, 120]

    public let grade: Grade
    public let fogPercent: Int
    public let headline: String

    /// § 10.3: `mix = SplitMix64.mix(dayKey ^ domain ^ 0)`; the grade takes
    /// bits 0–7 mod 4, the fog bits 8–15 mod 3, the headline bits 16–23
    /// mod 12. (The table names the fog and headline bit ranges; bits 0–7 is
    /// the remaining "separate bit range" for the grade.)
    public init(day: DailyRun.Day) {
        self.init(mix: DailyRun.candidate(day: day, salt: 0))
    }

    public init(mix: UInt64) {
        grade = Grade.allCases[Int((mix & 0xFF) % 4)]
        fogPercent = Self.fogPercents[Int(((mix >> 8) & 0xFF) % 3)]
        headline = Self.headlines[Int(((mix >> 16) & 0xFF) % 12)]
    }

    /// Fog opacity multiplier, before D-094 thinning multiplies it again, so
    /// fog still thins in a fight.
    public var fogMultiplier: Double { Double(fogPercent) / 100 }

    /// The title's second line under the Daily Run label.
    public var titleDetail: String { "\(grade.rawValue) · FOG \(fogPercent)%" }
}

/// The world grade as a ground-only overlay (§ 10.3 limits). The app draws it
/// above the ground and its dressing and below everything else, so actors,
/// telegraphs, Camera fields, and outlines are never darkened.
public struct DailyGradeOverlay: Equatable, Sendable {
    /// Linear RGB 0…1.
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
    /// True for a multiply blend (it can only darken); false for an alpha
    /// blend at a low opacity (a warm wash).
    public let multiply: Bool

    public static func of(_ grade: DailyFlavour.Grade) -> DailyGradeOverlay? {
        switch grade {
        case .clear:
            return nil
        case .overcast:
            return DailyGradeOverlay(red: 0.78, green: 0.82, blue: 0.86, alpha: 1, multiply: true)
        case .goldenHour:
            return DailyGradeOverlay(red: 1.0, green: 0.62, blue: 0.25, alpha: 0.14, multiply: false)
        case .nightShift:
            return DailyGradeOverlay(red: 0.42, green: 0.47, blue: 0.66, alpha: 1, multiply: true)
        }
    }
}
