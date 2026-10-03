import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var collar: Collar
    @State private var showSettings = false
    @State private var editing: Phrase?
    @State private var addingPhrase = false
    @State private var dragging: UInt8?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CollarCard()

                    SayItCard()

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.phrases) { phrase in
                            PhraseButton(phrase: phrase, onEdit: { editing = phrase })
                                .opacity(dragging == phrase.id ? 0.4 : 1)
                                .onDrag {
                                    dragging = phrase.id
                                    return NSItemProvider(object: String(phrase.id) as NSString)
                                }
                                .onDrop(of: [.text], delegate: ReorderDropDelegate(target: phrase.id, model: model,
                                                                                   dragging: $dragging))
                        }
                    }
                    .animation(.default, value: model.order)
                    .onDrop(of: [.text], isTargeted: nil) { _ in
                        dragging = nil
                        return true
                    }

                    if !model.otherCollarClips.isEmpty {
                        otherClips
                    }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Dug")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addingPhrase = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(model).environmentObject(collar)
            }
            .sheet(isPresented: $addingPhrase) {
                PhraseEditor(phrase: nil).environmentObject(model)
            }
            .sheet(item: $editing) { phrase in
                PhraseEditor(phrase: phrase).environmentObject(model)
            }
            .alert("Ruh-roh", isPresented: errorBinding) {
                Button("OK") {}
            } message: {
                Text(model.errorMessage ?? collar.lastError ?? "")
            }
        }
    }

    private var otherClips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Also on the collar").font(.headline)
            ForEach(model.otherCollarClips) { clip in
                Button { collar.play(clip.id) } label: {
                    HStack {
                        Image(systemName: collar.playingID == clip.id ? "speaker.wave.2.fill" : "play.circle")
                        Text(clip.name.isEmpty ? "Clip \(clip.id)" : clip.name)
                        Spacer()
                        Text(String(format: "%.1fs", clip.duration)).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil || collar.lastError != nil },
            set: { if !$0 { model.errorMessage = nil; collar.lastError = nil } }
        )
    }
}

/// Hold a button, then drag it: the grid rearranges live as it passes over other buttons.
private struct ReorderDropDelegate: DropDelegate {
    let target: UInt8
    let model: AppModel
    @Binding var dragging: UInt8?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        model.move(dragging, to: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

#Preview {
    let model = AppModel()
    return ContentView().environmentObject(model).environmentObject(model.collar)
}
