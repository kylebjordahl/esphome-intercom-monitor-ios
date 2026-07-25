import Foundation

/// Which wire protocol a panel speaks.
///
/// The ESPHome project replaced the proprietary PBX-lite protocol with a
/// SIP/SDP/RTP profile (`voip-pcm/1`) in v2026.7.0 — the old TCP contract was
/// retired outright, not merely re-encoded.  A roster entry therefore has to say
/// which stack to use, and `auto` probes when nothing said.
enum DeviceProtocol: String, Codable, Sendable, CaseIterable {
    /// Probe the device: SIP first, then legacy PBX-lite.
    case auto
    /// Proprietary PBX-lite framing on TCP 6054 (firmware <= v2026.6.x).
    case legacy
    /// SIP signaling + RTP/UDP L16 media (firmware >= v2026.7.0).
    case voip

    var label: String {
        switch self {
        case .auto:   return "Automatic"
        case .legacy: return "Legacy (≤ 2026.6)"
        case .voip:   return "VoIP (≥ 2026.7)"
        }
    }
}

// A discoverable/callable intercom endpoint (an ESPHome panel, or the iPhone/
// Watch itself acting as a peer).  `id` is stable so it can key both the device
// roster and the live connection for that device.
struct IntercomDevice: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Host used by both stacks: the legacy TCP target and the SIP/RTP target.
    var host: String
    /// Legacy PBX-lite TCP port.  Unused when `protocolKind == .voip`.
    var port: Int

    // MARK: - VoIP profile metadata (firmware >= v2026.7.0)

    var protocolKind: DeviceProtocol
    /// Full SIP URI from the roster when present; otherwise synthesised from
    /// name/host/port.  The roster's URI is authoritative — it may carry a
    /// different user part or a `;transport=` parameter.
    var sipURI: String?
    var sipPort: Int
    var sipTransport: SIPTransportKind
    /// RTP port the device listens on, when the roster advertises one.  Media
    /// normally follows the SDP answer instead, so this is informational.
    var rtpPort: Int?
    /// Device-to-wire capability list (`tx_format`).
    var txFormats: [String]
    /// Wire-to-device capability list (`rx_format`).
    var rxFormats: [String]
    /// Internal dial-plan alias, when the roster defines one.
    var extensionNumber: String?

    init(id: UUID = UUID(),
         name: String,
         host: String,
         port: Int = 6054,
         protocolKind: DeviceProtocol = .auto,
         sipURI: String? = nil,
         sipPort: Int = Int(SIPEndpoint.defaultPort),
         sipTransport: SIPTransportKind = .udp,
         rtpPort: Int? = nil,
         txFormats: [String] = [],
         rxFormats: [String] = [],
         extensionNumber: String? = nil) {
        self.id   = id
        self.name = name
        self.host = host
        self.port = port
        self.protocolKind    = protocolKind
        self.sipURI          = sipURI
        self.sipPort         = sipPort
        self.sipTransport    = sipTransport
        self.rtpPort         = rtpPort
        self.txFormats       = txFormats
        self.rxFormats       = rxFormats
        self.extensionNumber = extensionNumber
    }

    // MARK: - Negotiation helpers

    var parsedTxFormats: [VoipAudioFormat] { VoipAudioFormat.parseList(txFormats.joined(separator: ";")) }
    var parsedRxFormats: [VoipAudioFormat] { VoipAudioFormat.parseList(rxFormats.joined(separator: ";")) }

    /// Packetisation interval shared by this device and this client.  Nil when
    /// the roster advertised nothing, in which case SDP negotiation decides.
    var preferredFrameMs: Int? {
        VoipAudioFormat.commonFrameMs(parsedTxFormats, parsedRxFormats)
    }

    // MARK: - Codable
    //
    // Hand-written so a roster persisted by an older build (which had only
    // id/name/host/port) still decodes.  Synthesised Codable throws on a missing
    // key even when the property has a default, which would silently wipe every
    // saved device on upgrade.

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port
        case protocolKind, sipURI, sipPort, sipTransport, rtpPort
        case txFormats, rxFormats, extensionNumber
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id   = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)

        // A device saved before VoIP support existed is, by definition, one the
        // user was talking to over the legacy protocol.
        protocolKind = try c.decodeIfPresent(DeviceProtocol.self, forKey: .protocolKind) ?? .legacy
        sipURI       = try c.decodeIfPresent(String.self, forKey: .sipURI)
        sipPort      = try c.decodeIfPresent(Int.self, forKey: .sipPort) ?? Int(SIPEndpoint.defaultPort)
        sipTransport = try c.decodeIfPresent(SIPTransportKind.self, forKey: .sipTransport) ?? .udp
        rtpPort      = try c.decodeIfPresent(Int.self, forKey: .rtpPort)
        txFormats    = try c.decodeIfPresent([String].self, forKey: .txFormats) ?? []
        rxFormats    = try c.decodeIfPresent([String].self, forKey: .rxFormats) ?? []
        extensionNumber = try c.decodeIfPresent(String.self, forKey: .extensionNumber)
    }

    /// UserDefaults key under which the saved roster is persisted.  Shared so the
    /// App Intents device query can load the same list DeviceStore writes.
    static let storageKey = "saved_devices"

    /// Load the persisted device roster.  Free function (no @MainActor / no
    /// DeviceStore instance) so App Intents can resolve a spoken device name even
    /// when invoked before the app's stores are built.
    static func loadSaved() -> [IntercomDevice] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([IntercomDevice].self, from: data)
        else { return [] }
        return decoded
    }

    // MARK: - Legacy phonebook parsing

    // Parse a single TCP phonebook entry: "name|tcp|ip|port"
    // This is the pre-v2026.7.0 `sensor.intercom_phonebook` format; entries
    // parsed here are legacy by construction.
    static func fromPhonebookEntry(_ entry: String) -> IntercomDevice? {
        let parts = entry.components(separatedBy: "|")
        guard parts.count >= 4, parts[1].lowercased() == "tcp" else { return nil }
        guard let port = Int(parts[3]) else { return nil }
        return IntercomDevice(name: parts[0], host: parts[2], port: port,
                              protocolKind: .legacy)
    }

    // MARK: - VoIP roster parsing

    /// Parse one entry of the canonical JSON roster published as
    /// `sensor.voip_phonebook` by firmware >= v2026.7.0.
    ///
    /// Fields (docs/PHONEBOOK_PROTOCOL.md): `id`, `name`, `address`, `sip_uri`,
    /// `extension`, `number`, `port`, `ha_bridge`, and a `metadata` object
    /// carrying `transport` / `sip_transport` / `sip_port` / `rtp_port` plus
    /// audio-format metadata.
    ///
    /// Entries that are pure HA routing constructs (`ha_bridge` groups with no
    /// address) are skipped — they are not directly callable by this client.
    static func fromRosterEntry(_ raw: [String: Any]) -> IntercomDevice? {
        guard let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty
        else { return nil }

        let metadata = raw["metadata"] as? [String: Any] ?? [:]
        let sipURI   = (raw["sip_uri"] as? String)?.trimmingCharacters(in: .whitespaces)

        // Host: prefer the explicit address, else the host part of the SIP URI.
        var host = (raw["address"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if host.isEmpty, let sipURI { host = hostPart(ofSipURI: sipURI) ?? "" }

        let isBridge = (raw["ha_bridge"] as? Bool) ?? false
        // A name-only or group entry has to be dialled through HA; this client
        // only places direct calls, so it is not a usable roster device.
        guard !host.isEmpty, !(isBridge && sipURI == nil) else { return nil }

        // Transport may appear under either key; `sip_transport` wins.
        let transport = SIPTransportKind(token: metadata["sip_transport"] as? String)
            ?? SIPTransportKind(token: metadata["transport"] as? String)
            ?? sipURI.flatMap { SIPTransportKind(token: uriParameter("transport", in: $0)) }
            ?? .udp

        let sipPort = intValue(metadata["sip_port"])
            ?? intValue(raw["port"])
            ?? sipURI.flatMap { portPart(ofSipURI: $0) }
            ?? Int(SIPEndpoint.defaultPort)

        let stableID = (raw["id"] as? String).flatMap(UUID.init(uuidString:))
            ?? UUID(stableFrom: "voip:\(name)@\(host)")

        return IntercomDevice(
            id: stableID,
            name: name,
            host: host,
            // Legacy port is meaningless for a VoIP device; keep the default so
            // a user who later flips the protocol back still has a sane value.
            port: 6054,
            protocolKind: .voip,
            sipURI: sipURI,
            sipPort: sipPort,
            sipTransport: transport,
            rtpPort: intValue(metadata["rtp_port"]),
            txFormats: formatList(metadata["tx_format"] ?? metadata["tx_formats"]),
            rxFormats: formatList(metadata["rx_format"] ?? metadata["rx_formats"]),
            extensionNumber: raw["extension"] as? String)
    }

    /// Parse the per-device endpoint state published by firmware >= v2026.7.0 as
    /// `text_sensor: platform: voip_stack, type: endpoint`:
    ///
    ///     Name|host|sip_port|rtp_port|audio_mode|tx_formats|rx_formats|sip_tcp|extension
    ///
    /// `audio_mode` is one of full_duplex / mic_only / speaker_only, the format
    /// fields are ';'-separated token lists, and the transport field is the
    /// literal `sip_tcp` or `sip_udp`.  Group membership is deliberately absent
    /// (it lives in sibling entities) so the state stays under HA's length cap.
    static func fromVoipEndpointString(_ raw: String) -> IntercomDevice? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty,
              !["unknown", "unavailable"].contains(text.lowercased())
        else { return nil }

        let parts = text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        // The transport token at index 7 is what distinguishes this shape from
        // the legacy "name|tcp|ip|port" entry.
        guard parts.count >= 8 else { return nil }

        let name = parts[0], host = parts[1]
        guard !name.isEmpty, !host.isEmpty else { return nil }
        guard let sipPort = Int(parts[2]), (1...65_535).contains(sipPort) else { return nil }

        let rtpPort = Int(parts[3]).flatMap { (1...65_535).contains($0) ? $0 : nil }

        let transport: SIPTransportKind
        switch parts[7].lowercased() {
        case "sip_tcp": transport = .tcp
        case "sip_udp": transport = .udp
        default: return nil
        }

        let txFormats = parts[5].split(separator: ";").map(String.init).filter { !$0.isEmpty }
        let rxFormats = parts[6].split(separator: ";").map(String.init).filter { !$0.isEmpty }
        // The firmware refuses to publish an endpoint without explicit formats;
        // an entry missing them is a partially-booted device, not a callable one.
        guard !txFormats.isEmpty, !rxFormats.isEmpty else { return nil }

        let ext = parts.count >= 9 && !parts[8].isEmpty ? parts[8] : nil

        return IntercomDevice(
            id: UUID(stableFrom: "voip:\(name)@\(host)"),
            name: name,
            host: host,
            port: 6054,
            protocolKind: .voip,
            sipURI: "sip:\(SIPCall.uriUser(name))@\(host):\(sipPort);transport=\(transport.rawValue)",
            sipPort: sipPort,
            sipTransport: transport,
            rtpPort: rtpPort,
            txFormats: txFormats,
            rxFormats: rxFormats,
            extensionNumber: ext)
    }

    /// Parse either endpoint-sensor shape, newest first.
    static func fromEndpointState(_ raw: String) -> IntercomDevice? {
        fromVoipEndpointString(raw) ?? fromPhonebookEntry(raw)
    }

    /// Parse a whole roster document (a JSON array, or an object wrapping one).
    static func fromRosterJSON(_ raw: String) -> [IntercomDevice] {
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        let entries: [[String: Any]]
        if let array = parsed as? [[String: Any]] {
            entries = array
        } else if let object = parsed as? [String: Any] {
            entries = (object["contacts"] as? [[String: Any]])
                ?? (object["entries"] as? [[String: Any]])
                ?? (object["phonebook"] as? [[String: Any]])
                ?? []
        } else {
            entries = []
        }

        return entries.compactMap(fromRosterEntry)
    }

    // MARK: - Parsing helpers

    /// Accept both `"16000:s16le:1:32;16000:s16le:1:20"` and a JSON array.
    private static func formatList(_ value: Any?) -> [String] {
        if let string = value as? String {
            return string.split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let array = value as? [String] { return array }
        return []
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// "sip:Kitchen@192.168.1.51:5060;transport=tcp" → "192.168.1.51"
    static func hostPart(ofSipURI uri: String) -> String? {
        var scan = uri
        if let range = scan.range(of: "sip:") { scan = String(scan[range.upperBound...]) }
        scan = String(scan.split(separator: ";").first ?? Substring(scan))
        if let at = scan.lastIndex(of: "@") { scan = String(scan[scan.index(after: at)...]) }
        let host = String(scan.split(separator: ":").first ?? Substring(scan))
        return host.isEmpty ? nil : host
    }

    static func portPart(ofSipURI uri: String) -> Int? {
        var scan = uri
        if let range = scan.range(of: "sip:") { scan = String(scan[range.upperBound...]) }
        scan = String(scan.split(separator: ";").first ?? Substring(scan))
        if let at = scan.lastIndex(of: "@") { scan = String(scan[scan.index(after: at)...]) }
        let parts = scan.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    static func uriParameter(_ name: String, in uri: String) -> String? {
        for component in uri.split(separator: ";").dropFirst() {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased()
            else { continue }
            return pair[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

// MARK: - Stable identifiers

extension UUID {
    /// Derive a deterministic UUID from a string so a roster entry keeps the
    /// same identity — and therefore the same live connection and Live Activity
    /// — across rediscoveries.
    init(stableFrom string: String) {
        var hash = [UInt8](repeating: 0, count: 16)
        // FNV-1a over the string, folded into 16 bytes.  Not cryptographic; it
        // only needs to be stable and collision-resistant across a home roster.
        var accumulator: UInt64 = 0xcbf2_9ce4_8422_2325
        for (index, byte) in Array(string.utf8).enumerated() {
            accumulator ^= UInt64(byte)
            accumulator = accumulator &* 0x1000_0000_01b3
            hash[index % 16] ^= UInt8(truncatingIfNeeded: accumulator >> UInt64((index % 8) * 8))
        }
        for i in 0..<8 {
            hash[i] ^= UInt8(truncatingIfNeeded: accumulator >> UInt64(i * 8))
        }
        // Set RFC 4122 version 4 / variant bits so this is a well-formed UUID.
        hash[6] = (hash[6] & 0x0F) | 0x40
        hash[8] = (hash[8] & 0x3F) | 0x80
        self.init(uuid: (hash[0], hash[1], hash[2], hash[3],
                         hash[4], hash[5], hash[6], hash[7],
                         hash[8], hash[9], hash[10], hash[11],
                         hash[12], hash[13], hash[14], hash[15]))
    }
}

// MARK: - Persistence

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [IntercomDevice] = []

    private let key = IntercomDevice.storageKey

    init() { load() }

    func add(_ device: IntercomDevice) {
        devices.append(device)
        save()
    }

    func remove(id: UUID) {
        devices.removeAll { $0.id == id }
        save()
    }

    func update(_ device: IntercomDevice) {
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            devices[idx] = device
            save()
        }
    }

    func replaceAll(with newDevices: [IntercomDevice]) {
        devices = newDevices
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([IntercomDevice].self, from: data)
        else { return }
        devices = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
