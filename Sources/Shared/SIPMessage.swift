import Foundation

// Minimal SIP/2.0 message codec for the `voip-pcm/1` ESP profile.
//
// Scope is deliberately narrow — exactly the subset the ESP firmware requires:
// INVITE / ACK / CANCEL / BYE / OPTIONS plus the responses listed in
// docs/voip_profile.md.  The profile states that ESP endpoints never send
// WWW-Authenticate and never implement REGISTER, so there is no digest-auth or
// registration machinery here; a 401/407 from a peer is surfaced as a hard
// failure instead (`auth_required_unsupported`).
//
// Header names are matched case-insensitively and the RFC 3261 compact forms
// are accepted, because ESP/HA peers are not guaranteed to use one spelling.

enum SIPMethod: String, Sendable {
    case invite  = "INVITE"
    case ack     = "ACK"
    case cancel  = "CANCEL"
    case bye     = "BYE"
    case options = "OPTIONS"
    case info    = "INFO"
    case update  = "UPDATE"
}

struct SIPMessage: Sendable {

    enum Kind: Sendable {
        case request(method: SIPMethod, uri: String)
        case response(code: Int, reason: String)
    }

    var kind: Kind
    /// Ordered header list — Via order is significant, so this is not a dictionary.
    var headers: [(name: String, value: String)]
    var body: Data

    // MARK: - Convenience accessors

    var method: SIPMethod? {
        if case .request(let m, _) = kind { return m }
        return nil
    }

    var statusCode: Int? {
        if case .response(let c, _) = kind { return c }
        return nil
    }

    var requestURI: String? {
        if case .request(_, let uri) = kind { return uri }
        return nil
    }

    /// First value for a header, accepting the RFC 3261 compact form.
    func first(_ name: String) -> String? {
        let wanted = Self.canonicalName(name)
        return headers.first { Self.canonicalName($0.name) == wanted }?.value
    }

    func all(_ name: String) -> [String] {
        let wanted = Self.canonicalName(name)
        return headers.filter { Self.canonicalName($0.name) == wanted }.map(\.value)
    }

    mutating func set(_ name: String, _ value: String) {
        let wanted = Self.canonicalName(name)
        if let idx = headers.firstIndex(where: { Self.canonicalName($0.name) == wanted }) {
            headers[idx] = (name, value)
            headers.removeAll { Self.canonicalName($0.name) == wanted && $0.value != value }
        } else {
            headers.append((name, value))
        }
    }

    mutating func append(_ name: String, _ value: String) {
        headers.append((name, value))
    }

    /// Map compact header forms onto their long names so lookups are uniform.
    static func canonicalName(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch lower {
        case "v": return "via"
        case "f": return "from"
        case "t": return "to"
        case "i": return "call-id"
        case "m": return "contact"
        case "c": return "content-type"
        case "l": return "content-length"
        case "s": return "subject"
        case "k": return "supported"
        default:  return lower
        }
    }

    // MARK: - Parsed header helpers

    var callID: String? { first("Call-ID")?.trimmingCharacters(in: .whitespaces) }

    /// CSeq split into its sequence number and method token.
    var cseq: (number: Int, method: String)? {
        guard let raw = first("CSeq") else { return nil }
        let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let n = Int(parts[0]) else { return nil }
        return (n, String(parts[1]).uppercased())
    }

    var fromTag: String? { Self.parameter("tag", in: first("From")) }
    var toTag:   String? { Self.parameter("tag", in: first("To")) }

