import SwiftUI

/// Connection, volume, and upload progress at a glance.
struct CollarCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var collar: Collar

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: statusColor, radius: collar.isConnected ? 4 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(collar.mode == .simulator ? "Simulated collar" : "Dug's collar")
                        .font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if collar.playingID != nil {
                    Button { collar.stopPlaying() } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                }
            }

            HStack {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: volumeBinding, in: 0 ... Double(collar.maxVolume))
                    .disabled(!collar.isConnected)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }

            if let activity = model.activity {
                VStack(alignment: .leading, spacing: 4) {
                    Text(activity).font(.caption)
                    if let progress = collar.uploadProgress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            } else if model.pendingCount > 0 {
                Button {
                    Task { await model.syncAll() }
                } label: {
                    Label("Teach Dug \(model.pendingCount) phrase\(model.pendingCount == 1 ? "" : "s")",
                          systemImage: "arrow.down.circle")
                        .font(.subheadline)
                }
            }
        }
        .padding()
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var subtitle: String {
        guard collar.isConnected else { return collar.link.label }
        if let freeKB = collar.freeKB {
            return "Connected · \(freeKB / 16)s of space left"
        }
        return "Connected"
    }

    private var statusColor: Color {
        switch collar.link {
        case .connected: .green
        case .searching, .connecting: .orange
        case .off, .unavailable: .red
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { Double(collar.volume) }, set: { collar.setVolume(UInt8($0)) })
    }
}
