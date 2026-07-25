import Foundation

// Verification harness for the voip-pcm/1 protocol layer.  Compiled against the
// real source files (see run_tests.sh) — not a copy.

var failures = 0
var checks   = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual == expected {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label) — got \(actual), expected \(expected)")
    }
}

// MARK: - Audio format tokens

print("\nVoipAudioFormat")
do {
    let fmt = VoipAudioFormat(token: "16000:s16le:1:32")
    check(fmt != nil, "parses documented token 16000:s16le:1:32")
    checkEqual(fmt?.sampleRate, 16_000, "sample rate")
    checkEqual(fmt?.frameMs, 32, "frame ms")
    checkEqual(fmt?.wireToken, "16000:s16le:1:32", "round-trips to the same token")
    // 16 kHz * 32 ms = 512 samples * 2 bytes = 1024 bytes.
    checkEqual(fmt?.frameSamples, 512, "frame samples")
    checkEqual(fmt?.frameBytes, 1024, "frame bytes")

    let twenty = VoipAudioFormat(token: "16000:s16le:1:20")
    checkEqual(twenty?.frameBytes, 640, "20 ms frame is 640 bytes")
    checkEqual(twenty?.fitsRtpPayload, true, "20 ms frame fits the 1200-byte cap")

    // frame_ms outside SUPPORTED_FRAME_MS must be rejected, not rounded.
    check(VoipAudioFormat(token: "16000:s16le:1:25") == nil, "rejects unsupported frame_ms 25")
    check(VoipAudioFormat(token: "22050:s16le:1:20") == nil, "rejects unsupported sample rate")
    check(VoipAudioFormat(token: "16000:opus:1:20") == nil, "rejects non-PCM format")
    check(VoipAudioFormat(token: "16000:s16le:1") == nil, "rejects 3-field token")

    let list = VoipAudioFormat.parseList("16000:s16le:1:20;16000:s16le:1:32;garbage")
    checkEqual(list.count, 2, "parses list and skips the invalid entry")

    // Firmware preference order is 10, 16, 20, 32.
    let a = VoipAudioFormat.parseList("16000:s16le:1:20;16000:s16le:1:32")
    let b = VoipAudioFormat.parseList("16000:s16le:1:32;16000:s16le:1:10")
    checkEqual(VoipAudioFormat.commonFrameMs(a, b), 32, "common frame_ms is the shared value")

    let c = VoipAudioFormat.parseList("16000:s16le:1:10;16000:s16le:1:20")
    checkEqual(VoipAudioFormat.commonFrameMs(a, c), 20, "prefers 10/16/20/32 order among shared")

    checkEqual(VoipAudioFormat.appDefault().isNativeToAudioEngine, true,
               "default format needs no resampling")
    checkEqual(VoipAudioFormat(token: "48000:s16le:2:20")?.isNativeToAudioEngine, false,
               "48 kHz stereo is not engine-native")
}

// MARK: - SIP messages

