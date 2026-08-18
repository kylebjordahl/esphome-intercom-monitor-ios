import Foundation

// The audio half of an RTSP stream: what the SDP says about it, and the pure
// byte-level unpacking of the payload types this app can play.
//
// Video is deliberately never described here.  Monitoring is audio-only, so the
// video m-section of the SDP is parsed past and never SETUP — the camera then
// sends no video at all, which is the whole point (bandwidth and battery).
//
// Foundation-only, like VoipAudioFormat: the AVFoundation decode/resample stage
// lives in RTSPAudioDecoder so all of this stays unit-testable.

// MARK: - Track description

struct RTSPAudioTrack: Equatable {
    /// Payload formats this client can turn into 16 kHz mono PCM.
    enum Encoding: Equatable {
        /// G.711 µ-law (RTP payload type 0, `PCMU`).
        case pcmu
        /// G.711 A-law (RTP payload type 8, `PCMA`).
        case pcma
        /// Uncompressed big-endian 16-bit PCM (`L16`, payload types 10/11).
        case l16
        /// AAC-LC in `mpeg4-generic` (RFC 3640) packetisation.
        case aacLC
        /// Recognised in the SDP but not playable — carries the name so the UI
        /// can say *which* codec instead of "stream failed".
        case unsupported(String)

        var isSupported: Bool {
            if case .unsupported = self { return false }
            return true
        }

        var label: String {
            switch self {
            case .pcmu:  return "G.711 µ-law"
            case .pcma:  return "G.711 A-law"
            case .l16:   return "L16"
            case .aacLC: return "AAC-LC"
            case .unsupported(let name): return name
            }
        }
    }

    var payloadType: UInt8
    var encoding: Encoding
    /// RTP clock rate from the rtpmap — the sample rate for every format here.
    var clockRate: Int
    var channels: Int
    /// `a=control` value, still unresolved against the request URL.
    var control: String?
    /// Decoder configuration from the AAC `fmtp config=` blob.
    var aacConfig: AACConfig?

    // RFC 3640 AU-header geometry, needed to split a `mpeg4-generic` payload.
    // The defaults are the `mode=AAC-hbr` values every camera actually sends.
    var auSizeLength: Int = 13
    var auIndexLength: Int = 3
    var auIndexDeltaLength: Int = 3

    /// Sample rate to decode at.  The AAC config is authoritative when present:
    /// a `mpeg4-generic` rtpmap sometimes advertises the RTP clock at twice the
    /// real rate (the SBR convention), and trusting that would play back fast.
    var sampleRate: Int { aacConfig?.sampleRate ?? clockRate }

    var sourceChannels: Int { aacConfig?.channels ?? channels }
}

/// AudioSpecificConfig (ISO/IEC 14496-3) as carried in `fmtp config=`.
struct AACConfig: Equatable {
    var objectType: Int
    var sampleRate: Int
    var channels: Int
    /// 1024 for normal AAC-LC, 960 when the config sets frameLengthFlag.
    var framesPerPacket: Int

    /// Only plain AAC-LC is decodable through the ASBD-described path in
    /// RTSPAudioDecoder; HE-AAC (SBR/PS) needs a magic cookie we can't attach.
    var isLowComplexity: Bool { objectType == 2 }

    static let sampleRateTable = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000,
                                  24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]

    static func parse(hex: String) -> AACConfig? {
        guard let data = Data(rtspHex: hex) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> AACConfig? {
        var reader = RTSPBitReader(data)
        guard var objectType = reader.read(5) else { return nil }
        // Escape value: the real object type is in the next 6 bits.
        if objectType == 31 {
            guard let extended = reader.read(6) else { return nil }
            objectType = 32 + extended
        }
        guard let frequencyIndex = reader.read(4) else { return nil }
        let sampleRate: Int
        if frequencyIndex == 0x0F {
            guard let explicit = reader.read(24) else { return nil }
            sampleRate = explicit
        } else {
            guard frequencyIndex < sampleRateTable.count else { return nil }
            sampleRate = sampleRateTable[frequencyIndex]
        }
        guard let channelConfiguration = reader.read(4) else { return nil }
        // channelConfiguration 0 means "described in the bitstream"; assume mono
        // rather than failing — the decoder reports the truth either way.
        let channels = channelConfiguration == 0 ? 1 : min(channelConfiguration, 2)

        // GASpecificConfig: frameLengthFlag is the next bit for AAC-LC.
        var frameLengthFlag = 0
        if objectType == 2, let flag = reader.read(1) { frameLengthFlag = flag }

        return AACConfig(objectType: objectType,
                         sampleRate: sampleRate,
                         channels: channels,
                         framesPerPacket: frameLengthFlag == 1 ? 960 : 1024)
    }
}

