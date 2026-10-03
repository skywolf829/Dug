import Foundation

/// G.711 mu-law: 8 bits per sample, ~14-bit dynamic range. Half the size of 16-bit PCM and
/// trivial for the collar to decode. The collar's decoder lives in firmware/DugCollar/AudioOut.cpp.
enum MuLaw {
    static let sampleRate: Double = 16_000

    private static let bias: Int32 = 0x84
    private static let clip: Int32 = 32_635

    static func encode(_ sample: Int16) -> UInt8 {
        var s = Int32(sample)
        let sign: Int32 = (s >> 8) & 0x80
        if sign != 0 { s = -s }
        s = min(s, clip) + bias
        var exponent: Int32 = 7
        var mask: Int32 = 0x4000
        while exponent > 0 && s & mask == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (s >> (exponent + 3)) & 0x0F
        return UInt8(truncatingIfNeeded: ~(sign | exponent << 4 | mantissa))
    }

    static func decode(_ byte: UInt8) -> Int16 {
        let u = Int32(~byte)
        var t = ((u & 0x0F) << 3) + bias
        t <<= (u & 0x70) >> 4
        return Int16(u & 0x80 != 0 ? bias - t : t - bias)
    }

    static func encode(_ samples: [Int16]) -> Data {
        Data(samples.map(encode))
    }

    static func decodeToFloat(_ data: Data) -> [Float] {
        data.map { Float(decode($0)) / 32_768 }
    }
}
