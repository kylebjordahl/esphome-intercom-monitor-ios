import Foundation
import Network

/// SIP signaling transport.  The profile allows UDP or TCP on the same
/// configured SIP port; RTP audio is always UDP regardless of this choice.
enum SIPTransportKind: String, Codable, Sendable {
    case udp
    case tcp

    var viaToken: String { self == .tcp ? "TCP" : "UDP" }

    init?(token: String?) {
        guard let token = token?.trimmingCharacters(in: .whitespaces).lowercased(),
              !token.isEmpty
        else { return nil }
        switch token {
        case "udp", "sip/udp": self = .udp
        case "tcp", "sip/tcp": self = .tcp
        default: return nil
        }
    }
}

// Owns this device's SIP presence: the UDP and TCP listeners on the SIP port,
// and the Call-ID → dialog routing table.
//
// Inbound in-dialog requests (BYE, CANCEL, re-INVITE) are addressed to the
// Contact URI we advertise, which points at this listener — not at the ephemeral
// socket an outbound call used.  So every dialog registers itself here and the
// endpoint demultiplexes by Call-ID; an INVITE with an unknown Call-ID becomes a
// new inbound call.
@MainActor
final class SIPEndpoint: ObservableObject {

    /// Nonisolated: roster parsing and view initialisers read this off the main
    /// actor, and it is an immutable constant.
    nonisolated static let defaultPort: UInt16 = 5060

    /// Shared instance.  A SIP user agent is a per-device singleton — there is
    /// one listening port and one dialog table — and routing it through here
    /// keeps IntercomConnection free of extra plumbing on both platforms.
    static let shared = SIPEndpoint()

    @Published private(set) var isListening = false
    @Published private(set) var error: String?

    /// Address advertised in Via/Contact/SDP.  Resolved from the Wi-Fi
    /// interface when the endpoint starts.
    private(set) var localAddress: String = "0.0.0.0"
    private(set) var localPort: UInt16 = SIPEndpoint.defaultPort
    private(set) var localName: String = "iPhone"

    /// Delivered for an INVITE that doesn't match an existing dialog.
    var onIncomingCall: ((SIPCall) -> Void)?

    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    private var calls: [String: SIPCall] = [:]
    /// TCP framing buffers, one per accepted connection.
    private var tcpBuffers: [ObjectIdentifier: Data] = [:]

    // MARK: - Lifecycle

    /// Bring the endpoint up before placing an outbound call.
    ///
    /// Outbound SIP is not self-contained: Via, Contact and the SDP `c=` line all
    /// have to carry a reachable address, and the peer sends BYE to that Contact
    /// rather than back down the socket we dialled from.  So an outbound-only
    /// user still needs the listener running and the local address resolved.
    @discardableResult
    func ensureStarted(localName: String) -> Bool {
        if udpListener == nil && tcpListener == nil {
            guard let ip = localWiFiIPAddress() else {
                error = "No Wi-Fi address — SIP calls need a LAN address"
                print("SIPEndpoint: cannot start, no local Wi-Fi address")
                return false
            }
            start(localName: localName, address: ip)
            return true
        }
        // Already listening, but a Wi-Fi change may have moved us.
        if localAddress == "0.0.0.0", let ip = localWiFiIPAddress() {
            localAddress = ip
        }
        return localAddress != "0.0.0.0"
    }

    func start(localName: String, address: String, port: UInt16 = SIPEndpoint.defaultPort) {
        guard udpListener == nil, tcpListener == nil else { return }
        self.localName    = localName
        self.localAddress = address
        self.localPort    = port

        udpListener = makeListener(parameters: .udp, port: port, label: "UDP")
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.enableKeepalive = true
        tcpListener = makeListener(parameters: NWParameters(tls: nil, tcp: tcpOpts),
                                   port: port, label: "TCP")
    }

    func stop() {
        udpListener?.cancel(); udpListener = nil
        tcpListener?.cancel(); tcpListener = nil
        calls.values.forEach { $0.teardown() }
        calls.removeAll()
        tcpBuffers.removeAll()
        isListening = false
    }

