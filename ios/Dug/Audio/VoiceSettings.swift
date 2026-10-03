import AVFoundation

/// How Dug sounds. Everything here feeds into each clip's fingerprint, so changing the voice
/// marks every phrase as needing a re-upload.
struct VoiceSettings: Codable, Equatable {
    /// `AVSpeechSynthesisVoice.identifier`; nil = system default English voice.
    var voiceIdentifier: String?
    /// 0.5...2.0. Dug is a little higher than a person.
    var pitch: Float = 1.35
    /// AVSpeechUtterance rate, 0...1 (0.5 is normal).
    var rate: Float = 0.52

    var voice: AVSpeechSynthesisVoice? {
        voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            // iOS's own en-US default is often the "super-compact" voice; prefer the best installed one.
            ?? AVSpeechSynthesisVoice.dugCandidates.first { !$0.isPersonalVoice && $0.language == "en-US" }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Stable across launches and devices (unlike `hashValue`), so both phones agree on
    /// whether a clip on the collar is current.
    func fingerprint(for text: String) -> UInt32 {
        let key = "\(text)|\(voiceIdentifier ?? "default")|\(String(format: "%.2f|%.2f", pitch, rate))"
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return hash
    }
}

extension AVSpeechSynthesisVoice {
    var isPersonalVoice: Bool { voiceTraits.contains(.isPersonalVoice) }

    var qualityLabel: String {
        switch quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Default"
        }
    }

    /// English voices, best first, with Personal Voices at the top.
    static var dugCandidates: [AVSpeechSynthesisVoice] {
        speechVoices()
            .filter { $0.isPersonalVoice || $0.language.hasPrefix("en") }
            .sorted {
                if $0.isPersonalVoice != $1.isPersonalVoice { return $0.isPersonalVoice }
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                return $0.name < $1.name
            }
    }
}
