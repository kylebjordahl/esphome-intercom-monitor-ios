import Foundation
import Network
import Security

// One monitored RTSP/RTSPS audio stream: signaling, media, and recovery.
//
// This is the third media source behind the IntercomConnection facade, alongside
// legacy PBX-lite and SIP/RTP.  Unlike those two it is **one-way**: there is no
// call to answer, nothing to transmit, and no keepalive obligation on the media
// path — only the RTSP session timeout to satisfy.
//
// Design decisions worth keeping:
//
//   * **Audio only.**  Only the audio m-section of the SDP is SETUP, so the
//     server never sends video.  A camera's video track is 100× the bitrate of
//     its audio; monitoring it would cost battery and Wi-Fi for pixels nobody
//     looks at.
//
//   * **RTP interleaved over the signaling socket** (`RTP/AVP/TCP`), not UDP.
//     One socket means no second port to bind, no NAT/firewall asymmetry, no
//     jitter-buffer reordering work (TCP delivers in order), and it is the only
//     transport that also works under TLS.  The trade-off — TCP can bunch
//     packets under loss — is the right one for a listen-only monitor.
//
//   * **Recovery favours a stream that has played.**  A monitor is expected to
//     survive a Wi-Fi blip for hours, so once PLAY has succeeded we retry
//     indefinitely with a capped backoff.  A stream that never played is
//     probably a wrong URL, so it fails after a few attempts *with the reason*
//     instead of retrying forever in silence.

// MARK: - Target

/// A parsed `rtsp://` / `rtsps://` URL.
struct RTSPTarget: Equatable {
    var host: String
    var port: UInt16
    var isSecure: Bool
    /// Absolute request URI **without** credentials.  Digest hashes this
    /// verbatim, so it has to be exactly what goes on the wire.
    var uri: String
    var username: String?
    var password: String?

    static let defaultPort: UInt16 = 554
    static let defaultSecurePort: UInt16 = 322

    /// Parse a stream URL, splitting out any `user:pass@` userinfo.
    ///
    /// Hand-written rather than going through `URL`: RTSP is not one of
    /// Foundation's "special" schemes, credentials routinely contain
    /// characters that make `URL` return nil, and the request URI has to come
    /// back out byte-stable for digest authentication.
    static func parse(_ raw: String) -> RTSPTarget? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var isSecure = false
        let lowered = text.lowercased()
        if lowered.hasPrefix("rtsps://") {
            isSecure = true
            text = String(text.dropFirst("rtsps://".count))
        } else if lowered.hasPrefix("rtsp://") {
            text = String(text.dropFirst("rtsp://".count))
        } else if lowered.contains("://") {
            return nil          // http, https, … — not an RTSP stream
        }
        guard !text.isEmpty else { return nil }

        // Authority ends at the first '/', which starts the path.
        let pathStart = text.firstIndex(of: "/")
        var authority = pathStart.map { String(text[text.startIndex..<$0]) } ?? text
        let path      = pathStart.map { String(text[$0...]) } ?? ""

        // userinfo: use the LAST '@' so a password containing '@' still works.
        var username: String?
        var password: String?
        if let at = authority.lastIndex(of: "@") {
            let userinfo = String(authority[authority.startIndex..<at])
            authority = String(authority[authority.index(after: at)...])
            let pair = userinfo.split(separator: ":", maxSplits: 1,
                                      omittingEmptySubsequences: false)
            let user = pair.first.map(String.init) ?? ""
            username = (user.removingPercentEncoding ?? user).nilIfEmpty
            if pair.count > 1 {
                let secret = String(pair[1])
                password = (secret.removingPercentEncoding ?? secret).nilIfEmpty
            }
        }

