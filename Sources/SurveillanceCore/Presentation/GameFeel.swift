import Foundation

// D-088 game feel: the presentation-side clocks that turn `VFXProjector`
// output into hit-stop, screen shake, a bounded effect pool, and the Network
// Blackout music drop. All of it is presentation. None of it reads the wall
// clock, and nothing here is ever an input to `Simulation`.

/// Display frames per second. The simulation also runs at 60 Hz, one tick per
/// unfrozen display frame, so a frame and a tick last the same time.
public enum PresentationFrameRate {
    public static let framesPerSecond = 60

    /// Frames that fit inside `ms` without exceeding it. Hit-stop uses this so
    /// the 50 ms and 90 ms caps are never exceeded (50 → 3, 90 → 5).
    public static func framesWithin(ms: Int) -> Int {
        max(0, ms) * framesPerSecond / 1000
    }

    /// Frames needed to cover `ms`, at least one. Effect lifetimes use this so
    /// an effect is on screen for its whole lifetime.
    public static func framesCovering(ms: Int) -> Int {
        max(1, (max(0, ms) * framesPerSecond + 999) / 1000)
    }
}

/// Hit-stop (animation.md § 8): a presentation freeze.
///
/// **Design.** While frozen, the app neither steps the simulation nor redraws
/// the world; it resumes on the next unfrozen frame with the very next tick.
/// The simulation is a pure function of its seed and its tick-indexed
/// commands, and a frozen frame produces no tick and consumes no command, so
/// the tick sequence, every command, the digest, and the receipt are exactly
/// what they would be with no hit-stop. Only wall-clock time stretches, the
/// same way a pause (PC-008) stretches it.
///
/// Freezes never stack: the app does not step while frozen, so no new impact
/// can arrive mid-freeze, and simultaneous impacts in one tick take the
/// longest hit-stop among them, capped per recipe class.
public struct HitStopClock: Equatable, Sendable {
    public private(set) var remainingFrames = 0
    /// Frozen frames so far this run, for frame-budget evidence.
    public private(set) var frozenFrames = 0
    public private(set) var freezes = 0

    public init() {}

    public mutating func reset() {
        self = HitStopClock()
    }

    public var isFrozen: Bool { remainingFrames > 0 }

    /// Starts a freeze for this tick's impacts.
    public mutating func admit(_ presentations: [VFXPresentation], catalog: ProceduralVFXCatalog) {
        let ms = presentations
            .map { min($0.hitStopMs, catalog.hitStopCapMs(for: $0.recipeId)) }
            .max() ?? 0
        let frames = PresentationFrameRate.framesWithin(ms: ms)
        guard frames > 0 else { return }
        if remainingFrames == 0 { freezes += 1 }
        remainingFrames = max(remainingFrames, frames)
    }

    /// Starts (or lengthens) a freeze of `ms`, for a beat no recipe carries:
    /// the D-097 takedown's 70 ms. Freezes still never stack.
    public mutating func admit(ms: Int) {
        let frames = PresentationFrameRate.framesWithin(ms: ms)
        guard frames > 0 else { return }
        if remainingFrames == 0 { freezes += 1 }
        remainingFrames = max(remainingFrames, frames)
    }

    /// Call once per display frame, before stepping. True means this frame is
    /// frozen: do not step the simulation and do not redraw the world.
    public mutating func consumeFrame() -> Bool {
        guard remainingFrames > 0 else { return false }
        remainingFrames -= 1
        frozenFrames += 1
        return true
    }
}

/// Screen shake (animation.md § 8, § 9): bounded, deterministic, coalesced,
/// and off under Reduced Motion. The app applies the offset to the world
/// camera node only; the HUD is a child of that node, so it does not move on
/// screen, and Camera fields and objective markers move with the world they
/// belong to rather than against it.
public struct ScreenShake: Equatable, Sendable {
    /// Largest offset in arena units (the visible frame is 896 × 414).
    public static let maxAmplitude = 6.0
    public static let durationFrames = 12

    /// "Small shake" per recipe. Anything unlisted that asks to shake takes
    /// the smallest amplitude.
    public static let amplitudeByRecipe: [String: Double] = [
        "playerHit": 3, "cameraDestroyed": 4, "lockdown": 5, "bossPhaseBreak": 6
    ]

    public private(set) var remainingFrames = 0
    public private(set) var peak = 0.0
    private var frame = 0

    public init() {}

    public mutating func reset() {
        self = ScreenShake()
    }

    /// The current envelope, before the pattern is applied.
    public var amplitude: Double {
        guard remainingFrames > 0 else { return 0 }
        return peak * Double(remainingFrames) / Double(Self.durationFrames)
    }

    /// Starts or refreshes a shake. Repeats coalesce: a new shake while one is
    /// running restarts the envelope at the larger of the two amplitudes and
    /// never adds them, so a burst of hits cannot build past the cap.
    public mutating func admit(_ presentations: [VFXPresentation], reducedMotion: Bool) {
        guard !reducedMotion else {
            reset()
            return
        }
        let requested = presentations
            .filter(\.screenShake)
            .map { Self.amplitudeByRecipe[$0.recipeId] ?? 3 }
            .max()
        guard let requested else { return }
        peak = min(Self.maxAmplitude, max(amplitude, requested))
        remainingFrames = Self.durationFrames
    }

