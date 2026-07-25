import Foundation

// SDP offer/answer for the `voip-pcm/1` media contract.
//
// Contract highlights (docs/voip_profile.md):
//   * ESP media is PCM-only.  RTP `L16` is mandatory, `L24` optional.
//   * Dynamic payload types 96..127.
//   * `a=rtpmap`, `a=ptime`, `a=maxptime` — packet time must NOT be smuggled
//     into `a=fmtp`.
//   * One packetisation interval per `m=audio`; TX and RX rates may differ but
//     both directions must share a compatible `frame_ms`/`ptime`.
//   * Compressed codecs (PCMU/PCMA/Opus/Speex/GSM/G.722) are not implemented on
//     ESP — an offer containing only those must be answered `488`.
//
// This client offers exactly one PCM format (L16/16000/1), which AudioEngine can
// render without a resampling stage, plus `telephone-event` so DTMF-capable
// peers don't consider the offer malformed.  We never generate DTMF ourselves.

struct SDPMediaDescription: Sendable {
    /// Connection address from `c=IN IP4 <addr>` (media-level wins over session).
    var address: String
    /// Port from `m=audio <port> RTP/AVP ...`.  Zero means the stream is rejected.
    var port: Int
    /// Payload type we should send with.
    var payloadType: UInt8
    /// Negotiated packetisation interval in milliseconds.
    var frameMs: Int
    /// Negotiated PCM format.
    var format: VoipAudioFormat
    /// `sendrecv` / `sendonly` / `recvonly` / `inactive` as seen on the wire.
    var direction: String
    /// Payload type the peer uses for RFC 2833 DTMF, when advertised.
    var telephoneEventPayloadType: UInt8?

    var isRejected: Bool { port == 0 }
    var peerWillSendAudio: Bool { direction == "sendrecv" || direction == "sendonly" }
    var peerWillReceiveAudio: Bool { direction == "sendrecv" || direction == "recvonly" }
}

enum SDPError: Error, LocalizedError {
    case malformed(String)
    /// No offered format is renderable by this client — answer with 488.
    case incompatibleMedia(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail):        return "Malformed SDP: \(detail)"
        case .incompatibleMedia(let detail): return "Incompatible audio format: \(detail)"
        }
    }
}

enum SDPSession {

    static let contentType = "application/sdp"

    /// Payload type this client assigns to its own L16 stream.  Any value in
    /// 96..127 is legal; the answerer echoes it back in its own rtpmap.
    static let localL16PayloadType: UInt8 = 96
    static let localDTMFPayloadType: UInt8 = 101

    // MARK: - Offer / answer construction

