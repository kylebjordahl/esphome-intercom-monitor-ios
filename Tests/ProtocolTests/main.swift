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

// MARK: - voip_phonebook attribute shapes

print("\nsensor.voip_phonebook parsing")
MainActor.assumeIsolated {
    let client = HomeAssistantClient()

    // Exactly what VoipPhonebookSensor.extra_state_attributes publishes:
    // roster_json is the canonical document, phonebook is the compact ESP
    // string built by format_entry_unified() and joined with ",".
    let rosterJSON = """
    {"version":2,"capabilities":["extension","ring_group"],"contacts":[
      {"id":"poppy","name":"Poppy Monitor","address":"192.168.2.180",
       "sip_uri":"sip:Poppy Monitor@192.168.2.180:5060","extension":"201","port":5060,
       "metadata":{"sip_transport":"udp","sip_port":5060,"rtp_port":40000,
                   "tx_format":"16000:s16le:1:20","rx_format":"16000:s16le:1:20"}},
      {"id":"allrooms","name":"AllRooms","address":"","sip_uri":"","ha_bridge":true,
       "metadata":{"group_type":"ring","members":["Poppy Monitor"]}}
    ]}
    """
    let fromJSON = client.parseVoipRosterForTesting(["roster_json": rosterJSON,
                                                     "phonebook": "",
                                                     "count": 2])
    checkEqual(fromJSON.count, 1, "roster_json is read and the group entry skipped")
    checkEqual(fromJSON.first?.name, "Poppy Monitor", "roster_json entry name")
    checkEqual(fromJSON.first?.host, "192.168.2.180", "roster_json entry address")
    checkEqual(fromJSON.first?.protocolKind, .voip, "roster_json entries are voip")

    // The compact fallback. Note this row has 8 fields — no trailing extension,
    // unlike the per-device endpoint sensor.
    let compact = "Poppy Monitor|192.168.2.180|5060|40000|full_duplex|" +
                  "16000:s16le:1:20;16000:s16le:1:32|16000:s16le:1:20|sip_udp"
    let fromCompact = client.parseVoipRosterForTesting(["phonebook": compact, "count": 1])
    checkEqual(fromCompact.count, 1, "falls back to the compact phonebook string")
    checkEqual(fromCompact.first?.host, "192.168.2.180", "compact row address")
    checkEqual(fromCompact.first?.sipPort, 5060, "compact row SIP port")
    checkEqual(fromCompact.first?.sipTransport, .udp, "compact row transport")
    checkEqual(fromCompact.first?.protocolKind, .voip, "compact rows are voip")

    // Several rows, comma-joined, including a bare-name peer that has no direct
    // address (format_entry_unified returns just the name for those).
    let multi = "\(compact),AllRooms,Gate|192.168.2.190|5060|40000|full_duplex|" +
                "16000:s16le:1:20|16000:s16le:1:20|sip_tcp"
    let fromMulti = client.parseVoipRosterForTesting(["phonebook": multi, "count": 3])
    checkEqual(fromMulti.count, 2, "bare-name rows are skipped, addressable rows kept")
    checkEqual(fromMulti.last?.sipTransport, .tcp, "sip_tcp row parses as TCP")

    // A mixed-generation house: legacy and voip rows in one string.
    let mixed = "OldPanel|tcp|192.168.2.50|6054,\(compact)"
    let fromMixed = client.parseVoipRosterForTesting(["phonebook": mixed, "count": 2])
    checkEqual(fromMixed.count, 2, "mixed legacy + voip rows both parse")
    checkEqual(fromMixed.first?.protocolKind, .legacy, "legacy row keeps the legacy protocol")
    checkEqual(fromMixed.last?.protocolKind, .voip, "voip row keeps the voip protocol")

    // roster_json wins when both are present and usable.
    let both = client.parseVoipRosterForTesting(["roster_json": rosterJSON,
                                                 "phonebook": compact, "count": 2])
    checkEqual(both.first?.extensionNumber, "201",
               "roster_json is preferred over the compact string")

    // Already-decoded JSON, which some HA versions hand back instead of a string.
    let decoded: [String: Any] = ["roster_json": ["version": 2, "contacts": [
        ["id": "gate", "name": "Gate", "address": "192.168.2.190",
         "metadata": ["sip_transport": "udp", "sip_port": 5060]]
    ]]]
    checkEqual(client.parseVoipRosterForTesting(decoded).first?.name, "Gate",
               "pre-decoded roster_json is handled")

    checkEqual(client.parseVoipRosterForTesting(["phonebook": "", "count": 0]).count, 0,
               "an empty roster yields nothing")
}

// MARK: - Real roster captured from a live v2026.8.0 install