    private func makeListener(parameters: NWParameters,
                              port: UInt16,
                              label: String) -> NWListener? {
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters,
                                          on: NWEndpoint.Port(rawValue: port) ?? .any)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.error = nil
                        print("SIPEndpoint: listening \(label) on \(self.localAddress):\(port)")
                    case .failed(let err):
                        self.error = err.localizedDescription
                        print("SIPEndpoint: \(label) listener failed — \(err)")
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection, transport: label == "TCP" ? .tcp : .udp)
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            return listener
        } catch {
            self.error = error.localizedDescription
            print("SIPEndpoint: could not bind \(label) \(port) — \(error)")
            return nil
        }
    }

    // MARK: - Dialog registry

    func register(_ call: SIPCall) {
        calls[call.callID] = call
    }

    func unregister(callID: String) {
        calls.removeValue(forKey: callID)
    }

    var activeCallCount: Int { calls.count }

    // MARK: - Inbound

    private func accept(_ connection: NWConnection, transport: SIPTransportKind) {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .cancelled = state {
                    self.tcpBuffers.removeValue(forKey: ObjectIdentifier(connection))
                }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveLoop(on: connection, transport: transport)
    }

    private func receiveLoop(on connection: NWConnection, transport: SIPTransportKind) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty {
                    switch transport {
                    case .udp:
                        if let message = SIPMessage.decode(data) {
                            self.route(message, from: connection, transport: transport)
                        }
                    case .tcp:
                        let key = ObjectIdentifier(connection)
                        var buffer = self.tcpBuffers[key] ?? Data()
                        buffer.append(data)
                        while let framed = SIPMessage.frame(from: buffer) {
                            buffer = framed.remaining
                            if let message = SIPMessage.decode(framed.message) {
                                self.route(message, from: connection, transport: transport)
                            }
                        }
                        self.tcpBuffers[key] = buffer
                    }
                }
                if isComplete || error != nil {
                    self.tcpBuffers.removeValue(forKey: ObjectIdentifier(connection))
                    connection.cancel()
                    return
                }
                self.receiveLoop(on: connection, transport: transport)
            }
        }
    }

    private func route(_ message: SIPMessage,
                       from connection: NWConnection,
                       transport: SIPTransportKind) {
        guard let callID = message.callID else { return }

        if let existing = calls[callID] {
            existing.handle(message, from: connection)
            return
        }

        // Unknown Call-ID.
        switch message.kind {
        case .request(let method, _) where method == .invite:
            let (host, port) = Self.peer(of: connection)
            let call = SIPCall(inbound: message,
                               from: connection,
                               peerHost: host,
                               peerPort: port,
                               transport: transport,
                               localName: localName,
                               endpoint: self)
            calls[callID] = call
            onIncomingCall?(call)
            // Let the owner wire its callbacks before the dialog starts ringing.
            call.handle(message, from: connection)

        case .request(let method, _) where method == .options:
            // Bare liveness probe outside any dialog — answer so peers and HA
            // can see this endpoint is alive.
            var response = SIPMessage(kind: .response(code: 200, reason: "OK"),
                                      headers: [], body: Data())
            for via in message.all("Via") { response.append("Via", via) }
            if let from = message.first("From")    { response.set("From", from) }
            if let to   = message.first("To")      { response.set("To", to + ";tag=\(SIPMessage.newTag())") }
            response.set("Call-ID", callID)
            if let cseq = message.first("CSeq")    { response.set("CSeq", cseq) }
            response.set("Allow", SIPCall.allowHeader)
            response.set("Contact", "<sip:\(SIPCall.uriUser(localName))@\(localAddress):\(localPort)>")
            connection.send(content: response.encode(), completion: .contentProcessed { _ in })

        case .request:
            // In-dialog method for a dialog we no longer have.
            var response = SIPMessage(kind: .response(code: 481,
                                                      reason: "Call/Transaction Does Not Exist"),
                                      headers: [], body: Data())
            for via in message.all("Via") { response.append("Via", via) }
            if let from = message.first("From") { response.set("From", from) }
            if let to   = message.first("To")   { response.set("To", to) }
            response.set("Call-ID", callID)
            if let cseq = message.first("CSeq") { response.set("CSeq", cseq) }
            connection.send(content: response.encode(), completion: .contentProcessed { _ in })

        case .response:
            break   // stray response for a dialog we already dropped
        }
    }

    private static func peer(of connection: NWConnection) -> (host: String, port: UInt16) {
        guard case .hostPort(let host, let port) = connection.endpoint else {
            return ("0.0.0.0", SIPEndpoint.defaultPort)
        }
        // NWEndpoint.Host renders IPv6 with a scope suffix (fe80::1%en0); strip
        // it so the string can be reused in SIP URIs.
        let rendered = "\(host)".components(separatedBy: "%").first ?? "\(host)"
        return (rendered, port.rawValue)
    }
}
