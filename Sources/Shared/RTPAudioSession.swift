import Foundation
import Network

// RTP/UDP media for the `voip-pcm/1` profile.
//
// This is the layer where the "new codec" actually differs from the legacy
// PBX-lite protocol.  Both carry 16-bit linear PCM, but:
//
//   legacy : raw S16 **little-endian** appended straight to the TCP stream,
//            re-framed to a fixed 1024-byte AUDIO message.
//   voip   : RTP packets (12-byte header + payload) over UDP, payload is
//            **L16 = network byte order (big-endian)**, framed to the
//            negotiated `a=ptime` rather than a fixed size.
//
// So the conversion is a byte swap plus a re-framing — no lossy transcode.
// AudioEngine keeps producing/consuming host-order S16 at 16 kHz and is not
// modified; everything VoIP-specific is contained here.
//
// Pacing mirrors legacy invariant #3 (silence keepalive): an RTP stream must be
// continuous or the peer tears the call down, so the send timer emits silence
// whenever the mic isn't supplying audio.  The timer starts with the media
// session, independent of the audio engine's own start latency.
@MainActor
final class RTPAudioSession {

    // MARK: - Configuration

    private let format: VoipAudioFormat
    private let payloadType: UInt8
    private let remoteHost: NWEndpoint.Host
    private let remotePort: NWEndpoint.Port
    private let localPort: UInt16

    /// Payload type the peer uses for RFC 2833 DTMF.  We never generate DTMF,
    /// but inbound events must not be mistaken for audio.
    private let telephoneEventPayloadType: UInt8?

    // MARK: - Callbacks

    /// Decoded host-order S16 PCM ready for AudioEngine.playAudio.
    var onAudioReceived: ((Data) -> Void)?
    /// Fired once if the media socket fails outright.
    var onFailure: ((String) -> Void)?

    // MARK: - State

    private var connection: NWConnection?
    private var sendTimer: Timer?

    private var sequenceNumber = UInt16.random(in: 0...UInt16.max)
    private var timestamp      = UInt32.random(in: 0...UInt32.max)
    private let ssrc           = UInt32.random(in: 1...UInt32.max)
    private var startOfTalkspurt = true

    /// Host-order PCM waiting to be packetised, filled by `enqueue(_:)`.
    private var txAccumulator = Data()
    /// Cap the backlog so a stalled socket can't grow this without bound
    /// (10 frames ≈ 200 ms at the default ptime).
    private var maxAccumulatorBytes: Int { format.frameBytes * 10 }

    private(set) var packetsSent     = 0
    private(set) var packetsReceived = 0

    /// Gates real mic audio.  Silence is the timer's job — this mirrors the
    /// legacy push-to-talk model rather than muting the engine.
    var isTalking = false

    // MARK: - Init

    init(remoteAddress: String,
         remotePort: UInt16,
         localPort: UInt16,
         format: VoipAudioFormat,
         payloadType: UInt8,
         telephoneEventPayloadType: UInt8?) {
        self.remoteHost  = NWEndpoint.Host(remoteAddress)
        self.remotePort  = NWEndpoint.Port(rawValue: remotePort) ?? 40_000
        self.localPort   = localPort
        self.format      = format
        self.payloadType = payloadType
        self.telephoneEventPayloadType = telephoneEventPayloadType
    }

    // MARK: - Lifecycle

    func start() {
        guard connection == nil else { return }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        // Bind the local port we advertised in SDP so media is symmetric: the
        // peer sends to the port it saw in our offer/answer.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.any),
            port: NWEndpoint.Port(rawValue: localPort) ?? .any)

