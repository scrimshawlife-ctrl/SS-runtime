import Foundation
import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct ProceduralVFXTests {
    @Test func vfxCatalogEncodesBudgetsAndReducedVariants() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        let ids = catalog.recipes.map(\.id)
        let defeat = try #require(catalog.recipesById["enemyDefeat"])
        let ghost = try #require(catalog.recipesById["ghostStep"])
        let hit = try #require(catalog.recipesById["playerHit"])
        let captain = try #require(catalog.recipesById["captainTelegraph"])
        let flashes = catalog.recipes.contains { $0.defaultVariant.fullScreenFlash || $0.reducedVariant.fullScreenFlash }
        let reducedShake = catalog.recipes.contains { $0.reducedVariant.screenShake }
        let defeatParticles = defeat.defaultVariant.particleCount
        let reducedDefeatParticles = defeat.reducedVariant.particleCount
        let ghostLifetime = ghost.defaultVariant.lifetimeMs
        let reducedGhostParticles = ghost.reducedVariant.particleCount
        let playerHitStop = hit.defaultVariant.hitStopMs
        let captainHitStop = captain.defaultVariant.hitStopMs
        let reducedHitShake = hit.reducedVariant.screenShake
        let defeatInRange = defeatParticles >= 4 && defeatParticles <= 8
        #expect(catalog.schemaVersion == ContractVersions.proceduralVFX)
        #expect(ids == ProceduralVFXCatalog.requiredRecipeIds)
        #expect(catalog.maxConcurrentEmitters == 16)
        #expect(catalog.forbidFullScreenWhiteFlash)
        #expect(!flashes)
        #expect(!reducedShake)
        #expect(defeatInRange)
        #expect(reducedDefeatParticles <= 2)
        #expect(ghostLifetime <= 300)
        #expect(reducedGhostParticles <= 1)
        #expect(playerHitStop == 50)
        // D-088: a telegraph is a cue to react, not an impact, so it carries
        // no hit-stop; the Captain cap belongs to the phase break.
        #expect(captainHitStop == 0)
        #expect(catalog.recipesById["bossPhaseBreak"]?.defaultVariant.hitStopMs == 90)
        #expect(!reducedHitShake)
        #expect(catalog.atlas == "combat_vfx.atlas")
    }

    @Test func vfxUnknownSchemaFailsClosed() throws {
        let json = #"{"schemaVersion":"procedural-vfx-000"}"#.data(using: .utf8)!
        do {
            _ = try ProceduralVFXLoader.decode(json)
            Issue.record("expected schema failure")
        } catch ProceduralVFXError.schemaVersion {
        }
    }

    @Test func vfxFullScreenFlashFailsClosed() throws {
        let json = try mutatedBundled { recipes in
            if var variant = recipes[0]["default"] as? [String: Any] {
                variant["fullScreenFlash"] = true
                recipes[0]["default"] = variant
            }
        }
        do {
            _ = try ProceduralVFXLoader.decode(json)
            Issue.record("expected flash failure")
        } catch ProceduralVFXError.fullScreenFlash("cameraAcquire") {
        }
    }

    @Test func vfxProjectorMapsEventsAndCoalescesPlayerHits() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        let damage = AuthoritativeEvent(
            tick: 20,
            phase: 12,
            type: .playerDamaged,
            primary: EntityID(1),
            payload: [
                "amount": .integer(4),
                "remainingIntegrity": .integer(96),
                "sourceEntityId": .string("9")
            ],
            insertion: 0
        )
        let first = projector.project(tick: 20, events: [damage], catalog: catalog)
        let firstId = first.presentations.first?.recipeId
        let firstShake = first.presentations.first?.screenShake ?? false
        var later = damage
        later.tick = 30
        let coalesced = projector.project(tick: 30, events: [later], catalog: catalog)
        let coalescedCount = coalesced.presentations.count
        later.tick = 35
        let allowed = projector.project(tick: 35, events: [later], catalog: catalog)
        let allowedId = allowed.presentations.first?.recipeId
        #expect(firstId == "playerHit")
        #expect(firstShake)
        #expect(coalescedCount == 0)
        #expect(allowedId == "playerHit")
    }

    @Test func vfxReducedMotionDisablesShakeAndUsesReducedLanguage() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        let damage = AuthoritativeEvent(
            tick: 8,
            phase: 12,
            type: .playerDamaged,
            primary: EntityID(1),
            payload: [
                "amount": .integer(4),
                "remainingIntegrity": .integer(96),
                "sourceEntityId": .string("9")
            ],
            insertion: 0
        )
        let lockdown = AuthoritativeEvent(
            tick: 8,
            phase: 13,
            type: .lockdownEntered,
            payload: ["reason": .string("exposure")],
            insertion: 1
        )
        let projection = projector.project(
            tick: 8,
            events: [damage, lockdown],
            catalog: catalog,
            settings: .reduced
        )
        let hit = try #require(projection.presentations.first { $0.recipeId == "playerHit" })
        let lock = try #require(projection.presentations.first { $0.recipeId == "lockdown" })
        let hitLanguage = hit.language
        let hitShake = hit.screenShake
        let lockLanguage = lock.language
        let lockShake = lock.screenShake
        #expect(hitLanguage == "directionalArcWithoutScreenFlash")
        #expect(!hitShake)
        #expect(lockLanguage == "staticPerimeterChange")
        #expect(!lockShake)
    }

    @Test func vfxRicochetProjectsOnceForTwoSameTickHits() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        let hits: [AuthoritativeEvent] = (0..<2).map { index in
            AuthoritativeEvent(
                tick: 4,
                phase: 9,
                type: .projectileHit,
                primary: EntityID(UInt64(index + 2)),
                payload: [
                    "projectileId": .string("1"),
                    "targetEntityId": .string("\(index + 2)"),
                    "appliedDamage": .integer(1)
                ],
                insertion: index
            )
        }
        let projection = projector.project(tick: 4, events: hits, catalog: catalog)
        let ricochetCount = projection.presentations.filter { $0.recipeId == "ricochet" }.count
        let language = projection.presentations.first?.language
        #expect(ricochetCount == 1)
        #expect(language == "segmentedPathTrace")
    }

    @Test func vfxEmitterCeilingStealsLowestPriority() throws {
        let catalog = try ProceduralVFXCatalog.bundled()
        var projector = VFXProjector()
        var events: [AuthoritativeEvent] = []
        for index in 0..<20 {
            events.append(
                AuthoritativeEvent(
                    tick: 3,
                    phase: 9,
                    type: .entityDamaged,
                    primary: EntityID(UInt64(index + 10)),
                    payload: [
                        "entityId": .string("\(index + 10)"),
                        "amount": .integer(1),
                        "remainingIntegrity": .integer(9)
                    ],
                    insertion: index
                )
            )
        }
        events.append(
            AuthoritativeEvent(
                tick: 3,
                phase: 13,
                type: .lockdownEntered,
                payload: ["reason": .string("exposure")],
                insertion: 20
            )
        )
        let projection = projector.project(tick: 3, events: events, catalog: catalog)
        let count = projection.presentations.count
        let hasLockdown = projection.presentations.contains { $0.recipeId == "lockdown" }
        let enemyHits = projection.presentations.filter { $0.recipeId == "enemyHit" }.count
        #expect(count == 16)
        #expect(hasLockdown)
        #expect(enemyHits == 15)
    }

    private func mutatedBundled(_ mutate: (inout [[String: Any]]) -> Void) throws -> Data {
        var root = try JSONSerialization.jsonObject(with: SpecBundle.contract("procedural-vfx-003")) as! [String: Any]
        var recipes = root["recipes"] as! [[String: Any]]
        mutate(&recipes)
        root["recipes"] = recipes
        return try JSONSerialization.data(withJSONObject: root)
    }
}
