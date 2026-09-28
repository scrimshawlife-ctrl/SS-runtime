import SurveillanceCore
import SwiftUI

/// `run-shell-001` §8: the surface the app presents on launch.
///
/// Exactly two actions, Start and Settings, and nothing else. No run history, no
/// statistics, no continue, no difficulty choice — those are the expansion this
/// level defers, and a title screen is where they creep in first.
///
/// The reason this surface exists is Settings, not presentation. `SettingsView`
/// was reachable only from Pause, during a run, so a player could not set
/// handedness before playing — which would have contaminated exactly the
/// onboarding data T903/T904 collect.
struct TitleView: View {
    let onStart: () -> Void
    let onSettings: () -> Void

    var body: some View {
        ZStack {
            // The ground the game itself uses, so the backdrop's edges never
            // reveal a letterbox of a different colour on an unmatched aspect.
            Color(.sRGB, red: 52 / 255, green: 61 / 255, blue: 67 / 255, opacity: 1)
                .ignoresSafeArea()

            Image("shell_title_backdrop")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            // The backdrop's sky is bright, and the wordmark is near-white over
            // it: measured 2.95:1, under both the 4.5:1 that visual-assets-001
            // requires for text and the 3:1 floor for critical UI. This scrim
            // is the smallest fix that keeps the art — it darkens the upper
            // band where type sits and clears at the horizon.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.62), location: 0.00),
                    .init(color: .black.opacity(0.48), location: 0.38),
                    .init(color: .black.opacity(0.12), location: 0.72),
                    .init(color: .black.opacity(0.30), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                Image("shell_wordmark")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 520)
                    .accessibilityLabel("Surveillance Survivor")

                // `run-shell.md` § 5 / § 8: the Daily Run label under the
                // wordmark. Presentation only; Start reads the date again, so
                // a title left open across midnight UTC re-labels itself here
                // and Start still plays the date it is pressed on.
                TimelineView(.everyMinute) { context in
                    Text(DailyRun.titleLabel(for: DailyRun.Day(utc: context.date)))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .kerning(1.5)
                        .foregroundStyle(Color(white: 0.92))
                        .padding(.top, 12)
                        .accessibilityLabel(
                            "Daily run, \(DailyRun.Day(utc: context.date).label)"
                        )
                }

                Spacer(minLength: 24)

                // Centred, so neither handedness is favoured. Handedness
                // reflects the stick and Dodge only, and never shell chrome.
                VStack(spacing: 16) {
                    TitleButton(title: "START", action: onStart)
                    TitleButton(title: "SETTINGS", action: onSettings)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 28)
        }
    }
}

/// A title control. `hud-tutorial-001` requires every interactive rectangle to
/// be at least 44 × 44 points; the plate art is 512 × 160, drawn here at a size
/// that clears that comfortably.
private struct TitleButton: View {
    let title: String
    let action: () -> Void
    @State private var pressed = false

    private static let width: CGFloat = 220
    private static let height: CGFloat = 56

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(pressed ? "shell_plate_wide_pressed" : "shell_plate_wide")
                    .resizable()
                    .frame(width: Self.width, height: Self.height)
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .kerning(1.5)
                    // The pressed plate lifts to a pale stucco, so the label has
                    // to invert with it or it would fail its contrast ratio at
                    // exactly the moment the player is looking at it.
                    .foregroundStyle(pressed ? Color(white: 0.12) : Color(white: 0.92))
            }
            .frame(width: Self.width, height: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.capitalized)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}
