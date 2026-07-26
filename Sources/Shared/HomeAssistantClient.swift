import Foundation

// Discovers intercom devices from Home Assistant.
//
// The ESPHome project renamed and restructured its roster in v2026.7.0 when it
// replaced the proprietary intercom protocol with SIP, so discovery has to cover
// both generations.  Strategy (tried in order):
//
//   1. sensor.voip_phonebook       — canonical JSON roster (VoIP Stack >= 2026.7)
//   2. sensor.intercom_phonebook   — legacy "name|tcp|ip|port" list (<= 2026.6)
//   3. per-device endpoint sensors — *_voip_endpoint (new) and
//      *_intercom_endpoint (legacy), parsed by shape
//
// Each path stamps the devices it produces with the protocol they speak, so a
// mixed-firmware house works without the user configuring anything.
@MainActor
final class HomeAssistantClient: ObservableObject {
    @Published private(set) var discoveredDevices: [IntercomDevice] = []
    @Published private(set) var statusMessage: String?   // human-readable; nil = not yet tried
    @Published private(set) var isError = false
    @Published private(set) var isConnected = false

    private var wsTask: URLSessionWebSocketTask?
    private var wsMessageId = 1

    // MARK: - Public API

    /// Fetch once, then subscribe to live WebSocket updates.
    func connect(baseURL: String, token: String) async {
        await fetchAll(baseURL: baseURL, token: token)
        await subscribeWebSocket(baseURL: baseURL, token: token)
    }

