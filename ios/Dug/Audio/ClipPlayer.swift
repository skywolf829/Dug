import AVFoundation

/// Plays collar-format audio (16 kHz mu-law) through the phone's speaker. Used for previews
/// and by the simulated collar, so what you hear is exactly what the collar would play.
final class ClipPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: MuLaw.sampleRate, channels: 1)!
    private var generation = 0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// `gain` is 0...1. `completion` runs on the main thread unless playback was interrupted
    /// by another `play` or `stop`.
    func play(_ ulaw: Data, gain: Float = 1, completion: (() -> Void)? = nil) {
        stop()
        let samples = MuLaw.decodeToFloat(ulaw)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        let out = buffer.floatChannelData![0]
        for i in samples.indices { out[i] = samples[i] * gain }

        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            print("ClipPlayer: engine failed to start: \(error)")
            return
        }
        generation += 1
        let token = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                completion?()
            }
        }
        player.play()
    }

    func stop() {
        generation += 1
        player.stop()
    }
}
