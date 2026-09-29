import Foundation

public struct VFXVariant: Equatable, Sendable {
    public var language: String
    public var particleCount: Int
    public var lifetimeMs: Int
    public var hitStopMs: Int
    public var screenShake: Bool
    public var fullScreenFlash: Bool
}

public struct VFXRecipe: Equatable, Sendable {
    public var id: String
    public var shape: String
    public var eventTypes: [EventType]
    public var poolSize: Int
    public var defaultVariant: VFXVariant
    public var reducedVariant: VFXVariant
}

public struct ProceduralVFXCatalog: Equatable, Sendable {
    public var schemaVersion: String
    public var visualVersion: String
    public var atlas: String
    public var maxConcurrentEmitters: Int
    public var standardHitStopMs: Int
    public var captainHitStopMs: Int
    public var playerDamageCoalesceTicks: UInt64
    public var forbidFullScreenWhiteFlash: Bool
    public var recipes: [VFXRecipe]

    public static let requiredRecipeIds = [
        "cameraAcquire", "exposureThreshold", "playerHit", "enemyHit", "enemyDefeat",
        "ghostStep", "ricochet", "lockdown", "captainTelegraph", "extraction",
        // procedural-vfx-002, animation.md § 8a (D-088): the four big moments.
        "cameraDestroyed", "networkBlackout", "bossPhaseBreak", "heatReinforcements"
    ]

    /// animation.md § 8: hit-stop is capped at 50 ms for standard impacts and
    /// 90 ms for major Captain impacts. These recipes take the Captain cap.
    public static let captainClassRecipeIds: Set<String> = ["captainTelegraph", "bossPhaseBreak"]

    public static func bundled() throws -> ProceduralVFXCatalog {
        try ProceduralVFXLoader.decode(SpecBundle.contract("procedural-vfx-002"))
    }

    /// The hit-stop cap that applies to `recipeId`.
    public func hitStopCapMs(for recipeId: String) -> Int {
        Self.captainClassRecipeIds.contains(recipeId) ? captainHitStopMs : standardHitStopMs
    }

    public var recipesById: [String: VFXRecipe] {
        Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
    }

    public func recipe(for eventType: EventType) -> VFXRecipe? {
        recipes.first { $0.eventTypes.contains(eventType) }
    }
}

public enum ProceduralVFXError: Equatable, Sendable, Error {
    case invalidJSON
    case schemaVersion
    case missingKey(String)
    case unexpectedKey(String)
    case missingRecipe(String)
    case budget(String)
    case fullScreenFlash(String)
    case reducedShake(String)
}

public struct PresentationVFXSettings: Equatable, Sendable, Codable {
    public var reducedMotion: Bool
    public var reducedFlash: Bool

    public init(reducedMotion: Bool = false, reducedFlash: Bool = false) {
        self.reducedMotion = reducedMotion
        self.reducedFlash = reducedFlash
    }

    public static let standard = PresentationVFXSettings()
    public static let reduced = PresentationVFXSettings(reducedMotion: true, reducedFlash: true)
}

public struct VFXPresentation: Equatable, Sendable {
    public var recipeId: String
    public var language: String
    public var particleCount: Int
    public var lifetimeMs: Int
    public var hitStopMs: Int
    public var screenShake: Bool
    public var shape: String
    public var sourceEntityId: EntityID?
    public var sequence: Int
    /// Text the moment shows: the boss phase name for `bossPhaseBreak`, and
    /// `NETWORK BLACKOUT` for `networkBlackout`. Nil for every other recipe.
    public var label: String? = nil
    /// `networkBlackout` only (animation.md § 8a): every Camera field, in
    /// stable-ID order, with the offset at which it turns off. Empty otherwise.
    public var cascade: [VFXCascadeStep] = []
    /// True when the reduced variant was chosen.
    public var reduced: Bool = false
}

/// One Camera field turning off during the Network Blackout cascade.
public struct VFXCascadeStep: Equatable, Sendable {
    public var cameraId: EntityID
    public var offsetMs: Int
}

/// What the projector needs beyond the tick's events. Presentation input
/// only: nothing here is read back into the simulation.
public struct VFXProjectionContext: Equatable, Sendable {
    /// Every Camera's stable ID, in any order. The Blackout cascade sorts them.
    public var cameraIds: [EntityID]
    /// D-083 heat reinforcements granted to the waves that started this tick.
    /// `heatReinforcements` projects only when this is above zero. The rules
    /// that grant reinforcements are not on main yet (SS-runtime #101), so
    /// every caller passes zero and the recipe stays inert until they land.
    public var heatReinforcements: Int

