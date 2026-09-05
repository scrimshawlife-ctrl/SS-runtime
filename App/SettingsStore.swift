import SurveillanceCore
import SwiftUI

/// Local persistence for `PresentationSettings`.
///
/// `plan.md` lists persistence as "settings-and-local-run-receipts", and
/// `audio-haptics-001` says settings are "local, independent, and excluded from
/// replay authority". So this never touches the simulation and never travels
/// with a replay — it is a per-device preference file and nothing more.
@MainActor
final class SettingsStore: ObservableObject {
    private static let key = "com.zer0state.surveillancesurvivor.presentationSettings"

    @Published var settings: PresentationSettings {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A stored file is untrusted input: a decode failure falls back to the
        // contract defaults rather than refusing to start.
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(PresentationSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = .defaults
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func resetToDefaults() {
        settings = .defaults
    }
}
