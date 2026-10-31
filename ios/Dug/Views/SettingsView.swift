import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var collar: Collar
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                collarSection
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
            Button("Re-teach every clip") {
                Task { await model.syncAll(force: true) }
            }
            .disabled(!collar.isConnected)
        } header: {
            Text("Collar")
        } footer: {
            Text("The simulator plays clips through this phone exactly as the collar would, so you can try everything before the hardware is built.")
        }
    }
}
