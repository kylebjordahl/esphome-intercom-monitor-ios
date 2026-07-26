import Foundation
import Network

// One SIP dialog — the `voip-pcm/1` replacement for a legacy PBX-lite TCP call.
//
// Supported methods (docs/voip_profile.md): INVITE, ACK, CANCEL, BYE, OPTIONS.
// Deliberately NOT implemented, because the ESP profile forbids or omits them:
//
//   * REGISTER / digest auth — ESP never challenges, and a 401/407 from any peer
//     is reported as `auth_required_unsupported` rather than retried.
//   * in-dialog re-INVITE / UPDATE offers — answered `488` while the existing
//     dialog and its media selection stay live, exactly as an ESP endpoint does.
//   * video — ESP endpoints never advertise or decode it.
//
// Media is handled by RTPAudioSession; this class only negotiates it.
@MainActor
final class SIPCall {

    enum State: Equatable, Sendable {
        case idle
        case calling         // INVITE sent, no provisional response yet
        case remoteRinging   // 180 received
        case incoming        // inbound INVITE, we sent 180 and await the user
        case active          // 200 + ACK exchanged, media flowing
        case ended(String)   // normal termination (BYE / CANCEL / decline)
        case failed(String)  // transport or negotiation failure
    }

    // MARK: - Identity

    let callID: String
    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    let isInbound: Bool

    // MARK: - Callbacks

    var onStateChange: ((State) -> Void)?
    /// Host-order S16 PCM from the RTP session, ready for AudioEngine.
    var onAudioReceived: ((Data) -> Void)?
    /// Caller identity learned from an inbound INVITE (display name, host).
    var onRemoteIdentity: ((String, String) -> Void)?

    // MARK: - Dialog state

    private var localTag  = SIPMessage.newTag()
    private var remoteTag: String?
    private var localCSeq = UInt32.random(in: 1...1_000)
    private var remoteCSeq = 0
    private var lastInviteBranch = SIPMessage.newBranch()

    /// Request-URI / route target for in-dialog requests.
    private var remoteTarget: String
    private var localURI: String
    private var remoteURI: String
    private var localDisplayName: String

    /// Retained so CANCEL and 487 can reference the original transaction.
    private var pendingInvite: SIPMessage?
    /// Retained so an inbound INVITE can be answered or rejected later.
    private var inboundInvite: SIPMessage?
    private var inboundOffer: SDPSession.ParsedSDP?

    // MARK: - Transport

    private let peerHost: String
    private let peerPort: UInt16
    private let transport: SIPTransportKind
    private weak var endpoint: SIPEndpoint?
    /// Connection used for our own requests (client side) or the accepted
    /// connection an inbound request arrived on (server side).
    private var signaling: NWConnection?
    private var signalingBuffer = Data()

    // MARK: - Media

    private var media: RTPAudioSession?
    private let localRTPPort: UInt16
    private var negotiated: SDPMediaDescription?
    private var localMediaFormat: VoipAudioFormat

    var isTalking = false {
        didSet { media?.isTalking = isTalking }
    }

    /// Human-readable identity of the far end, for the UI.
    private(set) var remoteDisplayName: String
    var remoteAddress: String { peerHost }

    // MARK: - Init

    /// Outbound call to a known SIP endpoint.
    init(outboundTo device: IntercomDevice,
         callerName: String,
         endpoint: SIPEndpoint) {
        self.isInbound        = false
        self.endpoint         = endpoint
        self.peerHost         = device.host
        self.peerPort         = UInt16(device.sipPort)
        self.transport        = device.sipTransport
        self.callID           = SIPMessage.newCallID(host: endpoint.localAddress)
        self.localRTPPort     = RTPAudioSession.allocateLocalPort()
        self.localDisplayName = callerName
        self.localMediaFormat = VoipAudioFormat.appDefault(
            frameMs: device.preferredFrameMs ?? 20)
        self.remoteDisplayName = device.name

        let contactPort = endpoint.localPort
        self.localURI     = "sip:\(Self.uriUser(callerName))@\(endpoint.localAddress):\(contactPort)"
        // Belt and braces: the roster commonly carries an empty `sip_uri`, and a
        // blank Request-URI would produce a malformed INVITE.
        self.remoteURI = device.sipURI?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? "sip:\(Self.uriUser(device.name))@\(device.host):\(device.sipPort)"
        self.remoteTarget = self.remoteURI
    }

