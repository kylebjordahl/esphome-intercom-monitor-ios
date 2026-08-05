import Foundation
import Combine
import Network
import WatchConnectivity
import AVFoundation

@MainActor
final class IntercomSession: NSObject, ObservableObject {

    // All live connections — both outbound (client-side) and inbound (server-side).
    @Published private(set) var connections: [IntercomConnection] = []

    // Derived state for the UI — computed but surfaced as @Published so views update.
    @Published private(set) var isCallActive    = false
    @Published private(set) var hasIncomingCall = false

    // Diagnostic / status
    @Published private(set) var audioStatus: AudioStatus = .idle

    enum AudioStatus: Equatable {
        case idle
        case starting
        case running
        case recovering   // engine died mid-call and is auto-restarting
        case failed(String)

        var label: String {
            switch self {
            case .idle:          return "Idle"
            case .starting:      return "Starting…"
            case .running:       return "Running"
            case .recovering:    return "Recovering…"
            case .failed(let e): return "Failed: \(e)"
            }
        }

        var isOK: Bool {
            if case .running = self { return true }
            return false
        }
    }

    let audioEngine = AudioEngine()
    let server      = IntercomServer()
    /// SIP presence for firmware >= v2026.7.0.  Runs alongside the legacy TCP
    /// listener so a house with both firmware generations works at once.
    let sipEndpoint = SIPEndpoint.shared
    private let callActivity = CallActivityController()

    private var isAudioRunning     = false
    private var isAudioConfiguring = false   // guard against concurrent ensureAudioConfigured() calls

    // Combine: keep one AnyCancellable per connection keyed by connection id.
    private var cancellables     = Set<AnyCancellable>()
    private var connCancellables = [UUID: AnyCancellable]()

    // Refreshes the Live Activity periodically while a call is active so its
    // staleDate keeps moving forward during long, quiet calls (no state changes).
    private var liveActivityRefreshTimer: Timer?