    public init(cameraIds: [EntityID] = [], heatReinforcements: Int = 0) {
        self.cameraIds = cameraIds
        self.heatReinforcements = heatReinforcements
    }

    public static let none = VFXProjectionContext()
}

public struct VFXProjection: Equatable, Sendable {
    public var presentations: [VFXPresentation]
}

public struct VFXProjector: Equatable, Sendable {
    public var lastPlayerDamageTick: UInt64?
    public var nextSequence: Int

    public init() {
        lastPlayerDamageTick = nil
        nextSequence = 0
    }

    public mutating func reset() {
        self = VFXProjector()
    }

    public mutating func project(
        tick: UInt64,
        events: [AuthoritativeEvent],
        catalog: ProceduralVFXCatalog,
        settings: PresentationVFXSettings = .standard,
        context: VFXProjectionContext = .none
    ) -> VFXProjection {
        var presentations: [VFXPresentation] = []
        let reduced = settings.reducedMotion || settings.reducedFlash
        for event in events {
            for recipe in catalog.recipes where recipe.eventTypes.contains(event.type) {
                if recipe.id == "playerHit" {
                    if let last = lastPlayerDamageTick, tick >= last, tick - last < catalog.playerDamageCoalesceTicks {
                        continue
                    }
                    lastPlayerDamageTick = tick
                }
                if recipe.id == "cameraAcquire" {
                    guard detectionRose(event, from: .hidden, to: .observed) else { continue }
                }
                if recipe.id == "exposureThreshold" {
                    guard detectionRosePastObserved(event) else { continue }
                }
                if recipe.id == "ricochet" {
                    continue
                }
                if recipe.id == "heatReinforcements" {
                    guard context.heatReinforcements > 0 else { continue }
                }
                var label: String?
                if recipe.id == "bossPhaseBreak" {
                    // Activation publishes `bossPhaseChanged` with no `before`;
                    // that is the Captain arriving, not a phase breaking.
                    guard payloadString(event, "before") != nil,
                          let after = payloadString(event, "after")
                    else { continue }
                    label = Self.phaseTitle(after)
                }
                var presentation = present(recipe, event: event, reduced: reduced, sequence: nextSequence)
                if recipe.id == "networkBlackout" {
                    label = Self.blackoutTitle
                    presentation.cascade = Self.cascade(
                        cameraIds: context.cameraIds,
                        lifetimeMs: presentation.lifetimeMs
                    )
                }
                presentation.label = label
                presentations.append(presentation)
                nextSequence += 1
            }
        }
        let projectileHits = events.filter { $0.type == .projectileHit }
        if projectileHits.count >= 2, let recipe = catalog.recipesById["ricochet"] {
            presentations.append(
                present(recipe, event: projectileHits[0], reduced: reduced, sequence: nextSequence)
            )
            nextSequence += 1
        }
        presentations = steal(presentations, limit: catalog.maxConcurrentEmitters)
        return VFXProjection(presentations: presentations)
    }

    private func present(
        _ recipe: VFXRecipe,
        event: AuthoritativeEvent,
        reduced: Bool,
        sequence: Int
    ) -> VFXPresentation {
        let variant = reduced ? recipe.reducedVariant : recipe.defaultVariant
        return VFXPresentation(
            recipeId: recipe.id,
            language: variant.language,
            particleCount: variant.particleCount,
            lifetimeMs: variant.lifetimeMs,
            hitStopMs: variant.hitStopMs,
            screenShake: variant.screenShake,
            shape: recipe.shape,
            sourceEntityId: event.primaryEntityId,
            sequence: sequence,
            reduced: reduced
        )
    }

    /// The title card text for `networkBlackout` (animation.md § 8a).
    public static let blackoutTitle = "NETWORK BLACKOUT"

    /// `publicSafety` → `PUBLIC SAFETY`.
    public static func phaseTitle(_ rawPhase: String) -> String {
        var words: [String] = []
        var current = ""
        for character in rawPhase {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.uppercased() }.joined(separator: " ")
    }

    /// animation.md § 8a: every Camera field turns off in stable-ID order over
    /// the recipe's lifetime. The first goes at once and the rest follow at
    /// even steps, so the whole cascade fits inside the 1.5 s.
    static func cascade(cameraIds: [EntityID], lifetimeMs: Int) -> [VFXCascadeStep] {
        let ordered = Array(Set(cameraIds)).sorted { $0.raw < $1.raw }
        guard !ordered.isEmpty else { return [] }
        return ordered.enumerated().map { index, id in
            VFXCascadeStep(cameraId: id, offsetMs: lifetimeMs * index / ordered.count)
        }
    }

