import Foundation
import Network

enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case idle
    case outgoing   // we sent START/INVITE, waiting for ANSWER/200
    case incoming   // received START/INVITE from remote, ringing, waiting for user
    case active
    case reconnecting   // socket dropped without an explicit HANGUP/DECLINE; retrying
    case error(String)
}

// Represents one call session against a panel, either:
//   - client-side (we opened the connection to call an ESP device), or
//   - server-side (an ESP device opened the connection to call us).
//
// Two wire protocols are supported behind this one interface:
//
//   .legacy — the proprietary PBX-lite framing on TCP 6054, used by firmware
//             up to v2026.6.x.  Implemented inline below, unchanged.
//   .voip   — SIP/SDP signaling with RTP/UDP L16 media (`voip-pcm/1`), used by
//             firmware from v2026.7.0, which retired the PBX-lite contract
//             entirely.  Delegated to SIPCall.
//
// Keeping both behind this facade is deliberate: IntercomSession, every SwiftUI
// view, the watchOS app and the Live Activity intents all talk to this type, so
// adding a protocol did not require touching any of them.
//
// The `id` is stable for the lifetime of the object regardless of mode.
// In server mode, `device` starts as a placeholder and is filled in when
// the caller's START/INVITE arrives.
@MainActor
final class IntercomConnection: ObservableObject, Identifiable {
    let id: UUID

    // In server mode this is updated when the START payload / INVITE is parsed.
    @Published private(set) var device: IntercomDevice

    @Published var state: ConnectionState = .disconnected {
        didSet {
            guard state != oldValue else { return }
            // Manage the legacy audio keepalive on transitions in/out of .active.
            // The VoIP path does not use it: RTP is inherently paced, and
            // RTPAudioSession emits silence frames on its own send timer.
            guard mode == .legacy else { return }
            if state == .active { startAudioKeepalive() }
            else if oldValue == .active { stopAudioKeepalive() }
        }
    }
    // Push-to-talk: the mic is silent unless `isTalking` is true (the user is
    // actively holding the talk control for this device).  Defaults to off so
    // every call starts muted.
    @Published var isTalking = false {
        didSet { sipCall?.isTalking = isTalking }
    }
    @Published var speakerVolume: Float = 1.0
    @Published var isSpeakerMuted = false

    private(set) var callId = ""
    let isServerSide: Bool

    var onAudioReceived: ((Data) -> Void)?

    // MARK: - Transport selection

    /// Which stack this connection is actually driving.  Resolved from the
    /// device's `protocolKind`; `.auto` starts on `.legacy` and falls forward to
    /// `.voip` if the legacy port refuses the connection (see `probeFailed`).
    private enum Mode { case legacy, voip }
    private var mode: Mode
    /// True while an `.auto` device is still being probed, so a legacy connect
    /// failure switches protocol instead of entering the reconnect backoff.
    private var isProbing: Bool
    /// Set once a legacy socket has actually come up, so we can tell "this panel
    /// isn't serving that port" from "an established call dropped".
    private var hasEverConnected = false
    /// Latches so the legacy→VoIP fallback can never loop.
    private var hasTriedVoIP = false

    // MARK: - Legacy transport state

    private var nwConn: NWConnection?
    private var receiveBuffer = Data()
    private var pingTimer: Timer?
    private var audioKeepaliveTimer: Timer?

    // One silent AUDIO frame: 512 samples × int16 = 1024 bytes (matches the ESP).
    private static let silenceFrameBytes = 512 * 2

    // MARK: - VoIP transport state

    private var sipCall: SIPCall?

    // MARK: - Auto-reconnect

    // Set whenever a HANGUP/DECLINE is sent or received, or disconnect() is
    // called explicitly.  Marks the current call/socket as deliberately ended,
    // so a subsequent socket drop is expected rather than something to recover.
    private var explicitEnd = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private static let maxReconnectAttempts = 5
    private static let maxReconnectDelay: Double = 16

    /// Half-duplex playback volume: muted while the user is talking, so the mic
    /// doesn't pick up this call's own audio from the speaker and create an
    /// acoustic feedback loop.  Otherwise honours the user's speaker mute/volume.
    var effectivePlaybackVolume: Float {
        if isTalking { return 0 }
        return isSpeakerMuted ? 0 : speakerVolume
    }

    // Client-mode config: set before connect() to auto-dial when TCP ready.
    var callerName: String = ""
    var callOnConnect: Bool = false

    // MARK: - Init

