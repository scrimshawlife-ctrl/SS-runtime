import Foundation

/// D-094 readability and finish pass (`animation.md` § 8b, `audio-haptics.md`
/// "On-screen captions (D-094)").
///
/// Everything here is presentation: each type reads snapshots, projected
/// cues, and local settings, and writes only its own presentation state. None
/// of it is a simulation input, so none of it can reach the digest.

// MARK: - Captions

/// The caption setting (D-094): Important (default), All, or Off.
public enum CaptionSetting: String, Equatable, Sendable, Codable, CaseIterable {
    /// Safety-critical captions only. The default.
    case important
    /// Safety-critical and routine captions.
    case all
    /// No on-screen captions. Safety-critical events keep their other
    /// visual carriers (HUD state, telegraph, VFX), so D-015 still holds.
    case off
}

/// Whether a caption is safety-critical (D-094) or routine.
public enum CaptionClass: Int, Equatable, Sendable, Comparable {
    case safety = 0
    case routine = 1

    public static func < (lhs: CaptionClass, rhs: CaptionClass) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Classifies a projected cue by its `audio-haptics-001` cue ID.
    ///
    /// D-094 names five safety-critical kinds. `AudioProjector` priorities do
    /// not line up with that list (`player_damage` is priority 5 and the
    /// extraction countdown is 7, below Camera cues at 4), so the class is
    /// keyed on the cue ID instead:
    ///
    /// | D-094 kind | Cue IDs |
    /// |---|---|
    /// | damage taken | `player_damage` |
    /// | telegraphs | `daemon_query`, `daemon_dash`, `boss_telegraph_*` |
    /// | detection rising | `exposure_state_up` |
    /// | Lockdown | `lockdown_enter` |
    /// | extraction | `extraction_armed`, `extraction_reset`, `extraction_tick` |
    ///
    /// Every other cue is routine: weapon, impact, Dodge, Camera hit,
    /// critical, destroy, field off and tamper, Network Blackout, upgrade,
    /// boss phase and defeat, and the run's end (which has its own terminal
    /// surface).
    public static func of(cueId: String) -> CaptionClass {
        if safetyCueIds.contains(cueId) || cueId.hasPrefix("boss_telegraph_") { return .safety }
        return .routine
    }

    public static let safetyCueIds: Set<String> = [
        "player_damage",
        "daemon_query", "daemon_dash",
        "exposure_state_up",
        "lockdown_enter",
        "extraction_armed", "extraction_reset", "extraction_tick"
    ]
}

/// The on-screen caption stack (D-094): at most three at once, each for
/// 2.5 seconds, safety-critical first. Timed in simulation ticks, so it
/// freezes with the run under pause and hit-stop. The eight-message caption
/// history (`AudioProjector.captionHistory`) is separate and unchanged.
public struct CaptionBoard: Equatable, Sendable {
    public static let maxVisible = 3
    /// 2.5 s at 60 Hz.
    public static let visibleTicks: UInt64 = 150

    public struct Entry: Equatable, Sendable {
        public var text: String
        public var cueId: String
        public var captionClass: CaptionClass
        /// `AudioProjector` priority; lower is more urgent.
        public var priority: Int
        public var tick: UInt64
        public var sequence: Int
    }

    private(set) var entries: [Entry] = []
    private var nextSequence = 0

    public init() {}

    public mutating func reset() {
        self = CaptionBoard()
    }

    /// Records this tick's captioned cues. A repeat of a caption already
    /// showing restarts its time rather than stacking a duplicate.
    public mutating func ingest(tick: UInt64, cues: [ProjectedCue]) {
        for cue in cues.sorted(by: { $0.sequence < $1.sequence }) where !cue.caption.isEmpty {
            entries.removeAll { $0.text == cue.caption }
            entries.append(
                Entry(
                    text: cue.caption,
                    cueId: cue.audioId,
                    captionClass: CaptionClass.of(cueId: cue.audioId),
                    priority: cue.priority,
                    tick: tick,
                    sequence: nextSequence
                )
            )
            nextSequence += 1
        }
        // Expired entries can never show again; drop them.
        entries.removeAll { tick >= $0.tick && tick - $0.tick >= Self.visibleTicks }
    }

    /// The captions to draw at `tick`, oldest first (newest at the bottom).
    ///
    /// Selection: live entries the setting admits, ranked safety before
    /// routine, then by cue priority, then newest; the top three show.
    public func visible(at tick: UInt64, setting: CaptionSetting) -> [Entry] {
        guard setting != .off else { return [] }
        let live = entries.filter { entry in
            guard tick >= entry.tick, tick - entry.tick < Self.visibleTicks else { return false }
            return setting == .all || entry.captionClass == .safety
        }
        let chosen = live.sorted { a, b in
            if a.captionClass != b.captionClass { return a.captionClass < b.captionClass }
            if a.priority != b.priority { return a.priority < b.priority }
            return a.sequence > b.sequence
        }.prefix(Self.maxVisible)
        return chosen.sorted { $0.sequence < $1.sequence }
    }
}

