import CoreBluetooth
import Foundation

/// Wire protocol shared with `firmware/DugCollar/Protocol.h`. See docs/PROTOCOL.md.
enum DugProtocol {
    static let serviceUUID = CBUUID(string: "6E1D0001-D0C0-4B1A-9C55-55505F444F47")
    static let controlUUID = CBUUID(string: "6E1D0002-D0C0-4B1A-9C55-55505F444F47")
    static let dataUUID = CBUUID(string: "6E1D0003-D0C0-4B1A-9C55-55505F444F47")
    static let statusUUID = CBUUID(string: "6E1D0004-D0C0-4B1A-9C55-55505F444F47")

    /// "Say this now" clips overwrite this slot.
    static let scratchClipID: UInt8 = 255
    /// Preset phrases use 1..<32; user phrases are allocated from here up.
    static let firstCustomClipID: UInt8 = 32
    static let maxNameBytes = 40
    static let maxClipBytes = 30 * 16_000
    /// Max unacknowledged upload bytes in flight. The collar's receive ring is 8 KB.
    static let uploadWindow = 4096
    static let uploadAckEvery = 1024

    enum ErrorCode: UInt8, Error, CustomStringConvertible {
        case busy = 1, noSuchClip, flashFull, badCommand, overflow, fileSystem

        var description: String {
            switch self {
            case .busy: "The collar is busy with another upload."
            case .noSuchClip: "That clip isn't on the collar."
            case .flashFull: "The collar's memory is full."
            case .badCommand: "The collar didn't understand that."
            case .overflow: "Upload went too fast and got dropped."
            case .fileSystem: "The collar had a storage error."
            }
        }
    }

    enum Command: Equatable {
        case play(UInt8)
        case stop
        case setVolume(UInt8)
        case delete(UInt8)
        case list
        case uploadBegin(id: UInt8, size: Int, tag: UInt32, playWhenDone: Bool, name: String)
        case uploadAbort

        var encoded: Data {
            switch self {
            case .play(let id): return Data([0x01, id])
            case .stop: return Data([0x02])
            case .setVolume(let v): return Data([0x03, v])
            case .delete(let id): return Data([0x04, id])
            case .list: return Data([0x05])
            case .uploadBegin(let id, let size, let tag, let play, let name):
                var d = Data([0x10, id])
                d.appendLE(UInt32(size))
                d.appendLE(tag)
                d.append(play ? 0x01 : 0x00)
                d.append(Data(name.utf8.prefix(DugProtocol.maxNameBytes)))
                return d
            case .uploadAbort: return Data([0x11])
            }
        }

        init?(_ data: Data) {
            let b = [UInt8](data)
            guard let op = b.first else { return nil }
            switch op {
            case 0x01 where b.count >= 2: self = .play(b[1])
            case 0x02: self = .stop
            case 0x03 where b.count >= 2: self = .setVolume(b[1])
            case 0x04 where b.count >= 2: self = .delete(b[1])
            case 0x05: self = .list
            case 0x10 where b.count >= 11:
                self = .uploadBegin(id: b[1], size: Int(b.u32(at: 2)), tag: b.u32(at: 6),
                                    playWhenDone: b[10] & 1 != 0,
                                    name: String(decoding: b[11...], as: UTF8.self))
            case 0x11: self = .uploadAbort
            default: return nil
            }
        }
    }

    enum Event: Equatable {
        case state(volume: UInt8, maxVolume: UInt8, playing: UInt8?, freeKB: Int)
        case clip(id: UInt8, size: Int, tag: UInt32, name: String)
        case listEnd
        case uploadAck(Int)
        case uploadDone(UInt8)
        case uploadError(UInt8)
        case playStarted(UInt8)
        case playStopped(UInt8)
        case error(UInt8)

        var encoded: Data {
            switch self {
            case .state(let v, let maxV, let playing, let freeKB):
                return Data([0x80, v, maxV, playing ?? 0, UInt8(freeKB & 0xFF), UInt8(freeKB >> 8 & 0xFF)])
            case .clip(let id, let size, let tag, let name):
                var d = Data([0x81, id])
                d.appendLE(UInt32(size))
                d.appendLE(tag)
                d.append(Data(name.utf8.prefix(DugProtocol.maxNameBytes)))
                return d
            case .listEnd: return Data([0x82, 0])
            case .uploadAck(let n):
                var d = Data([0x90])
                d.appendLE(UInt32(n))
                return d
            case .uploadDone(let id): return Data([0x91, id])
            case .uploadError(let e): return Data([0x92, e])
            case .playStarted(let id): return Data([0xA0, id])
            case .playStopped(let id): return Data([0xA1, id])
            case .error(let e): return Data([0xEE, e])
            }
        }

        init?(_ data: Data) {
            let b = [UInt8](data)
            guard let op = b.first else { return nil }
            switch op {
            case 0x80 where b.count >= 6:
                self = .state(volume: b[1], maxVolume: b[2], playing: b[3] == 0 ? nil : b[3],
                              freeKB: Int(b[4]) | Int(b[5]) << 8)
            case 0x81 where b.count >= 10:
                self = .clip(id: b[1], size: Int(b.u32(at: 2)), tag: b.u32(at: 6),
                             name: String(decoding: b[10...], as: UTF8.self))
            case 0x82: self = .listEnd
            case 0x90 where b.count >= 5: self = .uploadAck(Int(b.u32(at: 1)))
            case 0x91 where b.count >= 2: self = .uploadDone(b[1])
            case 0x92 where b.count >= 2: self = .uploadError(b[1])
            case 0xA0 where b.count >= 2: self = .playStarted(b[1])
            case 0xA1 where b.count >= 2: self = .playStopped(b[1])
            case 0xEE where b.count >= 2: self = .error(b[1])
            default: return nil
            }
        }
    }
}

extension Data {
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

private extension Array where Element == UInt8 {
    func u32(at i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