    /// Extract a `;name=value` parameter from a header value.  Values may be
    /// quoted; angle-bracket URI portions are skipped so a `;` inside `<...>`
    /// is not mistaken for a header parameter.
    static func parameter(_ name: String, in header: String?) -> String? {
        guard let header else { return nil }
        var scan = Substring(header)
        // Drop the URI part so its own parameters (e.g. ;transport=udp) don't win.
        if let open = scan.firstIndex(of: "<"), let close = scan[open...].firstIndex(of: ">") {
            scan = scan[scan.index(after: close)...]
        }
        for component in scan.split(separator: ";").dropFirst(0) {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            guard pair[0].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased()
            else { continue }
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    /// The bare `sip:user@host:port` inside a From/To/Contact header.
    static func uri(in header: String?) -> String? {
        guard let header else { return nil }
        if let open = header.firstIndex(of: "<"), let close = header[open...].firstIndex(of: ">") {
            return String(header[header.index(after: open)..<close])
        }
        // Bare form: "sip:kitchen@host" with optional trailing params.
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("sip:") else { return nil }
        return String(trimmed.split(separator: ";").first ?? Substring(trimmed))
    }

    /// The display name preceding the URI, unquoted; nil when absent.
    static func displayName(in header: String?) -> String? {
        guard let header, let open = header.firstIndex(of: "<") else { return nil }
        var name = header[header.startIndex..<open].trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        return name.isEmpty ? nil : name
    }

    // MARK: - Serialisation

    func encode() -> Data {
        var head: String
        switch kind {
        case .request(let method, let uri):
            head = "\(method.rawValue) \(uri) SIP/2.0\r\n"
        case .response(let code, let reason):
            head = "SIP/2.0 \(code) \(reason)\r\n"
        }

        // Content-Length is authoritative for TCP framing — always emit the
        // real body size rather than trusting a caller-supplied header.
        for (name, value) in headers where canonicalNameIsNotContentLength(name) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n\r\n"

        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    private func canonicalNameIsNotContentLength(_ name: String) -> Bool {
        Self.canonicalName(name) != "content-length"
    }

    // MARK: - Parsing

    enum ParseError: Error { case malformed }

    /// Parse one complete message.  `data` must contain exactly one message
    /// (UDP datagram) or have been framed by `SIPMessage.frame(from:)` first.
    static func decode(_ data: Data) -> SIPMessage? {
        guard let split = headerBodySplit(in: data) else { return nil }
        guard let headText = String(data: data[data.startIndex..<split.headerEnd], encoding: .utf8)
        else { return nil }

        var lines = unfold(headText)
        guard !lines.isEmpty else { return nil }
        let startLine = lines.removeFirst()

        let kind: Kind
        if startLine.uppercased().hasPrefix("SIP/2.0") {
            let parts = startLine.split(separator: " ", maxSplits: 2,
                                        omittingEmptySubsequences: true)
            guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
            let reason = parts.count > 2 ? String(parts[2]) : ""
            kind = .response(code: code, reason: reason)
        } else {
            let parts = startLine.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let method = SIPMethod(rawValue: String(parts[0]).uppercased())
            else { return nil }
            kind = .request(method: method, uri: String(parts[1]))
        }

        var headers: [(name: String, value: String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name  = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers.append((name, value))
        }

        let body = Data(data[split.bodyStart...])
        return SIPMessage(kind: kind, headers: headers, body: body)
    }

    /// Locate the CRLF-CRLF (or LF-LF) header/body boundary.
    private static func headerBodySplit(in data: Data) -> (headerEnd: Data.Index, bodyStart: Data.Index)? {
        let bytes = [UInt8](data)
        var i = 0
        while i + 1 < bytes.count {
            if bytes[i] == 0x0D, i + 3 < bytes.count,
               bytes[i + 1] == 0x0A, bytes[i + 2] == 0x0D, bytes[i + 3] == 0x0A {
                return (data.index(data.startIndex, offsetBy: i),
                        data.index(data.startIndex, offsetBy: i + 4))
            }
            if bytes[i] == 0x0A, bytes[i + 1] == 0x0A {
                return (data.index(data.startIndex, offsetBy: i),
                        data.index(data.startIndex, offsetBy: i + 2))
            }
            i += 1
        }
        return nil
    }

    /// Split header text into logical lines, re-joining RFC 3261 line folds
    /// (a continuation line starts with SP or HTAB).
    private static func unfold(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n",
                                                                           omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty { continue }
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !out.isEmpty {
                out[out.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// Framing for SIP over TCP: returns one complete message and the leftover
    /// bytes, or nil while the buffer is still short of a full message.
    static func frame(from buffer: Data) -> (message: Data, remaining: Data)? {
        guard let split = headerBodySplit(in: buffer) else { return nil }
        guard let headText = String(data: buffer[buffer.startIndex..<split.headerEnd], encoding: .utf8)
        else { return nil }

        var contentLength = 0
        for line in unfold(headText).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon])
            guard canonicalName(name) == "content-length" else { continue }
            contentLength = Int(String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)) ?? 0
            break
        }

        let bodyAvailable = buffer.distance(from: split.bodyStart, to: buffer.endIndex)
        guard bodyAvailable >= contentLength else { return nil }

        let end = buffer.index(split.bodyStart, offsetBy: contentLength)
        return (Data(buffer[buffer.startIndex..<end]), Data(buffer[end...]))
    }

    // MARK: - Token generation

    /// RFC 3261 requires the branch to start with this cookie.
    static func newBranch() -> String { "z9hG4bK" + randomToken(16) }
    static func newTag()    -> String { randomToken(10) }
    static func newCallID(host: String) -> String { "\(randomToken(16))@\(host)" }

    static func randomToken(_ length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }
}