// MARK: - Fog

/// D-094 "Fog thins in a fight": while any aware enemy is within the
/// viewport, both fog layers render at 50% of their authored opacity,
/// easing over 0.5 s. Advanced by simulation ticks, so it holds still under
/// pause and hit-stop.
public struct FogThinning: Equatable, Sendable {
    /// Fraction of authored opacity while thinned.
    public static let thinnedOpacity = 0.5
    /// 0.5 s at 60 Hz.
    public static let easeTicks = 30

    /// 0 = full authored opacity, 1 = fully thinned.
    public private(set) var progress = 0.0
    private var lastTick: UInt64?

    public init() {}

    public mutating func reset() {
        self = FogThinning()
    }

    /// True when an aware enemy lies inside the presentation camera's view.
    /// The boss and the elite are never unaware, so they always count.
    public static func awareEnemyInView(_ snap: PresentationSnapshot) -> Bool {
        snap.enemies.contains { enemy in
            !enemy.unaware && PresentationCamera.contains(VecI(x: enemy.x, y: enemy.y), center: snap.camera.center)
        }
    }

    /// Advances to `snap.tick` and returns the fog opacity multiplier.
    public mutating func update(_ snap: PresentationSnapshot) -> Double {
        let elapsed: UInt64
        if let lastTick, snap.tick >= lastTick {
            elapsed = snap.tick - lastTick
        } else {
            elapsed = 0
        }
        lastTick = snap.tick
        let step = Double(elapsed) / Double(Self.easeTicks)
        if Self.awareEnemyInView(snap) {
            progress = min(1, progress + step)
        } else {
            progress = max(0, progress - step)
        }
        return opacity
    }

    /// Opacity multiplier for the current progress, eased (smoothstep).
    public var opacity: Double {
        let eased = progress * progress * (3 - 2 * progress)
        return 1 - (1 - Self.thinnedOpacity) * eased
    }
}

// MARK: - Lockdown

/// D-094 Lockdown atmosphere: while Lockdown is latched the world layer (never
/// the HUD) takes a red tint at 6% that pulses to 10% once every 2 seconds;
/// steady 6% under Reduced Flash or Reduced Motion. It never brightens.
///
/// The tint is applied multiplicatively: a red layer at opacity `a` over a
/// scene colour `c` is `c * (1 - a) + (c * red) * a = c * (1, 1 - a, 1 - a)`.
/// Every channel factor is at most 1, so no pixel can get brighter.
public enum LockdownTint {
    public static let baseOpacity = 0.06
    public static let peakOpacity = 0.10
    /// One pulse every 2 s at 60 Hz.
    public static let periodTicks: UInt64 = 120

    /// The tint opacity at `tick`, or nil when Lockdown is not latched.
    public static func opacity(
        tick: UInt64,
        detection: DetectionState,
        reducedFlash: Bool,
        reducedMotion: Bool
    ) -> Double? {
        guard detection == .lockdown else { return nil }
        if reducedFlash || reducedMotion { return baseOpacity }
        let phase = Double(tick % periodTicks) / Double(periodTicks)
        // Raised cosine: 6% at the start of each period, 10% at its middle.
        let wave = 0.5 - 0.5 * cos(2 * Double.pi * phase)
        return baseOpacity + (peakOpacity - baseOpacity) * wave
    }

    /// The per-channel multiplier (r, g, b) for a tint of `opacity`.
    public static func multiplier(opacity: Double) -> (red: Double, green: Double, blue: Double) {
        let a = max(0, min(1, opacity))
        return (1, 1 - a, 1 - a)
    }
}

// MARK: - Actor contrast

/// D-094 actor contrast: a soft ground shadow and a 1-point faction outline.
/// The outline carries faction by colour and by shape (the Player's is
/// unbroken, an enemy's dashed), never by colour alone.
public enum ActorContrast {
    public enum Faction: Hashable, Sendable {
        case player
        case enemy
    }

    /// Shadow fill: 35% black.
    public static let shadowOpacity = 0.35
    /// Shadow width as a multiple of the actor's collision diameter (see
    /// `shadowSize`).
    public static let shadowWidthFactor = 1.4
    /// Ground-plane squash of the shadow ellipse.
    public static let shadowAspect = 0.5

