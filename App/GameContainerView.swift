import SpriteKit
import SurveillanceCore
import SwiftUI

/// Hosts the SpriteKit scene and the SwiftUI surfaces over it.
///
/// `plan.md` §Architecture: "SpriteKit owns presentation, input sampling,
/// audio, and animation. ... SwiftUI owns application lifecycle, menus,
/// settings, protected overlays, and accessible non-gameplay controls."
struct GameContainerView: View {
    @StateObject private var store = SettingsStore()
    @State private var showSettings = false
    private let scene: GameScene = {
        let scene = GameScene()
        scene.scaleMode = .resizeFill
        return scene
    }()

    var body: some View {
        SpriteView(scene: scene, preferredFramesPerSecond: 60)
            .ignoresSafeArea()
            .accessibilityLabel("Surveillance Survivor gameplay")
            .onAppear {
                scene.apply(settings: store.settings)
                // Pause is a HUD control, so the scene raises it and SwiftUI
                // presents the surface.
                scene.onPauseRequested = { showSettings = true }
            }
            .onChange(of: store.settings) { _, settings in
                scene.apply(settings: settings)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(store: store) { showSettings = false }
            }
            // PC-008: a paused run creates no simulation ticks.
            .onChange(of: showSettings) { _, presented in
                scene.setPaused(presented)
            }
    }
}
