import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct CameraHUDTests {
    @Test func cameraUI004ThreeNotchesShowAuthoritativeIntegrity() {
        var hud = CameraHUDProjector()
        let intact = hud.project(
            tick: 10,
            events: [],
            query: CameraHUDQuery(targetIntegrity: 3, damageable: true, targeted: true, inRange: true)
        )
        let damaged = hud.project(
            tick: 11,
            events: [],
            query: CameraHUDQuery(
                targetIntegrity: 2,
                damageable: true,
                targeted: true,
                inRange: true,
                damaged: true
            )
        )
        let critical = hud.project(
            tick: 12,
            events: [],
            query: CameraHUDQuery(
                targetIntegrity: 1,
                damageable: true,
                targeted: false,
                inRange: true,
                damaged: true
            )
        )
        let intactFilled = intact.notchFilled
        let damagedFilled = damaged.notchFilled
        let criticalFilled = critical.notchFilled
        #expect(intact.notchesVisible)
        #expect(intactFilled == [true, true, true])
        #expect(damagedFilled == [true, true, false])
        #expect(criticalFilled == [true, false, false])
        #expect(HUDLayout.integrityNotchCount == 3)
        #expect(HUDLayout.tamperSpike().x == 642)
    }

    @Test func cameraNotchesPersistNinetyTicksAfterHit() {
        var hud = CameraHUDProjector()
        let hit = AuthoritativeEvent(
            tick: 20,
            phase: 9,
            type: .cameraIntegrityChanged,
            primary: EntityID(4),
            payload: ["cameraId": .string("4"), "before": .integer(3), "after": .integer(2)],
            insertion: 0
        )
        let atHit = hud.project(
            tick: 20,
            events: [hit],
            query: CameraHUDQuery(
                targetIntegrity: 2,
                damageable: true,
                targeted: true,
                inRange: true,
                damaged: true
            )
        )
        let still = hud.project(tick: 109, events: [], query: .none)
        let expired = hud.project(tick: 110, events: [], query: .none)
        let filled = still.notchFilled
        #expect(atHit.notchesVisible)
        #expect(still.notchesVisible)
        #expect(filled == [true, true, false])
        #expect(!expired.notchesVisible)
    }

    @Test func cameraTamperCopySitsBesideExposureAfterDestroy() {
        var hud = CameraHUDProjector()
        let destroyed = AuthoritativeEvent(
            tick: 8,
            phase: 10,
            type: .cameraDestroyed,
            primary: EntityID(4),
            payload: [
                "cameraId": .string("4"),
                "socketId": .string("cam-z02-a"),
                "projectileId": .string("1"),
                "wasDetecting": .bool(false)
            ],
            insertion: 0
        )
        let shown = hud.project(tick: 8, events: [destroyed], query: .none)
        let persisted = hud.project(tick: 97, events: [], query: .none)
        let gone = hud.project(tick: 98, events: [], query: .none)
        let copy = shown.tamperCopy
        let adjacent = HUDLayout.tamperSpike().x > HUDLayout.exposureBar().x
        #expect(shown.tamperVisible)
        #expect(copy == HUDLayout.tamperCopy)
        #expect(copy == "+150 TAMPER")
        #expect(adjacent)
        #expect(persisted.tamperVisible)
        #expect(!gone.tamperVisible)
    }

    @Test func cameraUI005LockdownPreemptsTutorialWithoutAdvancingPhase() {
        var tutorial = TutorialState()
        tutorial.noteDisplacement(96)
        tutorial.noteContact(true)
        tutorial.noteCameraTargetable()
        let phaseBefore = tutorial.phase
        let copyBefore = tutorial.copy
        tutorial.lockdownPreempts = true
        let lockdownCopy = tutorial.copy
        let phaseDuring = tutorial.phase
        tutorial.lockdownPreempts = false
        let copyAfter = tutorial.copy
        #expect(phaseBefore == .cameraDamage)
        #expect(copyBefore == HUDLayout.firstEncounterCameraCopy)
        #expect(lockdownCopy == "LOCKDOWN")
        #expect(phaseDuring == .cameraDamage)
        #expect(copyAfter == HUDLayout.firstEncounterCameraCopy)
    }
}
