import AVFoundation
import SwiftUI

enum PhraseStatus {
    case ready, needsUpload, unknown
}

/// Ties the soundboard and the collar together.
@MainActor
final class AppModel: ObservableObject {
    /// Soundboard order, by phrase id. Phrases missing from it go at the end.
    @Published private(set) var order: [UInt8] { didSet { save(order, key: Keys.order) } }
    @Published var mode: CollarMode {
        didSet {
            save(mode, key: Keys.mode)
            collar.setMode(mode)
        }
    }
    /// e.g. "Teaching Dug 3 of 6…" while clips upload.
    @Published private(set) var activity: String?
    @Published var errorMessage: String?

    let collar: Collar
    /// Clips actually bundled in this build, with their tags (hashed once, off the file).
    private let available: [(phrase: Phrase, tag: UInt32)]
    private let previewPlayer = ClipPlayer()
    private var isSyncing = false

    private enum Keys {
        static let order = "phraseOrder"
        static let mode = "collarMode"
    }

    init() {
        available = Phrase.all.filter { $0.url != nil }.map { ($0, $0.tag) }
        order = Self.load([UInt8].self, key: Keys.order) ?? []
        let mode = Self.load(CollarMode.self, key: Keys.mode) ?? .simulator
        self.mode = mode
        collar = Collar(mode: mode)

        // Play through the speaker even with the ring/silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])

        collar.onClipsLoaded = { [weak self] in
            Task { await self?.syncAll() }
        }
    }

    var phrases: [Phrase] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return available.map(\.phrase).enumerated()
            .sorted { (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset) }
            .map(\.element)
    }

    /// Moves `id` into `target`'s spot on the soundboard.
    func move(_ id: UInt8, to target: UInt8) {
        var ids = phrases.map(\.id)
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        order = ids
    }

    func status(of phrase: Phrase) -> PhraseStatus {
        guard collar.isConnected else { return .unknown }
        return collar.clips[phrase.id]?.tag == tag(of: phrase) ? .ready : .needsUpload
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

    /// Plays the collar-quality audio on the phone, no collar needed.
    func preview(_ phrase: Phrase) async {
        await perform(nil) {
            self.previewPlayer.play(try await self.render(phrase))
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

        // Clear out anything else, like speech clips from earlier versions of the app.
        if !available.isEmpty {
            let known = Set(phrases.map(\.id))
            for id in collar.clips.keys where !known.contains(id) { collar.delete(id) }
        }

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

    // MARK: - Private

    private func tag(of phrase: Phrase) -> UInt32? {
        available.first { $0.phrase.id == phrase.id }?.tag
    }

    private func render(_ phrase: Phrase) async throws -> Data {
        guard let url = phrase.url else { throw RenderError.noAudio }
        return try await Task.detached { try ClipRenderer.render(url) }.value
    }

    private func upload(_ phrase: Phrase, playWhenDone: Bool) async throws {
        try await collar.upload(id: phrase.id, name: phrase.title, tag: tag(of: phrase) ?? 0,
                                audio: render(phrase), playWhenDone: playWhenDone)
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
