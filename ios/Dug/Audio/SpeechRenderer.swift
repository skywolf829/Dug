import AVFoundation

enum RenderError: LocalizedError {
    case emptyText
    case noAudio
    case conversionFailed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .emptyText: "There's nothing to say."
        case .noAudio: "The voice didn't produce any audio. Try another voice in Settings."
        case .conversionFailed: "Couldn't convert the speech audio."
        case .timedOut: "The voice took too long to respond. Try again in a moment."
        }
    }
}

/// Turns text into collar-ready audio entirely on device: AVSpeechSynthesizer renders to
/// buffers (instead of the speaker), which are resampled to 16 kHz mono, trimmed, run through
/// the loudness chain below, and mu-law encoded.
@MainActor
final class SpeechRenderer {
    private let synthesizer = AVSpeechSynthesizer()
    private let queue = SerialQueue()

    func render(_ text: String, voice: VoiceSettings) async throws -> Data {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RenderError.emptyText }
        // AVSpeechSynthesizer only renders one utterance at a time.
        return try await queue.run {
            let samples = try await self.synthesize(text, voice: voice)
            let cleaned = Self.trimAndNormalize(samples)
            guard !cleaned.isEmpty else { throw RenderError.noAudio }
            return MuLaw.encode(cleaned)
        }
    }

    private func synthesize(_ text: String, voice: VoiceSettings) async throws -> [Int16] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice.voice
        utterance.pitchMultiplier = voice.pitch
        utterance.rate = voice.rate

        let collector = PCMCollector()
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                // An empty buffer marks the end of the utterance.
                if pcm.frameLength == 0 {
                    once.run { continuation.resume(with: Result { try collector.finish() }) }
                    return
                }
                do {
                    try collector.append(pcm)
                } catch {
                    once.run { continuation.resume(throwing: error) }
                }
            }
            // The speech service occasionally stalls (seen on a fresh simulator); don't hang forever.
            Task { [synthesizer] in
                try? await Task.sleep(for: .seconds(15))
                once.run {
                    log.error("render timed out")
                    synthesizer.stopSpeaking(at: .immediate)
                    continuation.resume(throwing: RenderError.timedOut)
                }
            }
        }
    }

    /// Tuning for the loudness chain in `trimAndNormalize`. The collar's driver is small and
    /// usually competing with a noisy street, so clips are high-passed, compressed, and the
    /// headroom that frees up is handed back as gain. On synthetic speech that measured about
    /// +5 dB in the band the driver can actually reproduce.
    private enum Loudness {
        /// A small driver in a padded box reproduces almost nothing below this, so the amp only
        /// wastes power and cone excursion down there. Filtering it frees peak headroom for the
        /// 1-4 kHz band that carries intelligibility. Lower it if you fit a bigger speaker.
        static let highPassHz: Float = 300
        /// Peak ceiling, in Int16 counts, a shade under full scale.
        static let ceiling: Float = 29_000
        /// Compression threshold as a fraction of `ceiling` (0.25 is -12 dB).
        static let thresholdFraction: Float = 0.25
        /// Compression ratio above the threshold. High enough to be close to limiting; pushing
        /// further measured well under a dB of gain and starts to sound squashed.
        static let ratio: Float = 20
        /// Cap on total gain, so a near-silent render isn't amplified into its own artifacts.
        /// It has to apply to the whole chain, not one stage, or the makeup below sidesteps it.
        static let maxBoost: Float = 8
        /// Look-ahead in samples (2 ms), so gain is already down when a peak lands.
        static let lookAhead = 32
        /// Release. Short values level one syllable against the next, which is where the loudness
        /// actually comes from; longer ones measured consistently worse.
        static let releaseSeconds: Float = 0.06
    }

    /// Trims leading/trailing silence (so taps feel instant), then runs the loudness chain so the
    /// collar carries over outdoor noise. See `Loudness` for the tuning.
    nonisolated static func trimAndNormalize(_ samples: [Int16]) -> [Int16] {
        let threshold: Int16 = 400
        let pad = Int(MuLaw.sampleRate * 0.03)
        guard let first = samples.firstIndex(where: { abs(Int32($0)) > threshold }),
              let last = samples.lastIndex(where: { abs(Int32($0)) > threshold })
        else { return [] }
        let slice = samples[max(0, first - pad)...min(samples.count - 1, last + pad)]

        var audio = highPassed(slice.map { Float($0) })
        let rawPeak = peak(audio)
        guard rawPeak > 0 else { return [] }

        // Normalize first so the threshold means the same thing on every clip, compress, then
        // hand back the headroom compression freed up.
        scale(&audio, by: Loudness.ceiling / rawPeak)
        compress(&audio)
        let compressed = peak(audio)
        if compressed > 0 { scale(&audio, by: Loudness.ceiling / compressed) }

        // Both normalizations land on `ceiling`, so total gain is exactly ceiling/rawPeak. Pull
        // it back if that came out over budget.
        let allowed = min(Loudness.ceiling, rawPeak * Loudness.maxBoost)
        if allowed < Loudness.ceiling { scale(&audio, by: allowed / Loudness.ceiling) }

        return audio.map { Int16(clamping: Int32($0.rounded())) }
    }

    private nonisolated static func peak(_ x: [Float]) -> Float {
        x.reduce(0) { max($0, abs($1)) }
    }

    private nonisolated static func scale(_ x: inout [Float], by gain: Float) {
        guard gain != 1 else { return }
        for i in x.indices { x[i] *= gain }
    }

    /// Second-order Butterworth high-pass (RBJ cookbook coefficients), direct form I.
    private nonisolated static func highPassed(_ x: [Float]) -> [Float] {
        let w0 = 2 * Float.pi * Loudness.highPassHz / Float(MuLaw.sampleRate)
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * 0.70710678)  // Q = 1/sqrt(2), maximally flat
        let a0 = 1 + alpha
        let b0 = (1 + cosW0) / 2 / a0
        let b1 = -(1 + cosW0) / a0
        let b2 = b0
        let a1 = -2 * cosW0 / a0
        let a2 = (1 - alpha) / a0

        var y = [Float](repeating: 0, count: x.count)
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in x.indices {
            let out = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x[i]
            y2 = y1; y1 = out
            y[i] = out
        }
        return y
    }

    /// Downward compression above `Loudness.thresholdFraction` of the ceiling. The look-ahead
    /// means gain is already down when a transient lands, so there's none of the grit a plain
    /// clipper adds, and the quick release is what levels one syllable against the next.
    private nonisolated static func compress(_ x: inout [Float]) {
        let threshold = Loudness.ceiling * Loudness.thresholdFraction
        let release = 1 - exp(-1 / (Loudness.releaseSeconds * Float(MuLaw.sampleRate)))
        var gain: Float = 1
        for i in x.indices {
            // Reads stay ahead of writes, so the sidechain always sees uncompressed samples. The
            // window scan is O(lookAhead) per sample, which is nothing for a few seconds of audio
            // rendered off the audio path.
            let ahead = x[i..<min(i + Loudness.lookAhead, x.count)].reduce(0) { max($0, abs($1)) }
            let desired = ahead > threshold
                ? (threshold + (ahead - threshold) / Loudness.ratio) / ahead
                : 1
            // Attack is instant: the look-ahead already saw this peak coming.
            gain = desired < gain ? desired : gain + (desired - gain) * release
            x[i] *= gain
        }
    }
}

/// Resamples whatever the synthesizer hands us (often 22.05 kHz Float32) to 16 kHz Int16 mono.
private final class PCMCollector {
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: MuLaw.sampleRate,
                                       channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var samples: [Int16] = []

    func append(_ buffer: AVAudioPCMBuffer) throws {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { throw RenderError.conversionFailed }
        try convert(converter, input: buffer)
    }

    func finish() throws -> [Int16] {
        if let converter { try convert(converter, input: nil) }
        return samples
    }

    /// `input == nil` flushes the converter's tail.
    private func convert(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?) throws {
        let ratio = target.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + 1024
        var supplied = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw RenderError.conversionFailed
            }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if let input, !supplied {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            if out.frameLength > 0, let channel = out.int16ChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            }
            // .haveData means the output filled up and there's more; anything else means done.
            guard status == .haveData else { return }
        }
    }
}

/// Runs a closure at most once, from any thread.
private final class Once {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
