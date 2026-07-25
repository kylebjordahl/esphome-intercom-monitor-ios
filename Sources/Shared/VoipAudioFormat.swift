import Foundation

// PCM audio-format contract for the `voip-pcm/1` profile used by
// esphome-intercom (VoIP Stack) >= v2026.7.0.
//
// The firmware describes audio capability with a four-field token:
//
//     <sample_rate>:<pcm_format>:<channels>:<frame_ms>      e.g. "16000:s16le:1:32"
//
// Lists of tokens are ';'-separated and capped at 8 entries.  TX and RX are
// advertised separately ("per direction"), so a device may capture at one rate
// and accept playback at another.
//
// This app deliberately negotiates a single format — 16 kHz / s16le / mono —
// because AudioEngine's wire format is exactly that, so no resampling layer is
// needed on our side.  Only `frameMs` (the RTP packetisation interval) is
// negotiated dynamically; see SDPSession.
struct VoipAudioFormat: Equatable, Sendable {

    enum PcmFormat: String, Sendable {
        case s16le
        case s24le
        case s24leInS32 = "s24le_in_s32"
        case s32le

        /// Bytes occupied by one sample in its wire container.
        var containerBytes: Int {
            switch self {
            case .s16le:      return 2
            case .s24le:      return 3
            case .s24leInS32: return 4
            case .s32le:      return 4
            }
        }
    }

    var sampleRate: Int
    var pcmFormat: PcmFormat
    var channels: Int
    var frameMs: Int

    // Mirrors SUPPORTED_* in the firmware's audio_format.py.  A token outside
    // these sets is rejected rather than guessed at.
    static let supportedSampleRates = Set([8_000, 12_000, 16_000, 24_000, 32_000, 44_100, 48_000])
    static let supportedChannels    = Set([1, 2])
    static let supportedFrameMs     = Set([10, 16, 20, 32])

    /// Firmware preference order when several packetisation intervals are common.
    static let preferredFrameMs = [10, 16, 20, 32]

    /// Largest RTP payload the profile allows (`UDP_SAFE_PAYLOAD_BYTES`).
    static let maxRtpPayloadBytes = 1_200

    init(sampleRate: Int = 16_000,
         pcmFormat: PcmFormat = .s16le,
         channels: Int = 1,
         frameMs: Int = 20) {
        self.sampleRate = sampleRate
        self.pcmFormat  = pcmFormat
        self.channels   = channels
        self.frameMs    = frameMs
    }

    /// The single format this client offers.  16 kHz mono s16 matches
    /// AudioEngine.wireFormat byte-for-byte (modulo RTP byte order).
    static func appDefault(frameMs: Int = 20) -> VoipAudioFormat {
        VoipAudioFormat(sampleRate: 16_000, pcmFormat: .s16le, channels: 1, frameMs: frameMs)
    }

    var isValid: Bool {
        Self.supportedSampleRates.contains(sampleRate)
            && Self.supportedChannels.contains(channels)
            && Self.supportedFrameMs.contains(frameMs)
            && (sampleRate * frameMs) % 1_000 == 0
    }

    /// True when this format can be rendered by AudioEngine without resampling.
    var isNativeToAudioEngine: Bool {
        sampleRate == 16_000 && pcmFormat == .s16le && channels == 1
    }

    // MARK: - Frame maths

    /// Samples (per channel) in one packetisation interval.
    var frameSamples: Int { sampleRate * frameMs / 1_000 }

    /// Bytes in one full frame across all channels.
    var frameBytes: Int { frameSamples * channels * pcmFormat.containerBytes }

    var fitsRtpPayload: Bool { frameBytes <= Self.maxRtpPayloadBytes }

    // MARK: - Token codec

    var wireToken: String {
        "\(sampleRate):\(pcmFormat.rawValue):\(channels):\(frameMs)"
    }

    init?(token: String) {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let rate     = Int(parts[0]),
              let pcm      = PcmFormat(rawValue: parts[1].lowercased()),
              let channels = Int(parts[2]),
              let frameMs  = Int(parts[3])
        else { return nil }

        self.init(sampleRate: rate, pcmFormat: pcm, channels: channels, frameMs: frameMs)
        guard isValid else { return nil }
    }

    /// Parse a ';'-separated capability list.  Invalid entries are skipped so one
    /// unknown future token can't blank out an otherwise usable device.
    static func parseList(_ value: String?) -> [VoipAudioFormat] {
        guard let value, !value.isEmpty else { return [] }
        return value
            .split(separator: ";")
            .compactMap { VoipAudioFormat(token: String($0)) }
            .prefix(8)
            .map { $0 }
    }

    static func encodeList(_ formats: [VoipAudioFormat]) -> String {
        formats.prefix(8).map(\.wireToken).joined(separator: ";")
    }

    /// Pick the packetisation interval shared by every supplied capability list,
    /// honouring the firmware's preference order.  Empty lists are ignored so a
    /// peer that advertises nothing doesn't veto the negotiation.
    static func commonFrameMs(_ lists: [VoipAudioFormat]...) -> Int? {
        var available: Set<Int>?
        for list in lists where !list.isEmpty {
            let frames = Set(list.map(\.frameMs))
            available = available.map { $0.intersection(frames) } ?? frames
        }
        guard let available, !available.isEmpty else { return nil }
        return preferredFrameMs.first(where: { available.contains($0) }) ?? available.min()
    }
}