// MARK: - SDP

enum RTSPSDP {
    /// Pick the audio track out of a DESCRIBE body.
    ///
    /// Prefers the first *playable* audio format when a server offers several
    /// (some cameras list AAC and G.711 side by side), and otherwise returns the
    /// first audio format at all so the caller can name the codec it can't play.
    static func audioTrack(from sdp: String) -> RTSPAudioTrack? {
        var candidates: [RTSPAudioTrack] = []

        var inAudioSection = false
        var payloadTypes: [UInt8] = []
        var control: String?
        var rtpmaps: [UInt8: String] = [:]
        var fmtps: [UInt8: String] = [:]

        func flushSection() {
            guard inAudioSection, !payloadTypes.isEmpty else { return }
            candidates += payloadTypes.map {
                track(payloadType: $0, rtpmap: rtpmaps[$0], fmtp: fmtps[$0], control: control)
            }
        }

        for rawLine in sdp.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("m=") {
                flushSection()
                inAudioSection = line.hasPrefix("m=audio")
                payloadTypes = []; control = nil; rtpmaps = [:]; fmtps = [:]
                if inAudioSection {
                    // m=audio 0 RTP/AVP 97 98  →  the payload-type list is the tail.
                    payloadTypes = line.dropFirst(2)
                        .split(separator: " ")
                        .dropFirst(3)
                        .compactMap { UInt8($0) }
                }
                continue
            }

            guard inAudioSection else { continue }

            if let value = line.dropPrefix("a=control:") {
                control = value.trimmingCharacters(in: .whitespaces).nilIfEmpty
            } else if let value = line.dropPrefix("a=rtpmap:") {
                let parts = value.split(separator: " ", maxSplits: 1)
                if parts.count == 2, let pt = UInt8(parts[0]) {
                    rtpmaps[pt] = String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            } else if let value = line.dropPrefix("a=fmtp:") {
                let parts = value.split(separator: " ", maxSplits: 1)
                if parts.count == 2, let pt = UInt8(parts[0]) {
                    fmtps[pt] = String(parts[1]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        flushSection()

        return candidates.first { $0.encoding.isSupported } ?? candidates.first
    }

    /// Static payload types that need no rtpmap (RFC 3551 table 4).
    private static func staticFormat(_ payloadType: UInt8) -> (String, Int, Int)? {
        switch payloadType {
        case 0:  return ("PCMU", 8_000, 1)
        case 8:  return ("PCMA", 8_000, 1)
        case 10: return ("L16", 44_100, 2)
        case 11: return ("L16", 44_100, 1)
        default: return nil
        }
    }

    static func track(payloadType: UInt8,
                      rtpmap: String?,
                      fmtp: String?,
                      control: String?) -> RTSPAudioTrack {
        // rtpmap value is "<name>/<clock rate>[/<channels>]".
        var name = ""
        var clockRate = 0
        var channels = 0

        if let rtpmap {
            let fields = rtpmap.split(separator: "/")
            name = fields.first.map(String.init) ?? ""
            clockRate = fields.count > 1 ? Int(fields[1]) ?? 0 : 0
            channels  = fields.count > 2 ? Int(fields[2]) ?? 0 : 0
        }
        if name.isEmpty, let known = staticFormat(payloadType) {
            (name, clockRate, channels) = known
        }

        let parameters = fmtpParameters(fmtp)
        let aacConfig  = parameters["config"].flatMap { AACConfig.parse(hex: $0) }

        var encoding: RTSPAudioTrack.Encoding
        switch name.lowercased() {
        case "pcmu": encoding = .pcmu
        case "pcma": encoding = .pcma
        case "l16":  encoding = .l16
        case "mpeg4-generic":
            // Only AAC-LC in the AAC-hbr / AAC-lbr modes is playable here.
            if let aacConfig, !aacConfig.isLowComplexity {
                encoding = .unsupported("HE-AAC (object type \(aacConfig.objectType))")
            } else if aacConfig == nil {
                encoding = .unsupported("AAC without a decoder config")
            } else {
                encoding = .aacLC
            }
        case "":
            encoding = .unsupported("payload type \(payloadType)")
        default:
            encoding = .unsupported(name.uppercased())
        }

        // A stream that says nothing usable about its clock rate can't be
        // resampled correctly, so treat it as unplayable rather than guessing.
        if encoding.isSupported, aacConfig == nil, clockRate <= 0 {
            encoding = .unsupported("\(name.uppercased()) with no clock rate")
        }

        return RTSPAudioTrack(
            payloadType: payloadType,
            encoding: encoding,
            clockRate: clockRate,
            channels: max(1, channels),
            control: control,
            aacConfig: aacConfig,
            auSizeLength: parameters["sizelength"].flatMap(Int.init) ?? 13,
            auIndexLength: parameters["indexlength"].flatMap(Int.init) ?? 3,
            auIndexDeltaLength: parameters["indexdeltalength"].flatMap(Int.init) ?? 3)
    }

    /// `streamtype=5;mode=AAC-hbr;config=1408;sizelength=13` → keyed map.
    static func fmtpParameters(_ fmtp: String?) -> [String: String] {
        guard let fmtp else { return [:] }
        var result: [String: String] = [:]
        for parameter in fmtp.split(separator: ";") {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    /// Absolute URL to SETUP for this track.
    ///
    /// `a=control` may be absolute, relative ("trackID=1"), or "*" (meaning the
    /// aggregate URL).  RFC 2326 resolves a relative value against Content-Base
    /// when the response supplies one, else the request URL.
    static func resolveControl(_ control: String?,
                               requestURI: String,
                               contentBase: String?) -> String {
        let base = contentBase?.nilIfEmpty ?? requestURI
        guard let control, control != "*" else { return base }
        let lowered = control.lowercased()
        if lowered.hasPrefix("rtsp://") || lowered.hasPrefix("rtsps://") { return control }
        if base.hasSuffix("/") { return base + control }
        return base + "/" + control
    }
}

// MARK: - Payload unpacking

enum RTSPAudioPayload {

    /// G.711 µ-law → host-order S16 (the classic Sun reference expansion).
    static func decodeULaw(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count * 2)
        for byte in payload {
            let value = ~byte
            var magnitude = (Int(value & 0x0F) << 3) + 0x84
            magnitude <<= Int((value & 0x70) >> 4)
            let sample = (value & 0x80) != 0 ? 0x84 - magnitude : magnitude - 0x84
            appendLittleEndian(&out, Int16(clamping: sample))
        }
        return out
    }

    /// G.711 A-law → host-order S16.
    static func decodeALaw(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count * 2)
        for byte in payload {
            let value = byte ^ 0x55
            var magnitude = Int(value & 0x0F) << 4
            let segment = Int((value & 0x70) >> 4)
            switch segment {
            case 0:  magnitude += 8
            case 1:  magnitude += 0x108
            default: magnitude = (magnitude + 0x108) << (segment - 1)
            }
            let sample = (value & 0x80) != 0 ? magnitude : -magnitude
            appendLittleEndian(&out, Int16(clamping: sample))
        }
        return out
    }

    /// Split a `mpeg4-generic` (RFC 3640) payload into its access units.
    ///
    /// Layout: a 16-bit AU-headers-length in *bits*, then that many bits of
    /// per-AU headers (an AU size plus an index/index-delta), then the AU data
    /// back to back.  Most cameras send exactly one AU per packet, but a
    /// multi-AU packet mis-split as one AU decodes to garbage, so honour the
    /// header block properly.
    static func accessUnits(from payload: Data,
                            sizeLength: Int,
                            indexLength: Int,
                            indexDeltaLength: Int) -> [Data] {
        // sizeLength 0 means "no AU headers at all": the payload is one AU.
        guard sizeLength > 0 else { return payload.isEmpty ? [] : [payload] }
        guard payload.count > 2 else { return [] }

        let bytes = [UInt8](payload)
        let headerBits = Int(bytes[0]) << 8 | Int(bytes[1])
        guard headerBits > 0 else { return [] }
        let headerBytes = (headerBits + 7) / 8
        guard payload.count >= 2 + headerBytes else { return [] }

        var reader = RTSPBitReader(Data(bytes[2..<(2 + headerBytes)]))
        var sizes: [Int] = []
        var consumedBits = 0
        while consumedBits + sizeLength <= headerBits {
            guard let size = reader.read(sizeLength) else { break }
            consumedBits += sizeLength
            // The first AU carries an index, subsequent ones an index-delta.
            let indexBits = sizes.isEmpty ? indexLength : indexDeltaLength
            if indexBits > 0 {
                guard consumedBits + indexBits <= headerBits,
                      reader.read(indexBits) != nil else { break }
                consumedBits += indexBits
            }
            sizes.append(size)
        }

        var units: [Data] = []
        var offset = 2 + headerBytes
        for size in sizes {
            guard size > 0, offset + size <= bytes.count else { break }
            units.append(Data(bytes[offset..<(offset + size)]))
            offset += size
        }
        // A truncated final header block (or a server that lies about sizes)
        // still leaves usable audio: fall back to the whole remainder as one AU.
        if units.isEmpty, offset < bytes.count {
            units.append(Data(bytes[offset...]))
        }
        return units
    }

    /// Average interleaved stereo down to mono in place of a converter channel
    /// map — AudioConverter's channel mixing is not dependable for this, and the
    /// arithmetic is trivial for 16-bit PCM.
    static func downmixToMono(_ pcm: Data, channels: Int) -> Data {
        guard channels > 1 else { return pcm }
        let frameBytes = channels * 2
        let frames = pcm.count / frameBytes
        guard frames > 0 else { return Data() }

        var out = Data(capacity: frames * 2)
        let bytes = [UInt8](pcm)
        for frame in 0..<frames {
            var sum = 0
            for channel in 0..<channels {
                let offset = frame * frameBytes + channel * 2
                let sample = Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
                sum += Int(sample)
            }
            appendLittleEndian(&out, Int16(clamping: sum / channels))
        }
        return out
    }

    /// AudioEngine's wire format is host-order, and every platform this app runs
    /// on is little-endian.
    private static func appendLittleEndian(_ data: inout Data, _ sample: Int16) {
        let unsigned = UInt16(bitPattern: sample)
        data.append(UInt8(unsigned & 0xFF))
        data.append(UInt8(unsigned >> 8))
    }
}

// MARK: - Bit reader

/// Minimal big-endian bit reader for the two bit-packed structures RTSP audio
/// needs: AudioSpecificConfig and RFC 3640 AU headers.
struct RTSPBitReader {
    private let bytes: [UInt8]
    private var bitOffset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var bitsRemaining: Int { bytes.count * 8 - bitOffset }

    /// Read up to 24 bits, MSB first.  Nil when the buffer is exhausted.
    mutating func read(_ count: Int) -> Int? {
        guard count > 0, count <= 24, bitsRemaining >= count else { return nil }
        var value = 0
        for _ in 0..<count {
            let byte = bytes[bitOffset >> 3]
            let bit  = (byte >> (7 - UInt8(bitOffset & 7))) & 1
            value = (value << 1) | Int(bit)
            bitOffset += 1
        }
        return value
    }
}

// MARK: - Small helpers

extension Data {
    /// Decode a hex string such as an AAC `config=1408` blob.
    init?(rtspHex hex: String) {
        let characters = Array(hex.trimmingCharacters(in: .whitespaces))
        guard !characters.isEmpty, characters.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...(index + 1)]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self = Data(bytes)
    }
}

extension String {
    /// Return the remainder after `prefix`, or nil when the string doesn't start
    /// with it.  Keeps the SDP line scanner readable.
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