    /// Build an SDP body advertising one L16 stream at `format`.
    ///
    /// Used both for the initial INVITE offer and for the 200 OK answer to an
    /// inbound INVITE — in the answer case, pass the payload type the *offerer*
    /// used for the format we selected, so the peer sees its own numbering.
    static func buildDescription(address: String,
                                 port: UInt16,
                                 format: VoipAudioFormat,
                                 payloadType: UInt8,
                                 dtmfPayloadType: UInt8? = localDTMFPayloadType,
                                 direction: String = "sendrecv",
                                 sessionID: UInt32 = UInt32.random(in: 1...UInt32.max)) -> Data {
        var payloadList = "\(payloadType)"
        if let dtmfPayloadType { payloadList += " \(dtmfPayloadType)" }

        var lines = [
            "v=0",
            "o=- \(sessionID) \(sessionID) IN IP4 \(address)",
            "s=IntercomListener",
            "c=IN IP4 \(address)",
            "t=0 0",
            "m=audio \(port) RTP/AVP \(payloadList)",
            // L16 is always 16-bit linear; rate/channels come from the format.
            "a=rtpmap:\(payloadType) L16/\(format.sampleRate)/\(format.channels)",
        ]
        if let dtmfPayloadType {
            lines.append("a=rtpmap:\(dtmfPayloadType) telephone-event/8000")
            lines.append("a=fmtp:\(dtmfPayloadType) 0-15")
        }
        // Packet time is media-level and must not appear in fmtp.
        lines.append("a=ptime:\(format.frameMs)")
        lines.append("a=maxptime:\(format.frameMs)")
        lines.append("a=\(direction)")

        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Build a rejecting answer body (`m=audio 0`) for media we cannot render.
    /// A standards-compliant answer retains the section with port zero.
    static func buildRejection(address: String, offer: ParsedSDP) -> Data {
        let lines = [
            "v=0",
            "o=- 0 0 IN IP4 \(address)",
            "s=IntercomListener",
            "c=IN IP4 \(address)",
            "t=0 0",
            "m=audio 0 RTP/AVP \(offer.payloadOrder.first.map(String.init) ?? "96")",
        ]
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    // MARK: - Parsing

    struct ParsedSDP: Sendable {
        var sessionAddress: String?
        var mediaAddress: String?
        var port: Int
        /// Payload types in the order the peer listed them (preference order).
        var payloadOrder: [UInt8]
        /// payload type → (encoding, clock rate, channels)
        var rtpmap: [UInt8: (encoding: String, clockRate: Int, channels: Int)]
        var ptime: Int
        var maxptime: Int
        var direction: String

        var address: String? { mediaAddress ?? sessionAddress }
    }

    static func parse(_ body: Data) throws -> ParsedSDP {
        guard let text = String(data: body, encoding: .utf8) else {
            throw SDPError.malformed("body is not UTF-8")
        }

        var sessionAddress: String?
        var mediaAddress: String?
        var port = -1
        var payloadOrder: [UInt8] = []
        var rtpmap: [UInt8: (String, Int, Int)] = [:]
        var ptime = 0
        var maxptime = 0
        var direction = "sendrecv"
        var inAudioSection = false
        var sawAudioSection = false

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("m=") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                // "m=audio <port> RTP/AVP <pt> <pt> ..."
                inAudioSection = parts.first == "m=audio"
                if inAudioSection {
                    sawAudioSection = true
                    port = parts.count > 1 ? (Int(parts[1]) ?? -1) : -1
                    payloadOrder = parts.dropFirst(3).compactMap { UInt8($0) }
                }
                continue
            }

            if line.hasPrefix("c=") {
                // "c=IN IP4 <address>"
                let parts = line.dropFirst(2).split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 3 else { continue }
                let addr = String(parts[2])
                if inAudioSection { mediaAddress = addr } else { sessionAddress = addr }
                continue
            }

            // Only attributes inside (or before) the audio section matter here;
            // video sections are never negotiated by this client.
            guard inAudioSection || !sawAudioSection else { continue }

            if line.hasPrefix("a=rtpmap:") {
                // "a=rtpmap:96 L16/16000/1"
                let spec = line.dropFirst("a=rtpmap:".count)
                let halves = spec.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard halves.count == 2, let pt = UInt8(halves[0]) else { continue }
                let fields = halves[1].split(separator: "/", omittingEmptySubsequences: true)
                guard let encoding = fields.first else { continue }
                let clockRate = fields.count > 1 ? (Int(fields[1]) ?? 0) : 0
                let channels  = fields.count > 2 ? (Int(fields[2]) ?? 1) : 1
                rtpmap[pt] = (encoding.uppercased(), clockRate, channels)
            } else if line.hasPrefix("a=ptime:") {
                ptime = Int(line.dropFirst("a=ptime:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("a=maxptime:") {
                maxptime = Int(line.dropFirst("a=maxptime:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if ["a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"].contains(line) {
                direction = String(line.dropFirst(2))
            }
        }

        guard sawAudioSection, port >= 0 else {
            throw SDPError.malformed("missing m=audio section")
        }
        guard sessionAddress != nil || mediaAddress != nil else {
            throw SDPError.malformed("missing c= connection address")
        }

        return ParsedSDP(sessionAddress: sessionAddress,
                         mediaAddress: mediaAddress,
                         port: port,
                         payloadOrder: payloadOrder,
                         rtpmap: rtpmap,
                         ptime: ptime,
                         maxptime: maxptime,
                         direction: direction)
    }

    // MARK: - Negotiation

    /// Choose a media description we can actually render from a peer's SDP.
    ///
    /// Only L16 at a rate AudioEngine handles natively (16 kHz mono) is accepted;
    /// anything else — including the compressed codecs a general-purpose SIP
    /// softphone might offer — yields `.incompatibleMedia`, which the caller
    /// turns into `488 Not Acceptable Here`.
    static func negotiate(_ sdp: ParsedSDP,
                          preferredFrameMs: Int = 20) throws -> SDPMediaDescription {
        guard let address = sdp.address else {
            throw SDPError.malformed("missing connection address")
        }

        // A zero port means the peer rejected the stream outright.
        if sdp.port == 0 {
            throw SDPError.incompatibleMedia("peer rejected the audio stream (m=audio 0)")
        }

        let dtmfPT = sdp.rtpmap.first { $0.value.encoding == "TELEPHONE-EVENT" }?.key

        // Walk the peer's payload list in *their* preference order.
        for pt in sdp.payloadOrder {
            guard let entry = sdp.rtpmap[pt] else {
                // Static payload types we deliberately don't implement (0 = PCMU,
                // 8 = PCMA) can appear without an rtpmap; skip rather than guess.
                continue
            }
            guard entry.encoding == "L16" else { continue }

            let channels  = max(1, entry.channels)
            let clockRate = entry.clockRate
            let candidate = VoipAudioFormat(sampleRate: clockRate,
                                            pcmFormat: .s16le,
                                            channels: channels,
                                            frameMs: resolveFrameMs(sdp: sdp,
                                                                    preferred: preferredFrameMs))
            guard candidate.isNativeToAudioEngine else { continue }
            guard candidate.isValid, candidate.fitsRtpPayload else { continue }

            return SDPMediaDescription(address: address,
                                       port: sdp.port,
                                       payloadType: pt,
                                       frameMs: candidate.frameMs,
                                       format: candidate,
                                       direction: sdp.direction,
                                       telephoneEventPayloadType: dtmfPT)
        }

        let offered = sdp.payloadOrder
            .map { pt in sdp.rtpmap[pt].map { "\($0.encoding)/\($0.clockRate)/\($0.channels)" } ?? "PT\(pt)" }
            .joined(separator: ", ")
        throw SDPError.incompatibleMedia("no L16/16000/1 stream on offer (peer offered: \(offered))")
    }

    /// Pick the packetisation interval: honour the peer's `a=ptime` when it is a
    /// value the profile supports, otherwise fall back to our preference and
    /// clamp to the peer's `a=maxptime`.
    private static func resolveFrameMs(sdp: ParsedSDP, preferred: Int) -> Int {
        var frameMs = preferred
        if sdp.ptime > 0, VoipAudioFormat.supportedFrameMs.contains(sdp.ptime) {
            frameMs = sdp.ptime
        }
        if sdp.maxptime > 0, frameMs > sdp.maxptime {
            frameMs = VoipAudioFormat.preferredFrameMs
                .filter { $0 <= sdp.maxptime }
                .max() ?? frameMs
        }
        return VoipAudioFormat.supportedFrameMs.contains(frameMs) ? frameMs : 20
    }
}
