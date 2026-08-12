import Foundation
import CryptoKit

// RTSP 1.0 signaling (RFC 2326) — the text protocol used to negotiate an audio
// stream from a camera / restreamer before any media flows.
//
// Deliberately kept free of Network / AVFoundation so the whole message layer is
// testable on its own (see Tests/ProtocolTests).  It is a client-side subset:
// only the methods this app sends (DESCRIBE / SETUP / PLAY / TEARDOWN / OPTIONS),
// plus the Basic and Digest authentication that every real camera demands.
//
// RTSP looks like HTTP but is not HTTP: responses share the socket with binary
// interleaved media frames (see RTSPStreamSession), so the parser here always
// reports how many bytes it consumed and never assumes it owns the buffer.

// MARK: - Requests

struct RTSPRequest {
    var method: String
    /// Absolute request URI, credential-free.  Digest hashes this verbatim, so
    /// it must be byte-identical to what goes on the wire.
    var uri: String
    var cseq: Int
    var session: String?
    var authorization: String?
    var extraHeaders: [(name: String, value: String)] = []

    func encode(userAgent: String) -> Data {
        var text = "\(method) \(uri) RTSP/1.0\r\n"
        text += "CSeq: \(cseq)\r\n"
        text += "User-Agent: \(userAgent)\r\n"
        if let session, !session.isEmpty { text += "Session: \(session)\r\n" }
        if let authorization, !authorization.isEmpty {
            text += "Authorization: \(authorization)\r\n"
        }
        for header in extraHeaders { text += "\(header.name): \(header.value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }
}

// MARK: - Responses

struct RTSPResponse: Equatable {
    var statusCode: Int
    var reasonPhrase: String
    /// Header fields in wire order.  A list rather than a dictionary because a
    /// 401 legitimately carries two `WWW-Authenticate` headers (Digest *and*
    /// Basic) and collapsing them would lose the stronger one.
    var fields: [(name: String, value: String)]
    var body: Data

    var isSuccess: Bool { (200...299).contains(statusCode) }
    var statusLine: String { "\(statusCode) \(reasonPhrase)" }

    static func == (lhs: RTSPResponse, rhs: RTSPResponse) -> Bool {
        lhs.statusCode == rhs.statusCode
            && lhs.reasonPhrase == rhs.reasonPhrase
            && lhs.body == rhs.body
            && lhs.fields.map { [$0.name, $0.value] } == rhs.fields.map { [$0.name, $0.value] }
    }

    func value(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func values(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    var cseq: Int? { value("CSeq").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    /// `Session: 4ee1a2f;timeout=60` → ("4ee1a2f", 60)
    var sessionID: String? {
        guard let raw = value("Session") else { return nil }
        let id = raw.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return id?.nilIfEmpty
    }

    var sessionTimeout: Int? {
        guard let raw = value("Session") else { return nil }
        for parameter in raw.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "timeout"
            else { continue }
            return Int(pair[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Channel the server picked for RTP in `Transport: …;interleaved=0-1`.
    /// Servers are free to renumber, so the answer wins over what we asked for.
    var interleavedRTPChannel: UInt8? {
        guard let transport = value("Transport") else { return nil }
        return Self.interleavedRTPChannel(inTransport: transport)
    }

    static func interleavedRTPChannel(inTransport transport: String) -> UInt8? {
        for parameter in transport.split(separator: ";") {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "interleaved"
            else { continue }
            let channels = pair[1].split(separator: "-")
            guard let first = channels.first,
                  let value = UInt8(first.trimmingCharacters(in: .whitespaces))
            else { return nil }
            return value
        }
        return nil
    }

    /// Base URL for resolving a relative `a=control` from the SDP.
    var contentBase: String? {
        (value("Content-Base") ?? value("Content-Location"))?
            .trimmingCharacters(in: .whitespaces)
            .nilIfEmpty
    }

    /// Parse one response from the head of `buffer`.
    ///
    /// Returns nil while the message is still incomplete (short read), so the
    /// caller can simply wait for more bytes, and reports the exact byte count
    /// consumed because interleaved media frames may follow in the same buffer.
    static func parse(_ buffer: Data) -> (response: RTSPResponse, consumed: Int)? {
        // Header block ends at the first blank line.  Tolerate a bare-LF server
        // (they exist) as well as the mandated CRLF.
        let headerEnd: Range<Data.Index>
        if let crlf = buffer.range(of: Data("\r\n\r\n".utf8)) {
            headerEnd = crlf
        } else if let lf = buffer.range(of: Data("\n\n".utf8)) {
            headerEnd = lf
        } else {
            return nil
        }

        let headerBytes = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: Data(headerBytes), encoding: .utf8) else { return nil }

        // Split on either line ending; drop the empty tail a trailing CR leaves.
        let lines = headerText
            .components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let statusLine = lines.first else { return nil }

        // "RTSP/1.0 200 OK" — the version token is not optional, and rejecting a
        // line that doesn't start with it is what catches a desynchronised stream
        // instead of silently mis-framing the rest of the socket.
        let statusParts = statusLine.split(separator: " ", maxSplits: 2,
                                           omittingEmptySubsequences: false)
        guard statusParts.count >= 2,
              statusParts[0].uppercased().hasPrefix("RTSP/"),
              let statusCode = Int(statusParts[1])
        else { return nil }
        let reason = statusParts.count >= 3
            ? String(statusParts[2]).trimmingCharacters(in: .whitespaces)
            : ""

        var fields: [(name: String, value: String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            // Continuation line (RFC 2326 allows folding): append to the previous.
            if line.first == " " || line.first == "\t", !fields.isEmpty {
                fields[fields.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name  = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            fields.append((name: name, value: value))
        }

        let headerLength = buffer.distance(from: buffer.startIndex, to: headerEnd.upperBound)
        let contentLength = fields.first {
            $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame
        }.flatMap { Int($0.value) } ?? 0
        guard contentLength >= 0 else { return nil }
        guard buffer.count >= headerLength + contentLength else { return nil }   // body still arriving

        let bodyStart = buffer.index(buffer.startIndex, offsetBy: headerLength)
        let bodyEnd   = buffer.index(bodyStart, offsetBy: contentLength)
        let response  = RTSPResponse(statusCode: statusCode,
                                     reasonPhrase: reason,
                                     fields: fields,
                                     body: Data(buffer[bodyStart..<bodyEnd]))
        return (response, headerLength + contentLength)
    }
}

// MARK: - Authentication

/// A `WWW-Authenticate` challenge, and the `Authorization` header that answers it.
///
/// Cameras overwhelmingly use Digest/MD5 (some fall back to Basic); anything else
/// — SHA-256, MD5-sess — is reported as unsupported rather than answered wrongly,
/// because a wrong answer just loops on 401 with no explanation.
struct RTSPAuthChallenge: Equatable {
    enum Scheme: String, Equatable { case basic, digest }

    var scheme: Scheme
    var realm: String
    var nonce: String
    var opaque: String?
    var qop: [String]
    var algorithm: String?

    /// Pick the strongest challenge we can answer out of every `WWW-Authenticate`
    /// header on a 401.
    static func best(from headers: [String]) -> RTSPAuthChallenge? {
        let parsed = headers.compactMap(parse)
        return parsed.first { $0.scheme == .digest } ?? parsed.first { $0.scheme == .basic }
    }

    static func parse(_ header: String) -> RTSPAuthChallenge? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else {
            // A bare "Basic" with no realm is legal and answerable.
            return trimmed.lowercased() == "basic"
                ? RTSPAuthChallenge(scheme: .basic, realm: "", nonce: "", opaque: nil,
                                    qop: [], algorithm: nil)
                : nil
        }
        guard let scheme = Scheme(rawValue: String(trimmed[..<space]).lowercased())
        else { return nil }

        let parameters = Self.parameters(in: String(trimmed[trimmed.index(after: space)...]))
        let realm = parameters["realm"] ?? ""
        let nonce = parameters["nonce"] ?? ""
        // Digest without a nonce is unanswerable.
        guard scheme == .basic || !nonce.isEmpty else { return nil }

        let qop = (parameters["qop"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        return RTSPAuthChallenge(scheme: scheme,
                                 realm: realm,
                                 nonce: nonce,
                                 opaque: parameters["opaque"]?.nilIfEmpty,
                                 qop: qop,
                                 algorithm: parameters["algorithm"]?.nilIfEmpty)
    }

    /// Split `realm="x", nonce="y", stale=FALSE` into a keyed map.  Commas inside
    /// quoted values must not split a parameter — nonces contain them routinely.
    static func parameters(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = "", value = ""
        var readingKey = true
        var inQuotes = false

        func commit() {
            let name = key.trimmingCharacters(in: .whitespaces).lowercased()
            if !name.isEmpty { result[name] = value.trimmingCharacters(in: .whitespaces) }
            key = ""; value = ""; readingKey = true
        }

        for character in text {
            switch character {
            case "\"":
                inQuotes.toggle()
            case "=" where readingKey && !inQuotes:
                readingKey = false
            case "," where !inQuotes:
                commit()
            default:
                if readingKey { key.append(character) } else { value.append(character) }
            }
        }
        commit()
        return result
    }

    /// Whether this app can answer the challenge at all.  Checked before dialing
    /// so an unsupported scheme surfaces as a readable error instead of a 401 loop.
    var isSupported: Bool {
        guard scheme == .digest else { return true }
        guard let algorithm else { return true }
        return algorithm.uppercased() == "MD5"
    }

    /// Build the `Authorization` header value for one request.
    func authorization(method: String,
                       uri: String,
                       credentials: StreamCredentials,
                       cnonce: String,
                       nonceCount: Int) -> String? {
        switch scheme {
        case .basic:
            let raw = "\(credentials.username):\(credentials.password)"
            return "Basic " + Data(raw.utf8).base64EncodedString()

        case .digest:
            guard isSupported else { return nil }
            let ha1 = Self.md5("\(credentials.username):\(realm):\(credentials.password)")
            let ha2 = Self.md5("\(method):\(uri)")

            var parts = [
                "username=\"\(credentials.username)\"",
                "realm=\"\(realm)\"",
                "nonce=\"\(nonce)\"",
                "uri=\"\(uri)\"",
            ]
            let digest: String
            if qop.contains("auth") {
                let nc = String(format: "%08x", nonceCount)
                digest = Self.md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
                parts += ["qop=auth", "nc=\(nc)", "cnonce=\"\(cnonce)\""]
            } else {
                digest = Self.md5("\(ha1):\(nonce):\(ha2)")
            }
            parts.append("response=\"\(digest)\"")
            if let opaque { parts.append("opaque=\"\(opaque)\"") }
            return "Digest " + parts.joined(separator: ", ")
        }
    }

    static func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
