import AVFoundation

enum RenderError: LocalizedError {
    case emptyText
    case noAudio
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .emptyText: "There's nothing to say."
        case .noAudio: "The voice didn't produce any audio. Try another voice in Settings."
        case .conversionFailed: "Couldn't convert the speech audio."
        }
    }
}

/// Turns text into collar-ready audio entirely on device: AVSpeechSynthesizer renders to
/// buffers (instead of the speaker), which are resampled to 16 kHz mono, trimmed, normalized,
/// and mu-law encoded.
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
        }
    }

    /// Trims leading/trailing silence (so taps feel instant) and boosts quiet voices so the
    /// small collar speaker gets the most out of its range.
    nonisolated static func trimAndNormalize(_ samples: [Int16]) -> [Int16] {
        let threshold: Int16 = 400
        let pad = Int(MuLaw.sampleRate * 0.03)
        guard let first = samples.firstIndex(where: { abs(Int32($0)) > threshold }),
              let last = samples.lastIndex(where: { abs(Int32($0)) > threshold })
        else { return [] }
        let slice = samples[max(0, first - pad)...min(samples.count - 1, last + pad)]

        let peak = slice.map { abs(Int32($0)) }.max() ?? 1
        let gain = min(Float(29_000) / Float(max(peak, 1)), 4)
        return slice.map { Int16(clamping: Int32((Float($0) * gain).rounded())) }
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
