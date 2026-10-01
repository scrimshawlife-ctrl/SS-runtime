import AVFoundation

/// D-097: one effect voice played at a pitch offset (the takedown's
/// `impact_enemy`, 4 semitones down). `AVAudioPlayer.rate` changes speed, not
/// pitch, so a true semitone shift goes through `AVAudioUnitTimePitch`.
///
/// A small engine of its own, started lazily on the first pitched cue, so the
/// default path through `AudioEngine` is untouched.
@MainActor
final class PitchedVoice {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private var files: [URL: AVAudioFile] = [:]
    private var connectedFormat: AVAudioFormat?

    init() {
        engine.attach(player)
        engine.attach(pitch)
    }

    /// Plays `url` once at `cents` (100 cents = 1 semitone) and `volume`.
    func play(url: URL, cents: Int, volume: Float) {
        guard let file = file(url) else { return }
        if connectedFormat != file.processingFormat {
            engine.stop()
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(pitch)
            engine.connect(player, to: pitch, format: file.processingFormat)
            engine.connect(pitch, to: engine.mainMixerNode, format: file.processingFormat)
            connectedFormat = file.processingFormat
        }
        pitch.pitch = Float(cents)
        player.volume = volume
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        player.scheduleFile(file, at: nil)
        if !player.isPlaying { player.play() }
    }

    func stop() {
        player.stop()
    }

    private func file(_ url: URL) -> AVAudioFile? {
        if let cached = files[url] { return cached }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        files[url] = file
        return file
    }
}