    /// Outline weight in screen points.
    public static let outlinePoints = 1.0
    /// Enemy dash pattern, in outline texture pixels: `dashOn` drawn, then
    /// `dashOff` skipped, along the diagonal.
    public static let dashOn = 3
    public static let dashOff = 2

    /// Cool white (Player) and warm red-orange (enemies), as 0…1 RGB.
    public static func outlineColour(_ faction: Faction) -> (red: Double, green: Double, blue: Double) {
        switch faction {
        case .player: (0.86, 0.94, 1.0)
        case .enemy: (1.0, 0.42, 0.20)
        }
    }

    public static func dashed(_ faction: Faction) -> Bool { faction == .enemy }

    /// Shadow ellipse size in world units for an actor of `radius`.
    ///
    /// `animation.md` § 8b says "1.4 × radius wide". Read literally (1.4 r) the
    /// shadow would be narrower than the actor's own collision circle and
    /// hidden under its sprite, so it is read as 1.4 × the collision width
    /// (2.8 r); the half-height is half that.
    public static func shadowSize(radius: Int) -> (width: Double, height: Double) {
        let width = shadowWidthFactor * 2 * Double(radius)
        return (width, width * shadowAspect)
    }

    /// Whether an outline texture pixel at (x, y) is drawn: always for the
    /// Player, on a diagonal dash pattern for enemies.
    public static func outlinePixelOn(x: Int, y: Int, faction: Faction) -> Bool {
        guard dashed(faction) else { return true }
        let period = dashOn + dashOff
        return (x + y) % period < dashOn
    }
}

// MARK: - Gates

/// D-094 closed gates: barricade art tiled along the gate's box with a thin
/// warning-light strip on its open face. Collision is unchanged and the art
/// fills the collision box exactly: the tiles partition the box, and the
/// strip lies inside it. An open gate draws nothing.
public enum GateBarrier {
    /// Warning-light strip depth, in world units.
    public static let stripThickness = 4.0
    /// Light segment length and the gap between lights, along the strip.
    public static let lightLength = 10.0
    public static let lightGap = 6.0

    /// A rectangle in world units, by centre and full size.
    public struct Rect: Equatable, Sendable {
        public var centerX: Double
        public var centerY: Double
        public var width: Double
        public var height: Double

        public var minX: Double { centerX - width / 2 }
        public var maxX: Double { centerX + width / 2 }
        public var minY: Double { centerY - height / 2 }
        public var maxY: Double { centerY + height / 2 }
    }

    public struct Layout: Equatable, Sendable {
        /// True when the gate's long axis is y; the art is then turned a
        /// quarter turn.
        public var vertical: Bool
        /// Art tiles, axis-aligned, in order along the long axis.
        public var tiles: [Rect]
        /// The warning-light strip, along the long side facing `openFace`.
        public var strip: Rect
        /// +1 or -1: which side of the short axis is the open face.
        public var openFace: Int
    }

    /// Lays out a gate `box`. `textureAspect` is the art's length over its
    /// depth (`env_prop_barricade` is 128 × 48); tiles keep roughly that
    /// aspect and are stretched slightly so a whole number of them fills
    /// the box. The open face is the long side facing `viewer`, normally
    /// the Player, who is inside the encounter when its gate closes.
    public static func layout(box: AABB, viewer: VecI, textureAspect: Double) -> Layout {
        let vertical = box.halfSize.y > box.halfSize.x
        let length = Double(vertical ? box.halfSize.y : box.halfSize.x) * 2
        let depth = Double(vertical ? box.halfSize.x : box.halfSize.y) * 2
        let nominal = max(1, depth * max(textureAspect, 0.01))
        let count = max(1, Int((length / nominal).rounded()))
        let tileLength = length / Double(count)
        let cx = Double(box.center.x)
        let cy = Double(box.center.y)
        let start = (vertical ? cy : cx) - length / 2
        let tiles = (0..<count).map { index -> Rect in
            let along = start + tileLength * (Double(index) + 0.5)
            return vertical
                ? Rect(centerX: cx, centerY: along, width: depth, height: tileLength)
                : Rect(centerX: along, centerY: cy, width: tileLength, height: depth)
        }
        let offset = vertical ? viewer.x - box.center.x : viewer.y - box.center.y
        let face = offset < 0 ? -1 : 1
        let inset = Double(face) * (depth / 2 - stripThickness / 2)
        let strip = vertical
            ? Rect(centerX: cx + inset, centerY: cy, width: stripThickness, height: length)
            : Rect(centerX: cx, centerY: cy + inset, width: length, height: stripThickness)
        return Layout(vertical: vertical, tiles: tiles, strip: strip, openFace: face)
    }
}