    /// Client mode — we open an outbound connection to call a known device.
    init(device: IntercomDevice) {
        self.id           = device.id   // stable id tied to the device store entry
        self.device       = device
        self.isServerSide = false
        switch device.protocolKind {
        case .legacy: self.mode = .legacy; self.isProbing = false
        case .voip:   self.mode = .voip;   self.isProbing = false
        // Probe legacy first: the PBX-lite port is a reliable discriminator —
        // v2026.7.0+ firmware doesn't listen on it, so a refused connect means
        // the panel is a SIP endpoint.
        case .auto:   self.mode = .legacy; self.isProbing = true
        }
    }

    /// Server mode — the remote device opened a legacy TCP connection.
    init(accepted nwConn: NWConnection) {
        self.id           = UUID()
        self.device       = IntercomDevice(name: "Incoming…", host: "", port: 0,
                                           protocolKind: .legacy)
        self.isServerSide = true
        self.nwConn       = nwConn
        self.mode         = .legacy
        self.isProbing    = false
    }

    /// Server mode — a SIP peer sent us an INVITE.
    init(accepted call: SIPCall) {
        self.id           = UUID()
        self.device       = IntercomDevice(name: "Incoming…", host: call.remoteAddress,
                                           port: 0, protocolKind: .voip)
        self.isServerSide = true
        self.mode         = .voip
        self.isProbing    = false
        self.sipCall      = call
        attachSIPHandlers(to: call)
    }

    // MARK: - Connection lifecycle

    /// Client-side: open a new connection.  Also used internally to retry after
    /// an unexpected drop, so `.reconnecting` is an accepted starting state.
    func connect() {
        guard !isServerSide, state == .disconnected || state == .reconnecting else { return }

        switch mode {
        case .legacy: connectLegacy()
        case .voip:   connectVoIP()
        }
    }

    private func connectLegacy() {
        state = .connecting
        print("IntercomConnection: [\(device.name)] legacy connect \(device.host):\(device.port) " +
              "(protocol=\(device.protocolKind.rawValue) probing=\(isProbing) " +
              "sip=\(device.host):\(device.sipPort)/\(device.sipTransport.rawValue))")

        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.enableKeepalive = true
        tcpOpts.keepaliveIdle   = 30
        // Always bound the first attempt.  Without this, a panel that silently
        // drops the SYN (rather than refusing it) leaves the UI sitting on
        // "Connecting…" for the system default timeout with nothing logged.
        if !hasTriedVoIP { tcpOpts.connectionTimeout = 3 }
        let params = NWParameters(tls: nil, tcp: tcpOpts)

        let conn = NWConnection(
            host: NWEndpoint.Host(device.host),
            port: NWEndpoint.Port(rawValue: UInt16(device.port)) ?? 6054,
            using: params
        )
        nwConn = conn
        attachHandlers(to: conn)
        conn.start(queue: .global(qos: .userInitiated))
    }

    private func connectVoIP() {
        state = .connecting

        // Without a resolved local address every SIP call would advertise
        // 0.0.0.0 in Via/Contact/SDP and the panel would have nowhere to send
        // media or a BYE — fail loudly instead of placing a mute call.
        guard SIPEndpoint.shared.ensureStarted(
            localName: callerName.isEmpty ? "iPhone" : callerName) else {
            state = .error("No Wi-Fi address for SIP")
            return
        }

        let call = SIPCall(outboundTo: device,
                           callerName: callerName.isEmpty ? "iPhone" : callerName,
                           endpoint: SIPEndpoint.shared)
        sipCall = call
        SIPEndpoint.shared.register(call)
        attachSIPHandlers(to: call)

        // SIP has no separate "connected but idle" phase — the INVITE both opens
        // the transport and places the call.  A VoIP connection that isn't meant
        // to dial immediately simply stays idle until call() is invoked.
        if callOnConnect {
            callId = call.callID
            call.isTalking = isTalking
            call.dial()
            state = .outgoing
        } else {
            state = .idle
        }
    }

    func startAccepted() {
        guard isServerSide else { return }
        switch mode {
        case .legacy:
            guard let conn = nwConn else { return }
            state = .connecting
            attachHandlers(to: conn)
            conn.start(queue: .global(qos: .userInitiated))
        case .voip:
            // The SIPCall is already live; its state callback drives us.
            state = .connecting
        }
    }

    func disconnect() {
        explicitEnd = true
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTimer?.invalidate()
        pingTimer = nil
        stopAudioKeepalive()
        nwConn?.cancel()
        nwConn = nil
        sipCall?.teardown()
        sipCall = nil
        receiveBuffer.removeAll()
        callId = ""
        state  = .disconnected
    }