    /// Inbound call: an INVITE arrived on `connection`.
    init(inbound invite: SIPMessage,
         from connection: NWConnection,
         peerHost: String,
         peerPort: UInt16,
         transport: SIPTransportKind,
         localName: String,
         endpoint: SIPEndpoint) {
        self.isInbound        = true
        self.endpoint         = endpoint
        self.peerHost         = peerHost
        self.peerPort         = peerPort
        self.transport        = transport
        self.callID           = invite.callID ?? SIPMessage.newCallID(host: endpoint.localAddress)
        self.localRTPPort     = RTPAudioSession.allocateLocalPort()
        self.localDisplayName = localName
        self.localMediaFormat = VoipAudioFormat.appDefault()
        self.signaling        = connection
        self.inboundInvite    = invite
        self.remoteTag        = invite.fromTag
        self.remoteCSeq       = invite.cseq?.number ?? 0

        let fromHeader = invite.first("From")
        self.remoteDisplayName = SIPMessage.displayName(in: fromHeader)
            ?? SIPMessage.uri(in: fromHeader).flatMap(Self.userPart)
            ?? peerHost
        self.remoteURI    = SIPMessage.uri(in: fromHeader) ?? "sip:\(peerHost):\(peerPort)"
        // In-dialog requests go to the caller's Contact when it provided one.
        self.remoteTarget = SIPMessage.uri(in: invite.first("Contact")) ?? self.remoteURI
        self.localURI     = "sip:\(Self.uriUser(localName))@\(endpoint.localAddress):\(endpoint.localPort)"
    }

    // MARK: - Outbound call setup