        let conn = NWConnection(host: remoteHost, port: remotePort, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    print("RTPAudioSession: media ready \(self.remoteHost):\(self.remotePort) " +
                          "pt=\(self.payloadType) \(self.format.wireToken) local=\(self.localPort)")
                case .failed(let error):
                    print("RTPAudioSession: media socket failed — \(error)")
                    self.onFailure?(error.localizedDescription)
                default:
                    break
                }
            }
        }
        connection = conn
        conn.start(queue: .global(qos: .userInitiated))
        receiveLoop()
        startSendTimer()
    }

    func stop() {
        sendTimer?.invalidate()
        sendTimer = nil
        connection?.cancel()
        connection = nil
        txAccumulator.removeAll(keepingCapacity: false)
    }

    // MARK: - Transmit

    /// Accept host-order S16 PCM from AudioEngine.  Buffered here and drained by
    /// the pacing timer in exactly one ptime per RTP packet.
    func enqueue(_ pcm: Data) {
        guard isTalking else { return }
        txAccumulator.append(pcm)
        if txAccumulator.count > maxAccumulatorBytes {
            txAccumulator.removeFirst(txAccumulator.count - maxAccumulatorBytes)
        }
    }

    private func startSendTimer() {
        sendTimer?.invalidate()
        let interval = Double(format.frameMs) / 1_000.0
        sendTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendNextFrame() }
        }
    }

    private func sendNextFrame() {
        let frameBytes = format.frameBytes
        let payload: Data

        let haveAudio = txAccumulator.count >= frameBytes
        if haveAudio {
            payload = Data(txAccumulator.prefix(frameBytes))
            txAccumulator.removeFirst(frameBytes)
        } else {
            // Nothing to say — keep the stream continuous with silence.
            payload = Data(count: frameBytes)
        }

        // The marker bit flags the first packet of a talkspurt, so the peer's
        // jitter buffer can resynchronise after a silent stretch.
        let marker = haveAudio && startOfTalkspurt
        let packet = buildPacket(payload: hostToNetwork(payload), marker: marker)
        startOfTalkspurt = !haveAudio

        // Advance by whole frames whether we sent audio or silence, so the
        // peer's jitter buffer sees a monotonic clock.
        timestamp      = timestamp &+ UInt32(format.frameSamples)
        sequenceNumber = sequenceNumber &+ 1
        packetsSent += 1

        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func buildPacket(payload: Data, marker: Bool) -> Data {
        var packet = Data(capacity: 12 + payload.count)
        // V=2, P=0, X=0, CC=0
        packet.append(0x80)
        packet.append(marker ? (payloadType | 0x80) : (payloadType & 0x7F))
        packet.append(UInt8(sequenceNumber >> 8))
        packet.append(UInt8(sequenceNumber & 0xFF))
        appendBigEndian(&packet, timestamp)
        appendBigEndian(&packet, ssrc)
        packet.append(payload)
        return packet
    }

    private func appendBigEndian(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    // MARK: - Receive

    private func receiveLoop() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty { self.handlePacket(data) }
                guard error == nil, self.connection != nil else { return }
                self.receiveLoop()
            }
        }
    }

    private func handlePacket(_ packet: Data) {
        // Minimum RTP header is 12 bytes.
        guard packet.count > 12 else { return }
        let bytes = [UInt8](packet)

        guard (bytes[0] >> 6) == 2 else { return }          // version must be 2
        let hasPadding   = (bytes[0] & 0x20) != 0
        let hasExtension = (bytes[0] & 0x10) != 0
        let csrcCount    = Int(bytes[0] & 0x0F)
        let pt           = bytes[1] & 0x7F

        // Ignore DTMF/telephone-event and any payload type we didn't negotiate;
        // feeding those to the speaker would render them as noise.
        guard pt != telephoneEventPayloadType, pt == payloadType else { return }

        var offset = 12 + csrcCount * 4
        guard packet.count > offset else { return }

        if hasExtension {
            // Extension header: 2 bytes profile + 2 bytes length (in 32-bit words).
            guard packet.count >= offset + 4 else { return }
            let words = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4 + words * 4
            guard packet.count > offset else { return }
        }

        var end = packet.count
        if hasPadding, let padding = bytes.last.map(Int.init), padding > 0, end - padding > offset {
            end -= padding
        }
        guard end > offset else { return }

        let payloadStart = packet.index(packet.startIndex, offsetBy: offset)
        let payloadEnd   = packet.index(packet.startIndex, offsetBy: end)
        let payload      = Data(packet[payloadStart..<payloadEnd])
        packetsReceived += 1
        onAudioReceived?(networkToHost(payload))
    }

    // MARK: - L16 byte order

    // RTP L16 is big-endian; AudioEngine's wire format is host-order (little-
    // endian on every platform this app runs on).  The swap is its own inverse,
    // but both directions are named for readability at the call sites.

    private func hostToNetwork(_ pcm: Data) -> Data { Self.byteSwapped16(pcm) }
    private func networkToHost(_ pcm: Data) -> Data { Self.byteSwapped16(pcm) }

    /// Swap every 16-bit sample.  A trailing odd byte (never expected for L16)
    /// is dropped rather than emitted misaligned.
    nonisolated static func byteSwapped16(_ data: Data) -> Data {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return Data() }
        var out = Data(count: sampleCount * 2)
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                for i in 0..<sampleCount {
                    let lo = s.load(fromByteOffset: i * 2, as: UInt8.self)
                    let hi = s.load(fromByteOffset: i * 2 + 1, as: UInt8.self)
                    d.storeBytes(of: hi, toByteOffset: i * 2, as: UInt8.self)
                    d.storeBytes(of: lo, toByteOffset: i * 2 + 1, as: UInt8.self)
                }
            }
        }
        return out
    }

    // MARK: - Port allocation

    /// First local RTP port.  This is the value advertised to Home Assistant in
    /// our endpoint registration, so the first (usually only) call really does
    /// land on the port the roster claims.
    nonisolated static let basePort: UInt16 = 40_000

    private static var nextPortOffset: UInt16 = 0

    /// Allocate an even port, per the RTP convention that media uses an even
    /// port and RTCP the next odd one.  Wraps after 50 concurrent sessions,
    /// which is far beyond what this app opens.
    static func allocateLocalPort() -> UInt16 {
        let port = basePort &+ (nextPortOffset * 2)
        nextPortOffset = (nextPortOffset &+ 1) % 50
        return port
    }
}
