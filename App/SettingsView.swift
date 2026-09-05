import SurveillanceCore
import SwiftUI

/// The settings surface.
///
/// `plan.md` §Architecture assigns SwiftUI "application lifecycle, menus,
/// settings, protected overlays, and accessible non-gameplay controls", which
/// is why this is SwiftUI over the SpriteKit view rather than more SpriteKit:
/// sliders, pickers, VoiceOver, and Dynamic Type all come from the platform.
///
/// The run is paused while this is open, and `player-controller-001` PC-008
/// requires that pause create no simulation ticks — so nothing here can affect
/// the run even in principle.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    var onResume: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                audioSection
                displaySection
                accessibilitySection
                gameplaySection
                resetSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resume", action: onResume)
                        .accessibilityHint("Closes settings and resumes the run")
                }
            }
        }
    }

    // MARK: - Audio

    /// audio-haptics-001 §Mix buses: five independent 0–100 buses.
    private var audioSection: some View {
        Section {
            mixSlider("Master", value: $store.settings.mix.master)
            mixSlider("Music", value: $store.settings.mix.music)
            mixSlider("Effects", value: $store.settings.mix.effects)
            mixSlider("Voice and captions", value: $store.settings.mix.voice)
            mixSlider("Haptics", value: $store.settings.mix.haptics)

            Toggle("Effects", isOn: $store.settings.audio.effectsEnabled)
            Toggle("Music", isOn: $store.settings.audio.musicEnabled)
            Toggle("Haptics", isOn: $store.settings.audio.hapticsEnabled)
        } header: {
            Text("Audio")
        } footer: {
            Text("Captions always appear, whatever these are set to. No audio event is the only carrier of a safety-critical warning.")
        }
    }

    private func mixSlider(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.wrappedValue)%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = MixLevels.clamp(Int($0.rounded())) }
                ),
                in: Double(MixLevels.range.lowerBound)...Double(MixLevels.range.upperBound),
                step: 1
            )
            .accessibilityLabel(label)
            .accessibilityValue("\(value.wrappedValue) percent")
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section {
            Picker("HUD scale", selection: $store.settings.hudScale) {
                Text("Standard").tag(HUDScaleSetting.standard)
                Text("Large").tag(HUDScaleSetting.large)
                Text("Extra large").tag(HUDScaleSetting.extraLarge)
            }
            .accessibilityHint("Scales readouts. Controls never shrink below their touch target.")

            Picker("Handedness", selection: $store.settings.handedness) {
                Text("Right").tag(Handedness.right)
                Text("Left").tag(Handedness.left)
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Mirrors the movement stick and Dodge. Pause and readouts do not move.")

            Toggle("Always show Camera counter", isOn: $store.settings.pinCameraCounter)
        } header: {
            Text("Display")
        } footer: {
            Text("The Camera counter normally appears once a Camera is damaged.")
        }
    }

    // MARK: - Accessibility

    private var accessibilitySection: some View {
        Section {
            Toggle("Reduced motion", isOn: $store.settings.vfx.reducedMotion)
            Toggle("Reduced flash", isOn: $store.settings.vfx.reducedFlash)
            Toggle("Reduced sensory", isOn: $store.settings.audio.reducedSensory)
        } header: {
            Text("Accessibility")
        } footer: {
            Text("Reduced motion swaps state changes instantly instead of animating them. Reduced flash removes full-screen luminance changes. Every warning keeps its shape and caption.")
        }
    }

    // MARK: - Gameplay

    private var gameplaySection: some View {
        Section {
            Toggle("Tutorial prompts", isOn: $store.settings.tutorialsEnabled)
        } header: {
            Text("Gameplay")
        } footer: {
            Text("Recorded on the run receipt. Settings never change the outcome of a run or its digest.")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset to defaults", role: .destructive) {
                store.resetToDefaults()
            }
        }
    }
}