    func dial() {
        guard !isInbound, state == .idle else { return }

        let params: NWParameters
        switch transport {
        case .udp:
            params = .udp
        case .tcp:
            let tcpOpts = NWProtocolTCP.Options()
            tcpOpts.enableKeepalive = true
            tcpOpts.keepaliveIdle   = 30
            params = NWParameters(tls: nil, tcp: tcpOpts)
        }

        let conn = NWConnection(host: NWEndpoint.Host(peerHost),
                                port: NWEndpoint.Port(rawValue: peerPort) ?? 5060,
                                using: params)
        signaling = conn
        conn.stateUpdateHandler = { [weak self] nwState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch nwState {
                case .ready:
                    print("SIPCall: signaling ready \(self.transport.rawValue) " +
                          "→ \(self.peerHost):\(self.peerPort)")
                    self.sendInitialInvite()
                case .failed(let error):
                    print("SIPCall: signaling failed \(self.transport.rawValue) " +
                          "→ \(self.peerHost):\(self.peerPort) — \(error)")
                    self.state = .failed("SIP transport failed: \(error.localizedDescription)")
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        receiveLoop(on: conn)
        state = .calling
    }

    private func sendInitialInvite() {
        guard state == .calling, pendingInvite == nil else { return }

        let offer = SDPSession.buildDescription(
            address: endpoint?.localAddress ?? "0.0.0.0",
            port: localRTPPort,
            format: localMediaFormat,
            payloadType: SDPSession.localL16PayloadType)

        var invite = SIPMessage(
            kind: .request(method: .invite, uri: remoteTarget),
            headers: [],
            body: offer)
        localCSeq += 1
        lastInviteBranch = SIPMessage.newBranch()
        applyCommonHeaders(to: &invite, cseq: localCSeq, method: "INVITE",
                           branch: lastInviteBranch)
        invite.set("Content-Type", SDPSession.contentType)

        pendingInvite = invite
        send(invite)
        print("SIPCall: INVITE → \(remoteTarget) callID=\(callID) offer=\(localMediaFormat.wireToken)")
    }

    // MARK: - Call control

    /// Accept an inbound call: 200 OK carrying our SDP answer.
    func answer() {
        guard isInbound, state == .incoming,
              let invite = inboundInvite, let offer = inboundOffer else { return }

        let media: SDPMediaDescription
        do {
            media = try SDPSession.negotiate(offer,
                                             preferredFrameMs: localMediaFormat.frameMs)
        } catch {
            print("SIPCall: cannot answer — \(error.localizedDescription)")
            respond(to: invite, code: 488, reason: "Not Acceptable Here")
            state = .failed(error.localizedDescription)
            return
        }

        localMediaFormat = media.format
        negotiated       = media

        let answerBody = SDPSession.buildDescription(
            address: endpoint?.localAddress ?? "0.0.0.0",
            port: localRTPPort,
            format: media.format,
            // Echo the offerer's payload numbering back to it.
            payloadType: media.payloadType,
            dtmfPayloadType: media.telephoneEventPayloadType)

        var response = buildResponse(to: invite, code: 200, reason: "OK")
        response.set("Content-Type", SDPSession.contentType)
        response.set("Contact", "<\(localURI)>")
        response.body = answerBody
        send(response)

        startMedia(with: media)
        state = .active
    }

    /// Reject an inbound call.  `603 Decline` is the profile's explicit
    /// user-declined response; `486 Busy Here` is reserved for busy/DND.
    func decline(busy: Bool = false) {
        guard isInbound, state == .incoming, let invite = inboundInvite else { return }
        if busy {
            respond(to: invite, code: 486, reason: "Busy Here")
        } else {
            respond(to: invite, code: 603, reason: "Decline")
        }
        state = .ended("declined")
    }

    /// End the call.  Before a final response this is a CANCEL; after the dialog
    /// is established it is a BYE.
    func hangup() {
        switch state {
        case .calling, .remoteRinging:
            sendCancel()
            state = .ended("cancelled")
        case .active:
            sendBye()
            state = .ended("hung up")
        case .incoming:
            decline()
        default:
            break
        }
    }

    /// Release sockets.  Safe to call repeatedly.
    func teardown() {
        media?.stop()
        media = nil
        signaling?.cancel()
        signaling = nil
        endpoint?.unregister(callID: callID)
    }

    /// Forward host-order S16 PCM from AudioEngine into the RTP stream.
    func sendAudio(_ pcm: Data) {
        media?.enqueue(pcm)
    }

    // MARK: - Message handling

    /// Called by SIPEndpoint for any message matching this dialog's Call-ID.
    func handle(_ message: SIPMessage, from connection: NWConnection?) {
        if let connection, isInbound { signaling = connection }

        switch message.kind {
        case .response(let code, let reason):
            handleResponse(message, code: code, reason: reason)
        case .request(let method, _):
            handleRequest(message, method: method)
        }
    }

    private func handleResponse(_ message: SIPMessage, code: Int, reason: String) {
        print("SIPCall: ← \(code) \(reason) (\(message.cseq?.method ?? "?")) callID=\(callID)")

        // Only INVITE responses drive the call state machine; a late 200 to BYE
        // needs no action.
        guard message.cseq?.method == "INVITE" else { return }

        if let tag = message.toTag, !tag.isEmpty { remoteTag = tag }
        if let contact = SIPMessage.uri(in: message.first("Contact")) {
            remoteTarget = contact
        }

        switch code {
        case 100:
            break                                   // Trying — no state change
        case 180, 183:
            if state == .calling { state = .remoteRinging }
        case 200:
            guard state == .calling || state == .remoteRinging else {
                // Retransmitted 200 — re-ACK and stay put.
                sendAck(); return
            }
            sendAck()
            do {
                let parsed = try SDPSession.parse(message.body)
                let media  = try SDPSession.negotiate(parsed,
                                                      preferredFrameMs: localMediaFormat.frameMs)
                localMediaFormat = media.format
                negotiated       = media
                startMedia(with: media)
                state = .active
            } catch {
                // We got an answer we cannot render — terminate cleanly rather
                // than sitting in a call with no audio.
                print("SIPCall: unusable answer — \(error.localizedDescription)")
                sendBye()
                state = .failed(error.localizedDescription)
            }
        case 401, 407:
            // The ESP profile has no registration/auth story; surface it rather
            // than silently failing.
            state = .failed(code == 401 ? "auth_required_unsupported"
                                        : "proxy_auth_required_unsupported")
        case 486:
            state = .ended("busy")
        case 487:
            state = .ended("cancelled")
        case 488:
            state = .failed("incompatible_audio_format")
        case 603:
            state = .ended("declined")
        default:
            if code >= 400 {
                state = .failed("SIP \(code) \(reason)")
            }
        }
    }

    private func handleRequest(_ message: SIPMessage, method: SIPMethod) {
        remoteCSeq = message.cseq?.number ?? remoteCSeq

        switch method {
        case .invite:
            if state == .idle, isInbound {
                beginInbound(message)
            } else {
                // In-dialog re-INVITE: reject the offer, keep the dialog and its
                // existing media exactly as an ESP endpoint does.
                respond(to: message, code: 488, reason: "Not Acceptable Here")
            }

        case .ack:
            // Completes our 200 OK for an inbound call; media already started.
            break

        case .cancel:
            respond(to: message, code: 200, reason: "OK")
            if let invite = inboundInvite, state == .incoming {
                respond(to: invite, code: 487, reason: "Request Terminated")
            }
            state = .ended("cancelled")

        case .bye:
            respond(to: message, code: 200, reason: "OK")
            state = .ended("remote hung up")

        case .options:
            // Liveness probe — answer with our capabilities.
            var response = buildResponse(to: message, code: 200, reason: "OK")
            response.set("Allow", Self.allowHeader)
            response.set("Accept", SDPSession.contentType)
            send(response)

        case .update, .info:
            // UPDATE offers and INFO digit bodies are not part of the ESP
            // contract; DTMF routing is RTP telephone-event.
            respond(to: message, code: 488, reason: "Not Acceptable Here")
        }
    }

    /// Ring for an inbound INVITE after validating its media offer.
    private func beginInbound(_ invite: SIPMessage) {
        inboundInvite = invite
        respond(to: invite, code: 100, reason: "Trying")

        do {
            let parsed = try SDPSession.parse(invite.body)
            // Validate now so an incompatible caller is rejected immediately
            // instead of ringing the user for a call that cannot carry audio.
            _ = try SDPSession.negotiate(parsed, preferredFrameMs: localMediaFormat.frameMs)
            inboundOffer = parsed
        } catch {
            print("SIPCall: rejecting inbound INVITE — \(error.localizedDescription)")
            respond(to: invite, code: 488, reason: "Not Acceptable Here")
            state = .failed(error.localizedDescription)
            return
        }

        onRemoteIdentity?(remoteDisplayName, peerHost)

        var ringing = buildResponse(to: invite, code: 180, reason: "Ringing")
        ringing.set("Contact", "<\(localURI)>")
        send(ringing)
        state = .incoming
    }

    // MARK: - Media

    private func startMedia(with description: SDPMediaDescription) {
        media?.stop()

        let session = RTPAudioSession(
            remoteAddress: description.address,
            remotePort: UInt16(clamping: description.port),
            localPort: localRTPPort,
            format: description.format,
            payloadType: description.payloadType,
            telephoneEventPayloadType: description.telephoneEventPayloadType)

        session.onAudioReceived = { [weak self] pcm in
            self?.onAudioReceived?(pcm)
        }
        session.onFailure = { [weak self] reason in
            self?.state = .failed("media: \(reason)")
        }
        session.isTalking = isTalking
        session.start()
        media = session

        print("SIPCall: media up \(description.format.wireToken) pt=\(description.payloadType) " +
              "→ \(description.address):\(description.port)")
    }

    // MARK: - Request/response construction

    static let allowHeader = "INVITE, ACK, CANCEL, BYE, OPTIONS"

    private func applyCommonHeaders(to message: inout SIPMessage,
                                    cseq: UInt32,
                                    method: String,
                                    branch: String) {
        let localHost = endpoint?.localAddress ?? "0.0.0.0"
        let localPort = endpoint?.localPort ?? 5060
        message.set("Via", "SIP/2.0/\(transport.viaToken) \(localHost):\(localPort)" +
                           ";branch=\(branch);rport")
        message.set("Max-Forwards", "70")
        message.set("From", "\"\(localDisplayName)\" <\(localURI)>;tag=\(localTag)")
        if let remoteTag {
            message.set("To", "<\(remoteURI)>;tag=\(remoteTag)")
        } else {
            message.set("To", "<\(remoteURI)>")
        }
        message.set("Call-ID", callID)
        message.set("CSeq", "\(cseq) \(method)")
        message.set("Contact", "<\(localURI)>")
        message.set("Allow", Self.allowHeader)
        message.set("User-Agent", "IntercomListener/voip-pcm-1")
    }

    /// Build a response that mirrors the request's dialog-identifying headers.
    private func buildResponse(to request: SIPMessage, code: Int, reason: String) -> SIPMessage {
        var response = SIPMessage(kind: .response(code: code, reason: reason),
                                  headers: [], body: Data())
        // Via headers are copied verbatim and in order.
        for via in request.all("Via") { response.append("Via", via) }
        if let from = request.first("From") { response.set("From", from) }

        // Every response that establishes or confirms a dialog carries our tag.
        if var to = request.first("To") {
            if SIPMessage.parameter("tag", in: to) == nil, code > 100 {
                to += ";tag=\(localTag)"
            }
            response.set("To", to)
        }
        if let callID = request.first("Call-ID") { response.set("Call-ID", callID) }
        if let cseq   = request.first("CSeq")    { response.set("CSeq", cseq) }
        response.set("Allow", Self.allowHeader)
        response.set("User-Agent", "IntercomListener/voip-pcm-1")
        return response
    }

    private func respond(to request: SIPMessage, code: Int, reason: String) {
        send(buildResponse(to: request, code: code, reason: reason))
    }

    private func sendAck() {
        var ack = SIPMessage(kind: .request(method: .ack, uri: remoteTarget),
                             headers: [], body: Data())
        // ACK for a 2xx is its own transaction but reuses the INVITE's CSeq number.
        applyCommonHeaders(to: &ack, cseq: localCSeq, method: "ACK",
                           branch: SIPMessage.newBranch())
        send(ack)
    }

    private func sendCancel() {
        guard let invite = pendingInvite else { return }
        var cancel = SIPMessage(kind: .request(method: .cancel, uri: remoteTarget),
                                headers: [], body: Data())
        // CANCEL must match the INVITE's branch and CSeq number exactly.
        applyCommonHeaders(to: &cancel, cseq: localCSeq, method: "CANCEL",
                           branch: lastInviteBranch)
        if let to = invite.first("To") { cancel.set("To", to) }
        send(cancel)
    }

    private func sendBye() {
        localCSeq += 1
        var bye = SIPMessage(kind: .request(method: .bye, uri: remoteTarget),
                             headers: [], body: Data())
        applyCommonHeaders(to: &bye, cseq: localCSeq, method: "BYE",
                           branch: SIPMessage.newBranch())
        send(bye)
    }

    private func send(_ message: SIPMessage) {
        guard let signaling else { return }
        signaling.send(content: message.encode(), completion: .contentProcessed { error in
            guard let error else { return }
            print("SIPCall: send failed — \(error)")
        })
    }

    // MARK: - Receiving on our own signaling socket

    private func receiveLoop(on connection: NWConnection) {
        switch transport {
        case .udp:  receiveDatagram(on: connection)
        case .tcp:  receiveStream(on: connection)
        }
    }

    /// UDP: one datagram is exactly one SIP message.
    ///
    /// This MUST use `receiveMessage` and re-arm unconditionally.  With the
    /// stream-oriented `receive`, every datagram sets `isComplete` — a UDP
    /// "message" is complete as soon as it arrives — so treating that as
    /// end-of-stream tore the loop down after the very first response.  The
    /// symptom was a call that logged `100 Trying` and then went permanently
    /// deaf: the `180 Ringing` and `200 OK` were delivered but never read, so
    /// the call sat in `.calling` until the user gave up and hung up.
    private func receiveDatagram(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty, let message = SIPMessage.decode(data) {
                    self.handle(message, from: connection)
                }
                // Only a real transport error stops the loop; a completed
                // datagram is the normal case, not a reason to stop listening.
                if let error {
                    print("SIPCall: UDP signaling error — \(error)")
                    if case .active = self.state { self.state = .ended("signaling closed") }
                    return
                }
                guard self.signaling === connection else { return }   // superseded/torn down
                self.receiveDatagram(on: connection)
            }
        }
    }

