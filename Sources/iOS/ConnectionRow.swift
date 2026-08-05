import SwiftUI

// Per-connection call controls: state, hang-up, mic/speaker mute, volume,
// and incoming-call answer/decline.  Used on the main Devices page for live
// calls; the ActiveCallView details screen is reserved for diagnostics.
struct ConnectionRow: View {
    @ObservedObject var conn: IntercomConnection
    @EnvironmentObject private var session: IntercomSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conn.device.name).font(.headline)
                    Text(stateLabel).font(.caption).foregroundStyle(stateColor)
                }
                Spacer()
                if conn.state == .reconnecting {
                    ProgressView().scaleEffect(0.8)
                }
                // Hang up / dismiss — also lets the user cancel a reconnect, or
                // clear a call that didn't connect (busy, no answer, declined,
                // transport error) instead of it being stuck with no control.
                if canDismiss {
                    Button(role: .destructive) {
                        session.hangup(conn)
                    } label: {
                        Image(systemName: "phone.down.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            if conn.state == .active {
                // Push-to-talk: hold to open the mic, release to go silent.
                PushToTalkButton(isTalking: conn.isTalking) { talking in
                    session.setTalking(talking, for: conn)
                }

                HStack(spacing: 16) {
                    // Speaker mute toggle — drives playback volume via the engine.
                    Toggle(isOn: $conn.isSpeakerMuted) {
                        Label(
                            conn.isSpeakerMuted ? "Spk Off" : "Spk On",
                            systemImage: conn.isSpeakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                        )
                        .font(.caption)
                    }
                    .toggleStyle(.button)
                    .tint(conn.isSpeakerMuted ? .red : .blue)
                    .onChange(of: conn.isSpeakerMuted) { _, _ in
                        session.applySpeakerMute(for: conn)
                    }

                    // Volume slider (only when speaker not muted)
                    if !conn.isSpeakerMuted {
                        Slider(value: $conn.speakerVolume, in: 0...1, step: 0.05)
                            .onChange(of: conn.speakerVolume) { _, vol in
                                session.setVolume(vol, for: conn)
                            }
                    }
                }
            }

            if case .incoming = conn.state {
                HStack {
                    Button("Answer") { conn.answer() }
                        .buttonStyle(.borderedProminent)
                    Button("Decline", role: .destructive) { conn.decline() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var stateLabel: String {
        switch conn.state {
        case .connecting:      return "Connecting…"
        case .idle:            return "Connected (idle)"
        case .outgoing:        return "Calling…"
        case .incoming:        return "Incoming call"
        case .active:          return "Active"
        case .reconnecting:    return "Reconnecting…"
        case .callFailed(let reason): return Self.callFailedLabel(reason)
        case .error(let e):    return "Error: \(e)"
        case .disconnected:    return "Disconnected"
        }
    }

    private static func callFailedLabel(_ reason: String) -> String {
        switch reason {
        case "busy":             return "Busy"
        case "no answer":        return "No Answer"
        case "declined":         return "Declined"
        case "signaling closed": return "Call Dropped"
        default:                 return "Call Failed"
        }
    }

    private var stateColor: Color {
        switch conn.state {
        case .active:      return .green
        case .error:       return .red
        case .callFailed:  return .red
        case .outgoing, .incoming, .reconnecting: return .orange
        default:           return .secondary
        }
    }

    /// Whether a hang-up/dismiss control should be shown for the current state.
    /// Every non-terminal or failed state must be dismissable — a call that
    /// didn't connect (busy/no answer/declined) or hit a transport error
    /// should never be stuck on screen with no way to clear it.
    private var canDismiss: Bool {
        switch conn.state {
        case .active, .outgoing, .reconnecting, .callFailed, .error: return true
        case .connecting, .incoming, .idle, .disconnected: return false
        }
    }
}

// MARK: - Push-to-talk button

/// Press-and-hold control: reports `true` on press-down and `false` on release.
/// Uses a zero-distance drag so the press state tracks the finger directly.
private struct PushToTalkButton: View {
    let isTalking: Bool
    let onChange: (Bool) -> Void

    @State private var pressed = false

    var body: some View {
        Label(isTalking ? "Talking…" : "Hold to Talk",
              systemImage: isTalking ? "mic.fill" : "mic.slash.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isTalking ? Color.green : Color.accentColor, in: Capsule())
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: pressed)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        onChange(true)
                    }
                    .onEnded { _ in
                        pressed = false
                        onChange(false)
                    }
            )
            .accessibilityLabel("Push to talk")
            .accessibilityHint("Hold to transmit audio")
    }
}
