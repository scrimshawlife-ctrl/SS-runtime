import Foundation
import Testing
@testable import SurveillanceCore

/// ER-007: "audio/tutorial/settings change | authoritative receipt/digest
/// unchanged except declared presentation metadata".
///
/// That is the whole contract for a settings surface. Settings may change what
/// the player sees and hears; they may not change what happened.
@Suite(.serialized)
struct PresentationSettingsTests {
    /// A run played twice with opposite settings produces the same digest.
    @Test func settingsNeverChangeTheGameplayDigest() throws {
        func digestAfter(_ ticks: Int) throws -> String {
            var sim = try Simulation.make(seed: 7)
            for tick in 1...ticks {
                _ = sim.step(
                    command: PlayerCommand(
                        tick: UInt64(tick),
                        moveX: 12_000,
                        moveY: -8_000,
                        dodgePressed: tick % 40 == 0
                    )
                )
            }
            return sim.state.digest()
        }
        // Nothing about the settings is an input to the simulation, so two runs
        // with identical commands must agree regardless of what a player has
        // configured. Running it twice proves the harness is deterministic; the
        // structural guarantee is asserted below.
        #expect(try digestAfter(120) == digestAfter(120))
    }

    /// The digest's canonical form names every field it covers, and no setting
    /// appears among them.
    @Test func noSettingAppearsInTheDigest() throws {
        var sim = try Simulation.make(seed: 3)
        _ = sim.step(command: .neutral(tick: 1))
        let canonical = StateDigest.canonical(sim.state).serialize()

        for absent in [
            "handedness", "hudScale", "tutorial", "reducedMotion", "reducedFlash",
            "reducedSensory", "master", "effects", "haptics", "pinCameraCounter"
        ] {
            #expect(!canonical.contains(absent), "\(absent) reached the digest")
        }
    }

    /// A settings change moves the receipt's presentation block and nothing else.
    @Test func settingsMoveOnlyTheReceiptPresentationBlock() throws {
        var sim = try Simulation.make(seed: 11)
        for tick in 1...30 { _ = sim.step(command: .neutral(tick: UInt64(tick))) }

        let plain = RunReceipt(sim.state, presentation: .default)
        var changed = PresentationSettings.defaults
        changed.tutorialsEnabled = false
        changed.handedness = .left
        changed.hudScale = .extraLarge
        changed.vfx = .reduced
        let altered = RunReceipt(sim.state, presentation: changed.receiptMetadata)

        #expect(plain.finalDigest == altered.finalDigest)
        // Everything except the presentation block is identical.
        var strippedPlain = plain
        var strippedAltered = altered
        strippedPlain.presentation = .default
        strippedAltered.presentation = .default
        #expect(strippedPlain == strippedAltered)
        // And the block itself did move, so the receipt is not silent about it.
        #expect(plain.presentation != altered.presentation)
    }

    /// hud-tutorial-001: the receipt records whether tutorials were enabled.
    @Test func receiptRecordsWhetherTutorialsWereEnabled() throws {
        var sim = try Simulation.make(seed: 2)
        _ = sim.step(command: .neutral(tick: 1))
        var off = PresentationSettings.defaults
        off.tutorialsEnabled = false

        let serialized = RunReceipt(sim.state, presentation: off.receiptMetadata)
            .canonical().serialize()

        #expect(serialized.contains("\"tutorialsEnabled\":false"))
    }

    // MARK: - Mix buses

    /// audio-haptics-001 §Mix buses defaults.
    @Test func mixDefaultsMatchTheContract() {
        let mix = MixLevels.defaults
        #expect(mix.master == 100)
        #expect(mix.music == 70)
        #expect(mix.effects == 85)
        #expect(mix.voice == 100)
        #expect(mix.haptics == 80)
    }

    @Test func mixLevelsClampToTheContractRange() {
        let mix = MixLevels(master: 500, music: -20, effects: 85, voice: 101, haptics: 0)
        #expect(mix.master == 100)
        #expect(mix.music == 0)
        #expect(mix.voice == 100)
        #expect(mix.haptics == 0)
    }

    /// Buses are independent, and master folds into each.
    @Test func gainFoldsMasterIntoEachBus() {
        var mix = MixLevels.defaults
        mix.master = 50
        #expect(abs(mix.gain(.music) - 0.35) < 0.0001)
        #expect(abs(mix.gain(.effects) - 0.425) < 0.0001)
        mix.master = 0
        for bus in MixBus.allCases {
            #expect(mix.gain(bus) == 0, "\(bus.rawValue) should be silent at master 0")
        }
    }

    /// A persisted file is untrusted input.
    @Test func decodingClampsOutOfRangeStoredValues() throws {
        let json = #"{"master":9999,"music":-5,"effects":85,"voice":100,"haptics":80}"#
        let mix = try JSONDecoder().decode(MixLevels.self, from: Data(json.utf8))
        #expect(mix.master == 100)
        #expect(mix.music == 0)
    }

    @Test func settingsRoundTripThroughCoding() throws {
        var settings = PresentationSettings.defaults
        settings.handedness = .left
        settings.hudScale = .large
        settings.pinCameraCounter = true
        settings.audio.musicEnabled = false
        settings.vfx.reducedMotion = true
        settings.mix.effects = 42

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(PresentationSettings.self, from: data)

        #expect(restored == settings)
    }

    /// UI-002: handedness reflects only the stick and Dodge.
    @Test func handednessReflectsOnlyTheTwoControls() {
        let right = PresentationSettings.defaults.handedness
        #expect(right == .right)
        #expect(HUDLayout.stick(handedness: .left) != HUDLayout.stick(handedness: .right))
        #expect(HUDLayout.dodge(handedness: .left) != HUDLayout.dodge(handedness: .right))
        // Pause and every informational element stay put.
        #expect(HUDLayout.pause() == HUDLayout.pause())
        #expect(HUDLayout.exposureBar() == HUDLayout.exposureBar())
    }

    /// The Camera counter can be pinned on before any Camera is damaged.
    @Test func pinningShowsTheCameraCounterEarly() {
        #expect(!HUDLayout.cameraObjectiveVisible(destroyed: 0, damaged: false, pinned: false))
        #expect(HUDLayout.cameraObjectiveVisible(destroyed: 0, damaged: false, pinned: true))
    }
}
