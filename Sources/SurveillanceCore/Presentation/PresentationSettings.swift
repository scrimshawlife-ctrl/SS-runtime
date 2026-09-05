import Foundation

/// Local presentation settings.
///
/// `simulation-order.md` §18 excludes "presentation, device, elapsed wall time,
/// audio/haptic settings, and cosmetic seeds" from the state digest, and
/// `audio-haptics-001` says settings "are local, independent, and excluded from
/// replay authority". So nothing here may reach the simulation: these values
/// change what the player sees and hears, never what happens.
///
/// ER-007 is the acceptance vector — an audio, tutorial, or settings change
/// leaves the authoritative receipt and digest unchanged except for declared
/// presentation metadata.
public struct PresentationSettings: Equatable, Sendable, Codable {
    public var mix: MixLevels
    public var audio: PresentationAudioSettings
    public var vfx: PresentationVFXSettings
    public var hudScale: HUDScaleSetting
    public var handedness: Handedness
    /// `camera-destruction.md`: the Camera counter is visible after first damage
    /// "and may be pinned through settings".
    public var pinCameraCounter: Bool
    /// `hud-tutorial-001`: tutorial completion is a local setting, and the
    /// receipt records whether tutorials were enabled.
    public var tutorialsEnabled: Bool

    public init(
        mix: MixLevels = .defaults,
        audio: PresentationAudioSettings = .enabled,
        vfx: PresentationVFXSettings = .standard,
        hudScale: HUDScaleSetting = .standard,
        handedness: Handedness = .right,
        pinCameraCounter: Bool = false,
        tutorialsEnabled: Bool = true
    ) {
        self.mix = mix
        self.audio = audio
        self.vfx = vfx
        self.hudScale = hudScale
        self.handedness = handedness
        self.pinCameraCounter = pinCameraCounter
        self.tutorialsEnabled = tutorialsEnabled
    }

    public static let defaults = PresentationSettings()

    /// What the receipt is allowed to declare about this run's presentation.
    public var receiptMetadata: PresentationReceiptMetadata {
        PresentationReceiptMetadata(
            tutorialsEnabled: tutorialsEnabled,
            hudScale: hudScale,
            handedness: handedness,
            reducedMotion: vfx.reducedMotion,
            reducedFlash: vfx.reducedFlash,
            reducedSensory: audio.reducedSensory
        )
    }
}

/// `audio-haptics-001` §Mix buses. Each bus is an independent 0–100 percentage.
public struct MixLevels: Equatable, Sendable, Codable {
    public var master: Int
    public var music: Int
    public var effects: Int
    public var voice: Int
    public var haptics: Int

    public static let range = 0...100

    public init(
        master: Int = 100,
        music: Int = 70,
        effects: Int = 85,
        voice: Int = 100,
        haptics: Int = 80
    ) {
        self.master = Self.clamp(master)
        self.music = Self.clamp(music)
        self.effects = Self.clamp(effects)
        self.voice = Self.clamp(voice)
        self.haptics = Self.clamp(haptics)
    }

    /// The contract's default mix.
    public static let defaults = MixLevels()

    public static func clamp(_ value: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    /// A persisted file could carry anything; clamp on the way in rather than
    /// trusting it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            master: try container.decodeIfPresent(Int.self, forKey: .master) ?? 100,
            music: try container.decodeIfPresent(Int.self, forKey: .music) ?? 70,
            effects: try container.decodeIfPresent(Int.self, forKey: .effects) ?? 85,
            voice: try container.decodeIfPresent(Int.self, forKey: .voice) ?? 100,
            haptics: try container.decodeIfPresent(Int.self, forKey: .haptics) ?? 80
        )
    }

    /// Effective gain for a bus, master already folded in, as 0…1.
    public func gain(_ bus: MixBus) -> Double {
        let level: Int
        switch bus {
        case .music: level = music
        case .effects: level = effects
        case .voice: level = voice
        case .haptics: level = haptics
        }
        return Double(master) / 100 * Double(level) / 100
    }
}

public enum MixBus: String, Equatable, Sendable, CaseIterable, Codable {
    case music
    case effects
    case voice
    case haptics
}

/// The presentation facts a receipt may declare, per ER-007. Deliberately
/// excludes the mix levels: how loud a run was does not help interpret it,
/// while accessibility settings do — a playtest result reads differently if the
/// participant played with Reduced Motion on.
public struct PresentationReceiptMetadata: Equatable, Sendable, Codable {
    public var tutorialsEnabled: Bool
    public var hudScale: HUDScaleSetting
    public var handedness: Handedness
    public var reducedMotion: Bool
    public var reducedFlash: Bool
    public var reducedSensory: Bool

    public init(
        tutorialsEnabled: Bool = true,
        hudScale: HUDScaleSetting = .standard,
        handedness: Handedness = .right,
        reducedMotion: Bool = false,
        reducedFlash: Bool = false,
        reducedSensory: Bool = false
    ) {
        self.tutorialsEnabled = tutorialsEnabled
        self.hudScale = hudScale
        self.handedness = handedness
        self.reducedMotion = reducedMotion
        self.reducedFlash = reducedFlash
        self.reducedSensory = reducedSensory
    }

    public static let `default` = PresentationReceiptMetadata()

    public var canonical: CanonicalJSON {
        .object([
            "tutorialsEnabled": .bool(tutorialsEnabled),
            "hudScale": .integer(Int64(hudScale.rawValue)),
            "handedness": .string(handedness.rawValue),
            "reducedMotion": .bool(reducedMotion),
            "reducedFlash": .bool(reducedFlash),
            "reducedSensory": .bool(reducedSensory)
        ])
    }
}
