import SwiftUI

struct PhraseButton: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var collar: Collar
    let phrase: Phrase
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
            Button {
                Task { await model.preview(phrase) }
            } label: { Label("Preview on phone", systemImage: "iphone.gen3.radiowaves.left.and.right") }
        }
    }

    private var isPlaying: Bool { collar.playingID == phrase.id }
}
