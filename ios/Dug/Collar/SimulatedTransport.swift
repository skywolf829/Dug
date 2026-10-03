import Foundation

/// A pretend collar that lives inside the app and speaks the same byte protocol as the
/// firmware, playing clips through the phone speaker. Lets the whole app — uploads, flow
/// control, playback — be exercised before the hardware is built.
final class SimulatedTransport: CollarTransport {
    weak var delegate: CollarTransportDelegate?
    let maxDataChunk = 182
    let canSendData = true

    private struct Clip {
        var tag: UInt32
        var name: String
        var audio: Data
    }

    private struct Upload {
        var id: UInt8
        var size: Int
        var tag: UInt32
        var name: String
        var playWhenDone: Bool
        var received = Data()
        var lastAck = 0
    }

    private let maxVolume: UInt8 = 170
    private let capacity = 1_900_000
    private var clips: [UInt8: Clip] = [:]
    private var volume: UInt8 = 120
    private var upload: Upload?
    private var playingID: UInt8?
    private var running = false
    private let player = ClipPlayer()

    func start() {
        running = true
        report(.searching)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.running else { return }
            self.report(.connected)
        }
    }

    func stop() {
        running = false
        player.stop()
        playingID = nil
        upload = nil
        report(.off)
    }

    func sendControl(_ data: Data) {
        guard running, let command = DugProtocol.Command(data) else { return }
        switch command {
        case .play(let id): play(id)
        case .stop: stopPlayback()
        case .setVolume(let v):
            volume = min(v, maxVolume)
            emitState()
        case .delete(let id):
            if playingID == id { stopPlayback() }
            if clips.removeValue(forKey: id) == nil { emit(.error(DugProtocol.ErrorCode.noSuchClip.rawValue)) }
            emitState()
        case .list:
            emitState()
            for (id, clip) in clips.sorted(by: { $0.key < $1.key }) {
                emit(.clip(id: id, size: clip.audio.count, tag: clip.tag, name: clip.name))
            }
            emit(.listEnd)
        case .uploadBegin(let id, let size, let tag, let playWhenDone, let name):
            guard upload == nil else { return emit(.uploadError(DugProtocol.ErrorCode.busy.rawValue)) }
            guard size > 0, size <= DugProtocol.maxClipBytes else {
                return emit(.uploadError(DugProtocol.ErrorCode.badCommand.rawValue))
            }
            guard size <= freeBytes else { return emit(.uploadError(DugProtocol.ErrorCode.flashFull.rawValue)) }
            stopPlayback()
            upload = Upload(id: id, size: size, tag: tag, name: name, playWhenDone: playWhenDone)
            emit(.uploadAck(0))
        case .uploadAbort:
            if upload != nil {
                upload = nil
                emit(.uploadError(DugProtocol.ErrorCode.badCommand.rawValue))
            }
        }
    }

    func sendData(_ data: Data) {
        guard running, var up = upload else { return }
        up.received.append(data)
        if up.received.count > up.size {
            upload = nil
            return emit(.uploadError(DugProtocol.ErrorCode.badCommand.rawValue))
        }
        if up.received.count == up.size {
            upload = nil
            clips[up.id] = Clip(tag: up.tag, name: up.name, audio: up.received)
            emit(.uploadAck(up.size))
            emit(.uploadDone(up.id))
            emit(.clip(id: up.id, size: up.size, tag: up.tag, name: up.name))
            emitState()
            if up.playWhenDone { play(up.id) }
            return
        }
        if up.received.count - up.lastAck >= DugProtocol.uploadAckEvery {
            up.lastAck = up.received.count
            emit(.uploadAck(up.lastAck))
        }
        upload = up
    }

    // MARK: - Private

    private var freeBytes: Int { capacity - clips.values.reduce(0) { $0 + $1.audio.count } }

    private func play(_ id: UInt8) {
        guard upload == nil else { return emit(.error(DugProtocol.ErrorCode.busy.rawValue)) }
        guard let clip = clips[id] else { return emit(.error(DugProtocol.ErrorCode.noSuchClip.rawValue)) }
        stopPlayback()
        playingID = id
        emit(.playStarted(id))
        player.play(clip.audio, gain: Float(volume) / 255) { [weak self] in
            guard let self, self.playingID == id else { return }
            self.playingID = nil
            self.emit(.playStopped(id))
        }
    }

    private func stopPlayback() {
        guard let id = playingID else { return }
        player.stop()
        playingID = nil
        emit(.playStopped(id))
    }

    private func emitState() {
        emit(.state(volume: volume, maxVolume: maxVolume, playing: playingID, freeKB: freeBytes / 1024))
    }

    /// Delivered asynchronously, like real notifications, so callers never see re-entrancy.
    private func emit(_ event: DugProtocol.Event) {
        let bytes = event.encoded
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            MainActor.assumeIsolated { self.delegate?.transport(didReceive: bytes) }
        }
    }

    private func report(_ state: LinkState) {
        MainActor.assumeIsolated { delegate?.transport(didChange: state) }
    }
}
