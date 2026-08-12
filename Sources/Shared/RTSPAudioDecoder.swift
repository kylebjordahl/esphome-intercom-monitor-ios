import AVFoundation

// Turns one RTSP audio payload into AudioEngine's wire format: 16 kHz mono,
// host-order signed 16-bit PCM.
//
// This is the only place in the RTSP path that touches AVFoundation, and the
// only place in the app that does a real format conversion — the intercom
// protocols both negotiate 16 kHz mono S16 and need nothing but a byte swap
// (see invariants #9/#10 in AGENTS.md).  A camera has no such courtesy: it
// streams whatever it streams, so a monitor stream is resampled (and, for AAC,
// decoded) here rather than widening AudioEngine's format contract.
//
// Pipeline, per RTP payload:
//
//   G.711 / L16 → S16 at the stream's own rate  ┐
//   AAC-LC      → S16 at the stream's own rate  ┘→ downmix to mono → resample → 16 kHz
final class RTSPAudioDecoder {

    enum SetupError: LocalizedError {
        case unsupportedEncoding(String)
        case decoderUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedEncoding(let name):
                return "Stream audio codec not supported: \(name)"
            case .decoderUnavailable(let name):
                return "Could not start the \(name) decoder"
            }
        }
    }

    /// AudioEngine's sample rate.  Everything is converted to it.
    static let targetSampleRate = 16_000

    private let encoding: RTSPAudioTrack.Encoding
    private let sourceSampleRate: Int
    private let sourceChannels: Int
    private let auSizeLength: Int
    private let auIndexLength: Int
    private let auIndexDeltaLength: Int

    // AAC decode stage (nil for the PCM formats).
    private var aacConverter: AVAudioConverter?
    private var aacInputFormat: AVAudioFormat?
    private var aacOutputFormat: AVAudioFormat?
    private var aacFramesPerPacket = 1_024

    // Rate-conversion stage (nil when the stream is already 16 kHz).  Held for
    // the life of the decoder so the converter keeps its filter state across
    // packets instead of clicking at every boundary.
    private var resampler: AVAudioConverter?
    private var resamplerInputFormat: AVAudioFormat?
    private var resamplerOutputFormat: AVAudioFormat?

    /// Human-readable summary for logs and diagnostics.
    let formatSummary: String

    init(track: RTSPAudioTrack) throws {
        guard track.encoding.isSupported else {
            throw SetupError.unsupportedEncoding(track.encoding.label)
        }
        encoding           = track.encoding
        sourceSampleRate   = track.sampleRate
        sourceChannels     = max(1, min(track.sourceChannels, 2))
        auSizeLength       = track.auSizeLength
        auIndexLength      = track.auIndexLength
        auIndexDeltaLength = track.auIndexDeltaLength
        formatSummary = "\(track.encoding.label) \(track.sampleRate) Hz " +
            (max(1, min(track.sourceChannels, 2)) == 1 ? "mono" : "stereo")

        guard sourceSampleRate > 0 else {
            throw SetupError.unsupportedEncoding("\(track.encoding.label) with no sample rate")
        }

        if case .aacLC = track.encoding {
            guard let config = track.aacConfig else {
                throw SetupError.unsupportedEncoding("AAC without a decoder config")
            }
            try setUpAACDecoder(config)
        }
        if sourceSampleRate != Self.targetSampleRate {
            try setUpResampler()
        }
        print("RTSPAudioDecoder: \(formatSummary) → 16 kHz mono S16")
    }

    // MARK: - Decode

    /// One RTP payload → 16 kHz mono host-order S16.  Returns empty data for a
    /// payload that yielded nothing (a runt packet, or a decoder hiccup) — the
    /// caller simply plays nothing rather than injecting noise.
    func decode(_ payload: Data) -> Data {
        guard !payload.isEmpty else { return Data() }

        let native: Data
        switch encoding {
        case .pcmu:  native = RTSPAudioPayload.decodeULaw(payload)
        case .pcma:  native = RTSPAudioPayload.decodeALaw(payload)
        // L16 is big-endian on the wire, like the VoIP profile's RTP payload.
        case .l16:   native = RTPAudioSession.byteSwapped16(payload)
        case .aacLC: native = decodeAAC(payload)
        case .unsupported: return Data()
        }

        let mono = RTSPAudioPayload.downmixToMono(native, channels: sourceChannels)
        return resample(mono)
    }

    // MARK: - AAC

    private func setUpAACDecoder(_ config: AACConfig) throws {
        aacFramesPerPacket = config.framesPerPacket

        // Raw AAC access units carry no framing of their own, so the decoder is
        // described entirely by this ASBD: object type AAC-LC, the sample rate
        // and channel count from the AudioSpecificConfig, and a fixed 1024 (or
        // 960) frames per packet.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(config.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(config.framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(sourceChannels),
            mBitsPerChannel: 0,
            mReserved: 0)

        guard let inputFormat = AVAudioFormat(streamDescription: &asbd),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: Float64(config.sampleRate),
                                               channels: AVAudioChannelCount(sourceChannels),
                                               interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw SetupError.decoderUnavailable("AAC-LC") }

        aacInputFormat  = inputFormat
        aacOutputFormat = outputFormat
        aacConverter    = converter
    }

    private func decodeAAC(_ payload: Data) -> Data {
        guard let converter = aacConverter,
              let inputFormat = aacInputFormat,
              let outputFormat = aacOutputFormat
        else { return Data() }

        let units = RTSPAudioPayload.accessUnits(from: payload,
                                                 sizeLength: auSizeLength,
                                                 indexLength: auIndexLength,
                                                 indexDeltaLength: auIndexDeltaLength)
        var out = Data()
        for unit in units where !unit.isEmpty {
            let compressed = AVAudioCompressedBuffer(format: inputFormat,
                                                     packetCapacity: 1,
                                                     maximumPacketSize: unit.count)
            unit.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                compressed.data.copyMemory(from: base, byteCount: unit.count)
            }
            compressed.byteLength  = UInt32(unit.count)
            compressed.packetCount = 1
            compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(unit.count))

            guard let decoded = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(aacFramesPerPacket)) else { continue }

            var supplied = false
            var error: NSError?
            let status = converter.convert(to: decoded, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return compressed
            }

            guard status != .error, error == nil,
                  decoded.frameLength > 0,
                  let samples = decoded.int16ChannelData
            else {
                if let error { print("RTSPAudioDecoder: AAC decode failed — \(error)") }
                continue
            }
            // Interleaved, so channel 0's buffer holds every sample.
            out.append(Data(bytes: samples[0],
                            count: Int(decoded.frameLength) * 2 * sourceChannels))
        }
        return out
    }

    // MARK: - Resampling

    private func setUpResampler() throws {
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: Float64(sourceSampleRate),
                                              channels: 1, interleaved: true),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: Float64(Self.targetSampleRate),
                                               channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw SetupError.decoderUnavailable("\(sourceSampleRate) Hz resampler") }

        // Mono in, mono out — the downmix happens in RTSPAudioPayload, because
        // AudioConverter's own channel mixing needs a channel map to be reliable
        // and a 16-bit average is exact enough for speech.
        resamplerInputFormat  = inputFormat
        resamplerOutputFormat = outputFormat
        resampler             = converter
    }

    private func resample(_ mono: Data) -> Data {
        guard !mono.isEmpty else { return Data() }
        guard let converter = resampler,
              let inputFormat = resamplerInputFormat,
              let outputFormat = resamplerOutputFormat
        else { return mono }   // already 16 kHz

        let inputFrames = AVAudioFrameCount(mono.count / 2)
        guard inputFrames > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                 frameCapacity: inputFrames),
              let inputSamples = inputBuffer.int16ChannelData
        else { return Data() }
        inputBuffer.frameLength = inputFrames
        mono.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Int16.self).baseAddress else { return }
            inputSamples[0].update(from: source, count: Int(inputFrames))
        }

        // Slack on top of the ratio: a rate converter can emit slightly more
        // than the arithmetic suggests as it drains its internal filter.
        let ratio = Double(Self.targetSampleRate) / Double(sourceSampleRate)
        let capacity = AVAudioFrameCount(Double(inputFrames) * ratio) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                  frameCapacity: capacity)
        else { return Data() }

        var supplied = false
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard error == nil, outputBuffer.frameLength > 0,
              let outputSamples = outputBuffer.int16ChannelData
        else { return Data() }

        return Data(bytes: outputSamples[0], count: Int(outputBuffer.frameLength) * 2)
    }
}
