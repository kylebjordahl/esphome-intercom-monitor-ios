import SwiftUI

// Debugging / diagnostics screen for the audio engine.  Live call controls
// live on the main Devices page (see ConnectionRow); this view is intentionally
// limited to engine status and packet counters.
struct ActiveCallView: View {
    @EnvironmentObject private var session: IntercomSession
    @Environment(\.dismiss) private var dismiss

    // Poll audio packet counters every second so the UI reflects real traffic.
    @State private var packetsSent     = 0
    @State private var packetsReceived = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var statusDotColor: Color { session.audioStatus.isOK ? .green : .orange }

    var body: some View {
        NavigationStack {
            List {
                // ── Audio engine diagnostics ───────────────────────────────────
                Section("Audio Engine") {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusDotColor)
                                .frame(width: 8, height: 8)
                            Text(session.audioStatus.label)
                                .font(.caption)
                                .foregroundStyle(session.audioStatus.isOK ? Color.primary : Color.orange)
                        }
                    }
                    LabeledContent("Mic → ESP (sent)") {
                        Text("\(packetsSent) frames")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(packetsSent > 0 ? .green : .secondary)
                    }
                    LabeledContent("ESP → Spk (received)") {
                        Text("\(packetsReceived) frames")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(packetsReceived > 0 ? .green : .secondary)
                    }
                }

                Section("Connections") {
                    ForEach(session.connections) { conn in
                        LabeledContent(conn.device.name) {
                            Text(diagnosticState(conn.state))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onReceive(timer) { _ in
                packetsSent     = session.audioEngine.packetsSent
                packetsReceived = session.audioEngine.packetsReceived
            }
        }
    }

    private func diagnosticState(_ state: ConnectionState) -> String {
        switch state {
        case .connecting:   return "connecting"
        case .idle:         return "idle"
        case .outgoing:     return "outgoing"
        case .incoming:     return "incoming"
        case .active:       return "active"
        case .reconnecting: return "reconnecting"
        case .error(let e): return "error: \(e)"
        case .disconnected: return "disconnected"
        }
    }
}