print("\nSIPMessage")
do {
    let raw = """
    SIP/2.0 200 OK\r
    Via: SIP/2.0/UDP 192.168.1.10:5060;branch=z9hG4bKabc;rport=5060\r
    From: "iPhone" <sip:iphone@192.168.1.10:5060>;tag=localtag\r
    t: <sip:kitchen@192.168.1.51:5060>;tag=remotetag\r
    i: call-123@192.168.1.10\r
    CSeq: 42 INVITE\r
    Contact: <sip:kitchen@192.168.1.51:5060>\r
    Content-Type: application/sdp\r
    Content-Length: 5\r
    \r
    hello
    """
    let msg = SIPMessage.decode(Data(raw.utf8))
    check(msg != nil, "decodes a response")
    checkEqual(msg?.statusCode, 200, "status code")
    checkEqual(msg?.callID, "call-123@192.168.1.10", "compact 'i' header maps to Call-ID")
    checkEqual(msg?.toTag, "remotetag", "compact 't' header yields the To tag")
    checkEqual(msg?.fromTag, "localtag", "From tag")
    checkEqual(msg?.cseq?.number, 42, "CSeq number")
    checkEqual(msg?.cseq?.method, "INVITE", "CSeq method")
    checkEqual(String(data: msg?.body ?? Data(), encoding: .utf8), "hello", "body")
    checkEqual(SIPMessage.uri(in: msg?.first("Contact")), "sip:kitchen@192.168.1.51:5060",
               "extracts URI from angle brackets")

    // A tag inside the URI must not be mistaken for a header parameter.
    checkEqual(SIPMessage.parameter("transport", in: "<sip:a@b;transport=tcp>;tag=xyz"), nil,
               "URI parameters are not read as header parameters")
    checkEqual(SIPMessage.parameter("tag", in: "<sip:a@b;transport=tcp>;tag=xyz"), "xyz",
               "header tag still parsed when the URI has its own params")

    checkEqual(SIPMessage.displayName(in: #""Front Door" <sip:door@h>"#), "Front Door",
               "unquotes display name")

    // Round trip: Content-Length must be recomputed from the real body.
    var request = SIPMessage(kind: .request(method: .invite, uri: "sip:kitchen@192.168.1.51"),
                             headers: [], body: Data("abc".utf8))
    request.set("Call-ID", "xyz")
    request.set("Content-Length", "999")     // deliberately wrong
    let encoded = request.encode()
    let text = String(data: encoded, encoding: .utf8) ?? ""
    check(text.contains("Content-Length: 3"), "recomputes Content-Length from the body")
    check(!text.contains("999"), "ignores a stale caller-supplied Content-Length")
    checkEqual(SIPMessage.decode(encoded)?.callID, "xyz", "request round-trips")

    // TCP framing: two messages arriving in one read.
    var buffer = Data()
    buffer.append(encoded)
    buffer.append(encoded)
    var framedCount = 0
    while let framed = SIPMessage.frame(from: buffer) {
        buffer = framed.remaining
        check(SIPMessage.decode(framed.message) != nil, "framed message \(framedCount + 1) decodes")
        framedCount += 1
    }
    checkEqual(framedCount, 2, "frames two concatenated messages")
    checkEqual(buffer.count, 0, "consumes the whole buffer")

    // A partial message must not be framed early.
    check(SIPMessage.frame(from: encoded.prefix(encoded.count - 1)) == nil,
          "withholds an incomplete message")

    check(SIPMessage.newBranch().hasPrefix("z9hG4bK"), "branch carries the RFC 3261 cookie")
}

// MARK: - SDP

print("\nSDPSession")
do {
    // A realistic ESP answer: L16 at 16 kHz mono with a 32 ms packet time.
    let espAnswer = """
    v=0\r
    o=- 12345 12345 IN IP4 192.168.1.51\r
    s=VoIP Stack\r
    c=IN IP4 192.168.1.51\r
    t=0 0\r
    m=audio 40000 RTP/AVP 96 101\r
    a=rtpmap:96 L16/16000/1\r
    a=rtpmap:101 telephone-event/8000\r
    a=fmtp:101 0-15\r
    a=ptime:32\r
    a=maxptime:32\r
    a=sendrecv\r
    """
    let parsed = try SDPSession.parse(Data(espAnswer.utf8))
    checkEqual(parsed.port, 40_000, "parses media port")
    checkEqual(parsed.address, "192.168.1.51", "parses connection address")
    checkEqual(parsed.ptime, 32, "parses ptime")
    checkEqual(parsed.direction, "sendrecv", "parses direction")

    let media = try SDPSession.negotiate(parsed)
    checkEqual(media.payloadType, 96, "selects the peer's L16 payload type")
    checkEqual(media.format.sampleRate, 16_000, "negotiates 16 kHz")
    checkEqual(media.frameMs, 32, "honours the peer's ptime over our preference")
    checkEqual(media.format.frameBytes, 1024, "frame size follows the negotiated ptime")
    checkEqual(media.telephoneEventPayloadType, 101, "identifies the DTMF payload type")
    checkEqual(media.peerWillSendAudio, true, "sendrecv means the peer sends")

    // Compressed-only offer: the profile requires 488, so negotiation must fail.
    let pcmuOnly = """
    v=0\r
    o=- 1 1 IN IP4 192.168.1.77\r
    c=IN IP4 192.168.1.77\r
    t=0 0\r
    m=audio 5004 RTP/AVP 0 8\r
    a=rtpmap:0 PCMU/8000\r
    a=rtpmap:8 PCMA/8000\r
    a=ptime:20\r
    """
    do {
        _ = try SDPSession.negotiate(try SDPSession.parse(Data(pcmuOnly.utf8)))
        check(false, "rejects a PCMU/PCMA-only offer")
    } catch SDPError.incompatibleMedia {
        check(true, "rejects a PCMU/PCMA-only offer")
    }

    // A rate we would have to resample is refused rather than played wrong.
    let highRate = """
    v=0\r
    o=- 1 1 IN IP4 192.168.1.78\r
    c=IN IP4 192.168.1.78\r
    t=0 0\r
    m=audio 5004 RTP/AVP 97\r
    a=rtpmap:97 L16/48000/2\r
    a=ptime:20\r
    """
    do {
        _ = try SDPSession.negotiate(try SDPSession.parse(Data(highRate.utf8)))
        check(false, "rejects L16/48000/2")
    } catch SDPError.incompatibleMedia {
        check(true, "rejects L16/48000/2")
    }

    // Mixed offer: must skip the compressed codecs and find the L16 stream.
    let mixed = """
    v=0\r
    o=- 1 1 IN IP4 192.168.1.79\r
    c=IN IP4 192.168.1.79\r
    t=0 0\r
    m=audio 6000 RTP/AVP 0 96\r
    a=rtpmap:0 PCMU/8000\r
    a=rtpmap:96 L16/16000/1\r
    a=ptime:20\r
    """
    let mixedMedia = try SDPSession.negotiate(try SDPSession.parse(Data(mixed.utf8)))
    checkEqual(mixedMedia.payloadType, 96, "skips PCMU and picks the L16 stream")

    // A peer that rejected the stream outright.
    let rejected = """
    v=0\r
    o=- 1 1 IN IP4 192.168.1.80\r
    c=IN IP4 192.168.1.80\r
    t=0 0\r
    m=audio 0 RTP/AVP 96\r
    a=rtpmap:96 L16/16000/1\r
    """
    do {
        _ = try SDPSession.negotiate(try SDPSession.parse(Data(rejected.utf8)))
        check(false, "treats m=audio 0 as incompatible")
    } catch SDPError.incompatibleMedia {
        check(true, "treats m=audio 0 as incompatible")
    }

    // Our own offer must satisfy the profile's structural rules.
    let offer = SDPSession.buildDescription(address: "192.168.1.10",
                                            port: 40_000,
                                            format: .appDefault(frameMs: 20),
                                            payloadType: 96)
    let offerText = String(data: offer, encoding: .utf8) ?? ""
    check(offerText.contains("a=rtpmap:96 L16/16000/1"), "offer advertises L16/16000/1")
    check(offerText.contains("a=ptime:20"), "offer carries a=ptime")
    check(offerText.contains("a=maxptime:20"), "offer carries a=maxptime")
    check(!offerText.contains("a=fmtp:96"), "offer does not put packet time in fmtp")
    check(offerText.contains("m=audio 40000 RTP/AVP 96 101"), "offer lists payload types")
    check((96...127).contains(Int(SDPSession.localL16PayloadType)), "uses a dynamic payload type")
    // Our own offer must be parseable by our own parser.
    let reparsed = try SDPSession.negotiate(try SDPSession.parse(offer))
    checkEqual(reparsed.payloadType, 96, "our offer round-trips through our parser")
}

// MARK: - Device / roster parsing

print("\nIntercomDevice")
do {
    // Legacy phonebook entry.
    let legacy = IntercomDevice.fromPhonebookEntry("Kitchen|tcp|192.168.1.42|6054")
    checkEqual(legacy?.name, "Kitchen", "legacy entry name")
    checkEqual(legacy?.port, 6054, "legacy entry port")
    checkEqual(legacy?.protocolKind, .legacy, "legacy entry is marked legacy")

    // New endpoint standard:
    // Name|host|sip_port|rtp_port|audio_mode|tx|rx|sip_tcp|extension
    let voipState = "Kitchen|192.168.1.51|5060|40000|full_duplex|" +
                    "16000:s16le:1:32;16000:s16le:1:20|16000:s16le:1:32|sip_udp|201"
    let voip = IntercomDevice.fromVoipEndpointString(voipState)
    check(voip != nil, "parses the voip endpoint string")
    checkEqual(voip?.name, "Kitchen", "voip endpoint name")
    checkEqual(voip?.host, "192.168.1.51", "voip endpoint host")
    checkEqual(voip?.sipPort, 5060, "voip endpoint SIP port")
    checkEqual(voip?.rtpPort, 40_000, "voip endpoint RTP port")
    checkEqual(voip?.sipTransport, .udp, "voip endpoint transport")
    checkEqual(voip?.protocolKind, .voip, "voip endpoint marked voip")
    checkEqual(voip?.extensionNumber, "201", "voip endpoint extension")
    checkEqual(voip?.txFormats.count, 2, "voip endpoint tx formats")
    checkEqual(voip?.preferredFrameMs, 32, "picks the frame_ms shared by tx and rx")

    // TCP variant.
    let tcpState = "Gate|192.168.1.52|5060|40000|full_duplex|" +
                   "16000:s16le:1:20|16000:s16le:1:20|sip_tcp|"
    checkEqual(IntercomDevice.fromVoipEndpointString(tcpState)?.sipTransport, .tcp,
               "sip_tcp maps to TCP signaling")

    // Shape detection must not confuse the two generations.
    checkEqual(IntercomDevice.fromEndpointState("Kitchen|tcp|192.168.1.42|6054")?.protocolKind,
               .legacy, "shape detection routes a legacy string to the legacy parser")
    checkEqual(IntercomDevice.fromEndpointState(voipState)?.protocolKind, .voip,
               "shape detection routes a voip string to the voip parser")
    check(IntercomDevice.fromEndpointState("unavailable") == nil, "ignores 'unavailable'")
    // Missing formats mean a half-booted device, not a callable one.
    check(IntercomDevice.fromVoipEndpointString(
            "Kitchen|192.168.1.51|5060|40000|full_duplex|||sip_udp|") == nil,
          "rejects an endpoint with no advertised formats")

    // Stable identity across rediscovery.
    checkEqual(IntercomDevice.fromVoipEndpointString(voipState)?.id,
               IntercomDevice.fromVoipEndpointString(voipState)?.id,
               "endpoint identity is stable across parses")

    // JSON roster.
    let roster = """
    [
      {"name": "Salotto", "address": "192.168.1.52",
       "sip_uri": "sip:Salotto@192.168.1.52:5060;transport=tcp",
       "extension": "202",
       "metadata": {"sip_transport": "tcp", "sip_port": 5060, "rtp_port": 40000,
                    "tx_format": "16000:s16le:1:20", "rx_format": "16000:s16le:1:20"}},
      {"name": "AllRooms", "ha_bridge": true,
       "metadata": {"group_type": "ring", "members": ["Salotto"]}}
    ]
    """
    let entries = IntercomDevice.fromRosterJSON(roster)
    checkEqual(entries.count, 1, "skips the name-only HA bridge group")
    checkEqual(entries.first?.name, "Salotto", "roster entry name")
    checkEqual(entries.first?.sipTransport, .tcp, "roster transport metadata")
    checkEqual(entries.first?.sipPort, 5060, "roster SIP port")
    checkEqual(entries.first?.protocolKind, .voip, "roster entries are voip")

    // A roster entry with only a SIP URI still yields a usable host.
    let uriOnly = """
    [{"name": "Gate", "sip_uri": "sip:Gate@192.168.1.60:5062;transport=udp"}]
    """
    let gate = IntercomDevice.fromRosterJSON(uriOnly).first
    checkEqual(gate?.host, "192.168.1.60", "derives host from the SIP URI")
    checkEqual(gate?.sipPort, 5062, "derives port from the SIP URI")
    checkEqual(gate?.sipTransport, .udp, "derives transport from the SIP URI")

    // Upgrade safety: a roster persisted by the previous build has none of the
    // new keys and must still decode — as a legacy device.
    let oldJSON = """
    [{"id":"11111111-2222-3333-4444-555555555555","name":"Old","host":"10.0.0.5","port":6054}]
    """
    let decoded = try JSONDecoder().decode([IntercomDevice].self, from: Data(oldJSON.utf8))
    checkEqual(decoded.count, 1, "decodes a pre-upgrade saved roster")
    // Must be .auto, not .legacy: a panel saved before this update may since have
    // been upgraded past v2026.7.0, and .legacy would strand it permanently.
    checkEqual(decoded.first?.protocolKind, .auto, "pre-upgrade devices probe rather than assume legacy")
    checkEqual(decoded.first?.sipPort, 5060, "pre-upgrade devices get a default SIP port")

    // And the new shape must survive a save/load cycle.
    let reencoded = try JSONEncoder().encode(entries)
    let reloaded  = try JSONDecoder().decode([IntercomDevice].self, from: reencoded)
    checkEqual(reloaded.first?.protocolKind, .voip, "voip devices persist their protocol")
    checkEqual(reloaded.first?.sipTransport, .tcp, "voip devices persist their transport")
}

// MARK: - Persisted-store migration

print("\nDeviceStore.migrate")
do {
    // The pre-fix build wrote protocolKind explicitly on every save, so simply
    // changing the decode default could not reach devices already on disk.
    let stored = [
        IntercomDevice(name: "Poppy Monitor", host: "192.168.2.171", protocolKind: .legacy),
        IntercomDevice(name: "Salotto", host: "192.168.1.52", protocolKind: .voip),
        IntercomDevice(name: "Manual", host: "192.168.1.99", protocolKind: .auto),
    ]

    let migrated = DeviceStore.migrate(stored, fromSchema: 0)
    checkEqual(migrated[0].protocolKind, .auto, "legacy-pinned device is re-armed for probing")
    checkEqual(migrated[1].protocolKind, .voip, "voip devices are left alone")
    checkEqual(migrated[2].protocolKind, .auto, "auto devices are left alone")
    checkEqual(migrated.count, stored.count, "migration preserves the roster")
    checkEqual(migrated[0].host, "192.168.2.171", "migration preserves addressing")

    // Schema 1 is the pre-fix build; it needs the same treatment.
    checkEqual(DeviceStore.migrate(stored, fromSchema: 1)[0].protocolKind, .auto,
               "schema 1 stores are migrated too")

    // Once migrated, a deliberate user choice must survive.
    checkEqual(DeviceStore.migrate(stored, fromSchema: 2)[0].protocolKind, .legacy,
               "a hand-pinned legacy device is not re-armed at the current schema")
}

// MARK: - Discovery reconciliation

print("\nDeviceStore.upsertDiscovered")
MainActor.assumeIsolated {
    // Isolate from any real persisted roster.
    UserDefaults.standard.removeObject(forKey: IntercomDevice.storageKey)
    UserDefaults.standard.removeObject(forKey: "saved_devices_schema")

    let store = DeviceStore()
    let original = IntercomDevice(name: "Poppy Monitor", host: "192.168.2.171",
                                  protocolKind: .legacy)
    store.add(original)

    // The panel takes a new DHCP lease. Matching on host (the old behaviour)
    // could never reconcile this — it duplicated the entry and left calls
    // pointed at the dead address.
    let moved = IntercomDevice(name: "Poppy Monitor", host: "192.168.2.180",
                              protocolKind: .voip, sipPort: 5060, sipTransport: .udp,
                              txFormats: ["16000:s16le:1:20"], rxFormats: ["16000:s16le:1:20"])
    store.upsertDiscovered(moved)

    checkEqual(store.devices.count, 1, "a device that changed IP is not duplicated")
    checkEqual(store.devices.first?.host, "192.168.2.180", "the new address is adopted")
    checkEqual(store.devices.first?.id, original.id, "the stored id is preserved")
    checkEqual(store.devices.first?.protocolKind, .voip, "discovery refreshes protocol metadata")
    checkEqual(store.devices.first?.sipPort, 5060, "discovery refreshes the SIP port")

    // Case/diacritic-insensitive identity matching.
    store.upsertDiscovered(IntercomDevice(name: "poppy monitor", host: "192.168.2.181",
                                          protocolKind: .voip))
    checkEqual(store.devices.count, 1, "name matching ignores case")
    checkEqual(store.devices.first?.host, "192.168.2.181", "case-insensitive match still updates")

    // A genuinely different panel is added.
    store.upsertDiscovered(IntercomDevice(name: "Gate", host: "192.168.2.190", protocolKind: .voip))
    checkEqual(store.devices.count, 2, "a genuinely new device is added")

    // An unchanged re-discovery is a no-op, so we don't churn UserDefaults or
    // re-donate Siri shortcuts on every poll.
    let unchanged = store.upsertDiscovered(IntercomDevice(name: "Gate", host: "192.168.2.190",
                                                          protocolKind: .voip))
    checkEqual(unchanged, false, "an unchanged rediscovery reports no change")

    UserDefaults.standard.removeObject(forKey: IntercomDevice.storageKey)
    UserDefaults.standard.removeObject(forKey: "saved_devices_schema")
}

// MARK: - Legacy→VoIP fallback trigger

print("\nIntercomConnection.isConnectionRefused")
do {
    // ECONNREFUSED means the host is up and nothing is bound to that port, so
    // the panel is running firmware that dropped the legacy protocol. This is
    // the signal that must override a stale stored protocolKind.
    check(IntercomConnection.isConnectionRefused(.posix(.ECONNREFUSED)),
          "connection refused is recognised")
    // These mean the panel itself is absent, so legacy reconnect/backoff should
    // still apply rather than switching protocol.
    check(!IntercomConnection.isConnectionRefused(.posix(.ETIMEDOUT)),
          "timeout is not treated as a protocol signal")
    check(!IntercomConnection.isConnectionRefused(.posix(.EHOSTUNREACH)),
          "unreachable host is not treated as a protocol signal")
    check(!IntercomConnection.isConnectionRefused(.posix(.ENETDOWN)),
          "network down is not treated as a protocol signal")
    check(!IntercomConnection.isConnectionRefused(nil),
          "a clean close is not treated as a protocol signal")
}

// MARK: - SIP URI user part

print("\nSIPCall.uriUser")
do {
    // The roster addresses panels by their exact name, and VoIP Stack validates
    // the Request-URI — so the name must survive, not be slugified.
    checkEqual(SIPCall.uriUser("Kitchen"), "Kitchen", "preserves a simple name verbatim")
    checkEqual(SIPCall.uriUser("Poppy Monitor"), "Poppy%20Monitor", "escapes a space rather than lowercasing")
    checkEqual(SIPCall.uriUser("Salotto"), "Salotto", "preserves capitalisation")
    checkEqual(SIPCall.uriUser("Front-Door_2"), "Front-Door_2", "keeps unreserved punctuation")
    checkEqual(SIPCall.uriUser(""), "phone", "falls back for an empty name")
    checkEqual(SIPCall.uriUser("Caffè"), "Caff%C3%A8", "percent-escapes non-ASCII as UTF-8")
    // Whatever we emit has to survive our own URI parsing.
    let uri = "sip:\(SIPCall.uriUser("Poppy Monitor"))@192.168.2.171:5060"
    checkEqual(IntercomDevice.hostPart(ofSipURI: uri), "192.168.2.171", "escaped user part still parses")
    checkEqual(IntercomDevice.portPart(ofSipURI: uri), 5060, "escaped user part keeps the port parseable")
}

// MARK: - RTP payload conversion

print("\nRTPAudioSession")
do {
    // L16 on the wire is big-endian; AudioEngine is host order.
    let host = Data([0x01, 0x02, 0x03, 0x04])
    let wire = RTPAudioSession.byteSwapped16(host)
    checkEqual([UInt8](wire), [0x02, 0x01, 0x04, 0x03], "swaps each 16-bit sample")
    checkEqual([UInt8](RTPAudioSession.byteSwapped16(wire)), [UInt8](host),
               "swap is its own inverse")
    checkEqual(RTPAudioSession.byteSwapped16(Data()).count, 0, "handles an empty buffer")
    checkEqual(RTPAudioSession.byteSwapped16(Data([0x01])).count, 0,
               "drops a misaligned trailing byte")

    // Silence must stay silence through the conversion.
    let silence = Data(count: 640)
    checkEqual(RTPAudioSession.byteSwapped16(silence), silence, "silence survives conversion")
}

// MARK: - Endpoint advertisement

print("\nEndpoint registration")
do {
    let state = HomeAssistantClient.voipEndpointState(name: "iPhone", ip: "192.168.1.10")
    let parts = state.components(separatedBy: "|")
    checkEqual(parts.count, 9, "advertisement has the 9 documented fields")
    checkEqual(parts[0], "iPhone", "advertised name")
    checkEqual(parts[1], "192.168.1.10", "advertised host")
    checkEqual(parts[4], "full_duplex", "advertised audio mode")
    checkEqual(parts[7], "sip_udp", "advertised transport token")
    // The firmware's own parser must accept what we publish.
    let roundTrip = IntercomDevice.fromVoipEndpointString(state)
    check(roundTrip != nil, "our advertisement parses as a valid voip endpoint")
    checkEqual(roundTrip?.sipPort, 5060, "advertised SIP port matches the listener")
    checkEqual(Int(RTPAudioSession.basePort), roundTrip?.rtpPort,
               "advertised RTP port matches the first port we actually bind")

    // When 5060 is taken we bind elsewhere; the advertisement has to follow, or
    // peers call a port nothing is listening on.
    let ephemeral = HomeAssistantClient.voipEndpointState(name: "iPhone",
                                                          ip: "192.168.1.10",
                                                          sipPort: 54321)
    checkEqual(ephemeral.components(separatedBy: "|")[2], "54321",
               "advertises the actually-bound SIP port, not the convention")
    checkEqual(IntercomDevice.fromVoipEndpointString(ephemeral)?.sipPort, 54321,
               "ephemeral-port advertisement still parses")
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILURE(S)")
    exit(1)
}
print("All protocol checks passed.")