    /// Emitter priority for stealing: a lower rank is kept longer. The big
    /// moments outrank every per-event recipe; `enemyHit` goes first.
    public static let priorityRank: [String: Int] = [
        "networkBlackout": 0, "bossPhaseBreak": 1,
        "lockdown": 1, "captainTelegraph": 2, "extraction": 2, "cameraDestroyed": 2,
        "playerHit": 3, "exposureThreshold": 3, "cameraAcquire": 4, "heatReinforcements": 4,
        "enemyDefeat": 5, "ghostStep": 6, "ricochet": 6, "enemyHit": 7
    ]

    static func rank(_ recipeId: String) -> Int { priorityRank[recipeId] ?? 9 }

    private func steal(_ items: [VFXPresentation], limit: Int) -> [VFXPresentation] {
        var remaining = items
        while remaining.count > limit {
            let lowest = remaining.map { Self.rank($0.recipeId) }.max()!
            let oldest = remaining
                .enumerated()
                .filter { Self.rank($0.element.recipeId) == lowest }
                .min { $0.element.sequence < $1.element.sequence }!
            remaining.remove(at: oldest.offset)
        }
        return remaining
    }

    private func detectionRose(
        _ event: AuthoritativeEvent,
        from: DetectionState,
        to: DetectionState
    ) -> Bool {
        guard event.type == .detectionStateChanged else { return false }
        let before = payloadString(event, "before").flatMap(DetectionState.init(rawValue:))
        let after = payloadString(event, "after").flatMap(DetectionState.init(rawValue:))
        return before == from && after == to
    }

    private func detectionRosePastObserved(_ event: AuthoritativeEvent) -> Bool {
        guard event.type == .detectionStateChanged else { return false }
        let after = payloadString(event, "after").flatMap(DetectionState.init(rawValue:))
        return after == .tracked || after == .hunted || after == .lockdown
    }

    private func payloadString(_ event: AuthoritativeEvent, _ key: String) -> String? {
        if case .string(let value)? = event.payload[key] { return value }
        return nil
    }
}

enum ProceduralVFXLoader {
    private static let catalogKeys: Set<String> = [
        "schemaVersion", "visualVersion", "atlas", "maxConcurrentEmitters",
        "standardHitStopMs", "captainHitStopMs", "playerDamageCoalesceTicks",
        "forbidFullScreenWhiteFlash", "recipes"
    ]
    private static let recipeKeys: Set<String> = [
        "id", "shape", "eventTypes", "poolSize", "default", "reduced"
    ]
    private static let variantKeys: Set<String> = [
        "language", "particleCount", "lifetimeMs", "hitStopMs", "screenShake", "fullScreenFlash"
    ]

