import SwiftUI

struct PhraseEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// nil = new phrase.
    let phrase: Phrase?
    @State private var title = ""
    @State private var emoji = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Button") {
                    TextField("Title", text: $title)
                    TextField("Emoji", text: $emoji)
                }
                Section {
                    TextField("What Dug says", text: $text, axis: .vertical)
                        .lineLimit(3 ... 8)
                    Button {
                        Task { await model.preview(text) }
                    } label: {
                        Label("Preview on phone", systemImage: "ear")
                    }
                    .disabled(text.isEmpty)
                } header: {
                    Text("Speech")
                } footer: {
                    Text("Tip: punctuation shapes delivery. “Oh boy! Oh boy!” sounds more excited than “oh boy oh boy”.")
                }
            }
            .navigationTitle(phrase == nil ? "New phrase" : "Edit phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(title.isEmpty || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let phrase else { return }
                title = phrase.title
                emoji = phrase.emoji
                text = phrase.text
            }
        }
    }

    private func save() {
        let emoji = String(emoji.prefix(2))
        if var phrase {
            phrase.title = title
            phrase.emoji = emoji.isEmpty ? "💬" : emoji
            phrase.text = text
            model.update(phrase)
        } else {
            _ = model.addPhrase(title: title, emoji: emoji, text: text)
        }
        dismiss()
    }
}
