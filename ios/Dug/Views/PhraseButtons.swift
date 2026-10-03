import SwiftUI

struct PhraseButton: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var collar: Collar
    let phrase: Phrase
    var onEdit: () -> Void
    @State private var tapped = 0

    var body: some View {
        Button {
            tapped += 1
            Task { await model.play(phrase) }
        } label: {
            VStack(spacing: 6) {
                Text(phrase.emoji).font(.system(size: 34))
                Text(phrase.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .padding(8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.gold, lineWidth: isPlaying ? 3 : 0)
            }
            .overlay(alignment: .topTrailing) {
                if model.status(of: phrase) == .needsUpload {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: tapped)
        .contextMenu {
            Text(phrase.text)
            Button {
                Task { await model.preview(phrase.text) }
            } label: { Label("Preview on phone", systemImage: "iphone.gen3.radiowaves.left.and.right") }
            if !phrase.isPreset {
                Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { model.delete(phrase) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private var isPlaying: Bool { collar.playingID == phrase.id }
}

/// Type anything and Dug says it.
struct SayItCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var collar: Collar
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            TextField("Make Dug say…", text: $text, axis: .vertical)
                .lineLimit(1 ... 4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(say)

            HStack {
                Button {
                    Task { await model.preview(text) }
                } label: {
                    Label("Preview", systemImage: "ear")
                }
                .buttonStyle(.bordered)

                Button {
                    _ = model.addPhrase(title: String(text.prefix(24)), emoji: "💬", text: text)
                    text = ""
                } label: {
                    Label("Save", systemImage: "plus.square.on.square")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(action: say) {
                    Label("Say it", systemImage: "waveform")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!collar.isConnected)
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
        }
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func say() {
        let line = text
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        focused = false
        Task { await model.say(line) }
    }
}
