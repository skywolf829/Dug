import Foundation

/// A button on the soundboard. The `id` is also the clip slot on the collar.
struct Phrase: Identifiable, Codable, Equatable {
    var id: UInt8
    var title: String
    var emoji: String
    var text: String
    var isPreset = false

    static let squirrelID: UInt8 = 3  // also the collar's physical-button clip (firmware BUTTON_CLIP)

    /// Preset ids are fixed (1..<32) so both phones and the collar agree on them.
    static let presets: [Phrase] = [
        Phrase(id: 1, title: "Hi there", emoji: "👋", text: "Hi there!"),
        Phrase(id: 2, title: "I love you", emoji: "❤️",
               text: "My name is Dug. I have just met you, and I love you."),
        Phrase(id: squirrelID, title: "Squirrel!", emoji: "🐿️", text: "Squirrel!"),
        Phrase(id: 4, title: "My master", emoji: "🧓",
               text: "My master made me this collar. He is a good and smart master, and he made me this collar so that I may speak."),
        Phrase(id: 5, title: "Under porch", emoji: "🏠",
               text: "I was hiding under your porch because I love you."),
        Phrase(id: 6, title: "Can I keep you?", emoji: "🥺", text: "Can I keep you?"),
        Phrase(id: 7, title: "Point!", emoji: "👉", text: "Point!"),
        Phrase(id: 8, title: "Cone of shame", emoji: "🔺", text: "I do not like the cone of shame."),
        Phrase(id: 9, title: "Trick or treat", emoji: "🎃", text: "Trick or treat! I would like a treat, please."),
        Phrase(id: 10, title: "Happy Halloween", emoji: "👻", text: "Happy Halloween!"),
        Phrase(id: 11, title: "Good dog", emoji: "🦴", text: "I am a good dog. I am a very good dog."),
        Phrase(id: 12, title: "Oh boy", emoji: "🤩", text: "Oh boy! Oh boy! Oh boy!"),
        Phrase(id: 13, title: "Ranger!", emoji: "🎖️", text: "That is my ranger. She is the best ranger."),
        Phrase(id: 14, title: "Balloons", emoji: "🎈", text: "Your house is floating. I did not know houses could do that."),
    ].map { var p = $0; p.isPreset = true; return p }
}
