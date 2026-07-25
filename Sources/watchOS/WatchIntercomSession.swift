import Foundation
import WatchKit
import WatchConnectivity
import Network

@MainActor
final class WatchIntercomSession: NSObject, ObservableObject {
    @Published private(set) var connections: [IntercomConnection] = []
    @Published private(set) var isCallActive = false
    @Published private(set) var sessionExpired = false

    let audioEngine = AudioEngine()   // shared, hardened engine (Sources/Shared)
    private var extSession: WKExtendedRuntimeSession?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - Call management

    func startCall(to devices: [IntercomDevice], callerName: String) async throws {
        guard !isCallActive else { return }
        sessionExpired = false

        // Configure + start the shared engine once with zero players (mirrors the
        // iOS flow), then attach one player per call.  configure() awaits the
        // microphone-permission prompt, so this is async.
        try await audioEngine.configure()

        audioEngine.onCapture = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Push-to-talk gating + silence keepalive live in IntercomConnection.
                for conn in self.connections { conn.sendAudio(data) }
            }
        }
        audioEngine.startCapture()

        for device in devices {
            let conn           = IntercomConnection(device: device)
            conn.callerName    = callerName
            conn.callOnConnect = true
            conn.onAudioReceived = { [weak self, id = conn.id] data in
                self?.audioEngine.playAudio(data, for: id)
            }
            connections.append(conn)
            audioEngine.addPlayerAndDrain(for: conn.id)
            conn.connect()
        }

        isCallActive = true
        beginExtendedSession()
    }

    func hangupAll(reason: String? = nil) {
        connections.forEach { $0.hangup(); $0.disconnect() }
        audioEngine.stop()
        audioEngine.deactivate()
        connections.removeAll()
        isCallActive = false
        extSession?.invalidate()
        extSession = nil
        if reason != nil { sessionExpired = true }
    }

    // MARK: - Per-connection controls

    func setVolume(_ volume: Float, for conn: IntercomConnection) {
        conn.speakerVolume = volume
        applyPlaybackVolume(for: conn)
    }

    func toggleSpeakerMute(for conn: IntercomConnection) {
        conn.isSpeakerMuted.toggle()
        applyPlaybackVolume(for: conn)
    }

    /// Tap-to-talk; mutes this call's incoming audio while talking to avoid an
    /// acoustic feedback loop (half-duplex).
    func toggleTalk(for conn: IntercomConnection) {
        conn.isTalking.toggle()
        applyPlaybackVolume(for: conn)
    }

    private func applyPlaybackVolume(for conn: IntercomConnection) {
        audioEngine.setVolume(conn.effectivePlaybackVolume, for: conn.id)
    }

    // MARK: - WKExtendedRuntimeSession

    private func beginExtendedSession() {
        let s = WKExtendedRuntimeSession()
        s.delegate = self
        extSession = s
        s.start()
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension WatchIntercomSession: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSession(_ session: WKExtendedRuntimeSession,
                                             didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                             error: (any Error)?) {
        Task { @MainActor in
            // Drop the call gracefully when the OS terminates the extended session.
            if self.isCallActive {
                self.hangupAll(reason: "Background session expired")
            }
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {
        Task { @MainActor in
            if self.isCallActive {
                self.hangupAll(reason: "Background session expiring")
            }
        }
    }
}

// MARK: - WCSessionDelegate (device list sync fallback)

extension WatchIntercomSession: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {}

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext context: [String: Any]) {
        // Phone sends the device list when it changes.
        guard
            let b64   = context["devices"] as? String,
            let data  = Data(base64Encoded: b64),
            let devs  = try? JSONDecoder().decode([IntercomDevice].self, from: data)
        else { return }

        Task { @MainActor in
            // Persist on watch so it's available without the phone.
            if let enc = try? JSONEncoder().encode(devs) {
                UserDefaults.standard.set(enc, forKey: "saved_devices")
            }
            // Notify observers via DeviceStore — handled at the App level.
            NotificationCenter.default.post(name: .watchDevicesUpdated, object: devs)
        }
    }
}

extension Notification.Name {
    static let watchDevicesUpdated = Notification.Name("watchDevicesUpdated")
}
