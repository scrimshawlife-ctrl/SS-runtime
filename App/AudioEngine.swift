import AVFoundation
import CoreHaptics
import SurveillanceCore
import UIKit

/// Plays what `AudioProjector` projects, and nothing else.
///
/// `audio-haptics-001` is explicit that audio and haptics "project authoritative
/// events. They never create, delay, cancel, or acknowledge gameplay state." So
/// this type is downstream of the simulation in one direction only: it reads a
/// projection and makes noise. It never feeds anything back.
///
/// The projector already owns the rules — priority, the eight-voice ceiling,
/// voice stealing, coalescence, caption history. This is the device layer:
/// files, players, buses, crossfades, and the haptic engine.
@MainActor
final class AudioEngine {
    /// Mix buses, `audio-haptics-001` §Mix buses defaults. Local settings,
    /// excluded from replay authority.
    struct Mix {
        var master: Float = 1.00
        var music: Float = 0.70
        var effects: Float = 0.85
        var voice: Float = 1.00
        var haptics: Float = 0.80
    }

    /// The contract's ceiling: "At most eight effects voices play simultaneously."
    /// The projector already caps its output; the pool enforces it at the device.
    private static let effectVoiceCount = 8
    private static let musicCrossfadeSeconds: TimeInterval = 1.0
    /// Terminal music "begins within 100 ms".
    private static let terminalCrossfadeSeconds: TimeInterval = 0.08

    var mix = Mix()
    var settings: PresentationAudioSettings = .enabled

    private var buffers: [String: AVAudioPlayer] = [:]
    /// Round-robin effect voices; index of the next one to reuse.
    private var voices: [AVAudioPlayer?] = Array(repeating: nil, count: effectVoiceCount)
    private var voiceCursor = 0

    /// Beds by asset ID, not by state: the boss state selects among four phase
    /// beds, so state alone is not enough to identify what is playing.
    private var musicPlayers: [String: AVAudioPlayer] = [:]
    private var currentBedId: String?
    private var ambience: AVAudioPlayer?
    private(set) var musicState: MusicState = .explore
    private var musicStarted = false

    private var haptics: CHHapticEngine?
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notify = UINotificationFeedbackGenerator()

    /// Asset IDs the catalog accepted. A cue for anything else plays nothing —
    /// the caption still carries the meaning.
    private let deliveredPaths: [String: String]

    private(set) var missingCueIds: Set<String> = []

    init() {
        var delivered: [String: String] = [:]
        if let catalog = try? AssetCatalog.bundled() {
            for entry in catalog.entries
            where entry.admissionDecision == .adaptedAdmitted
                && entry.record.productionStatus == .accepted
                && (entry.record.kind == .audio || entry.record.kind == .music)
            {
                if let path = entry.record.runtimePath {
                    delivered[entry.record.assetId] = path
                }
            }
        }
        deliveredPaths = delivered
        configureSession()
        prepareHaptics()
    }

    private func configureSession() {
        // .ambient so the game never interrupts the player's own music, and
        // mixes rather than ducking.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        haptics = try? CHHapticEngine()
        try? haptics?.start()
        impactLight.prepare()
        impactRigid.prepare()
        impactHeavy.prepare()
        notify.prepare()
    }

    // MARK: - Frame

    /// Consumes one tick of projection.
    func apply(_ projection: AudioProjection) {
        for cue in projection.cues {
            play(cue)
            fire(cue.haptic)
        }
        setMusic(projection.musicState, bed: projection.musicBedAssetId)
    }

    func reset() {
        for index in voices.indices {
            voices[index]?.stop()
            voices[index] = nil
        }
        for player in musicPlayers.values { player.stop() }
        musicPlayers = [:]
        ambience?.stop()
        ambience = nil
        musicStarted = false
        musicState = .explore
        currentBedId = nil
    }

    // MARK: - Effects

    private func play(_ cue: ProjectedCue) {
        guard settings.effectsEnabled else { return }
        guard let template = player(for: cue.audioId) else {
            missingCueIds.insert(cue.audioId)
            return
        }
        // A fresh player per voice: AVAudioPlayer cannot overlap itself.
        guard let voice = try? AVAudioPlayer(contentsOf: template.url!) else { return }
        voice.volume = mix.master * mix.effects
        // Camera hits alternate by hit count; the projector supplies the
        // variant, and pitch is the only carrier that does not need a new file.
        if let variant = cue.variant, variant > 0 {
            voice.enableRate = true
            voice.rate = min(2.0, 1.0 + Float(variant) * 0.06)
        }
        voices[voiceCursor]?.stop()
        voices[voiceCursor] = voice
        voiceCursor = (voiceCursor + 1) % Self.effectVoiceCount
        voice.prepareToPlay()
        voice.play()
    }

