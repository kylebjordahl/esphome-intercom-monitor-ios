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
    // The softphone is never listed; the panel and both groups are.
    checkEqual(devices.count, 3, "the ESP panel and both groups are listed")

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

    // Groups have no address of their own — they're dialled by name at HA's own
    // SIP listener (the softphone entry's address: 192.168.7.148:5060 tcp).
    guard let cgCasa = devices.first(where: { $0.name == "CG Casa" }) else {
        check(false, "conference group is discovered"); exit(1)
    }
    checkEqual(cgCasa.groupKind, .conference, "CG Casa is a conference group")
    checkEqual(cgCasa.host, "192.168.7.148", "conference group dials the HA softphone's address")
    checkEqual(cgCasa.sipPort, 5060, "conference group uses the HA softphone's SIP port")
    checkEqual(cgCasa.sipTransport, .tcp, "conference group uses the HA softphone's transport")
    checkEqual(cgCasa.groupMembers, ["Poppy Monitor"], "conference group members")

    guard let rgCasa = devices.first(where: { $0.name == "RG Casa" }) else {
        check(false, "ring group is discovered"); exit(1)
    }
    checkEqual(rgCasa.groupKind, .ring, "RG Casa is a ring group")
    checkEqual(rgCasa.host, "192.168.7.148", "ring group dials the HA softphone's address")
    checkEqual(rgCasa.sipPort, 5060, "ring group uses the HA softphone's SIP port")
    checkEqual(rgCasa.sipTransport, .tcp, "ring group uses the HA softphone's transport")
    checkEqual(rgCasa.groupMembers, ["Poppy Monitor"], "ring group members")

    // A group entry with no HA softphone entry anywhere in the roster has no
    // dialable target and is skipped, same as before this app understood groups.
    let groupWithoutBridge = """
    [{"name": "AllRooms", "ha_bridge": true,
      "metadata": {"group_type": "ring", "members": ["Salotto"]}}]
    """
    checkEqual(IntercomDevice.fromRosterJSON(groupWithoutBridge).count, 0,
               "a group with no HA softphone entry in the roster has no dial target")

    // Isolated two-pass resolution: a group entry paired with just an HA
    // softphone entry (no panels) still resolves.
    let groupWithBridge = """
    [{"name": "HA", "address": "10.0.0.9", "enabled": true,
      "metadata": {"local_ha": true, "sip_port": 5061, "sip_transport": "udp"}},
     {"name": "RG Test", "ha_bridge": true, "enabled": true,
      "metadata": {"group_type": "ring", "members": ["Salotto", "Gate"]}}]
    """
    let resolved = IntercomDevice.fromRosterJSON(groupWithBridge)
    checkEqual(resolved.count, 1, "only the group is listed; the softphone itself is excluded")
    checkEqual(resolved.first?.name, "RG Test", "resolved entry is the group")
    checkEqual(resolved.first?.host, "10.0.0.9", "group borrows the softphone's host")
    checkEqual(resolved.first?.sipPort, 5061, "group borrows the softphone's SIP port")
    checkEqual(resolved.first?.sipTransport, .udp, "group borrows the softphone's transport")
    checkEqual(resolved.first?.groupKind, .ring, "group_type ring parses to .ring")
    checkEqual(resolved.first?.groupMembers, ["Salotto", "Gate"], "group members carry through")

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

// MARK: - RTSP URL parsing