    // MARK: - Init

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }

        // Wire up the server to hand us incoming connections.
        server.onAccepted = { [weak self] (nwConn: NWConnection) in
            self?.acceptIncoming(nwConn)
        }

        // Inbound SIP INVITE from a v2026.7.0+ panel (or any SIP peer on the LAN).
        sipEndpoint.onIncomingCall = { [weak self] call in
            self?.acceptIncoming(call)
        }

        // Live Activity talk button → toggle push-to-talk for that connection.
        // The intent runs in this process, so a default-center post reaches us.
        NotificationCenter.default.addObserver(
            forName: .intercomToggleTalk, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor [weak self] in self?.toggleTalk(connectionId: id) }
        }

        // Live Activity hang-up button → end one call (id) or all (empty id).
        NotificationCenter.default.addObserver(
            forName: .intercomHangup, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor [weak self] in self?.hangupFromIntent(connectionId: id) }
        }

        // Fresh launch ⇒ no live calls.  End any Live Activity left over from a
        // previous crash / force-quit so it can't get stuck on the Lock Screen.
        callActivity.endOrphaned()

        // Siri / App Shortcuts route "listen in on …" / "stop listening" here.
        // attach() also drains any command that fired during a cold launch,
        // before this session existed (see IntercomCommandBus).
        IntercomCommandBus.shared.attach(self)
    }

    // MARK: - Siri / App Shortcuts

    /// Execute a command delivered by an App Intent (see IntercomIntents.swift).
    func handle(command: IntercomCommandBus.Command) {
        switch command {
        case .listen(let device):
            // "Listening" is just a normal push-to-talk call: it starts muted
            // (isTalking == false), so the user hears the panel without talking.
            let name = UserDefaults.standard.string(forKey: "callerName")
            startCall(to: [device], callerName: (name?.isEmpty == false) ? name! : "iPhone")
        case .stopListening:
            hangupAll()
        }
    }

    // MARK: - Server lifecycle

    /// Starts both inbound listeners and registers the endpoint in HA.
    func startServer(name: String, haBaseURL: String, haToken: String,
                     haClient: HomeAssistantClient) {
        server.start(deviceName: name)

        // The SIP listener may not get the conventional 5060 (something else on
        // the device can hold it), and the port it does get is what peers must
        // call.  Re-advertise once the real port is known rather than publishing
        // 5060 and hoping.
        sipEndpoint.onListeningChanged = { [weak self] in
            guard let self, let ip = localWiFiIPAddress() else { return }
            Task {
                await haClient.registerEndpoint(baseURL: haBaseURL, token: haToken,
                                                name: name, ip: ip,
                                                port: Int(IntercomServer.listenPort),
                                                sipPort: Int(self.sipEndpoint.localPort))
            }
        }

        // Register our endpoint in HA so intercom_native / VoIP Stack can add us
        // to the phonebook, and bring up the SIP listener on the same address we
        // advertise (Via/Contact/SDP all have to agree with it).
        Task {
            guard let ip = localWiFiIPAddress() else { return }
            sipEndpoint.start(localName: name, address: ip)
            await haClient.registerEndpoint(baseURL: haBaseURL, token: haToken,
                                            name: name, ip: ip,
                                            port: Int(IntercomServer.listenPort),
                                            sipPort: Int(sipEndpoint.localPort))
        }
    }

    // MARK: - Outbound calls

    func startCall(to devices: [IntercomDevice], callerName: String) {
        // Don't start audio yet — configure it lazily when the first connection
        // actually reaches .active.  Starting the engine before any connection
        // is established floods the simulator audio device with reconfig events.

        for device in devices {
            guard !connections.contains(where: { $0.device.id == device.id }) else { continue }
            let conn           = IntercomConnection(device: device)
            conn.callerName    = callerName
            conn.callOnConnect = true
            addConnection(conn)
            conn.connect()
        }

        // Push-to-talk model: every call starts silent (isTalking == false).
        // The user opens the mic only while holding the talk control.
    }

    // MARK: - Inbound connections

    private func acceptIncoming(_ nwConn: NWConnection) {
        let conn = IntercomConnection(accepted: nwConn)
        addConnection(conn)
        conn.startAccepted()
    }

    /// A SIP peer sent us an INVITE.  Wrapped in the same IntercomConnection
    /// facade as a legacy call so the UI, Live Activity and watch app treat it
    /// identically.
    private func acceptIncoming(_ call: SIPCall) {
        let conn = IntercomConnection(accepted: call)
        addConnection(conn)
        conn.startAccepted()
    }

    // MARK: - Per-connection audio controls

    func setVolume(_ volume: Float, for conn: IntercomConnection) {
        conn.speakerVolume = volume
        applyPlaybackVolume(for: conn)
    }

    /// Push the connection's current speaker-mute state to the audio engine.
    /// The `isSpeakerMuted` bool is owned by the SwiftUI Toggle binding; this
    /// must NOT toggle it again (doing so flips it straight back, which made the
    /// speaker control appear to do nothing).
    func applySpeakerMute(for conn: IntercomConnection) {
        applyPlaybackVolume(for: conn)
    }

    /// Push the connection's half-duplex playback volume to the engine (muted
    /// while talking — see IntercomConnection.effectivePlaybackVolume).
    private func applyPlaybackVolume(for conn: IntercomConnection) {
        audioEngine.setVolume(conn.effectivePlaybackVolume, for: conn.id)
    }

    // MARK: - Hangup

    func hangup(_ conn: IntercomConnection) {
        conn.hangup()
        conn.disconnect()
    }

    func hangupAll() {
        connections.forEach { $0.hangup(); $0.disconnect() }
        teardownAudio()
        connections.removeAll()
        connCancellables.removeAll()
        updateDerivedState()
    }

    // MARK: - Private: connection management

    private func addConnection(_ conn: IntercomConnection) {
        connections.append(conn)

        // Forward the connection's objectWillChange so our own views re-render
        // when any nested property (state, device name, etc.) changes.
        connCancellables[conn.id] = conn.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }

        // React to state transitions.
        conn.$state
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak conn] newState in
                guard let self, let conn else { return }
                self.handleStateChange(conn: conn, newState: newState)
            }
            .store(in: &cancellables)

        // Wire audio: received PCM → play on speaker.
        // NOTE: playAudio now buffers early frames if the player node isn't
        // ready yet (race between ANSWER and the addPlayerAndDrain call below).
        conn.onAudioReceived = { [weak self, id = conn.id] data in
            self?.audioEngine.playAudio(data, for: id)
        }

        updateDerivedState()
    }

    private func handleStateChange(conn: IntercomConnection, newState: ConnectionState) {
        print("IntercomSession: [\(conn.device.name)] → \(newState)")
        switch newState {
        case .active:
            // Lazy audio: start the engine only when the first call is actually live.
            // addPlayerAndDrain also flushes any AUDIO frames that raced ahead of
            // the Combine callback (arriving in the same TCP-receive pass as ANSWER).
            Task {
                // The call can die while we're asynchronously configuring audio
                // (mic-permission / session activation are slow).  Guard before
                // and after so we never start — or leave running — an engine for
                // a call that no longer exists.
                guard conn.state == .active else { return }
                await ensureAudioConfigured()
                guard conn.state == .active, case .running = audioStatus else {
                    teardownAudioIfIdle()
                    return
                }
                audioEngine.addPlayerAndDrain(for: conn.id)
            }

        case .reconnecting, .callFailed:
            // .reconnecting retries internally; .callFailed shows why a call we
            // placed didn't connect (busy/no answer/declined/dropped) and clears
            // itself a few seconds later — or immediately via the hang-up button
            // — either path drives it to .disconnected, handled below. Keep the
            // row for now, but drop its audio player like any non-active state.
            guard connections.contains(where: { $0.id == conn.id }) else { return }
            audioEngine.removePlayer(for: conn.id)
            teardownAudioIfIdle()

        case .disconnected, .idle, .error:
            // Ignore stale/duplicate terminal events for a connection we've
            // already dropped.  Critical: disconnect() below flips state to
            // .disconnected, which re-fires this observer — without this guard
            // that recurses forever.
            guard connections.contains(where: { $0.id == conn.id }) else { return }

            audioEngine.removePlayer(for: conn.id)
            // .idle means connected-but-no-call (keep the socket for re-dialing);
            // .disconnected / .error mean the call is gone (reconnect attempts,
            // if any, are already exhausted by this point), so drop it entirely.
            if newState != .idle {
                conn.disconnect()
                connections.removeAll { $0.id == conn.id }
                connCancellables.removeValue(forKey: conn.id)
            }
            teardownAudioIfIdle()

        default:
            break
        }
        updateDerivedState()
    }

    /// Tear down the audio engine whenever no call is active.  Centralised so it
    /// also covers the race where a call drops while audio is still configuring.
    private func teardownAudioIfIdle() {
        guard isAudioRunning,
              !connections.contains(where: { $0.state == .active })
        else { return }
        print("IntercomSession: no active calls — tearing down audio")
        teardownAudio()
    }

    private func updateDerivedState() {
        isCallActive    = connections.contains { $0.state == .active }
        hasIncomingCall = connections.contains { $0.state == .incoming }
        syncLiveActivity()
        updateLiveActivityRefresh()
    }

    /// Keep a periodic refresh running while any call is active so the Live
    /// Activity's staleDate stays fresh even during long calls with no UI changes.
    private func updateLiveActivityRefresh() {
        if isCallActive, liveActivityRefreshTimer == nil {
            liveActivityRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.syncLiveActivity() }
            }
        } else if !isCallActive {
            liveActivityRefreshTimer?.invalidate()
            liveActivityRefreshTimer = nil
        }
    }

    /// Reconcile the call Live Activity with the current set of active calls.
    /// Safe to call frequently — the controller no-ops when nothing changed.
    func syncLiveActivity() {
        let active  = connections.filter { $0.state == .active }
        let primary = active.first
        callActivity.sync(activeCount: active.count,
                          primaryName: primary?.device.name ?? "",
                          primaryId: primary?.id.uuidString ?? "",
                          isTalking: primary?.isTalking ?? false)
    }

    // MARK: - Push-to-talk

    /// Open or close the mic for a specific connection (app press-and-hold).
    func setTalking(_ talking: Bool, for conn: IntercomConnection) {
        guard conn.isTalking != talking else { return }
        conn.isTalking = talking
        applyPlaybackVolume(for: conn)   // half-duplex: mute incoming while talking
        syncLiveActivity()
    }

    /// Toggle push-to-talk for a connection id — invoked by the Live Activity
    /// talk button via the .intercomToggleTalk notification.
    private func toggleTalk(connectionId: String) {
        guard let conn = connections.first(where: { $0.id.uuidString == connectionId })
        else { return }
        conn.isTalking.toggle()
        applyPlaybackVolume(for: conn)
        syncLiveActivity()
    }

    /// Hang up from the Live Activity: an empty id ends every call ("End All"),
    /// otherwise just the matching connection.
    private func hangupFromIntent(connectionId: String) {
        if connectionId.isEmpty {
            hangupAll()
        } else if let conn = connections.first(where: { $0.id.uuidString == connectionId }) {
            hangup(conn)
        }
    }

    // MARK: - Private: audio engine

    private func ensureAudioConfigured() async {
        // On @MainActor, two Tasks can both see isAudioRunning=false before the
        // first one sets it true (they interleave at await suspension points).
        // isAudioConfiguring guards the critical section.
        guard !isAudioRunning, !isAudioConfiguring else { return }
        isAudioConfiguring = true
        defer { isAudioConfiguring = false }
        audioStatus = .starting

        do {
            try await audioEngine.configure()
        } catch {
            print("IntercomSession: audio configure FAILED — \(error)")
            audioStatus = .failed(error.localizedDescription)
            return
        }

        // configure() awaits (permission, session activation); the call may have
        // dropped in the meantime.  Don't start the engine — and release the
        // audio session we just activated — if nothing is active anymore.
        guard connections.contains(where: { $0.state == .active }) else {
            print("IntercomSession: call dropped during audio configure — aborting start")
            audioEngine.deactivate()
            audioStatus = .idle
            return
        }

        audioEngine.onCapture = { [weak self] data in
            // Called on the AVAudioEngine tap thread — dispatch to main actor
            // to safely iterate the connections list.
            Task { @MainActor [weak self] in
                guard let self else { return }
                for conn in self.connections where conn.state == .active {
                    conn.sendAudio(data)
                }
            }
        }

        // Reflect the engine's LIVE running state.  A first start can fail and
        // then self-heal via the engine's internal backoff/watchdog; this
        // callback flips the status to Running once it actually comes up (and to
        // Recovering if it dies again), instead of latching a one-shot check.
        audioEngine.onRunningStateChanged = { [weak self] running in
            Task { @MainActor [weak self] in
                guard let self, self.isAudioRunning else { return }
                if running {
                    self.audioStatus = .running
                } else if self.connections.contains(where: { $0.state == .active }) {
                    self.audioStatus = .recovering
                }
            }
        }

        audioEngine.startCapture()

        // `isAudioRunning` now means "audio is configured and SHOULD be running"
        // (mirrors the engine's own shouldBeRunning intent).  We set it true even
        // if the very first start attempt hasn't reported success yet — the engine
        // retries on its own and onRunningStateChanged will confirm.  Leaving it
        // false here (the old behaviour) made a recovered engine invisible to the
        // session: the UI stayed "Failed" and teardown/reconfigure got confused.
        isAudioRunning = true
        audioStatus    = audioEngine.isRunning ? .running : .starting
        print("IntercomSession: audio engine start requested (running=\(audioEngine.isRunning))")
    }

    private func teardownAudio() {
        // Clear intent first so any late onRunningStateChanged callback from the
        // engine winding down is ignored (it guards on isAudioRunning).
        isAudioRunning     = false
        isAudioConfiguring = false
        audioEngine.onRunningStateChanged = nil
        audioEngine.stop()
        audioEngine.deactivate()
        audioStatus        = .idle
    }

    // MARK: - WatchConnectivity

    func publishDevicesToWatch(_ devices: [IntercomDevice]) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable || WCSession.default.isPaired
        else { return }
        let encoded = (try? JSONEncoder().encode(devices)).map {
            ["devices": $0.base64EncodedString()]
        } ?? [:]
        try? WCSession.default.updateApplicationContext(encoded)
    }
}

// MARK: - WCSessionDelegate

extension IntercomSession: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            if (message["action"] as? String) == "hangup" { self.hangupAll() }
        }
    }
}