    private func player(for assetId: String) -> AVAudioPlayer? {
        if let cached = buffers[assetId] { return cached }
        guard let path = deliveredPaths[assetId],
              let url = RuntimeAssetBundle.url(forFile: path),
              let player = try? AVAudioPlayer(contentsOf: url)
        else { return nil }
        buffers[assetId] = player
        return player
    }

    // MARK: - Music

    /// `explore → observed → lockdown → boss → extraction → terminal`, crossfading
    /// over one second; terminal begins within 100 ms.
    private func setMusic(_ state: MusicState, bed: String) {
        guard settings.musicEnabled, !settings.reducedSensory else {
            if musicStarted { fadeOutAll() }
            return
        }
        startAmbienceIfNeeded()
        // A boss phase change moves the bed without moving the state, so the
        // bed is what decides whether anything needs to crossfade.
        guard bed != currentBedId || !musicStarted else { return }

        let previous = currentBedId
        musicState = state
        currentBedId = bed
        musicStarted = true
        let duration = state == .terminal
            ? Self.terminalCrossfadeSeconds
            : Self.musicCrossfadeSeconds

        if let previous, previous != bed, let outgoing = musicPlayers[previous] {
            outgoing.setVolume(0, fadeDuration: duration)
        }
        guard let incoming = musicPlayer(for: bed) else { return }
        if !incoming.isPlaying {
            incoming.numberOfLoops = -1
            incoming.volume = 0
            incoming.prepareToPlay()
            incoming.play()
        }
        incoming.setVolume(mix.master * mix.music, fadeDuration: duration)
    }

    private func musicPlayer(for assetId: String) -> AVAudioPlayer? {
        if let existing = musicPlayers[assetId] { return existing }
        // A phase bed that was never accepted falls back to the plain boss bed,
        // so an incomplete set still scores the encounter.
        let fallback = assetId.hasPrefix("music_boss_") ? "music_boss" : nil
        guard let path = deliveredPaths[assetId] ?? fallback.flatMap({ deliveredPaths[$0] }),
              let url = RuntimeAssetBundle.url(forFile: path),
              let player = try? AVAudioPlayer(contentsOf: url)
        else { return nil }
        musicPlayers[assetId] = player
        return player
    }

    /// audio-haptics-001 §Music states asset table.
    static func musicAssetId(for state: MusicState) -> String {
        "music_\(state.rawValue)"
    }

    private func startAmbienceIfNeeded() {
        guard ambience == nil,
              let path = deliveredPaths["ambience_civic_seam"],
              let url = RuntimeAssetBundle.url(forFile: path),
              let player = try? AVAudioPlayer(contentsOf: url)
        else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        player.play()
        player.setVolume(mix.master * mix.music * 0.5, fadeDuration: Self.musicCrossfadeSeconds)
        ambience = player
    }

    private func fadeOutAll() {
        for player in musicPlayers.values {
            player.setVolume(0, fadeDuration: Self.musicCrossfadeSeconds)
        }
        ambience?.setVolume(0, fadeDuration: Self.musicCrossfadeSeconds)
        musicStarted = false
    }

    // MARK: - Haptics

    /// Haptics are never the only carrier: every cue that fires one also carries
    /// a caption, so disabling them loses nothing safety-critical.
    private func fire(_ pattern: HapticPattern) {
        guard settings.hapticsEnabled, !settings.reducedSensory, mix.haptics > 0 else { return }
        switch pattern {
        case .none: break
        case .light: impactLight.impactOccurred(intensity: CGFloat(mix.haptics))
        case .rigid: impactRigid.impactOccurred(intensity: CGFloat(mix.haptics))
        case .heavy: impactHeavy.impactOccurred(intensity: CGFloat(mix.haptics))
        case .warning: notify.notificationOccurred(.warning)
        case .success: notify.notificationOccurred(.success)
        }
    }
}