print("\nRTSPTarget")
do {
    let plain = RTSPTarget.parse("rtsp://192.168.1.20/audio")
    checkEqual(plain?.host, "192.168.1.20", "host")
    checkEqual(plain?.port, 554, "default RTSP port")
    checkEqual(plain?.isSecure, false, "rtsp:// is not TLS")
    checkEqual(plain?.uri, "rtsp://192.168.1.20/audio", "request URI round-trips")

    checkEqual(RTSPTarget.parse("rtsps://cam.local/ch0")?.port, 322,
               "default RTSPS port")
    checkEqual(RTSPTarget.parse("rtsps://cam.local/ch0")?.isSecure, true,
               "rtsps:// is TLS")

    // A URL with no path still needs a request URI a server will accept.
    checkEqual(RTSPTarget.parse("rtsp://cam.local")?.uri, "rtsp://cam.local/",
               "empty path becomes /")

    // Credentials must come out of the URI — it is what digest hashes, and what
    // gets persisted in the (plain-text) device roster.
    let authed = RTSPTarget.parse("rtsp://admin:sec%40ret@cam.local:8554/ch0?x=1")
    checkEqual(authed?.username, "admin", "username from userinfo")
    checkEqual(authed?.password, "sec@ret", "percent-decoded password")
    checkEqual(authed?.port, 8554, "explicit port")
    checkEqual(authed?.uri, "rtsp://cam.local:8554/ch0?x=1",
               "credentials stripped, query preserved")

    // Cameras ship passwords containing '@' more often than anyone would like.
    let atSign = RTSPTarget.parse("rtsp://admin:p@ss@cam.local/audio")
    checkEqual(atSign?.host, "cam.local", "splits on the LAST @")
    checkEqual(atSign?.password, "p@ss", "password may contain @")

    check(RTSPTarget.parse("http://cam.local/audio") == nil, "rejects a non-RTSP scheme")
    check(RTSPTarget.parse("   ") == nil, "rejects blank input")
    check(RTSPTarget.parse("rtsp://cam.local:notaport/x") == nil, "rejects a bad port")
    // No scheme at all is accepted as rtsp:// so a pasted "ip/path" works.
    checkEqual(RTSPTarget.parse("192.168.1.20/audio")?.uri, "rtsp://192.168.1.20/audio",
               "bare host/path defaults to rtsp://")
}

// MARK: - go2rtc URL adaptation

print("\nGo2RTCStream")
do {
    // The URL people actually have is the WebRTC one — the go2rtc player is
    // WebRTC, so that's what the web UI and Frigate hand out.
    let webrtc = Go2RTCStream.detect("http://192.168.1.10:1984/api/webrtc?src=nursery")
    checkEqual(webrtc?.host, "192.168.1.10", "host from the API URL")
    checkEqual(webrtc?.streamName, "nursery", "stream name from src=")
    checkEqual(webrtc?.rtspURL(), "rtsp://192.168.1.10:8554/nursery",
               "rewritten to the RTSP restream on go2rtc's default port")

    // Every go2rtc endpoint addresses a stream the same way, so all of them work.
    for path in ["/api/whep?src=nursery", "/api/ws?src=nursery",
                 "/stream.html?src=nursery&mode=webrtc",
                 "/api/stream.mp4?src=nursery"] {
        checkEqual(Go2RTCStream.detect("http://go2rtc.local:1984\(path)")?.streamName,
                   "nursery", "recognises \(path)")
    }

    // An RTSP URL already works — rewriting one would be second-guessing the user.
    check(Go2RTCStream.detect("rtsp://192.168.1.10:8554/nursery") == nil,
          "an rtsp:// URL is left alone")
    check(Go2RTCStream.detect("http://192.168.1.10:1984/") == nil,
          "a URL with no src= is not a go2rtc stream")
    check(Go2RTCStream.detect("http://example.com/page?srcset=x") == nil,
          "src= must be the whole parameter name")

    // A non-default RTSP port (go2rtc's rtsp module can be moved).
    checkEqual(webrtc?.rtspURL(port: 18554), "rtsp://192.168.1.10:18554/nursery",
               "honours a moved RTSP port")

    // go2rtc applies the same auth to its RTSP server, so credentials carry over
    // — and are split back into the Keychain by the RTSP parser on save.
    let authed = Go2RTCStream.detect("https://user:p%40ss@go2rtc.local/api/webrtc?src=back%20door")
    checkEqual(authed?.username, "user", "username from the URL")
    checkEqual(authed?.password, "p@ss", "percent-decoded password")
    checkEqual(authed?.streamName, "back door", "percent-decoded stream name")
    let derived = authed?.rtspURL() ?? ""
    check(derived.hasPrefix("rtsp://user:p%40ss@go2rtc.local:8554/"), "credentials re-encoded")
    check(derived.hasSuffix("/back%20door"), "stream name re-encoded for the path")
    checkEqual(RTSPTarget.parse(derived)?.password, "p@ss",
               "the derived URL round-trips through the RTSP parser")
    checkEqual(RTSPTarget.parse(derived)?.uri, "rtsp://go2rtc.local:8554/back%20door",
               "and the saved URI carries no credentials")

    // A stream name containing a path separator must not escape its path segment.
    checkEqual(Go2RTCStream(host: "h", streamName: "a/b", username: nil, password: nil)
        .rtspURL(), "rtsp://h:8554/a%2Fb", "escapes a slash in the stream name")
}

