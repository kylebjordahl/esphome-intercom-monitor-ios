# Agent / LLM guide

Orientation for AI coding agents working in this repo. Humans: see [README.md](README.md).

## What this is

Native iOS + watchOS client for ESPHome intercom panels. iOS is the primary,
battle-tested target; watchOS runs as an independent peer sharing the same
`AudioEngine` (less exercised).

**Two wire protocols are supported**, because the upstream ESPHome project
(`n-IA-hane/esphome-intercom`, "VoIP Stack") *retired* its proprietary protocol
in v2026.7.0 rather than re-encoding it:

| Firmware | Protocol | Signaling | Media |
|---|---|---|---|
| ≤ v2026.6.x | PBX-lite (proprietary) | framed messages, TCP 6054 | raw S16 **little-endian** inline on the same socket |
| ≥ v2026.7.0 | `voip-pcm/1` | SIP/SDP, UDP or TCP 5060 | RTP/UDP, L16 = S16 **big-endian**, framed to negotiated `a=ptime` |

Both are 16-bit linear PCM, so the conversion between them is a byte swap plus
re-framing — there is no lossy transcode anywhere in this app.

## Build & run

The Xcode project is **generated** from `project.yml` and is gitignored. Always:

```sh
xcodegen generate                       # after ANY change to files/targets in project.yml

# iOS (also builds the embedded widget + watch). Use -destination only — forcing
# -sdk iphoneos mis-builds the watchOS dependency against the iOS SDK.
xcodebuild -scheme IntercomListener -destination 'generic/platform=iOS' \
  build CODE_SIGNING_ALLOWED=NO

# watchOS on its own
xcodebuild -scheme IntercomListenerWatch -sdk watchsimulator \
  build CODE_SIGNING_ALLOWED=NO
```

Wire-protocol checks (no device or simulator needed — compiles the real
`Sources/Shared` files into a host binary and asserts against them):

```sh
sh Tests/run-protocol-tests.sh
```

Run these after touching anything under the SIP/SDP/RTP or device-parsing code;
they cover format tokens, SIP framing, SDP negotiation, roster parsing, the L16
byte swap, and `IntercomDevice` upgrade-decoding.