    // MARK: - Call control

    /// Client-side: dial the remote device.
    func call() {
        guard !isServerSide, case .idle = state else { return }
        explicitEnd = false   // fresh call attempt on this connection

        switch mode {
        case .legacy:
            callId = "\(callerName)<->\(device.name)"
            send(.start(callId: callId,
                        callerRoute: callerName, callerName: callerName,
                        destRoute: device.name,  destName: device.name))
            state = .outgoing

        case .voip:
            let call = sipCall ?? {
                let fresh = SIPCall(outboundTo: device,
                                    callerName: callerName.isEmpty ? "iPhone" : callerName,
                                    endpoint: SIPEndpoint.shared)
                SIPEndpoint.shared.register(fresh)
                attachSIPHandlers(to: fresh)
                sipCall = fresh
                return fresh
            }()
            callId = call.callID
            call.isTalking = isTalking
            call.dial()
            state = .outgoing
        }
    }

    /// Answer an incoming call (server-side or any .incoming state).
    func answer() {
        guard case .incoming = state else { return }
        switch mode {
        case .legacy:
            send(.answer(callId: callId))
            state = .active
        case .voip:
            // The SIPCall drives the transition: it only reaches .active once the
            // 200 OK is out and RTP is running.
            sipCall?.answer()
        }
    }

    func decline() {
        guard case .incoming = state else { return }
        explicitEnd = true
        switch mode {
        case .legacy:
            send(.decline(callId: callId))
            callId = ""
            state  = .idle
        case .voip:
            // The dialog decides the terminal state — a server-side SIP call has
            // no socket to return to, so forcing .idle here would strand a dead
            // connection in the session's list.
            sipCall?.decline()
        }
    }

    func hangup() {
        switch state {
        case .outgoing, .active:
            explicitEnd = true
            switch mode {
            case .legacy:
                send(.hangup(callId: callId))
                callId = ""
                state  = .idle
            case .voip:
                // CANCEL vs BYE depends on how far the dialog got; SIPCall knows
                // and reports the resulting state back through handleSIPState.
                sipCall?.hangup()
            }
        default:
            break
        }
    }

    func sendAudio(_ data: Data) {
        // Push-to-talk: transmit live mic audio only while the user is talking.
        // Legacy silence comes from the keepalive timer; VoIP silence comes from
        // the RTP send timer.  Both start the instant the call goes active —
        // long before the mic-capture engine delivers its first buffer.
        guard case .active = state, isTalking else { return }
        switch mode {
        case .legacy: send(.audio(data))
        case .voip:   sipCall?.sendAudio(data)
        }
    }

    // MARK: - VoIP bridging

    private func attachSIPHandlers(to call: SIPCall) {
        call.onAudioReceived = { [weak self] pcm in
            self?.onAudioReceived?(pcm)
        }
        call.onRemoteIdentity = { [weak self] name, host in
            guard let self else { return }
            self.device = IntercomDevice(id: self.device.id,
                                         name: name.isEmpty ? host : name,
                                         host: host,
                                         port: 0,
                                         protocolKind: .voip)
        }
        call.onStateChange = { [weak self] sipState in
            Task { @MainActor [weak self] in self?.handleSIPState(sipState) }
        }
    }

    private func handleSIPState(_ sipState: SIPCall.State) {
        switch sipState {
        case .idle:
            break
        case .calling, .remoteRinging:
            state = .outgoing
        case .incoming:
            callId = sipCall?.callID ?? ""
            state  = .incoming
        case .active:
            state = .active
        case .ended(let reason):
            print("IntercomConnection: [\(device.name)] SIP call ended — \(reason)")
            explicitEnd = true
            callId = ""
            sipCall?.teardown()
            sipCall = nil
            // A server-side call has nothing to return to; a client-side one
            // keeps its roster entry so the user can redial.
            state = isServerSide ? .disconnected : .idle
        case .failed(let reason):
            print("IntercomConnection: [\(device.name)] SIP call failed — \(reason)")
            callId = ""
            sipCall?.teardown()
            sipCall = nil

            // We may have got here from the legacy fallback rather than because
            // this is really a SIP panel.  If the roster never said `.voip`, hand
            // back to legacy so a panel that was merely offline keeps its normal
            // reconnect/backoff.  `hasTriedVoIP` stays latched, so this cannot
            // ping-pong: the next legacy failure goes straight to backoff.
            if !isServerSide, hasTriedVoIP, device.protocolKind != .voip {
                print("IntercomConnection: [\(device.name)] SIP attempt failed too — " +
                      "returning to legacy retry")
                mode = .legacy
                handleUnexpectedDrop()
                return
            }
            state = .error(reason)
        }
    }

