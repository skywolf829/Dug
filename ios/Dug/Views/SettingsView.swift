import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var collar: Collar
    @Environment(\.dismiss) private var dismiss
    @State private var personalVoiceStatus = AVSpeechSynthesizer.personalVoiceAuthorizationStatus

    var body: some View {
        NavigationStack {
            Form {
                collarSection
                voiceSection
                personalVoiceSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var collarSection: some View {
        Section {
            Picker("Collar", selection: $model.mode) {
                ForEach(CollarMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            LabeledContent("Status", value: collar.link.label)
            if let freeKB = collar.freeKB {
                LabeledContent("Space left", value: "\(freeKB) KB (~\(freeKB / 16) s)")
            }
            LabeledContent("Clips stored", value: "\(collar.clips.count)")

            Button("Reconnect") { collar.reconnect() }
            Button("Re-teach every phrase") {
                Task { await model.syncAll(force: true) }
            }
            .disabled(!collar.isConnected)
        } header: {
            Text("Collar")
        } footer: {
            Text("The simulator plays clips through this phone exactly as the collar would, so you can try everything before the hardware is built.")
        }
    }

    private var voiceSection: some View {
        Section {
            NavigationLink {
                VoicePicker(selection: $model.voice.voiceIdentifier)
            } label: {
                LabeledContent("Voice", value: model.voice.voice?.name ?? "Default")
            }
            VStack(alignment: .leading) {
                Text("Pitch: \(model.voice.pitch, specifier: "%.2f")×")
                Slider(value: $model.voice.pitch, in: 0.5 ... 2.0, step: 0.05)
            }
            VStack(alignment: .leading) {
                Text("Speed: \(model.voice.rate, specifier: "%.2f")")
                Slider(value: $model.voice.rate, in: 0.3 ... 0.7, step: 0.01)
            }
            Button {
                Task { await model.preview("Hi there! My name is Dug. I have just met you, and I love you.") }
            } label: {
                Label("Test voice", systemImage: "ear")
            }
        } header: {
            Text("Dug's voice")
        } footer: {
            Text("Changing the voice re-teaches every phrase the next time the collar connects. For better voices, download “Enhanced” or “Premium” ones in iOS Settings → Accessibility → Spoken Content → Voices.")
        }
    }

    private var personalVoiceSection: some View {
        Section {
            switch personalVoiceStatus {
            case .authorized:
                Label("Personal Voice is allowed. Pick it in Voice above.", systemImage: "checkmark.circle")
            case .denied:
                Text("Personal Voice access was denied. Turn it on in iOS Settings → Accessibility → Personal Voice → Allow Apps to Request to Use.")
            case .unsupported:
                Text("Personal Voice isn't supported on this device.")
            default:
                Button("Allow Personal Voice") {
                    AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                        DispatchQueue.main.async { personalVoiceStatus = status }
                    }
                }
            }
        } header: {
            Text("Personal Voice")
        } footer: {
            Text("Record your own voice in iOS Settings → Accessibility → Personal Voice (about 15 minutes of reading, then it trains overnight while charging). Read the prompts in your best Dug voice and the collar will sound like you-as-Dug.")
        }
    }
}

private struct VoicePicker: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: String?
    private let voices = AVSpeechSynthesisVoice.dugCandidates

    var body: some View {
        List {
            Button {
                selection = nil
            } label: {
                row(name: "System default", detail: "en-US", selected: selection == nil)
            }
            ForEach(voices, id: \.identifier) { voice in
                Button {
                    selection = voice.identifier
                    Task { await model.preview("Hi there! I am Dug.") }
                } label: {
                    row(name: voice.name,
                        detail: voice.isPersonalVoice ? "Personal Voice" : "\(voice.language) · \(voice.qualityLabel)",
                        selected: selection == voice.identifier)
                }
            }
        }
        .navigationTitle("Voice")
    }

    private func row(name: String, detail: String, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Theme.gold) }
        }
    }
}