- **Run the `IntercomListener` scheme, never `IntercomWidgets`** (the latter is a
  Live-Activity-only extension and can't be launched standalone).
- Schemes are declared explicitly in `project.yml` (`schemes:`). If you add a new
  runnable target, add a scheme for it there too, or XcodeGen's auto-generation
  produces only a widget scheme.
- Adding a new source file requires `xcodegen generate` before it's picked up.

## Architecture in one paragraph

`IntercomSession` (iOS coordinator) owns N `IntercomConnection`s (one call each),
one shared `AudioEngine`, an `IntercomServer` (inbound legacy calls), a
`SIPEndpoint` (inbound SIP calls), and a `CallActivityController` (Live
Activity). `HomeAssistantClient` discovers devices into `DeviceStore`.
`Sources/Shared` compiles into both platforms; `Sources/LiveActivity` compiles
into the app **and** the widget (but not watchOS, which has no ActivityKit).

`IntercomConnection` is a **facade over both protocols**. It keeps one public API
(`connect/call/answer/decline/hangup/sendAudio` + `state`), switching internally
between the inline legacy transport and a `SIPCall`. This is why adding VoIP
support required no changes to the views, the watch app, or the Live Activity
intents — keep it that way rather than leaking a protocol enum into the UI.

VoIP layer, all in `Sources/Shared`:

- `VoipAudioFormat` — the `rate:pcm:channels:frame_ms` token contract.
- `SIPMessage` — SIP parse/serialise (compact headers, CRLF folding, TCP framing).
- `SDPSession` — offer/answer + format negotiation.
- `SIPCall` — one dialog (INVITE/ACK/CANCEL/BYE/OPTIONS).
- `SIPEndpoint` — listeners on 5060 + Call-ID → dialog routing (`.shared`).
- `RTPAudioSession` — RTP framing, pacing, and the L16 byte swap.

## Non-obvious invariants — do not regress these

1. **Mic tap uses `format: nil`** (`AudioEngine.startCapture`). Pinning a sample
   rate crashes with `-10868` when the HW rate changes mid-call.
2. **Legacy outgoing AUDIO frames are exactly 1024 bytes** (`AudioEngine.convertAndForward`
   re-framing). Oversized frames make the panel RST the socket.
3. **Silence keepalive** (`IntercomConnection.startAudioKeepalive`): the panel
   hangs up ~1–2 s after ANSWER without audio, so we stream zero-filled frames
   while not talking. It must start on the `.active` transition (a `didSet` on
   `state`), independent of the audio engine.
4. **`AudioEngine.scheduleRestart` runs on `@MainActor`** — racing the
   `AVAudioEngineConfigurationChange` observer causes "player started when in a
   disconnected state".
5. **Audio teardown guards the configure race** (`IntercomSession`): a call can
   drop while audio is asynchronously configuring; `teardownAudioIfIdle()` and
   the post-await `guard conn.state == .active` prevent an orphaned engine.
6. **Push-to-talk:** `IntercomConnection.isTalking` gates real mic audio;
   silence is the timer's job. Don't reintroduce a persistent mic-mute flag.
7. **Engine self-recovery** (`AudioEngine`): `shouldBeRunning` + 4 s watchdog +
   start-retry-with-backoff + session re-activation in `startCapture`. Don't make
   `engine.start()` failure a dead end, and keep `scheduleRestart` guarded on
   `shouldBeRunning` so it can't resurrect a stopped engine after `stop()`.
8. **VoIP silence pacing mirrors #3.** RTP must be continuous or the peer drops
   the call, so `RTPAudioSession`'s send timer emits silence frames when the mic
   isn't supplying audio. The legacy 10 Hz keepalive is skipped in VoIP mode
   (`IntercomConnection.state`'s `didSet` guards on `mode == .legacy`) — don't
   run both.
9. **L16 is big-endian.** Every RTP payload is byte-swapped on the way in and
   out (`RTPAudioSession.byteSwapped16`). Skipping it yields loud static, not
   silence. `AudioEngine` stays host-order throughout and is deliberately
   untouched by the VoIP work.
10. **Only 16 kHz mono is negotiated.** `SDPSession.negotiate` refuses anything
    else (including PCMU/PCMA/Opus) with `488 Not Acceptable Here`, because
    `AudioEngine`'s wire format is 16 kHz mono and resampling would be a
    quality regression. Widen `isNativeToAudioEngine` only alongside a real
    resampling stage.
11. **`SIPEndpoint` must be started before an outbound SIP call.** Via, Contact
    and the SDP `c=` line all need a reachable LAN address, and the peer sends
    BYE to our Contact, not back down the dialling socket.
    `IntercomConnection.connectVoIP()` calls `ensureStarted` and fails the call
    rather than advertising `0.0.0.0`.
12. **`IntercomDevice` has a hand-written `init(from:)`.** Synthesised `Codable`
    throws on missing keys even when a property has a default, which would wipe
    every saved device on upgrade. Add new fields with `decodeIfPresent` and a
    default; devices saved before VoIP support decode as `.legacy`.
13. **Live Activity cleanup:** `CallActivityController.endOrphaned()` runs at
   launch (in `IntercomSession.init`) and activities carry a `staleDate` — both
   prevent an activity getting stuck after a crash/force-quit. `.error`
   connections are cleaned up like `.disconnected` in `handleStateChange`.

## Conventions

- Logging is via `print("Component: …")`. Keep that prefix style.
- Notification observers on non-NSObject classes must be closure-based
  (`addObserver(forName:object:queue:using:)`), never selector-based — selectors
  crash on real devices here.
- Keep `Sources/Shared` free of `ActivityKit`/`UIKit`-only APIs (watchOS compiles it).