    // MARK: - Audio keepalive (legacy only)

    /// The ESP gracefully hangs up a second or two after ANSWER if it receives
    /// no AUDIO frames.  Stream silence ~10×/sec whenever the call is active and
    /// the user isn't talking, starting immediately on ANSWER (independent of
    /// the audio engine, which takes hundreds of ms to start).  While talking,
    /// the mic-capture path carries real audio, so we skip silence then.
    private func startAudioKeepalive() {
        audioKeepaliveTimer?.invalidate()
        sendSilenceFrameIfIdle()   // send one right away
        audioKeepaliveTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendSilenceFrameIfIdle() }
        }
    }

    private func stopAudioKeepalive() {
        audioKeepaliveTimer?.invalidate()
        audioKeepaliveTimer = nil
    }

    private func sendSilenceFrameIfIdle() {
        guard case .active = state, !isTalking else { return }
        send(.audio(Data(count: Self.silenceFrameBytes)))
    }

    // MARK: - Private (legacy transport)

    private func attachHandlers(to conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] nwState in
            Task { @MainActor [weak self] in self?.handleNWState(nwState) }
        }
        receive()
    }

    private func send(_ msg: IntercomMessage) {
        nwConn?.send(content: msg.encode(), completion: .contentProcessed { [weak self] err in
            guard let err else { return }
            // A failed send means the socket is dead — route through the same
            // recovery path as a closed/failed read so a write failure (e.g. a
            // dropped keepalive frame mid-call) gets a reconnect attempt too.
            Task { @MainActor [weak self] in
                print("IntercomConnection: [\(self?.device.name ?? "?")] send failed — \(err)")
                self?.handleUnexpectedDrop()
            }
        })
    }

    private func handleNWState(_ nwState: NWConnection.State) {
        switch nwState {
        case .ready:
            // A legacy panel answered on 6054 — the probe is settled.
            isProbing = false
            hasEverConnected = true
            reconnectAttempt = 0
            state = .idle
            startPingTimer()
            if !isServerSide, callOnConnect { call() }

        case .failed(let err):
            print("IntercomConnection: [\(device.name)] NWConnection failed — \(err)")
            handleUnexpectedDrop(error: err)

        case .cancelled:
            // Only force the terminal state here for a deliberate disconnect().
            // An unexpected drop is already routed through handleUnexpectedDrop(),
            // which may have moved us into .reconnecting by the time this fires.
            if explicitEnd { state = .disconnected }

        default:
            break
        }
    }

    /// The legacy port refused us, so this panel is running firmware that
    /// retired the PBX-lite protocol.  Retry the same device over SIP.
    /// True only for an explicit "connection refused" (RST), which means the
    /// host is up and nothing is bound to that port — as opposed to a timeout or
    /// unreachable host, which mean the panel itself is absent.
    nonisolated static func isConnectionRefused(_ error: NWError?) -> Bool {
        guard let error else { return false }
        if case .posix(let code) = error { return code == .ECONNREFUSED }
        return false
    }

    private func switchToVoIPAfterProbe() {
        isProbing    = false
        hasTriedVoIP = true
        mode         = .voip
        nwConn?.cancel()
        nwConn = nil
        receiveBuffer.removeAll()
        print("IntercomConnection: [\(device.name)] legacy port \(device.port) refused — " +
              "retrying as VoIP (SIP \(device.host):\(device.sipPort)/\(device.sipTransport.rawValue))")
        state = .disconnected
        connect()
    }

    /// The socket died without either side sending HANGUP/DECLINE for the
    /// current call — likely a transient network blip (Wi-Fi drop, NAT
    /// timeout, ESP reboot) rather than a deliberate call end.  Retry the
    /// connection with backoff instead of just giving up.  Only meaningful
    /// client-side: a server-side connection can't dial the remote panel back,
    /// so it just has to wait for the panel to redial us.
    private func handleUnexpectedDrop(error: NWError? = nil) {
        // A refused connection surfaces through the receive completion handler
        // *before* NWConnection reports .failed, so the fallback decision has to
        // be made here too, or the connection just enters the reconnect backoff.
        //
        // If a legacy socket never came up, try SIP before falling into the
        // reconnect backoff — whatever the reason and whatever protocolKind
        // says.  Classifying the error (refused vs timeout) was too clever and
        // kept missing cases; a panel that dropped the legacy protocol can
        // present as a refusal, a timeout, or a silent drop depending on how its
        // firmware and the network behave.  Attempting both protocols once is
        // simpler and cannot be defeated by a stale stored value — from an older
        // build's default, discovery, an App Intents round trip, or a hand pin
        // made before the panel was upgraded.
        //
        // `hasTriedVoIP` latches, so this happens at most once per connection,
        // and a SIP failure hands back to legacy reconnect (see handleSIPState)
        // so a merely-offline legacy panel keeps its retry behaviour.
        if !isServerSide, mode == .legacy, !hasTriedVoIP, !hasEverConnected {
            let why = Self.isConnectionRefused(error) ? "actively refused" : "did not connect"
            print("IntercomConnection: [\(device.name)] legacy port \(device.port) \(why) " +
                  "(protocol='\(device.protocolKind.rawValue)') — trying VoIP/SIP")
            switchToVoIPAfterProbe()
            return
        }

        pingTimer?.invalidate()
        pingTimer = nil
        stopAudioKeepalive()
        nwConn?.cancel()
        nwConn = nil
        receiveBuffer.removeAll()

        guard !isServerSide, !explicitEnd, reconnectAttempt < Self.maxReconnectAttempts else {
            let gaveUp = !isServerSide && !explicitEnd
            callId = ""
            state = gaveUp ? .error("Reconnect failed after \(reconnectAttempt) attempts") : .disconnected
            return
        }

        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), Self.maxReconnectDelay)
        print("IntercomConnection: [\(device.name)] connection lost unexpectedly — reconnecting in \(delay)s (attempt \(reconnectAttempt)/\(Self.maxReconnectAttempts))")
        state = .reconnecting

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.attemptReconnect()
        }
    }

    private func attemptReconnect() {
        guard case .reconnecting = state else { return }
        print("IntercomConnection: [\(device.name)] reconnecting (attempt \(reconnectAttempt)/\(Self.maxReconnectAttempts))")
        connect()
    }

    private func receive() {
        nwConn?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data {
                    self.receiveBuffer.append(data)
                    let (msgs, remaining) = IntercomMessage.decode(from: self.receiveBuffer)
                    self.receiveBuffer = remaining
                    msgs.forEach { self.handle($0) }
                }
                if done || err != nil {
                    print("IntercomConnection: [\(self.device.name)] socket closed — done=\(done) err=\(err.map { "\($0)" } ?? "nil") state=\(self.state)")
                    self.handleUnexpectedDrop(error: err)
                } else {
                    self.receive()
                }
            }
        }
    }

    private func handle(_ msg: IntercomMessage) {
        switch msg.type {
        case .audio:
            onAudioReceived?(msg.payload)

        case .start:
            guard let p = StartPayload(data: msg.payload) else { return }
            explicitEnd = false   // fresh call attempt on this connection
            callId = p.callId
            // Learn the caller's identity from the START payload.
            // Use the remote host from the NWConnection for display.
            let remoteHost = remoteHostString()
            device = IntercomDevice(
                id: device.id,          // keep stable UUID
                name: p.callerName.isEmpty ? remoteHost : p.callerName,
                host: remoteHost,
                port: 0,
                protocolKind: .legacy
            )
            // Acknowledge receipt by ringing.
            send(.ring(callId: callId))
            state = .incoming

        case .ring:
            break   // device is ringing; remain in .outgoing

        case .answer:
            state = .active

        case .hangup:
            explicitEnd = true
            callId = ""
            state  = .idle

        case .decline:
            explicitEnd = true
            callId = ""
            state  = .idle

        case .ping:
            send(.pong())

        case .pong, .error:
            break
        }
    }

    private func remoteHostString() -> String {
        guard let endpoint = nwConn?.endpoint,
              case .hostPort(let host, _) = endpoint
        else { return "unknown" }
        return "\(host)"
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        // Only client-side legacy connections send keepalive pings.  SIP peers
        // use OPTIONS, which the endpoint answers without a per-call timer.
        guard !isServerSide, mode == .legacy else { return }
        pingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Keep the connection alive in every "connected" state — not
                // just .idle.  During an active call with the mic muted we send
                // no AUDIO frames, so without these pings the ESP sees a silent
                // socket and drops the call after its keepalive timeout.
                switch self.state {
                case .idle, .outgoing, .active:
                    self.send(.ping())
                default:
                    break
                }
            }
        }
    }
}
