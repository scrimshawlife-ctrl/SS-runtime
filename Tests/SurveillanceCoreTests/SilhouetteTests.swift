import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct SilhouetteTests {
    @Test func enemyT405SilhouettesAreDistinctAndIndependentOfCollision() throws {
        let language = try VisualLanguage.bundled()
        let content = CombatContent.bundled()
        let standard: [ArchetypeID] = [
            .fogAnalyticsCloud, .cableCarCorrelator, .sutroSignalWitch,
            .autonomousInformant, .victorianVendor
        ]
        var seen = Set<String>()
        for archetype in standard {
            let silhouette = ActorSilhouette.enemy(archetype)
            #expect(seen.insert(silhouette.rawValue).inserted)
            #expect(silhouette.spriteBox == language.spriteBoxes["playerAndStandardEnemy"])
            let radius = try #require(content.standardEnemies[archetype]?.radius)
            #expect(radius * 2 != silhouette.spriteBox.width)
            #expect(silhouette.contour.count >= 5)
        }
        let elite = ActorSilhouette.enemy(.improperSearchDaemon)
        let boss = ActorSilhouette.enemy(.algorithmicModerate)
        #expect(elite.spriteBox == language.spriteBoxes["improperSearchDaemon"])
        #expect(boss.spriteBox == language.spriteBoxes["algorithmicModerate"])
        #expect(elite.rawValue != boss.rawValue)
        #expect(seen.insert(elite.rawValue).inserted)
        #expect(seen.insert(boss.rawValue).inserted)
        #expect(ActorSilhouette.playerRing.contour != elite.contour)

        let contours = ActorSilhouette.allCases.map { "\($0.contour)" }
        #expect(Set(contours).count == ActorSilhouette.allCases.count)
    }

    @Test func enemyT405SnapshotProjectsSilhouetteWithoutChangingRadius() {
        let silhouette = ActorSilhouette.enemy(.fogAnalyticsCloud)
        let sprite = PresentationSnapshot.CircleSprite(
            id: EntityID(99),
            x: 0,
            y: 0,
            radius: 18,
            role: ArchetypeID.fogAnalyticsCloud.rawValue,
            silhouette: silhouette,
            clipId: nil,
            direction: "s"
        )
        #expect(sprite.radius == 18)
        #expect(sprite.silhouette == .clusteredMass)
        #expect(sprite.silhouette.spriteBox.width != sprite.radius * 2)
        #expect(sprite.silhouette.contour != ActorSilhouette.playerRing.contour)
    }
}