    func disconnect() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        isConnected = false
    }

    /// One-shot refresh (called from the Settings "Discover" button).
    /// When `silent` is true (periodic background rediscovery) the human-facing
    /// status message is left untouched so the Settings screen doesn't flicker.
    func fetchAll(baseURL: String, token: String, silent: Bool = false) async {
        if !silent {
            statusMessage = "Querying Home Assistant…"
            isError = false
        }

        // 1 — VoIP Stack's canonical JSON roster (firmware >= v2026.7.0).
        if await fetchVoipPhonebook(baseURL: baseURL, token: token, silent: silent) { return }

        // 2 — Legacy phonebook aggregator sensor.
        if await fetchPhonebook(baseURL: baseURL, token: token, silent: silent) { return }

        // 3 — Fall back to individual endpoint sensors (either generation).
        await fetchEndpointSensors(baseURL: baseURL, token: token, silent: silent)
    }

    // MARK: - REST: VoIP Stack JSON roster

    /// Read `sensor.voip_phonebook`.  Returns true if the entity exists, so the
    /// caller stops walking the fallback chain even when the roster is empty.
    ///
    /// The roster document lives in the entity's attributes; VoIP Stack keeps the
    /// state string itself short (HA caps state at 255 chars), so the JSON is
    /// carried under `contacts` / `phonebook` / `roster` depending on version.
    @discardableResult
    private func fetchVoipPhonebook(baseURL: String, token: String,
                                    silent: Bool = false) async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/states/sensor.voip_phonebook") else {
            if !silent { setError("Invalid HA URL") }
            return false
        }
        do {
            let (data, response) = try await makeRequest(url: url, token: token)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 404 { return false }        // VoIP Stack not installed
            if status != 200 {
                if !silent { setError("HA returned HTTP \(status)") }
                return true
            }

            guard
                let obj   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let attrs = obj["attributes"] as? [String: Any]
            else {
                if !silent { setError("Could not parse HA response") }
                return true
            }

            let parsed = parseVoipRoster(attrs)
            discoveredDevices = parsed

            if !silent {
                if parsed.isEmpty {
                    // `count` is the roster size HA itself reports, so this
                    // distinguishes "the roster is genuinely empty" from "it has
                    // entries this app can't dial directly".
                    let reported = (attrs["count"] as? Int)
                        ?? (attrs["count"] as? String).flatMap(Int.init)
                    if let reported, reported > 0 {
                        setStatus("sensor.voip_phonebook lists \(reported) entr" +
                                  "\(reported == 1 ? "y" : "ies"), but none are directly " +
                                  "callable — the Home Assistant softphone entry is always " +
                                  "excluded. If a panel is missing, check it is online and " +
                                  "publishing its VoIP endpoint; if a ring or conference group " +
                                  "is missing, make sure Home Assistant's own SIP endpoint " +
                                  "(softphone) is enabled in VoIP Stack — that's the address " +
                                  "this app dials groups through.")
                    } else {
                        setStatus("sensor.voip_phonebook exists but is empty. Check that your " +
                                  "ESP devices are online and publishing their VoIP endpoint.")
                    }
                } else {
                    setStatus("\(parsed.count) device(s) found via VoIP Stack phonebook")
                }
            }
            return true

        } catch {
            if !silent { setError(error.localizedDescription) }
            return false
        }
    }

    /// Parse the roster out of `sensor.voip_phonebook`'s attributes.
    ///
    /// VoIP Stack publishes the same roster twice, in two different shapes:
    ///
    ///   `roster_json` — the canonical document,
    ///                   `{"version":2,"capabilities":[…],"contacts":[…]}`
    ///   `phonebook`   — a compact ESP-oriented string: rows joined with ",",
    ///                   each `name|ip|sip_port|rtp_port|audio_mode|tx|rx|sip_udp`
    ///                   (the same shape as a per-device endpoint sensor, minus
    ///                   the trailing extension field).  A peer with no address
    ///                   or no usable transport degrades to a bare name.
    ///
    /// The JSON is richer, so it wins; the compact string is the fallback.
    /// Entries that resolve to no address are skipped either way — those are
    /// name-only or group targets that only Home Assistant can route.
    /// Test seam for the roster-attribute parsing above, which has repeatedly
    /// been the layer that silently produced an empty device list.
    func parseVoipRosterForTesting(_ attributes: [String: Any]) -> [IntercomDevice] {
        parseVoipRoster(attributes)
    }

    private func parseVoipRoster(_ attributes: [String: Any]) -> [IntercomDevice] {
        // This layer has silently produced an empty list more than once, so say
        // what was actually received before deciding anything.
        let shapes = attributes.keys.sorted().map { key -> String in
            let value = attributes[key]
            let kind: String
            switch value {
            case let string as String: kind = "string(\(string.count))"
            case is [Any]:             kind = "array"
            case is [String: Any]:     kind = "object"
            case is Int:               kind = "int"
            default:                   kind = "other"
            }
            return "\(key):\(kind)"
        }
        print("HomeAssistantClient: voip_phonebook attributes — \(shapes.joined(separator: " "))")

        // 1 — canonical JSON document.
        if let raw = attributes["roster_json"] as? String, !raw.isEmpty {
            let parsed = IntercomDevice.fromRosterJSON(raw)
            print("HomeAssistantClient: roster_json string → \(parsed.count) device(s)")
            if !parsed.isEmpty { return parsed }
        }
        // Some HA versions hand back already-decoded JSON rather than a string.
        for key in ["roster_json", "contacts", "roster", "entries"] {
            if let array = attributes[key] as? [[String: Any]] {
                let parsed = IntercomDevice.fromRosterEntries(array)
                if !parsed.isEmpty { return parsed }
            }
            if let object = attributes[key] as? [String: Any],
               let contacts = object["contacts"] as? [[String: Any]] {
                let parsed = IntercomDevice.fromRosterEntries(contacts)
                if !parsed.isEmpty { return parsed }
            }
        }
        // 2 — compact ESP phonebook string.
        if let raw = attributes["phonebook"] as? String, !raw.isEmpty {
            let parsed = parsePhonebook(raw)
            print("HomeAssistantClient: compact phonebook (\(raw.count) chars) → " +
                  "\(parsed.count) device(s)")
            return parsed
        }
        print("HomeAssistantClient: no usable roster attribute found")
        return []
    }

    // MARK: - REST: phonebook aggregator

    /// Returns true if the entity exists (even if it has 0 entries).
    @discardableResult
    private func fetchPhonebook(baseURL: String, token: String, silent: Bool = false) async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/states/sensor.intercom_phonebook") else {
            if !silent { setError("Invalid HA URL") }
            return false
        }
        do {
            let (data, response) = try await makeRequest(url: url, token: token)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 404 {
                // Entity doesn't exist — intercom_native not installed; try fallback.
                return false
            }
            if status != 200 {
                if !silent { setError("HA returned HTTP \(status)") }
                return true   // entity-level error; don't try fallback
            }

            guard
                let obj   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let attrs = obj["attributes"] as? [String: Any]
            else {
                if !silent { setError("Could not parse HA response") }
                return true
            }

            let raw = attrs["phonebook"] as? String ?? ""
            let parsed = parsePhonebook(raw)
            discoveredDevices = parsed

            if !silent {
                if parsed.isEmpty {
                    setStatus("sensor.intercom_phonebook exists but has 0 entries. " +
                              "Ensure your ESP devices are configured in HA.")
                } else {
                    setStatus("\(parsed.count) device(s) found via intercom_native phonebook")
                }
            }
            return true

        } catch {
            if !silent { setError(error.localizedDescription) }
            return false
        }
    }

    // MARK: - REST: individual endpoint sensors

    private func fetchEndpointSensors(baseURL: String, token: String, silent: Bool = false) async {
        guard let url = URL(string: "\(baseURL)/api/states") else {
            if !silent { setError("Invalid HA URL") }
            return
        }
        do {
            let (data, response) = try await makeRequest(url: url, token: token)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if !silent { setError("HA returned HTTP \(status) — check your URL and token") }
                return
            }
            guard let states = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                if !silent { setError("Could not parse HA states list") }
                return
            }

            // Each ESPHome node publishes one endpoint entity:
            //   <= 2026.6 : sensor.<name>_intercom_endpoint  → "name|tcp|ip|port"
            //   >= 2026.7 : sensor.<name>_voip_endpoint      → the longer
            //               "Name|host|sip_port|rtp_port|mode|tx|rx|sip_udp|ext"
            let endpoints = states.filter {
                let id = $0["entity_id"] as? String ?? ""
                return id.hasSuffix("_intercom_endpoint") || id.hasSuffix("_voip_endpoint")
            }

            let devices: [IntercomDevice] = endpoints.compactMap { entity in
                // Long endpoint strings can exceed HA's 255-char state cap, in
                // which case the full value is mirrored into an attribute.
                let attrs = entity["attributes"] as? [String: Any]
                let state = (attrs?["endpoint"] as? String)
                    ?? (entity["state"] as? String)
                    ?? ""
                // Shape-detected, so either generation resolves correctly.
                return IntercomDevice.fromEndpointState(state)
            }

            discoveredDevices = devices

            if !silent {
                if devices.isEmpty {
                    if endpoints.isEmpty {
                        setError("No intercom entities found in HA. " +
                                 "Install the intercom_native custom component, " +
                                 "or ensure your ESP devices have published their endpoints.")
                    } else {
                        setStatus("\(endpoints.count) endpoint sensor(s) found but none are reachable yet")
                    }
                } else {
                    setStatus("\(devices.count) device(s) found via endpoint sensors")
                }
            }
        } catch {
            if !silent { setError(error.localizedDescription) }
        }
    }

    // MARK: - WebSocket live updates

    private func subscribeWebSocket(baseURL: String, token: String) async {
        var wsURL = baseURL
        if wsURL.hasPrefix("https://") {
            wsURL = "wss://" + wsURL.dropFirst("https://".count)
        } else {
            wsURL = "ws://" + wsURL.dropFirst("http://".count)
        }
        wsURL += "/api/websocket"

        guard let url = URL(string: wsURL) else { return }

        let task = URLSession.shared.webSocketTask(with: url)
        wsTask = task
        task.resume()

        do {
            _ = try await task.receive()   // auth_required
            try await task.send(.string(#"{"type":"auth","access_token":"\#(token)"}"#))
            let authMsg = try await task.receive()
            if case .string(let s) = authMsg, s.contains("auth_invalid") {
                isConnected = false
                return
            }

            let subId = wsMessageId; wsMessageId += 1
            try await task.send(.string(
                #"{"id":\#(subId),"type":"subscribe_events","event_type":"state_changed"}"#
            ))

            isConnected = true

            while wsTask === task {
                let msg = try await task.receive()
                if case .string(let s) = msg { handleWSEvent(s, token: token, baseURL: baseURL) }
            }
        } catch {
            isConnected = false
        }
    }

    private func handleWSEvent(_ json: String, token: String, baseURL: String) {
        guard
            let data    = json.data(using: .utf8),
            let obj     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let event   = obj["event"]  as? [String: Any],
            let evData  = event["data"] as? [String: Any],
            let entityId = evData["entity_id"] as? String
        else { return }

        if entityId == "sensor.voip_phonebook" {
            guard
                let newState = evData["new_state"]  as? [String: Any],
                let attrs    = newState["attributes"] as? [String: Any]
            else { return }
            let parsed = parseVoipRoster(attrs)
            // An empty parse here usually means a transient publish, not a real
            // empty roster — don't blank a working device list on it.
            if !parsed.isEmpty { discoveredDevices = parsed }

        } else if entityId == "sensor.intercom_phonebook" {
            guard
                let newState = evData["new_state"]  as? [String: Any],
                let attrs    = newState["attributes"] as? [String: Any],
                let raw      = attrs["phonebook"] as? String
            else { return }
            discoveredDevices = parsePhonebook(raw)

        } else if entityId.hasSuffix("_intercom_endpoint") || entityId.hasSuffix("_voip_endpoint") {
            // Re-fetch all endpoint sensors to keep list consistent.
            Task { await fetchEndpointSensors(baseURL: baseURL, token: token) }
        }
    }

    // MARK: - Parsing

    /// Parse a comma/newline-separated phonebook string.  Rows are shape-detected
    /// per entry, so a VoIP Stack roster (`name|ip|sip_port|…|sip_udp`) and a
    /// legacy one (`name|tcp|ip|port`) both work — including a mixed list, which
    /// is what a house running two firmware generations produces.  Bare-name rows
    /// (a peer with no direct address) yield nothing and are skipped.
    private func parsePhonebook(_ phonebook: String) -> [IntercomDevice] {
        phonebook
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { IntercomDevice.fromEndpointState($0) }
    }

    // MARK: - Endpoint registration

    /// Publishes this device as sensor.intercom_<slug>_endpoint in HA.
    /// intercom_native will pick it up if it scans all *_intercom_endpoint entities,
    /// and it will also appear in our own fallback discovery scan.
    /// `sipPort` is the port the SIP endpoint actually bound, which is not
    /// necessarily 5060 — see SIPEndpoint's ephemeral fallback.  Advertising the
    /// conventional port when we're listening elsewhere makes us uncallable.
    func registerEndpoint(baseURL: String, token: String,
                          name: String, ip: String, port: Int,
                          sipPort: Int = Int(SIPEndpoint.defaultPort)) async {
        let slug = Self.slug(name)

        // Legacy registration — keeps pre-2026.7 installs working unchanged.
        await postState(baseURL: baseURL, token: token,
                        entityId: "sensor.intercom_\(slug)_endpoint",
                        state: "\(name)|tcp|\(ip)|\(port)",
                        friendlyName: "\(name) Intercom Endpoint")

        // VoIP Stack registration (>= v2026.7.0), in the endpoint shape that
        // release's device resolver parses:
        //   Name|host|sip_port|rtp_port|audio_mode|tx|rx|sip_udp|extension
        await postState(baseURL: baseURL, token: token,
                        entityId: "sensor.voip_\(slug)_endpoint",
                        state: Self.voipEndpointState(name: name, ip: ip, sipPort: sipPort),
                        friendlyName: "\(name) VoIP Endpoint")
    }

    /// Capability list this client advertises: 16 kHz mono s16 at every
    /// packetisation interval the profile allows.  The sample rate is fixed
    /// because AudioEngine renders 16 kHz natively — offering a rate we'd have
    /// to resample would trade audio quality for a compatibility we don't need.
    nonisolated static var advertisedFormats: [VoipAudioFormat] {
        VoipAudioFormat.preferredFrameMs.map { VoipAudioFormat.appDefault(frameMs: $0) }
    }

    nonisolated static func voipEndpointState(name: String, ip: String,
                                              sipPort: Int = Int(SIPEndpoint.defaultPort)) -> String {
        let formats = VoipAudioFormat.encodeList(advertisedFormats)
        return [name,
                ip,
                String(sipPort),
                String(RTPAudioSession.basePort),
                "full_duplex",
                formats,
                formats,
                "sip_udp",
                ""].joined(separator: "|")
    }

    nonisolated static func slug(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private func postState(baseURL: String, token: String,
                           entityId: String, state: String,
                           friendlyName: String) async {
        guard let url = URL(string: "\(baseURL)/api/states/\(entityId)") else { return }

        let body = ["state": state,
                    "attributes": ["friendly_name": friendlyName,
                                   "icon": "mdi:phone-voip",
                                   // Mirrored so a value over HA's 255-char state
                                   // cap is still readable by discovery.
                                   "endpoint": state]] as [String: Any]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Helpers

    private func makeRequest(url: URL, token: String) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await URLSession.shared.data(for: req)
    }

    private func setStatus(_ msg: String) {
        statusMessage = msg
        isError = false
    }

    private func setError(_ msg: String) {
        statusMessage = msg
        isError = true
    }
}

// MARK: - Keychain helpers

enum KeychainKey {
    static let haToken   = "ha_access_token"
    static let haBaseURL = "ha_base_url"
}

func keychainSave(key: String, value: String) {
    let data = Data(value.utf8)
    let query: [String: Any] = [
        kSecClass as String:       kSecClassGenericPassword,
        kSecAttrAccount as String: key,
        kSecValueData as String:   data
    ]
    SecItemDelete(query as CFDictionary)
    SecItemAdd(query as CFDictionary, nil)
}

func keychainLoad(key: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String:            kSecClassGenericPassword,
        kSecAttrAccount as String:      key,
        kSecReturnData as String:       true,
        kSecMatchLimit as String:       kSecMatchLimitOne
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
}

func keychainDelete(key: String) {
    let query: [String: Any] = [
        kSecClass as String:       kSecClassGenericPassword,
        kSecAttrAccount as String: key
    ]
    SecItemDelete(query as CFDictionary)
}
