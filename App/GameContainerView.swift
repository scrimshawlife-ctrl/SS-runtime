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
    /// `run-shell-001` §8: the app presents the title surface on launch, and a
    /// run begins only when the player asks for one.
    ///
    /// The debug pilot drives the simulation, not the shell, so a harness run
    /// skips the title rather than waiting behind it for a tap that will never
    /// come. Every `-SSAutopilot` and `-SSSeed` recipe keeps working unchanged.
    @State private var started = Self.startsImmediately

    private static var startsImmediately: Bool {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-SSAutopilot") || arguments.contains("-SSSeed")
#else
        return false
#endif
    }
    private let scene: GameScene = {
        let scene = GameScene()
        scene.scaleMode = .resizeFill
        return scene
    }()

    var body: some View {
        ZStack {
            game
            if !started {
                TitleView(
                    onStart: startDailyRun,
                    onSettings: { showSettings = true }
                )
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store) { showSettings = false }
        }
        // PC-008 for pause, and the same principle for the title surface: no
        // simulation tick occurs while either is presented.
        .onChange(of: showSettings) { _, presented in
            scene.setPaused(presented || !started)
        }
        .onChange(of: started) { _, running in
            scene.setPaused(!running || showSettings)
        }
    }

    /// `run-shell.md` § 10.1: the date is read once, when Start is pressed,
    /// and only here. The simulation receives a seed, never a date.
    private func startDailyRun() {
        guard let run = try? DailyRun(day: DailyRun.Day(utc: Date())) else { return }
        scene.beginDailyRun(run)
        started = true
    }

    private var game: some View {
        SpriteView(scene: scene, preferredFramesPerSecond: 60)
            .ignoresSafeArea()
            .accessibilityLabel("Surveillance Survivor gameplay")
            .onAppear {
                scene.apply(settings: store.settings)
                // Hold the simulation until the player starts a run — but not
                // when a harness run has already skipped the title, or this
                // would pause the very thing the autopilot came to drive.
                scene.setPaused(!started)
                // Pause is a HUD control, so the scene raises it and SwiftUI
                // presents the surface.
                scene.onPauseRequested = { showSettings = true }
            }
            .onChange(of: store.settings) { _, settings in
                scene.apply(settings: settings)
            }
    }
}