    /// Advances one display frame and returns the offset to apply to the
    /// world camera. The pattern is a fixed rotation, not a random walk.
    public mutating func advance() -> (x: Double, y: Double) {
        guard remainingFrames > 0 else { return (0, 0) }
        let current = amplitude
        let angle = Double(frame) * 2.399963 // golden angle, so frames do not repeat a direction
        frame += 1
        remainingFrames -= 1
        return (current * cos(angle), current * sin(angle))
    }
}

/// The live effect pool: per-recipe `poolSize` and the catalog-wide
/// `maxConcurrentEmitters`, across ticks. `VFXProjector` bounds one tick; this
/// bounds what is on screen at once, since effects outlive their tick.
public struct VFXPool: Equatable, Sendable {
    public struct Instance: Equatable, Sendable {
        public var presentation: VFXPresentation
        public var bornFrame: UInt64
        public var expiresFrame: UInt64
    }

    public struct Admission: Equatable, Sendable {
        public var admitted: [Instance] = []
        /// Live effects removed to make room, by `sequence`.
        public var evicted: [Int] = []
    }

    public private(set) var live: [Instance] = []
    public let maxConcurrent: Int
    private let poolSizes: [String: Int]

    public init(catalog: ProceduralVFXCatalog) {
        maxConcurrent = catalog.maxConcurrentEmitters
        poolSizes = Dictionary(uniqueKeysWithValues: catalog.recipes.map { ($0.id, $0.poolSize) })
    }

    public mutating func reset() {
        live = []
    }

    public func liveCount(_ recipeId: String) -> Int {
        live.filter { $0.presentation.recipeId == recipeId }.count
    }

    public mutating func admit(_ presentations: [VFXPresentation], frame: UInt64) -> Admission {
        var admission = Admission()
        for presentation in presentations {
            let limit = poolSizes[presentation.recipeId] ?? 1
            // A full pool recycles its oldest instance, as a node pool does.
            while liveCount(presentation.recipeId) >= limit {
                let oldest = live.enumerated()
                    .filter { $0.element.presentation.recipeId == presentation.recipeId }
                    .min { $0.element.presentation.sequence < $1.element.presentation.sequence }!
                admission.evicted.append(oldest.element.presentation.sequence)
                live.remove(at: oldest.offset)
            }
            let lifetime = UInt64(PresentationFrameRate.framesCovering(ms: presentation.lifetimeMs))
            live.append(Instance(presentation: presentation, bornFrame: frame, expiresFrame: frame + lifetime))
        }
        // Over the emitter ceiling: steal the lowest-priority, oldest effect.
        while live.count > maxConcurrent {
            let worst = live.map { VFXProjector.rank($0.presentation.recipeId) }.max()!
            let victim = live.enumerated()
                .filter { VFXProjector.rank($0.element.presentation.recipeId) == worst }
                .min { $0.element.presentation.sequence < $1.element.presentation.sequence }!
            admission.evicted.append(victim.element.presentation.sequence)
            live.remove(at: victim.offset)
        }
        // A new effect stolen in the same call was never drawn, so it is
        // neither admitted nor reported as evicted.
        let incoming = Set(presentations.map(\.sequence))
        admission.admitted = live.filter { incoming.contains($0.presentation.sequence) }
        admission.evicted.removeAll { incoming.contains($0) }
        return admission
    }

    /// Removes effects whose lifetime ended at or before `frame`.
    public mutating func expire(frame: UInt64) -> [Int] {
        let ended = live.filter { $0.expiresFrame <= frame }.map(\.presentation.sequence)
        live.removeAll { $0.expiresFrame <= frame }
        return ended
    }
}

/// audio-haptics.md § Network Blackout drop (D-088): the music bed ducks to
/// silence over 0.1 s, holds silence for 1.0 s, and returns over 0.5 s. The
/// `network_blackout` cue plays at the start of the silence.
public enum BlackoutMusicDrop {
    public static let duckSeconds = 0.1
    public static let holdSeconds = 1.0
    public static let restoreSeconds = 0.5
    public static let cueId = "network_blackout"

    /// The cue waits for the duck to finish, so it is heard alone.
    public static var cueDelaySeconds: Double { duckSeconds }
    public static var restoreStartSeconds: Double { duckSeconds + holdSeconds }
    public static var totalSeconds: Double { duckSeconds + holdSeconds + restoreSeconds }

    /// Music gain multiplier `t` seconds after the drop began.
    public static func gain(atSeconds t: Double) -> Double {
        if t <= 0 { return 1 }
        if t < duckSeconds { return 1 - t / duckSeconds }
        if t < restoreStartSeconds { return 0 }
        if t < totalSeconds { return (t - restoreStartSeconds) / restoreSeconds }
        return 1
    }

    /// True when this tick's audio projection starts a drop.
    public static func triggers(_ projection: AudioProjection) -> Bool {
        projection.cues.contains { $0.audioId == cueId }
    }
}