        // host[:port], with bracketed IPv6 support.
        var host = authority
        var portText: String?
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let rest = authority[authority.index(after: close)...]
            if rest.hasPrefix(":") { portText = String(rest.dropFirst()) }
        } else if let colon = authority.lastIndex(of: ":") {
            host = String(authority[authority.startIndex..<colon])
            portText = String(authority[authority.index(after: colon)...])
        }
        guard !host.isEmpty else { return nil }
        if let portText, portText.isEmpty == false, UInt16(portText) == nil { return nil }

        let fallbackPort = isSecure ? RTSPTarget.defaultSecurePort : RTSPTarget.defaultPort
        let port = portText.flatMap { UInt16($0) } ?? fallbackPort

        let scheme    = isSecure ? "rtsps" : "rtsp"
        let uriHost   = host.contains(":") ? "[\(host)]" : host   // bare IPv6
        var uri       = "\(scheme)://\(uriHost)"
        if port != fallbackPort { uri += ":\(port)" }
        uri += path.isEmpty ? "/" : path

        return RTSPTarget(host: host, port: port, isSecure: isSecure, uri: uri,
                          username: username, password: password)
    }
}

@MainActor
final class RTSPStreamSession {

    // MARK: - State

    enum State: Equatable {
        case idle
        case connecting
        case reconnecting
        /// Media is flowing.
        case playing
        /// Terminal: nothing worth retrying (bad URL, auth rejected, no audio
        /// track, unsupported codec, retries exhausted).
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Fires on the main actor whenever `state` changes.
    var onStateChange: ((State) -> Void)?
    /// 16 kHz mono host-order S16, ready for `AudioEngine.playAudio`.
    var onAudioReceived: ((Data) -> Void)?

    private(set) var packetsReceived = 0

    // MARK: - Configuration

    private let target: RTSPTarget
    private let credentials: StreamCredentials?
    private let userAgent: String

    private static let maxInitialAttempts = 4
    private static let maxReconnectDelay: Double = 30
    /// Anything larger than this without a parseable message means the socket has
    /// desynchronised — bail out instead of buffering forever.
    private static let maxBufferedBytes = 512 * 1_024
    /// Frame size handed to AudioEngine: 512 samples, matching every other audio
    /// path in the app.
    private static let outputFrameBytes = 512 * 2

    // MARK: - Transport state

    private var connection: NWConnection?
    private var readBuffer = Data()
    private let tlsVerifyQueue = DispatchQueue(label: "rtsp.tls.verify")

    private var cseq = 1
    private var pending: [Int: RTSPRequest] = [:]
    private var sessionID: String?
    private var sessionTimeout = 60
    private var aggregateURI: String
    private var controlURI: String
    private var interleavedChannel: UInt8 = 0
    private var keepaliveTimer: Timer?

    // MARK: - Authentication state

    private var challenge: RTSPAuthChallenge?
    private var nonceCount = 0
    private let cnonce: String
    /// 401 retries per method, so a server that keeps rejecting us fails with a
    /// readable reason instead of looping.
    private var authRetries: [String: Int] = [:]

    // MARK: - Media state

    private var track: RTSPAudioTrack?
    private var decoder: RTSPAudioDecoder?
    private var pcmAccumulator = Data()

    // MARK: - Recovery state

    private var hasEverPlayed = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var isStopped = false

    /// A camera that accepts the TCP connection and then says nothing (busy, or
    /// wedged) would otherwise leave the row on "Connecting…" forever.
    private static let handshakeTimeout: Double = 15

    // MARK: - Init

    /// - Parameters:
    ///   - target: parsed stream URL.
    ///   - credentials: Keychain-held username/password.  Credentials embedded in
    ///     the URL are used as a fallback so a pasted URL keeps working.
    init(target: RTSPTarget, credentials: StreamCredentials?, userAgent: String = "IntercomListener") {
        self.target = target
        self.userAgent = userAgent
        if let credentials, !credentials.isEmpty {
            self.credentials = credentials
        } else if let user = target.username {
            self.credentials = StreamCredentials(username: user,
                                                 password: target.password ?? "")
        } else {
            self.credentials = nil
        }
        aggregateURI = target.uri
        controlURI   = target.uri
        cnonce = String(format: "%08x%08x",
                        UInt32.random(in: 0...UInt32.max),
                        UInt32.random(in: 0...UInt32.max))
    }

