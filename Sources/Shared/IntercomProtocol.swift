import Foundation

// Wire protocol for ESPHome intercom_api component.
// Frame: [type: u8][length: u16 LE][payload: N bytes]
// All strings: [len: u8][utf8 bytes], max 64 bytes unless noted.

enum MessageType: UInt8, Sendable {
    case audio   = 0x01
    case start   = 0x02
    case hangup  = 0x03
    case ping    = 0x04
    case pong    = 0x05
    case error   = 0x06
    case ring    = 0x07
    case answer  = 0x08
    case decline = 0x09
}

struct IntercomMessage: Sendable {
    let type: MessageType
    let payload: Data

    static let headerSize = 3

    func encode() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(type.rawValue)
        var length = UInt16(payload.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    // Returns successfully parsed messages and any unconsumed trailing bytes.
    static func decode(from buffer: Data) -> (messages: [IntercomMessage], remaining: Data) {
        var messages: [IntercomMessage] = []
        var offset = 0

        while offset + headerSize <= buffer.count {
            let typeByte = buffer[buffer.startIndex + offset]
            let lo = UInt16(buffer[buffer.startIndex + offset + 1])
            let hi = UInt16(buffer[buffer.startIndex + offset + 2])
            let length = Int(lo | (hi << 8))

            guard offset + headerSize + length <= buffer.count else { break }

            guard let messageType = MessageType(rawValue: typeByte) else {
                offset += headerSize + length
                continue
            }

            let payloadStart = buffer.startIndex + offset + headerSize
            let payloadEnd   = payloadStart + length
            messages.append(IntercomMessage(type: messageType,
                                            payload: Data(buffer[payloadStart..<payloadEnd])))
            offset += headerSize + length
        }

        return (messages, Data(buffer[(buffer.startIndex + offset)...]))
    }
}

// MARK: - String codec

private func encodeLPString(_ s: String, maxLen: Int = 64) -> Data {
    let bytes = Array(s.utf8.prefix(maxLen))
    var data = Data(capacity: 1 + bytes.count)
    data.append(UInt8(bytes.count))
    data.append(contentsOf: bytes)
    return data
}

func decodeLPString(from data: Data, offset: inout Int) -> String? {
    guard offset < data.count else { return nil }
    let len = Int(data[data.startIndex + offset])
    offset += 1
    guard offset + len <= data.count else { return nil }
    let slice = data[(data.startIndex + offset)..<(data.startIndex + offset + len)]
    let str = String(bytes: slice, encoding: .utf8)
    offset += len
    return str
}

// MARK: - Message factories

extension IntercomMessage {
    static func ping() -> IntercomMessage {
        IntercomMessage(type: .ping, payload: Data([0x00]))
    }

    static func pong() -> IntercomMessage {
        IntercomMessage(type: .pong, payload: Data([0x00]))
    }

    static func start(callId: String,
                      callerRoute: String, callerName: String,
                      destRoute: String,   destName: String) -> IntercomMessage {
        var p = Data()
        p.append(encodeLPString(callId))
        p.append(encodeLPString(callerRoute))
        p.append(encodeLPString(callerName))
        p.append(encodeLPString(destRoute))
        p.append(encodeLPString(destName))
        return IntercomMessage(type: .start, payload: p)
    }

    static func hangup(callId: String) -> IntercomMessage {
        IntercomMessage(type: .hangup, payload: encodeLPString(callId))
    }

    static func answer(callId: String) -> IntercomMessage {
        IntercomMessage(type: .answer, payload: encodeLPString(callId))
    }

    static func decline(callId: String, reason: String = "") -> IntercomMessage {
        var p = encodeLPString(callId)
        p.append(encodeLPString(reason, maxLen: 160))
        return IntercomMessage(type: .decline, payload: p)
    }

    static func ring(callId: String) -> IntercomMessage {
        IntercomMessage(type: .ring, payload: encodeLPString(callId))
    }

    static func audio(_ pcmData: Data) -> IntercomMessage {
        IntercomMessage(type: .audio, payload: pcmData)
    }
}

// MARK: - Payload decoders

struct StartPayload: Sendable {
    let callId: String
    let callerRoute: String
    let callerName: String
    let destRoute: String
    let destName: String

    init?(data: Data) {
        var offset = 0
        guard
            let cid = decodeLPString(from: data, offset: &offset),
            let cr  = decodeLPString(from: data, offset: &offset),
            let cn  = decodeLPString(from: data, offset: &offset),
            let dr  = decodeLPString(from: data, offset: &offset),
            let dn  = decodeLPString(from: data, offset: &offset)
        else { return nil }
        callId = cid; callerRoute = cr; callerName = cn; destRoute = dr; destName = dn
    }
}

struct SimplePayload: Sendable {
    let callId: String

    init?(data: Data) {
        var offset = 0
        guard let cid = decodeLPString(from: data, offset: &offset) else { return nil }
        callId = cid
    }
}
