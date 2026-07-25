import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var deviceStore:  DeviceStore
    @EnvironmentObject private var watchSession: WatchIntercomSession
    @AppStorage("callerName") private var callerName = "Watch"

    @State private var selectedIds: Set<UUID> = []
    @State private var callError: String?

    var body: some View {
        if watchSession.isCallActive {
            WatchActiveCallView()
        } else {
            deviceListView
        }
    }

    private var deviceListView: some View {
        List {
            if deviceStore.devices.isEmpty {
                Text("No devices.\nConfigure in the iPhone app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(deviceStore.devices) { device in
                    Button {
                        toggleSelection(device.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.headline)
                                Text(device.host).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedIds.contains(device.id) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                if !selectedIds.isEmpty {
                    Button {
                        callSelected()
                    } label: {
                        Label("Call \(selectedIds.count)", systemImage: "phone.fill")
                    }
                    .tint(.green)
                }
            }
        }
        .navigationTitle("Intercom")
        .alert("Call Failed", isPresented: .constant(callError != nil), presenting: callError) { _ in
            Button("OK") { callError = nil }
        } message: { Text($0) }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIds.contains(id) { selectedIds.remove(id) }
        else { selectedIds.insert(id) }
    }

    private func callSelected() {
        let targets = deviceStore.devices.filter { selectedIds.contains($0.id) }
        Task {
            do {
                try await watchSession.startCall(to: targets, callerName: callerName)
                selectedIds.removeAll()
            } catch {
                callError = error.localizedDescription
            }
        }
    }
}

// MARK: - Active call view

struct WatchActiveCallView: View {
    @EnvironmentObject private var watchSession: WatchIntercomSession
    @State private var focusedConnIdx = 0
    @State private var crownValue: Double = 1.0

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if watchSession.sessionExpired {
                    Label("Session ended", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                ForEach(Array(watchSession.connections.enumerated()), id: \.element.id) { idx, conn in
                    WatchConnectionRow(conn: conn, isFocused: idx == focusedConnIdx) {
                        focusedConnIdx = idx
                    }
                }

                Button(role: .destructive) {
                    watchSession.hangupAll()
                } label: {
                    Label("End All", systemImage: "phone.down.fill")
                }
                .tint(.red)
            }
            .padding()
        }
        .focusable()
        .digitalCrownRotation($crownValue, from: 0, through: 1, by: 0.05, sensitivity: .low)
        .onChange(of: crownValue) { _, val in
            guard focusedConnIdx < watchSession.connections.count else { return }
            let conn = watchSession.connections[focusedConnIdx]
            watchSession.setVolume(Float(val), for: conn)
        }
        .onAppear {
            if let first = watchSession.connections.first {
                crownValue = Double(first.speakerVolume)
            }
        }
    }
}

private struct WatchConnectionRow: View {
    @ObservedObject var conn: IntercomConnection
    @EnvironmentObject private var watchSession: WatchIntercomSession
    let isFocused: Bool
    let onFocus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(conn.device.name).font(.headline)
                Spacer()
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
            }
            .onTapGesture { onFocus() }

            if conn.state == .active {
                HStack(spacing: 8) {
                    // Push-to-talk: tap to open the mic, tap again to go silent.
                    Button {
                        watchSession.toggleTalk(for: conn)
                    } label: {
                        Image(systemName: conn.isTalking ? "mic.fill" : "mic.slash.fill")
                            .foregroundStyle(conn.isTalking ? .green : .secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        watchSession.toggleSpeakerMute(for: conn)
                    } label: {
                        Image(systemName: conn.isSpeakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(conn.isSpeakerMuted ? .red : .primary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        conn.hangup()
                    } label: {
                        Image(systemName: "phone.down.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }

                if isFocused {
                    Text("Crown = volume")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(isFocused ? Color.blue.opacity(0.2) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var stateColor: Color {
        switch conn.state {
        case .active:   return .green
        case .outgoing, .incoming, .reconnecting: return .orange
        case .error:    return .red
        default:        return .gray
        }
    }
}