    static func decode(_ data: Data) throws -> ProceduralVFXCatalog {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProceduralVFXError.invalidJSON
        }
        if let unexpected = Set(root.keys).subtracting(catalogKeys).sorted().first {
            throw ProceduralVFXError.unexpectedKey(unexpected)
        }
        guard root["schemaVersion"] as? String == ContractVersions.proceduralVFX else {
            throw ProceduralVFXError.schemaVersion
        }
        guard root["visualVersion"] as? String == "visual-civic-seam-001" else {
            throw ProceduralVFXError.schemaVersion
        }
        guard let atlas = root["atlas"] as? String, atlas == "combat_vfx.atlas",
              let maxEmitters = intValue(root["maxConcurrentEmitters"]), maxEmitters > 0, maxEmitters <= 16,
              let standardHitStop = intValue(root["standardHitStopMs"]), standardHitStop == 50,
              let captainHitStop = intValue(root["captainHitStopMs"]), captainHitStop == 90,
              let coalesce = intValue(root["playerDamageCoalesceTicks"]), coalesce == 15,
              root["forbidFullScreenWhiteFlash"] as? Bool == true,
              let rawRecipes = root["recipes"] as? [[String: Any]]
        else {
            throw ProceduralVFXError.invalidJSON
        }
        var recipes: [VFXRecipe] = []
        var seen = Set<String>()
        for raw in rawRecipes {
            let recipe = try decodeRecipe(raw, standardHitStop: standardHitStop, captainHitStop: captainHitStop)
            if !seen.insert(recipe.id).inserted {
                throw ProceduralVFXError.missingRecipe(recipe.id)
            }
            recipes.append(recipe)
        }
        for required in ProceduralVFXCatalog.requiredRecipeIds {
            guard seen.contains(required) else {
                throw ProceduralVFXError.missingRecipe(required)
            }
        }
        try validateBudgets(recipes)
        return ProceduralVFXCatalog(
            schemaVersion: ContractVersions.proceduralVFX,
            visualVersion: "visual-civic-seam-001",
            atlas: atlas,
            maxConcurrentEmitters: maxEmitters,
            standardHitStopMs: standardHitStop,
            captainHitStopMs: captainHitStop,
            playerDamageCoalesceTicks: UInt64(coalesce),
            forbidFullScreenWhiteFlash: true,
            recipes: recipes
        )
    }

    private static func decodeRecipe(
        _ raw: [String: Any],
        standardHitStop: Int,
        captainHitStop: Int
    ) throws -> VFXRecipe {
        if let unexpected = Set(raw.keys).subtracting(recipeKeys).sorted().first {
            throw ProceduralVFXError.unexpectedKey(unexpected)
        }
        for key in recipeKeys {
            guard raw[key] != nil else { throw ProceduralVFXError.missingKey(key) }
        }
        guard let id = raw["id"] as? String, !id.isEmpty,
              let shape = raw["shape"] as? String, !shape.isEmpty,
              let eventNames = raw["eventTypes"] as? [String], !eventNames.isEmpty,
              let poolSize = intValue(raw["poolSize"]), poolSize >= 1,
              let defaultObject = raw["default"] as? [String: Any],
              let reducedObject = raw["reduced"] as? [String: Any]
        else {
            throw ProceduralVFXError.invalidJSON
        }
        let eventTypes = try eventNames.map { name -> EventType in
            guard let type = EventType(rawValue: name) else {
                throw ProceduralVFXError.budget(id)
            }
            return type
        }
        let defaultVariant = try decodeVariant(defaultObject, recipeId: id)
        let reducedVariant = try decodeVariant(reducedObject, recipeId: id)
        if defaultVariant.fullScreenFlash || reducedVariant.fullScreenFlash {
            throw ProceduralVFXError.fullScreenFlash(id)
        }
        if reducedVariant.screenShake {
            throw ProceduralVFXError.reducedShake(id)
        }
        let hitCap = ProceduralVFXCatalog.captainClassRecipeIds.contains(id) ? captainHitStop : standardHitStop
        if defaultVariant.hitStopMs > hitCap || reducedVariant.hitStopMs > hitCap {
            throw ProceduralVFXError.budget(id)
        }
        return VFXRecipe(
            id: id,
            shape: shape,
            eventTypes: eventTypes,
            poolSize: poolSize,
            defaultVariant: defaultVariant,
            reducedVariant: reducedVariant
        )
    }

    private static func decodeVariant(_ raw: [String: Any], recipeId: String) throws -> VFXVariant {
        if let unexpected = Set(raw.keys).subtracting(variantKeys).sorted().first {
            throw ProceduralVFXError.unexpectedKey(unexpected)
        }
        for key in variantKeys {
            guard raw[key] != nil else { throw ProceduralVFXError.missingKey(key) }
        }
        guard let language = raw["language"] as? String, !language.isEmpty,
              let particles = intValue(raw["particleCount"]), particles >= 0,
              let lifetime = intValue(raw["lifetimeMs"]), lifetime > 0,
              let hitStop = intValue(raw["hitStopMs"]), hitStop >= 0,
              let shake = raw["screenShake"] as? Bool,
              let flash = raw["fullScreenFlash"] as? Bool
        else {
            throw ProceduralVFXError.invalidJSON
        }
        _ = recipeId
        return VFXVariant(
            language: language,
            particleCount: particles,
            lifetimeMs: lifetime,
            hitStopMs: hitStop,
            screenShake: shake,
            fullScreenFlash: flash
        )
    }

    private static func validateBudgets(_ recipes: [VFXRecipe]) throws {
        for recipe in recipes {
            switch recipe.id {
            case "enemyHit":
                if recipe.defaultVariant.lifetimeMs > 120 { throw ProceduralVFXError.budget(recipe.id) }
            case "enemyDefeat":
                if recipe.defaultVariant.particleCount < 4 || recipe.defaultVariant.particleCount > 8 {
                    throw ProceduralVFXError.budget(recipe.id)
                }
                if recipe.defaultVariant.lifetimeMs > 350 { throw ProceduralVFXError.budget(recipe.id) }
                if recipe.reducedVariant.particleCount > 2 { throw ProceduralVFXError.budget(recipe.id) }
            case "ghostStep":
                if recipe.defaultVariant.lifetimeMs > 300 { throw ProceduralVFXError.budget(recipe.id) }
                if recipe.reducedVariant.particleCount > 1 { throw ProceduralVFXError.budget(recipe.id) }
            case "networkBlackout":
                // animation.md § 8a: the cascade runs over 1.5 s, in both variants.
                if recipe.defaultVariant.lifetimeMs != 1500 || recipe.reducedVariant.lifetimeMs != 1500 {
                    throw ProceduralVFXError.budget(recipe.id)
                }
            default:
                break
            }
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