// MARK: - RTSP messages

print("\nRTSPMessage")
do {
    let sdp = "v=0\r\nm=audio 0 RTP/AVP 97\r\n"
    let raw = "RTSP/1.0 200 OK\r\n" +
              "CSeq: 3\r\n" +
              "Content-Base: rtsp://cam.local/audio/\r\n" +
              "Content-Type: application/sdp\r\n" +
              "Content-Length: \(sdp.utf8.count)\r\n" +
              "\r\n" + sdp
    var buffer = Data(raw.utf8)
    // A media frame that arrived in the same read must survive the parse.
    buffer.append(Data([0x24, 0x00, 0x00, 0x02, 0xAA, 0xBB]))

    let parsed = RTSPResponse.parse(buffer)
    check(parsed != nil, "parses a complete response")
    checkEqual(parsed?.response.statusCode, 200, "status code")
    checkEqual(parsed?.response.reasonPhrase, "OK", "reason phrase")
    checkEqual(parsed?.response.cseq, 3, "CSeq")
    checkEqual(parsed?.response.contentBase, "rtsp://cam.local/audio/", "Content-Base")
    checkEqual(parsed?.response.body, Data(sdp.utf8), "body honours Content-Length")
    checkEqual(parsed?.consumed, raw.utf8.count,
               "consumes exactly the message, leaving the interleaved frame")

    // Short reads are the normal case on a socket: report incomplete, not broken.
    check(RTSPResponse.parse(Data("RTSP/1.0 200 OK\r\nCSeq: 3\r\n".utf8)) == nil,
          "incomplete headers parse as nil")
    let truncated = "RTSP/1.0 200 OK\r\nContent-Length: 10\r\n\r\nshort"
    check(RTSPResponse.parse(Data(truncated.utf8)) == nil,
          "a body still arriving parses as nil")
    check(RTSPResponse.parse(Data("$\u{0}\u{0}\u{2}ab".utf8)) == nil,
          "a media frame is not mistaken for a response")

    let setup = "RTSP/1.0 200 OK\r\nCSeq: 4\r\n" +
                "Session: 4ee1a2f;timeout=45\r\n" +
                "Transport: RTP/AVP/TCP;unicast;interleaved=2-3\r\n\r\n"
    let setupResponse = RTSPResponse.parse(Data(setup.utf8))?.response
    checkEqual(setupResponse?.sessionID, "4ee1a2f", "session id without the timeout")
    checkEqual(setupResponse?.sessionTimeout, 45, "session timeout")
    checkEqual(setupResponse?.interleavedRTPChannel, 2,
               "honours the server's channel numbering, not ours")

    // Request encoding: CSeq, Session and Authorization all have to be present.
    let request = RTSPRequest(method: "PLAY", uri: "rtsp://cam.local/audio",
                              cseq: 5, session: "4ee1a2f",
                              authorization: "Digest x", extraHeaders: [
                                (name: "Range", value: "npt=0.000-")
                              ])
    let encoded = String(data: request.encode(userAgent: "IntercomListener"), encoding: .utf8) ?? ""
    check(encoded.hasPrefix("PLAY rtsp://cam.local/audio RTSP/1.0\r\n"), "request line")
    check(encoded.contains("CSeq: 5\r\n"), "encodes CSeq")
    check(encoded.contains("Session: 4ee1a2f\r\n"), "encodes Session")
    check(encoded.contains("Authorization: Digest x\r\n"), "encodes Authorization")
    check(encoded.contains("Range: npt=0.000-\r\n"), "encodes extra headers")
    check(encoded.hasSuffix("\r\n\r\n"), "terminates the header block")
}

// MARK: - RTSP authentication