print("\nLive roster fixture")
MainActor.assumeIsolated {
    let client = HomeAssistantClient()

    // Verbatim from Developer Tools → States → sensor.voip_phonebook.
    let liveRosterJSON = """
    {"capabilities":["extension","ring_group","conference_group","conference_ring"],"contacts":[{"address":"192.168.7.173","enabled":true,"extension":"","ha_bridge":false,"id":"Poppy Monitor","metadata":{"audio_mode":"full_duplex","capabilities":["audio","dtmf"],"conference_group":"CG Casa","conference_ring":false,"device_id":"3484e3d6649858fab912c870f3e91de4","endpoint_id":"esphome:3484e3d6649858fab912c870f3e91de4","endpoint_kind":"esphome","local_ha":false,"ring_group":"RG Casa","rtp_port":40000,"rx_formats":["48000:s16le:1:10","32000:s16le:1:16","16000:s16le:1:10","16000:s16le:1:16","16000:s16le:1:32"],"sip_port":5060,"sip_transport":"udp","tx_formats":["16000:s16le:1:16","16000:s16le:1:10"]},"name":"Poppy Monitor","number":"","port":5060,"sip_uri":""},{"address":"192.168.7.148","enabled":true,"extension":"","ha_bridge":false,"id":"Patton Mannor","metadata":{"audio_mode":"full_duplex","capabilities":["audio","dtmf"],"conference_group":"","conference_ring":false,"device_id":"0aebd073ca623fa256a9c68b3e0b02c2","endpoint_id":"default","endpoint_kind":"browser","local_ha":true,"ring_group":"","rtp_port":40000,"rx_formats":["48000:s16le:2:20","48000:s16le:1:20","48000:s16le:1:10","32000:s16le:1:16","32000:s16le:1:10","16000:s16le:1:16","16000:s16le:1:10","16000:s16le:1:20"],"sip_port":5060,"sip_transport":"tcp","tx_formats":["48000:s16le:2:20","48000:s16le:1:20","48000:s16le:1:10","32000:s16le:1:16","32000:s16le:1:10","16000:s16le:1:16","16000:s16le:1:10","16000:s16le:1:20"]},"name":"Patton Mannor","number":"","port":5060,"sip_uri":""},{"address":"","enabled":true,"extension":"","ha_bridge":true,"id":"CG Casa","metadata":{"auto":true,"group_type":"conference","members":["Poppy Monitor"],"ring_members":[]},"name":"CG Casa","number":"","port":0,"sip_uri":""},{"address":"","enabled":true,"extension":"","ha_bridge":true,"id":"RG Casa","metadata":{"auto":true,"group_type":"ring","members":["Poppy Monitor"],"ring_members":[]},"name":"RG Casa","number":"","port":0,"sip_uri":""}],"version":2}
    """

    let devices = client.parseVoipRosterForTesting(["roster_json": liveRosterJSON, "count": 4])
    // Four contacts: one ESP panel, one HA browser softphone, two HA groups.
    // Only the ESP panel is an intercom this app should list.
    checkEqual(devices.count, 1, "only the ESP panel is listed")

    guard let poppy = devices.first(where: { $0.name == "Poppy Monitor" }) else {
        check(false, "Poppy Monitor is discovered"); exit(1)
    }
    checkEqual(poppy.host, "192.168.7.173", "ESP address")
    checkEqual(poppy.sipPort, 5060, "ESP SIP port from metadata")
    checkEqual(poppy.sipTransport, .udp, "ESP SIP transport from metadata")
    checkEqual(poppy.rtpPort, 40_000, "ESP RTP port from metadata")
    checkEqual(poppy.protocolKind, .voip, "ESP entry is voip")
    // The roster carries formats as JSON arrays under the *plural* keys.
    checkEqual(poppy.txFormats.count, 2, "tx_formats array parsed")
    checkEqual(poppy.rxFormats.count, 5, "rx_formats array parsed")

    // Every entry has "sip_uri": "" — an empty string, not a missing key. If that
    // reaches SIPCall the INVITE goes out with a blank Request-URI.
    check(poppy.sipURI == nil, "an empty sip_uri is normalised to nil, not kept as \"\"")

    // Packet time is the make-or-break detail for this device: it can only SEND
    // 16 ms or 10 ms frames, so the default 20 ms offer would earn a 488.
    checkEqual(Set(poppy.parsedTxFormats.map(\.frameMs)), Set([16, 10]), "ESP tx ptimes")
    checkEqual(Set(poppy.parsedRxFormats.map(\.frameMs)), Set([10, 16, 32]), "ESP rx ptimes")
    checkEqual(poppy.preferredFrameMs, 10, "negotiates a ptime the ESP supports in both directions")
    check(poppy.preferredFrameMs != 20, "does not fall back to the unsupported 20 ms default")

    // 16 kHz mono is present in both directions, so no resampling is needed.
    check(poppy.parsedTxFormats.contains { $0.isNativeToAudioEngine },
          "ESP can send a format AudioEngine renders natively")
    check(poppy.parsedRxFormats.contains { $0.isNativeToAudioEngine },
          "ESP accepts a format AudioEngine produces natively")

    // The HA browser softphone is a valid SIP target but not an intercom panel.
    check(!devices.contains { $0.name == "Patton Mannor" },
          "the HA browser softphone is not listed as a panel")
    // Both markers should independently suffice, since only one may be present.
    let byLocalHA = """
    {"version":2,"contacts":[{"name":"HA","address":"192.168.7.148","enabled":true,
     "metadata":{"local_ha":true,"sip_port":5060,"sip_transport":"tcp"}}]}
    """
    checkEqual(client.parseVoipRosterForTesting(["roster_json": byLocalHA]).count, 0,
               "local_ha alone filters the softphone")
    let byKind = """
    {"version":2,"contacts":[{"name":"HA","address":"192.168.7.148","enabled":true,
     "metadata":{"endpoint_kind":"browser","sip_port":5060,"sip_transport":"tcp"}}]}
    """
    checkEqual(client.parseVoipRosterForTesting(["roster_json": byKind]).count, 0,
               "endpoint_kind=browser alone filters the softphone")
    // An ESPHome endpoint must not be caught by that filter.
    let esphomeKind = """
    {"version":2,"contacts":[{"name":"Panel","address":"192.168.7.173","enabled":true,
     "metadata":{"endpoint_kind":"esphome","local_ha":false,"sip_port":5060,
                 "sip_transport":"udp"}}]}
    """
    checkEqual(client.parseVoipRosterForTesting(["roster_json": esphomeKind]).count, 1,
               "an esphome endpoint is still listed")

    // Groups route through HA and cannot be dialled directly by this client.
    check(!devices.contains { $0.name == "CG Casa" }, "conference group is not a direct target")
    check(!devices.contains { $0.name == "RG Casa" }, "ring group is not a direct target")

    // The compact attribute from the same install must agree with the JSON.
    let livePhonebook = "Poppy Monitor|192.168.7.173|5060|40000|full_duplex|" +
        "16000:s16le:1:16;16000:s16le:1:10|" +
        "48000:s16le:1:10;32000:s16le:1:16;16000:s16le:1:10;16000:s16le:1:16;16000:s16le:1:32|sip_udp," +
        "Patton Mannor|192.168.7.148|5060|40000|full_duplex|" +
        "48000:s16le:2:20;48000:s16le:1:20;48000:s16le:1:10;32000:s16le:1:16;32000:s16le:1:10;16000:s16le:1:16;16000:s16le:1:10;16000:s16le:1:20|" +
        "48000:s16le:2:20;48000:s16le:1:20;48000:s16le:1:10;32000:s16le:1:16;32000:s16le:1:10;16000:s16le:1:16;16000:s16le:1:10;16000:s16le:1:20|sip_tcp"

    let compactDevices = client.parseVoipRosterForTesting(["phonebook": livePhonebook, "count": 2])
    checkEqual(compactDevices.first?.host, "192.168.7.173", "compact ESP address")
    checkEqual(compactDevices.first?.preferredFrameMs, 10, "compact path negotiates the same ptime")
    // Known limitation: the compact rows carry no local_ha / endpoint_kind, so
    // the softphone cannot be identified there. roster_json is preferred
    // precisely because it does carry that metadata; this fallback only runs
    // when roster_json is absent or unparseable.
    checkEqual(compactDevices.count, 2, "compact rows lack the metadata to filter the softphone")

    // A disabled roster row is not offered as a target.
    let disabled = """
    {"version":2,"contacts":[{"name":"Old","address":"192.168.7.99","enabled":false,
     "metadata":{"sip_port":5060,"sip_transport":"udp"}}]}
    """
    checkEqual(client.parseVoipRosterForTesting(["roster_json": disabled]).count, 0,
               "a disabled entry is skipped")
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

    // The old host-keyed merge could already have written a duplicate for a
    // panel that moved; collapse it rather than leaving a dead entry behind.
    store.add(IntercomDevice(name: "Poppy Monitor", host: "192.168.2.171", protocolKind: .legacy))
    checkEqual(store.devices.filter { $0.name == "Poppy Monitor" }.count, 2,
               "precondition: a duplicate exists")
    store.upsertDiscovered(IntercomDevice(name: "Poppy Monitor", host: "192.168.2.181",
                                          protocolKind: .voip))
    checkEqual(store.devices.filter { $0.name.lowercased() == "poppy monitor" }.count, 1,
               "duplicate entries left by the old merge are collapsed")
    checkEqual(store.devices.count, 2, "collapsing does not disturb other devices")
    check(store.devices.contains { $0.name == "Gate" }, "unrelated devices survive de-duplication")

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