    /// TCP: a byte stream that may split or coalesce messages, so buffer and
    /// frame by Content-Length.  Here `isComplete` genuinely means FIN.
    private func receiveStream(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.signalingBuffer.append(data)
                    while let framed = SIPMessage.frame(from: self.signalingBuffer) {
                        self.signalingBuffer = framed.remaining
                        if let message = SIPMessage.decode(framed.message) {
                            self.handle(message, from: connection)
                        }
                    }
                }
                if isComplete || error != nil {
                    if case .active = self.state {
                        self.state = .ended("signaling closed")
                    }
                    return
                }
                guard self.signaling === connection else { return }
                self.receiveStream(on: connection)
            }
        }
    }

    // MARK: - URI helpers

    /// Encode a device name as a SIP user part.
    ///
    /// The name is preserved verbatim apart from percent-escaping, because the
    /// roster addresses panels by their exact name (`sip:Kitchen@192.168.1.51`)
    /// and VoIP Stack validates the Request-URI.  Lowercasing or substituting
    /// separators here produced URIs like `sip:poppy_monitor@…` that a panel
    /// named "Poppy Monitor" has no reason to accept.
    ///
    /// Nonisolated: roster parsing builds URIs off the main actor.
    nonisolated static func uriUser(_ name: String) -> String {
        // RFC 3261 user part: unreserved / escaped / user-unreserved.
        let unreserved = Set("abcdefghijklmnopqrstuvwxyz" +
                             "ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
                             "0123456789" +
                             "-_.!~*'()" +
                             "&=+$,;?/")
        var out = ""
        for byte in Array(name.utf8) {
            let scalar = Character(UnicodeScalar(byte))
            if byte < 0x80, unreserved.contains(scalar) {
                out.append(scalar)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out.isEmpty ? "phone" : out
    }

    nonisolated static func userPart(_ uri: String) -> String? {
        guard let at = uri.firstIndex(of: "@") else { return nil }
        let scheme = uri.hasPrefix("sip:") ? uri.index(uri.startIndex, offsetBy: 4) : uri.startIndex
        let user = String(uri[scheme..<at])
        return user.isEmpty ? nil : user
    }
}