    /// Convenience for a URL string; nil when the URL isn't a usable RTSP URL.
    convenience init?(url: String, credentials: StreamCredentials?) {
        guard let target = RTSPTarget.parse(url) else { return nil }
        self.init(target: target, credentials: credentials)
    }

    // MARK: - Lifecycle

    func start() {
        guard connection == nil else { return }
        isStopped = false
        openConnection(retrying: false)
    }

    /// Stop monitoring.  Sends TEARDOWN when a session is live so the camera
    /// releases its slot immediately rather than waiting out the timeout —
    /// several models allow only one or two concurrent sessions.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        // NWConnection.cancel() is a graceful close — queued sends go out before
        // the FIN — so the TEARDOWN below still reaches the camera.
        if sessionID != nil, connection != nil {
            send(makeRequest("TEARDOWN", uri: aggregateURI))
        }
        teardownTransport()
        state = .idle
        print("RTSPStreamSession: [\(target.host)] stopped")
    }

    // MARK: - Connection

    private func openConnection(retrying: Bool) {
        state = retrying ? .reconnecting : .connecting

        readBuffer.removeAll()
        pcmAccumulator.removeAll()
        pending.removeAll()
        authRetries.removeAll()
        sessionID = nil
        aggregateURI = target.uri
        controlURI   = target.uri

        let connection = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: target.port) ?? 554,
            using: parameters())
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] nwState in
            Task { @MainActor [weak self] in self?.handle(nwState) }
        }
        print("RTSPStreamSession: [\(target.host)] connecting \(target.uri) " +
              "(\(target.isSecure ? "TLS" : "plain") port \(target.port)" +
              "\(retrying ? ", retry \(reconnectAttempt)" : ""))")
        connection.start(queue: .global(qos: .userInitiated))
        receiveLoop()

        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.handshakeTimeout))
            guard let self, !Task.isCancelled, self.state != .playing else { return }
            self.handleDrop("no response from the server")
        }
    }

    private func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle   = 30
        tcp.noDelay         = true
        // Bound the attempt: a camera that silently drops the SYN would otherwise
        // leave the row on "Connecting…" for the system default timeout.
        tcp.connectionTimeout = 5

        guard target.isSecure else { return NWParameters(tls: nil, tcp: tcp) }

        let tls = NWProtocolTLS.Options()
        // Cameras and restreamers on a home LAN present self-signed certificates
        // for an IP address, so default trust evaluation always fails and
        // rtsps:// would simply never work.  Accept the certificate: TLS is still
        // doing the job that matters here — the camera password and the audio
        // don't cross the LAN in the clear — and vouching for the peer's identity
        // was never possible without a CA the user controls.
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            tlsVerifyQueue)
        return NWParameters(tls: tls, tcp: tcp)
    }

    private func handle(_ nwState: NWConnection.State) {
        switch nwState {
        case .ready:
            print("RTSPStreamSession: [\(target.host)] socket ready — DESCRIBE")
            sendDescribe()
        case .failed(let error):
            handleDrop("connection failed: \(error.localizedDescription)")
        case .cancelled:
            handleDrop("connection cancelled")
        case .waiting(let error):
            print("RTSPStreamSession: [\(target.host)] waiting — \(error)")
        default:
            break
        }
    }

    private func teardownTransport() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        // Drop the handler before cancelling so the resulting .cancelled event
        // can't re-enter handleDrop and start a reconnect we didn't ask for.
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        readBuffer.removeAll()
        pcmAccumulator.removeAll()
        pending.removeAll()
    }

    // MARK: - Requests

    private func makeRequest(_ method: String,
                             uri: String? = nil,
                             headers: [(name: String, value: String)] = []) -> RTSPRequest {
        defer { cseq += 1 }
        return RTSPRequest(method: method,
                           uri: uri ?? target.uri,
                           cseq: cseq,
                           session: nil,
                           authorization: nil,
                           extraHeaders: headers)
    }

    private func send(_ request: RTSPRequest) {
        guard let connection else { return }
        var request = request
        request.session = sessionID
        request.authorization = authorizationHeader(for: request)
        pending[request.cseq] = request

        connection.send(content: request.encode(userAgent: userAgent),
                        completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.handleDrop("send failed: \(error.localizedDescription)")
            }
        })
    }

    /// Digest signs the method and URI, so the header is rebuilt per request; the
    /// nonce count must increase monotonically for `qop=auth`.
    private func authorizationHeader(for request: RTSPRequest) -> String? {
        guard let challenge, let credentials else { return nil }
        nonceCount += 1
        return challenge.authorization(method: request.method,
                                       uri: request.uri,
                                       credentials: credentials,
                                       cnonce: cnonce,
                                       nonceCount: nonceCount)
    }

    private func sendDescribe() {
        send(makeRequest("DESCRIBE", headers: [(name: "Accept", value: "application/sdp")]))
    }

    private func sendSetup() {
        send(makeRequest("SETUP", uri: controlURI, headers: [
            (name: "Transport", value: "RTP/AVP/TCP;unicast;interleaved=0-1")
        ]))
    }

    private func sendPlay() {
        send(makeRequest("PLAY", uri: aggregateURI,
                         headers: [(name: "Range", value: "npt=0.000-")]))
    }

    // MARK: - Responses

    private func handle(_ response: RTSPResponse) {
        guard let cseq = response.cseq,
              let request = pending.removeValue(forKey: cseq)
        else { return }   // unsolicited or already-answered — nothing to drive

        if response.statusCode == 401 {
            retryWithAuthentication(request, response)
            return
        }
        guard response.isSuccess else {
            fail("\(request.method) rejected — \(response.statusLine)")
            return
        }

        switch request.method {
        case "DESCRIBE": handleDescribe(response)
        case "SETUP":    handleSetup(response)
        case "PLAY":     handlePlay(response)
        default:         break   // OPTIONS keepalive, TEARDOWN
        }
    }

    private func retryWithAuthentication(_ request: RTSPRequest, _ response: RTSPResponse) {
        guard let credentials, !credentials.isEmpty else {
            fail("Stream requires a username and password")
            return
        }
        let attempts = authRetries[request.method] ?? 0
        guard attempts < 2 else {
            fail("Authentication rejected — check the username and password")
            return
        }
        guard let challenge = RTSPAuthChallenge.best(from: response.values("WWW-Authenticate")) else {
            fail("Server sent an authentication challenge this app can't answer")
            return
        }
        guard challenge.isSupported else {
            fail("Unsupported authentication (\(challenge.algorithm ?? challenge.scheme.rawValue))")
            return
        }
        self.challenge = challenge
        authRetries[request.method] = attempts + 1

        var retry = request
        retry.cseq = cseq
        cseq += 1
        send(retry)
    }

    private func handleDescribe(_ response: RTSPResponse) {
        guard let sdp = String(data: response.body, encoding: .utf8), !sdp.isEmpty else {
            fail("Stream description was empty")
            return
        }
        // Content-Base is authoritative for building the SETUP/PLAY URLs.
        aggregateURI = response.contentBase ?? target.uri

        guard let track = RTSPSDP.audioTrack(from: sdp) else {
            fail("Stream has no audio track")
            return
        }
        do {
            decoder = try RTSPAudioDecoder(track: track)
        } catch {
            fail(error.localizedDescription)
            return
        }
        self.track = track
        controlURI = RTSPSDP.resolveControl(track.control,
                                            requestURI: target.uri,
                                            contentBase: response.contentBase)
        print("RTSPStreamSession: [\(target.host)] audio track pt=\(track.payloadType) " +
              "\(track.encoding.label) \(track.sampleRate) Hz ch=\(track.sourceChannels) " +
              "control=\(controlURI)")
        sendSetup()
    }

    private func handleSetup(_ response: RTSPResponse) {
        guard let id = response.sessionID else {
            fail("Server did not open an RTSP session")
            return
        }
        sessionID = id
        if let timeout = response.sessionTimeout, timeout >= 10 { sessionTimeout = timeout }

        // We never open a media socket, so a server that answered with UDP
        // transport would leave us waiting for audio that can't arrive.
        let transport = response.value("Transport") ?? ""
        let channel: UInt8?
        if let advertised = response.interleavedRTPChannel {
            channel = advertised
        } else if transport.lowercased().contains("tcp") {
            channel = 0        // TCP interleaved, channels left implicit: ours
        } else {
            channel = nil
        }
        guard let channel else {
            fail("Server did not accept TCP-interleaved media (transport: " +
                 "\(transport.nilIfEmpty ?? "none"))")
            return
        }
        interleavedChannel = channel
        print("RTSPStreamSession: [\(target.host)] session \(id) " +
              "timeout=\(sessionTimeout)s interleaved channel=\(channel)")
        sendPlay()
    }

    private func handlePlay(_ response: RTSPResponse) {
        _ = response
        hasEverPlayed    = true
        reconnectAttempt = 0
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        startKeepalive()
        state = .playing
        print("RTSPStreamSession: [\(target.host)] playing " +
              "(\(decoder?.formatSummary ?? "?") → 16 kHz mono)")
    }

    /// Keep the RTSP session from timing out.  OPTIONS with the Session header is
    /// the most widely accepted keepalive (GET_PARAMETER is not universal).
    private func startKeepalive() {
        keepaliveTimer?.invalidate()
        let interval = max(10, Double(sessionTimeout) / 2)
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .playing else { return }
                self.send(self.makeRequest("OPTIONS"))
            }
        }
    }

    // MARK: - Reading

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.readBuffer.append(data)
                    self.drainReadBuffer()
                }
                if let error {
                    self.handleDrop("read failed: \(error.localizedDescription)")
                    return
                }
                if isComplete {
                    self.handleDrop("server closed the stream")
                    return
                }
                // drainReadBuffer may have torn the transport down (terminal
                // failure) — don't resurrect the read loop in that case.
                guard self.connection != nil else { return }
                self.receiveLoop()
            }
        }
    }

    /// Split the socket into RTSP responses and interleaved media frames.
    ///
    /// Both share this one connection: a media frame is `$` + channel + 16-bit
    /// length + RTP packet, and anything else must be a `RTSP/1.0 …` response.
    private func drainReadBuffer() {
        while !readBuffer.isEmpty {
            if readBuffer[readBuffer.startIndex] == 0x24 {          // '$'
                guard readBuffer.count >= 4 else { return }
                let header  = [UInt8](readBuffer.prefix(4))
                let channel = header[1]
                let length  = Int(header[2]) << 8 | Int(header[3])
                guard readBuffer.count >= 4 + length else { return }

                let start = readBuffer.index(readBuffer.startIndex, offsetBy: 4)
                let end   = readBuffer.index(start, offsetBy: length)
                let packet = Data(readBuffer[start..<end])
                readBuffer.removeFirst(4 + length)
                handleInterleaved(channel: channel, packet: packet)
                continue
            }

            // A response always starts with the version token.  Checking it here
            // is what turns a desynchronised socket into a clear failure instead
            // of an endlessly growing buffer.
            if readBuffer.count >= 5,
               !readBuffer.prefix(5).elementsEqual(Data("RTSP/".utf8)) {
                fail("Unexpected data on the RTSP connection")
                return
            }
            guard let (response, consumed) = RTSPResponse.parse(readBuffer) else {
                if readBuffer.count > Self.maxBufferedBytes {
                    fail("Malformed RTSP response")
                }
                return   // still arriving
            }
            readBuffer.removeFirst(consumed)
            handle(response)
            guard connection != nil else { return }
        }
    }

    private func handleInterleaved(channel: UInt8, packet: Data) {
        // Channel mismatch = RTCP (or another track we didn't set up).
        guard channel == interleavedChannel else { return }
        guard let decoder, let rtp = Self.parseRTPPacket(packet) else { return }
        // Ignore anything that isn't the negotiated payload type: a stray DTMF or
        // comfort-noise packet rendered as PCM is a burst of noise.
        guard let track, rtp.payloadType == track.payloadType else { return }
        guard !rtp.payload.isEmpty else { return }

        packetsReceived += 1
        let pcm = decoder.decode(rtp.payload)
        guard !pcm.isEmpty else { return }
        emit(pcm)
    }

    /// Re-frame decoded PCM into fixed 512-sample frames before handing it on, so
    /// playback sees the same frame size as the intercom paths regardless of how
    /// the camera packetises its audio.
    private func emit(_ pcm: Data) {
        pcmAccumulator.append(pcm)
        while pcmAccumulator.count >= Self.outputFrameBytes {
            let frame = pcmAccumulator.prefix(Self.outputFrameBytes)
            pcmAccumulator.removeFirst(Self.outputFrameBytes)
            onAudioReceived?(Data(frame))
        }
    }

    // MARK: - RTP

    /// Parse an RTP packet header (RFC 3550) and return its payload.
    /// `nonisolated` so the protocol tests can exercise it directly.
    nonisolated static func parseRTPPacket(
        _ packet: Data
    ) -> (payloadType: UInt8, marker: Bool, sequence: UInt16,
          timestamp: UInt32, payload: Data)? {
        guard packet.count > 12 else { return nil }
        let bytes = [UInt8](packet)
        guard (bytes[0] >> 6) == 2 else { return nil }              // version 2

        let hasPadding   = (bytes[0] & 0x20) != 0
        let hasExtension = (bytes[0] & 0x10) != 0
        let csrcCount    = Int(bytes[0] & 0x0F)
        let marker       = (bytes[1] & 0x80) != 0
        let payloadType  = bytes[1] & 0x7F
        let sequence     = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let timestamp    = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16
                         | UInt32(bytes[6]) << 8  | UInt32(bytes[7])

        var offset = 12 + csrcCount * 4
        guard bytes.count > offset else { return nil }
        if hasExtension {
            guard bytes.count >= offset + 4 else { return nil }
            let words = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4 + words * 4
            guard bytes.count > offset else { return nil }
        }

        var end = bytes.count
        if hasPadding, let padding = bytes.last.map(Int.init), padding > 0, end - padding > offset {
            end -= padding
        }
        guard end > offset else { return nil }

        return (payloadType: payloadType,
                marker: marker,
                sequence: sequence,
                timestamp: timestamp,
                payload: Data(bytes[offset..<end]))
    }

    // MARK: - Failure & recovery

    /// Terminal failure: report the reason and stay down.
    private func fail(_ reason: String) {
        print("RTSPStreamSession: [\(target.host)] failed — \(reason)")
        teardownTransport()
        state = .failed(reason)
    }

    /// The transport died without us asking.  Retry with backoff — see the class
    /// comment for why a stream that has played is retried indefinitely.
    private func handleDrop(_ reason: String) {
        guard !isStopped else { return }
        // Ignore late callbacks from a connection we already gave up on.
        switch state {
        case .failed, .idle: return
        default: break
        }

        teardownTransport()

        guard hasEverPlayed || reconnectAttempt < Self.maxInitialAttempts else {
            state = .failed(reason)
            return
        }

        reconnectAttempt += 1
        let delay = min(Self.maxReconnectDelay, pow(2.0, Double(reconnectAttempt - 1)))
        print("RTSPStreamSession: [\(target.host)] \(reason) — reconnecting in \(delay)s " +
              "(attempt \(reconnectAttempt)\(hasEverPlayed ? "" : "/\(Self.maxInitialAttempts)"))")
        state = .reconnecting

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.isStopped else { return }
            self.openConnection(retrying: true)
        }
    }
}
