import Foundation

enum CollarMode: String, CaseIterable, Identifiable, Codable {
    case bluetooth
    case simulator

    var id: Self { self }
    var label: String { self == .bluetooth ? "Real collar" : "Simulator" }
}

/// What the collar reports about one stored clip.
struct CollarClip: Identifiable, Equatable {
    let id: UInt8
    var size: Int
    var tag: UInt32
    var name: String

    var duration: TimeInterval { Double(size) / MuLaw.sampleRate }
}

enum CollarError: LocalizedError {
    case notConnected
    case disconnected
    case timedOut
    case tooLong
    case collar(DugProtocol.ErrorCode)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Dug's collar isn't connected."
        case .disconnected: "Lost the collar mid-upload."
        case .timedOut: "The collar stopped responding."
        case .tooLong: "That's too long for the collar (30 seconds max)."
        case .collar(let code): code.description
        }
    }
}

/// The app's view of Dug's collar: speaks the protocol over whichever transport is active
/// and publishes the collar's state for the UI.
@MainActor
final class Collar: ObservableObject {
    @Published private(set) var mode: CollarMode
    @Published private(set) var link: LinkState = .off
    @Published private(set) var clips: [UInt8: CollarClip] = [:]
    @Published private(set) var playingID: UInt8?
    @Published private(set) var freeKB: Int?
    @Published private(set) var maxVolume: UInt8 = 255
    /// 0...255, as the collar knows it. Use `setVolume` to change.
    @Published private(set) var volume: UInt8 = 120
    /// Progress of the current upload, 0...1, or nil when idle.
    @Published private(set) var uploadProgress: Double?
    @Published var lastError: String?

    /// Called each time a full clip list arrives (on connect and on refresh).
    var onClipsLoaded: (() -> Void)?

    var isConnected: Bool { link == .connected }

    private var transport: CollarTransport
    private let uploads = SerialQueue()
    private var upload: UploadState?
    private var listing: Set<UInt8>?

    private struct UploadState {
        let audio: Data
        var ready = false
        var sent = 0
        var acked = 0
        var lastProgress = Date()
        let continuation: CheckedContinuation<Void, Error>
    }

    init(mode: CollarMode) {
        self.mode = mode
        transport = Self.makeTransport(mode)
        transport.delegate = self
        transport.start()
    }

    func setMode(_ newMode: CollarMode) {
        guard newMode != mode else { return }
        transport.stop()
        failUpload(CollarError.disconnected)
        clips = [:]
        playingID = nil
        freeKB = nil
        mode = newMode
        transport = Self.makeTransport(newMode)
        transport.delegate = self
        transport.start()
    }

    func reconnect() {
        transport.stop()
        transport.start()
    }

    // MARK: - Commands

    func play(_ id: UInt8) { send(.play(id)) }
    func stopPlaying() { send(.stop) }
    func refresh() {
        listing = []
        send(.list)
    }

    func delete(_ id: UInt8) {
        send(.delete(id))
        clips[id] = nil
    }

    func setVolume(_ value: UInt8) {
        let clamped = min(value, maxVolume)
        guard clamped != volume else { return }
        volume = clamped
        send(.setVolume(clamped))
    }

    /// Uploads mu-law audio into slot `id`. Uploads are queued and run one at a time.
    func upload(id: UInt8, name: String, tag: UInt32, audio: Data, playWhenDone: Bool) async throws {
        guard audio.count <= DugProtocol.maxClipBytes else { throw CollarError.tooLong }
        try await uploads.run {
            try await self.performUpload(id: id, name: name, tag: tag, audio: audio, playWhenDone: playWhenDone)
        }
    }

    // MARK: - Upload

    private func performUpload(id: UInt8, name: String, tag: UInt32, audio: Data, playWhenDone: Bool) async throws {
        guard isConnected else { throw CollarError.notConnected }
        uploadProgress = 0
        defer { uploadProgress = nil }

        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let up = self.upload else { continue }
                if Date().timeIntervalSince(up.lastProgress) > 6 {
                    self.send(.uploadAbort)
                    self.failUpload(CollarError.timedOut)
                }
            }
        }
        defer { watchdog.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            upload = UploadState(audio: Data(audio), continuation: continuation)
            send(.uploadBegin(id: id, size: audio.count, tag: tag, playWhenDone: playWhenDone, name: name))
        }
    }

    /// Streams as much as the window and the link allow.
    private func pump() {
        guard var up = upload, up.ready else { return }
        while up.sent < up.audio.count, transport.canSendData {
            let room = DugProtocol.uploadWindow - (up.sent - up.acked)
            let n = min(transport.maxDataChunk, up.audio.count - up.sent, room)
            guard n > 0 else { break }
            transport.sendData(up.audio.subdata(in: up.sent ..< up.sent + n))
            up.sent += n
        }
        upload = up
    }

    private func failUpload(_ error: Error) {
        guard let up = upload else { return }
        upload = nil
        up.continuation.resume(throwing: error)
    }

    private func send(_ command: DugProtocol.Command) {
        transport.sendControl(command.encoded)
    }

    private func handle(_ event: DugProtocol.Event) {
        switch event {
        case .state(let volume, let maxVolume, let playing, let freeKB):
            self.volume = volume
            self.maxVolume = maxVolume
            self.playingID = playing
            self.freeKB = freeKB

        case .clip(let id, let size, let tag, let name):
            clips[id] = CollarClip(id: id, size: size, tag: tag, name: name)
            listing?.insert(id)

        case .listEnd:
            if let seen = listing {
                clips = clips.filter { seen.contains($0.key) }
            }
            listing = nil
            onClipsLoaded?()

        case .uploadAck(let committed):
            guard var up = upload else { return }
            up.ready = true
            up.acked = committed
            up.lastProgress = Date()
            upload = up
            uploadProgress = Double(committed) / Double(max(up.audio.count, 1))
            pump()

        case .uploadDone:
            guard let up = upload else { return }
            upload = nil
            up.continuation.resume()

        case .uploadError(let code):
            failUpload(CollarError.collar(DugProtocol.ErrorCode(rawValue: code) ?? .badCommand))

        case .playStarted(let id):
            playingID = id

        case .playStopped(let id):
            if playingID == id { playingID = nil }

        case .error(let code):
            lastError = (DugProtocol.ErrorCode(rawValue: code) ?? .badCommand).description
        }
    }

    private static func makeTransport(_ mode: CollarMode) -> CollarTransport {
        switch mode {
        case .bluetooth: BLETransport()
        case .simulator: SimulatedTransport()
        }
    }
}

extension Collar: CollarTransportDelegate {
    func transport(didChange state: LinkState) {
        link = state
        if state == .connected {
            refresh()
        } else {
            playingID = nil
            failUpload(CollarError.disconnected)
        }
    }

    func transport(didReceive status: Data) {
        guard let event = DugProtocol.Event(status) else { return }
        handle(event)
    }

    func transportReadyToSend() {
        pump()
    }
}
