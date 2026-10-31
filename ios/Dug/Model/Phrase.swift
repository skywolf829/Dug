import Foundation

/// A button on the soundboard. The `id` is also the clip slot on the collar.
struct Phrase: Identifiable, Equatable {
    let id: UInt8
    let title: String
    let emoji: String
    /// Basename of an mp3 in ios/LocalClips, which is bundled into the app at build time.
    let file: String

    /// Ids are fixed so both phones and the collar agree on them. 3 is also the collar's
    /// physical-button clip (firmware BUTTON_CLIP).
    static let all = [
        Phrase(id: 1, title: "My name is Dug", emoji: "🐕", file: "my-name-is-dug"),
        Phrase(id: 2, title: "I love you", emoji: "❤️", file: "dug-met-you"),
        Phrase(id: 3, title: "Squirrel!", emoji: "🐿️", file: "squirrel"),
        Phrase(id: 4, title: "A ball!", emoji: "🎾", file: "oh-boy-oh-boy-a-ball"),
        Phrase(id: 5, title: "Seen a bird?", emoji: "🐦", file: "have-you-seen-a-bird"),
        Phrase(id: 6, title: "Cone of shame", emoji: "🔺", file: "i-do-not-like-the-cone-of-shame"),
        Phrase(id: 7, title: "My collar", emoji: "🎙️", file: "he-made-me-this-collar"),
    ]

    var url: URL? { Bundle.main.url(forResource: file, withExtension: "mp3", subdirectory: "Clips") }

    /// Identifies this clip's contents and processing, so the collar's copy can be checked
    /// (FNV-1a: stable across launches and devices, unlike `hashValue`).
    var tag: UInt32 {
        guard let url, let bytes = try? Data(contentsOf: url) else { return 0 }
        var hash: UInt32 = 2_166_136_261 &+ UInt32(ClipRenderer.version)
        for byte in bytes {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return hash
    }
}