print("\nRTSPAuthChallenge")
do {
    // Both schemes on one 401 — digest has to win, which is why the response
    // keeps its header fields as a list rather than a dictionary.
    let headers = ["Basic realm=\"cam\"",
                   "Digest realm=\"testrealm@host.com\", qop=\"auth,auth-int\", " +
                   "nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", " +
                   "opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""]
    let challenge = RTSPAuthChallenge.best(from: headers)
    checkEqual(challenge?.scheme, .digest, "prefers digest over basic")
    checkEqual(challenge?.realm, "testrealm@host.com", "realm")
    checkEqual(challenge?.qop, ["auth", "auth-int"], "qop list survives the quoted comma")
    checkEqual(challenge?.isSupported, true, "MD5 digest is supported")

    // RFC 2617 §3.5 test vector — proves the whole HA1/HA2/qop chain.
    let credentials = StreamCredentials(username: "Mufasa", password: "Circle Of Life")
    let header = challenge?.authorization(method: "GET",
                                         uri: "/dir/index.html",
                                         credentials: credentials,
                                         cnonce: "0a4f113b",
                                         nonceCount: 1) ?? ""
    check(header.contains("response=\"6629fae49393a05397450978507c4ef1\""),
          "digest response matches the RFC 2617 vector")
    check(header.contains("nc=00000001"), "nonce count is 8 hex digits")
    check(header.contains("qop=auth"), "qop echoed back")
    check(header.contains("opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""), "opaque echoed back")

    // Legacy (RFC 2069) servers send no qop; the answer must not invent one.
    let legacy = RTSPAuthChallenge.parse("Digest realm=\"cam\", nonce=\"abc\"")
    let legacyHeader = legacy?.authorization(method: "DESCRIBE", uri: "rtsp://cam/x",
                                             credentials: credentials,
                                             cnonce: "0a4f113b", nonceCount: 1) ?? ""
    check(!legacyHeader.contains("qop"), "no qop when the server offered none")
    check(!legacyHeader.contains("nc="), "no nonce count without qop")

    let basic = RTSPAuthChallenge.parse("Basic realm=\"cam\"")?
        .authorization(method: "DESCRIBE", uri: "rtsp://cam/x",
                       credentials: StreamCredentials(username: "u", password: "p"),
                       cnonce: "x", nonceCount: 1)
    checkEqual(basic, "Basic " + Data("u:p".utf8).base64EncodedString(), "basic header")

    // A challenge we can't answer must be reported, not answered wrongly — a
    // wrong answer is indistinguishable from a wrong password.
    checkEqual(RTSPAuthChallenge.parse("Digest realm=\"c\", nonce=\"n\", algorithm=SHA-256")?
        .isSupported, false, "SHA-256 digest is refused")
    check(RTSPAuthChallenge.parse("Digest realm=\"c\"") == nil, "digest without a nonce is unusable")
    check(RTSPAuthChallenge.parse("Negotiate abc") == nil, "unknown scheme")
}

// MARK: - RTSP SDP / audio track selection

print("\nRTSPSDP")
do {
    let cameraSDP = """
    v=0\r
    o=- 0 0 IN IP4 192.168.1.20\r
    s=Media Presentation\r
    a=control:*\r
    m=video 0 RTP/AVP 96\r
    a=control:trackID=0\r
    a=rtpmap:96 H264/90000\r
    m=audio 0 RTP/AVP 97\r
    a=control:trackID=1\r
    a=rtpmap:97 mpeg4-generic/16000/1\r
    a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;\
    indexlength=3;indexdeltalength=3;config=1408\r
    """
    let aac = RTSPSDP.audioTrack(from: cameraSDP)
    checkEqual(aac?.payloadType, 97, "picks the audio m-section, not the video one")
    checkEqual(aac?.encoding, .aacLC, "recognises mpeg4-generic AAC-LC")
    checkEqual(aac?.sampleRate, 16_000, "AAC sample rate")
    checkEqual(aac?.sourceChannels, 1, "AAC channel count")
    checkEqual(aac?.control, "trackID=1", "audio track control")
    checkEqual(aac?.auSizeLength, 13, "AU size length from fmtp")

    // G.711 needs no rtpmap at all — payload type 0 is defined by RFC 3551.
    let g711 = RTSPSDP.audioTrack(from: "m=audio 0 RTP/AVP 0\r\na=control:trackID=1\r\n")
    checkEqual(g711?.encoding, .pcmu, "static payload type 0 is µ-law")
    checkEqual(g711?.sampleRate, 8_000, "µ-law is 8 kHz")

    let l16 = RTSPSDP.audioTrack(from: "m=audio 0 RTP/AVP 10\r\n")
    checkEqual(l16?.encoding, .l16, "static payload type 10 is L16")
    checkEqual(l16?.sourceChannels, 2, "payload type 10 is stereo")

    // Several audio formats offered: pick one we can actually play.
    let mixed = "m=audio 0 RTP/AVP 96 8\r\n" +
                "a=rtpmap:96 MP4A-LATM/44100/2\r\n" +
                "a=rtpmap:8 PCMA/8000\r\n"
    checkEqual(RTSPSDP.audioTrack(from: mixed)?.encoding, .pcma,
               "skips LATM in favour of a playable format")

    // Nothing playable: still report the track so the UI can name the codec.
    let latmOnly = RTSPSDP.audioTrack(from: "m=audio 0 RTP/AVP 96\r\n" +
                                            "a=rtpmap:96 MP4A-LATM/44100/2\r\n")
    checkEqual(latmOnly?.encoding, .unsupported("MP4A-LATM"), "names an unplayable codec")
    checkEqual(latmOnly?.encoding.isSupported, false, "unplayable codec is not supported")

    check(RTSPSDP.audioTrack(from: "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n") == nil,
          "a video-only stream has no audio track")

    // HE-AAC decodes through a path we don't have, so it must be refused up front.
    let heAAC = "m=audio 0 RTP/AVP 97\r\na=rtpmap:97 mpeg4-generic/32000/2\r\n" +
                "a=fmtp:97 mode=AAC-hbr;config=2B0A08\r\n"
    checkEqual(RTSPSDP.audioTrack(from: heAAC)?.encoding.isSupported, false,
               "HE-AAC is refused rather than played as noise")

    // Control URL resolution (RFC 2326 §C.1.1).
    checkEqual(RTSPSDP.resolveControl("trackID=1",
                                      requestURI: "rtsp://cam/audio",
                                      contentBase: "rtsp://cam/audio/"),
               "rtsp://cam/audio/trackID=1", "relative control against Content-Base")
    checkEqual(RTSPSDP.resolveControl("trackID=1",
                                      requestURI: "rtsp://cam/audio",
                                      contentBase: nil),
               "rtsp://cam/audio/trackID=1", "relative control against the request URI")
    checkEqual(RTSPSDP.resolveControl("rtsp://cam/other",
                                      requestURI: "rtsp://cam/audio",
                                      contentBase: nil),
               "rtsp://cam/other", "absolute control wins")
    checkEqual(RTSPSDP.resolveControl("*",
                                      requestURI: "rtsp://cam/audio",
                                      contentBase: nil),
               "rtsp://cam/audio", "aggregate control")
}

// MARK: - AAC decoder configuration

print("\nAACConfig")
do {
    // "1408" is the canonical AAC-LC / 16 kHz / mono AudioSpecificConfig.
    let mono = AACConfig.parse(hex: "1408")
    checkEqual(mono?.objectType, 2, "AAC-LC object type")
    checkEqual(mono?.sampleRate, 16_000, "sample rate from the frequency index")
    checkEqual(mono?.channels, 1, "channel configuration")
    checkEqual(mono?.framesPerPacket, 1_024, "AAC-LC frame length")
    checkEqual(mono?.isLowComplexity, true, "AAC-LC is decodable")

    let stereo = AACConfig.parse(hex: "1210")
    checkEqual(stereo?.sampleRate, 44_100, "44.1 kHz frequency index")
    checkEqual(stereo?.channels, 2, "stereo channel configuration")

    check(AACConfig.parse(hex: "14") == nil, "rejects a truncated config")
    check(AACConfig.parse(hex: "zz") == nil, "rejects non-hex")
    check(AACConfig.parse(hex: "140") == nil, "rejects an odd-length config")
}

// MARK: - RTSP payload unpacking

print("\nRTSPAudioPayload")
do {
    // G.711 encodes zero as 0xFF (µ-law) and 0xD5 (A-law).
    let ulawSilence = RTSPAudioPayload.decodeULaw(Data([0xFF, 0xFF]))
    checkEqual(ulawSilence.count, 4, "µ-law expands 1 byte to 1 sample")
    checkEqual([UInt8](ulawSilence), [0, 0, 0, 0], "µ-law 0xFF is silence")

    // Full-scale negative: the loudest µ-law codepoint.
    let ulawLoud = RTSPAudioPayload.decodeULaw(Data([0x00]))
    let loudSample = Int16(bitPattern: UInt16([UInt8](ulawLoud)[0]) |
                                      UInt16([UInt8](ulawLoud)[1]) << 8)
    checkEqual(loudSample, -32_124, "µ-law 0x00 is full-scale negative")

    let alawSilence = RTSPAudioPayload.decodeALaw(Data([0xD5]))
    let alawSample = Int16(bitPattern: UInt16([UInt8](alawSilence)[0]) |
                                       UInt16([UInt8](alawSilence)[1]) << 8)
    check(abs(Int(alawSample)) <= 8, "A-law 0xD5 is (near) silence")
    checkEqual(RTSPAudioPayload.decodeALaw(Data(count: 160)).count, 320,
               "A-law expands 1 byte to 1 sample")

    // Stereo downmix: 16-bit average, in place of a converter channel map.
    // Frame 1 = (1000, 3000) → 2000; frame 2 = (-1000, -3000) → -2000.
    var stereo = Data()
    for sample in [Int16(1_000), 3_000, -1_000, -3_000] {
        let bits = UInt16(bitPattern: sample)
        stereo.append(UInt8(bits & 0xFF)); stereo.append(UInt8(bits >> 8))
    }
    let mono = RTSPAudioPayload.downmixToMono(stereo, channels: 2)
    checkEqual(mono.count, 4, "two stereo frames become two mono samples")
    let monoBytes = [UInt8](mono)
    checkEqual(Int16(bitPattern: UInt16(monoBytes[0]) | UInt16(monoBytes[1]) << 8),
               2_000, "averages the two channels")
    checkEqual(Int16(bitPattern: UInt16(monoBytes[2]) | UInt16(monoBytes[3]) << 8),
               -2_000, "averages negative samples")
    checkEqual(RTSPAudioPayload.downmixToMono(stereo, channels: 1), stereo,
               "mono passes through untouched")

    // RFC 3640 AU headers: one 20-byte access unit (13-bit size + 3-bit index).
    let single = Data([0x00, 0x10, 0x00, 0xA0]) + Data(repeating: 0x5A, count: 20)
    let units = RTSPAudioPayload.accessUnits(from: single, sizeLength: 13,
                                             indexLength: 3, indexDeltaLength: 3)
    checkEqual(units.count, 1, "one access unit")
    checkEqual(units.first?.count, 20, "access-unit size from the AU header")

    // Two AUs in one packet: a multi-AU payload mis-split as one decodes to noise.
    let multi = Data([0x00, 0x20, 0x00, 0x50, 0x00, 0x60])
        + Data(repeating: 0x01, count: 10) + Data(repeating: 0x02, count: 12)
    let multiUnits = RTSPAudioPayload.accessUnits(from: multi, sizeLength: 13,
                                                  indexLength: 3, indexDeltaLength: 3)
    checkEqual(multiUnits.count, 2, "splits a two-AU payload")
    checkEqual(multiUnits.first?.count, 10, "first AU size")
    checkEqual(multiUnits.last?.count, 12, "second AU size")
    checkEqual(multiUnits.last?.first, 0x02, "second AU starts after the first")

    // sizelength=0 means the payload is a single AU with no header block at all.
    let bare = Data(repeating: 0x7F, count: 8)
    checkEqual(RTSPAudioPayload.accessUnits(from: bare, sizeLength: 0,
                                            indexLength: 0, indexDeltaLength: 0),
               [bare], "no AU headers means one access unit")
}

// MARK: - RTP over RTSP

print("\nRTSPStreamSession RTP")
do {
    func rtpPacket(payloadType: UInt8, marker: Bool = false,
                   csrcCount: UInt8 = 0, padding: [UInt8] = [],
                   payload: [UInt8]) -> Data {
        var packet = Data([0x80 | (padding.isEmpty ? 0 : 0x20) | csrcCount,
                           marker ? payloadType | 0x80 : payloadType,
                           0x12, 0x34,                      // sequence
                           0x00, 0x00, 0x10, 0x00,          // timestamp
                           0xDE, 0xAD, 0xBE, 0xEF])         // ssrc
        packet.append(Data(repeating: 0, count: Int(csrcCount) * 4))
        packet.append(Data(payload))
        packet.append(Data(padding))
        return packet
    }

    let parsed = RTSPStreamSession.parseRTPPacket(
        rtpPacket(payloadType: 97, marker: true, payload: [1, 2, 3, 4]))
    checkEqual(parsed?.payloadType, 97, "payload type")
    checkEqual(parsed?.marker, true, "marker bit")
    checkEqual(parsed?.sequence, 0x1234, "sequence number")
    checkEqual(parsed?.timestamp, 0x1000, "timestamp")
    checkEqual(parsed?.payload, Data([1, 2, 3, 4]), "payload")

    checkEqual(RTSPStreamSession.parseRTPPacket(
        rtpPacket(payloadType: 0, csrcCount: 2, payload: [9, 9]))?.payload,
        Data([9, 9]), "skips the CSRC list")

    // Padding is counted in the last byte and must not reach the speaker.
    checkEqual(RTSPStreamSession.parseRTPPacket(
        rtpPacket(payloadType: 8, padding: [0, 0, 3], payload: [7]))?.payload,
        Data([7]), "strips RTP padding")

    check(RTSPStreamSession.parseRTPPacket(Data([0x80, 0x61, 0x00])) == nil,
          "rejects a runt packet")
    var wrongVersion = rtpPacket(payloadType: 97, payload: [1])
    wrongVersion[0] = 0x40
    check(RTSPStreamSession.parseRTPPacket(wrongVersion) == nil, "rejects RTP version 1")
}

// MARK: - Stream entries in the roster

print("\nRTSP roster entries")
do {
    let stream = IntercomDevice(name: "Nursery Camera",
                               host: "192.168.1.20",
                               port: 554,
                               protocolKind: .rtsp,
                               streamURL: "rtsp://192.168.1.20/audio")
    check(stream.isAudioStream, "an rtsp device is an audio stream")
    check(stream.isListenOnly, "an audio stream is listen-only")

    // Round-trips through the persisted roster, URL included.
    let encoded = try JSONEncoder().encode([stream])
    let decoded = try JSONDecoder().decode([IntercomDevice].self, from: encoded)
    checkEqual(decoded.first?.streamURL, "rtsp://192.168.1.20/audio", "streamURL persists")
    checkEqual(decoded.first?.protocolKind, .rtsp, "protocol persists")

    // A roster written before streams existed must still decode (invariant #12).
    let old = """
    [{"id":"\(UUID().uuidString)","name":"Kitchen","host":"192.168.1.42","port":6054}]
    """
    let upgraded = try JSONDecoder().decode([IntercomDevice].self, from: Data(old.utf8))
    checkEqual(upgraded.first?.streamURL, nil, "a pre-stream roster decodes with no URL")
    check(upgraded.first?.isAudioStream == false, "and is not treated as a stream")

    // Discovery must never adopt a stream: a camera and the panel in the same
    // room plausibly share a name, and matching them would overwrite the URL.
    let panel = IntercomDevice(name: "Nursery Camera", host: "192.168.1.51",
                               protocolKind: .voip)
    check(!DeviceStore.isSameEndpoint(stream, panel),
          "a stream never name-matches a discovered panel")
    check(DeviceStore.isSameEndpoint(stream, stream), "a stream matches itself by id")

    var renamed = panel
    renamed.host = "192.168.1.99"
    check(DeviceStore.isSameEndpoint(panel, renamed),
          "two panels still match by name (unchanged behaviour)")
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILURE(S)")
    exit(1)
}
print("All protocol checks passed.")
