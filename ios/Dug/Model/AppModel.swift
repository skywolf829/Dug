import AVFoundation
import SwiftUI

enum PhraseStatus {
    case ready, needsUpload, unknown
}

/// Ties the soundboard, the voice, and the collar together.
@MainActor
final class AppModel: ObservableObject {
    @Published var customPhrases: [Phrase] { didSet { save(customPhrases, key: Keys.phrases) } }
    @Published var voice: VoiceSettings { didSet { save(voice, key: Keys.voice) } }
    @Published var mode: CollarMode {
        didSet {
            save(mode, key: Keys.mode)
            collar.setMode(mode)
        }
    }
    /// e.g. "Teaching Dug 3 of 12…" while presets upload.
    @Published private(set) var activity: String?
    @Published var errorMessage: String?

    let collar: Collar
    private let renderer = SpeechRenderer()
    private let previewPlayer = ClipPlayer()
    private var isSyncing = false

    private enum Keys {
        static let phrases = "customPhrases"
        static let voice = "voiceSettings"
        static let mode = "collarMode"
    }

    init() {
        customPhrases = Self.load([Phrase].self, key: Keys.phrases) ?? []
        voice = Self.load(VoiceSettings.self, key: Keys.voice) ?? VoiceSettings()
        let mode = Self.load(CollarMode.self, key: Keys.mode) ?? .simulator
        self.mode = mode
        collar = Collar(mode: mode)

        // Play through the speaker even with the ring/silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])

        collar.onClipsLoaded = { [weak self] in
            Task { await self?.syncAll() }
        }
    }

    var phrases: [Phrase] { Phrase.presets + customPhrases }

    /// Clips on the collar that this phone has no button for (e.g. added from the other phone).
    var otherCollarClips: [CollarClip] {
        let known = Set(phrases.map(\.id))
        return collar.clips.values
            .filter { !known.contains($0.id) && $0.id != DugProtocol.scratchClipID }
            .sorted { $0.id < $1.id }
    }

    func status(of phrase: Phrase) -> PhraseStatus {
        guard collar.isConnected else { return .unknown }
        return collar.clips[phrase.id]?.tag == voice.fingerprint(for: phrase.text) ? .ready : .needsUpload
    }

    var pendingCount: Int { phrases.filter { status(of: $0) == .needsUpload }.count }

    // MARK: - Actions

    /// Plays the phrase on the collar, uploading it first if the collar doesn't have it yet.
    func play(_ phrase: Phrase) async {
        if status(of: phrase) == .ready {
            collar.play(phrase.id)
            return
        }
        await perform("Teaching Dug “\(phrase.title)”…") {
            try await self.upload(phrase, playWhenDone: true)
        }
    }

    /// Synthesizes `text` and has Dug say it right away.
    func say(_ text: String) async {
        await perform("Dug is thinking…") {
            let audio = try await self.renderer.render(text, voice: self.voice)
            try await self.collar.upload(id: DugProtocol.scratchClipID, name: String(text.prefix(40)),
                                         tag: 0, audio: audio, playWhenDone: true)
        }
    }

    /// Plays the collar-quality audio on the phone, no collar needed.
    func preview(_ text: String) async {
        await perform(nil) {
            let audio = try await self.renderer.render(text, voice: self.voice)
            self.previewPlayer.play(audio)
        }
    }

    /// Uploads every phrase the collar is missing (or has an outdated version of).
    func syncAll(force: Bool = false) async {
        guard collar.isConnected, !isSyncing else {
            log.info("sync skipped (connected: \(self.collar.isConnected), syncing: \(self.isSyncing))")
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        let todo = phrases.filter { force || status(of: $0) == .needsUpload }
        log.info("sync: \(todo.count) phrase(s) to upload")
        for (i, phrase) in todo.enumerated() {
            activity = "Teaching Dug \(i + 1) of \(todo.count)…"
            do {
                try await upload(phrase, playWhenDone: false)
            } catch {
                log.error("sync failed on \(phrase.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
                break
            }
        }
        activity = nil
    }

    // MARK: - Library

    func addPhrase(title: String, emoji: String, text: String) -> Phrase? {
        let used = Set(phrases.map(\.id)).union(collar.clips.keys)
        guard let id = (DugProtocol.firstCustomClipID ..< DugProtocol.scratchClipID).first(where: { !used.contains($0) })
        else {
            errorMessage = "Dug already knows too many phrases. Delete one first."
            return nil
        }
        let phrase = Phrase(id: id, title: title, emoji: emoji.isEmpty ? "💬" : emoji, text: text)
        customPhrases.append(phrase)
        Task { await syncAll() }
        return phrase
    }

    func update(_ phrase: Phrase) {
        guard let i = customPhrases.firstIndex(where: { $0.id == phrase.id }) else { return }
        customPhrases[i] = phrase
        Task { await syncAll() }
    }

    func delete(_ phrase: Phrase) {
        customPhrases.removeAll { $0.id == phrase.id }
        if collar.isConnected { collar.delete(phrase.id) }
    }

    // MARK: - Private

    private func upload(_ phrase: Phrase, playWhenDone: Bool) async throws {
        let audio = try await renderer.render(phrase.text, voice: voice)
        try await collar.upload(id: phrase.id, name: phrase.title, tag: voice.fingerprint(for: phrase.text),
                                audio: audio, playWhenDone: playWhenDone)
    }

    private func perform(_ message: String?, _ work: @escaping () async throws -> Void) async {
        if let message { activity = message }
        defer { if message != nil { activity = nil } }
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
