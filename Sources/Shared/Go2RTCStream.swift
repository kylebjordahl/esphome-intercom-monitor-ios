import Foundation

// go2rtc adaptation: turn a WebRTC (or any other go2rtc) URL into a stream this
// app can actually monitor.
//
// WHY THIS EXISTS
//
// go2rtc's browser player uses WebRTC, so the URL a user has to hand — copied
// from the go2rtc web UI, from Frigate, or from a dashboard card — is usually an
// `http://host:1984/…?src=camera` WebRTC endpoint.  Playing that natively would
// mean implementing ICE, DTLS-SRTP and Opus: a whole media stack (in practice,
// Google's ~50 MB libwebrtc binary) for a listen-only monitor.
//
// It isn't necessary.  go2rtc restreams *every* source it holds over plain RTSP
// on port 8554 — the same audio, minus the handshake — and this app already
// speaks RTSP.  So a go2rtc URL is recognised by its `src=` parameter and
// rewritten to `rtsp://host:8554/<stream>` at the point the user adds it.  What
// gets saved is an ordinary stream URL; nothing downstream knows about go2rtc.
//
// The one thing this cannot fix is a source whose audio only exists as Opus (a
// `webrtc:`/WHEP source, typically) — go2rtc passes Opus straight through to
// RTSP and does not transcode it natively.  That needs a transcoding stream in
// go2rtc itself (`ffmpeg:<stream>#audio=aac`); the README says so, and the app
// names the codec on the row rather than failing mutely.
struct Go2RTCStream: Equatable {
    /// Host of the go2rtc API, which is also where its RTSP server listens.
    var host: String
    /// The `src=` stream name.
    var streamName: String
    var username: String?
    var password: String?

    /// go2rtc's default RTSP port (its API default is 1984, which is not it).
    static let defaultRTSPPort: UInt16 = 8554

    /// Recognise a go2rtc URL.
    ///
    /// Every go2rtc endpoint addresses a stream the same way — `?src=NAME` — so
    /// that, on an http(s) URL, is the signal: `/api/webrtc`, `/api/whep`,
    /// `/api/ws`, `/api/stream.mp4`, `/stream.html`, Frigate's proxied variants,
    /// all of them.  An `rtsp://` URL is deliberately NOT matched: it already
    /// works as-is and must not be second-guessed.
    static func detect(_ raw: String) -> Go2RTCStream? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return nil }

        guard let components = URLComponents(string: text) else { return nil }
        // URLComponents keeps the brackets on a literal IPv6 host in some OS
        // versions and drops them in others; normalise to the bare address.
        let host = (components.host ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }

        guard let source = components.queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("src") == .orderedSame })?
            .value?
            .trimmingCharacters(in: .whitespaces),
              !source.isEmpty
        else { return nil }

        return Go2RTCStream(host: host,
                            streamName: source,
                            username: components.user?.nilIfEmpty,
                            password: components.password?.nilIfEmpty)
    }

    /// The RTSP restream URL for this stream.
    ///
    /// Credentials from the original URL are carried over — go2rtc applies the
    /// same authentication to its RTSP server — and are split back out into the
    /// Keychain when the device is saved, exactly like a hand-pasted RTSP URL.
    func rtspURL(port: UInt16 = defaultRTSPPort) -> String {
        var authority = ""
        if let username, !username.isEmpty {
            authority = Self.escape(username, allowed: .urlUserAllowed)
            if let password, !password.isEmpty {
                authority += ":" + Self.escape(password, allowed: .urlPasswordAllowed)
            }
            authority += "@"
        }
        let hostPart = host.contains(":") ? "[\(host)]" : host   // literal IPv6
        let path = Self.escape(streamName, allowed: .urlPathAllowed)
        return "rtsp://\(authority)\(hostPart):\(port)/\(path)"
    }

    private static func escape(_ value: String, allowed: CharacterSet) -> String {
        // A go2rtc stream name may contain anything the user put in go2rtc.yaml;
        // '/' would otherwise change the request path, and ':'/'@' would corrupt
        // the authority.
        var set = allowed
        set.remove(charactersIn: "/:@?#")
        return value.addingPercentEncoding(withAllowedCharacters: set) ?? value
    }
}
