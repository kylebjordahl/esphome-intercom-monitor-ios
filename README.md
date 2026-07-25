# Intercom Listener

A native **iOS** and **watchOS** client for [ESPHome intercom panels](https://github.com/n-IA-hane/esphome-intercom). It turns your iPhone (or Apple Watch) into a callable peer on a home intercom system — call one or several panels at once, listen continuously in the background (screen off, other audio still playing), and talk back with push-to-talk.

The original motivation was a **nursery monitor**: open a listen-only audio stream to the panel in the baby's room while an audiobook keeps playing, with a Lock Screen / Dynamic Island Live Activity and a hold-to-talk button to soothe from another room.

> **Status:** the iOS app is the primary, battle-tested target — multi-panel calls, background audio, push-to-talk, and Live Activities all work on real hardware. The watchOS app runs as an independent peer (its own connections + audio) using the same hardened audio engine; it's functional but less exercised (see [Known limitations](#known-limitations)).

---

## Features

- **Call multiple panels simultaneously** — select several devices and open a call to all of them at once; add more mid-call.
- **Background listening** — audio keeps streaming with the screen off and mixes with other playing audio (music, podcasts, audiobooks) rather than interrupting it.
- **Push-to-talk** — every call starts listen-only (mic closed). Hold the talk button to transmit; release to go back to listening. Privacy by default.
- **Incoming calls** — the app runs a TCP listener and advertises itself over mDNS, so panels can call *it*. Incoming calls surface as a full-screen answer/decline sheet.
- **Live Activity** — an active call shows on the Lock Screen and Dynamic Island with a live timer; a single call gets a tap-to-talk button right in the activity.
- **Home Assistant auto-discovery** — pulls the panel list from an HA phonebook/endpoint sensor over REST + WebSocket, and re-discovers periodically without disturbing live calls.
- **Per-call controls** — speaker mute, per-call volume, and individual hang-up.

---

## Requirements

- **Xcode 16+** and an iOS **17.0+** device (Live Activities and the interactive talk button require iOS 17).
- **[XcodeGen](https://github.com/yonigtek/xcodegen)** — the Xcode project is generated from [`project.yml`](project.yml), not checked in. Install with `brew install xcodegen`.
- One or more **ESPHome intercom panels** running the [esphome-intercom](https://github.com/n-IA-hane/esphome-intercom) firmware on the same LAN/Wi-Fi.
- *(Optional)* **Home Assistant** with the intercom integration, for automatic device discovery. Without it, you can add panels manually by IP.

---

## Quick start

```sh
# 1. Generate the Xcode project from project.yml
xcodegen generate

# 2. Open it
open IntercomListener.xcodeproj

# 3. In Xcode: select the "IntercomListener" scheme, choose your device,
#    set your signing team on both the app and the "IntercomWidgets" targets,
#    then Run (⌘R).
```

Command-line build (no signing, for CI / verification):

```sh
# iOS app (also builds the embedded widget + watch app).  Use -destination only
# — forcing -sdk iphoneos would mis-build the watchOS dependency against the iOS SDK.
xcodebuild -scheme IntercomListener \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO

# watchOS app on its own
xcodebuild -scheme IntercomListenerWatch -sdk watchsimulator build CODE_SIGNING_ALLOWED=NO
```

> **Important:** always run the **`IntercomListener`** scheme, not `IntercomWidgets`. The widget extension is a Live-Activity-only extension with no home-screen widget; running its scheme directly fails with *"Failed to get descriptors for extensionBundleID."* The app scheme builds and embeds the widget automatically.

---

## Home Assistant setup (optional)

1. In Home Assistant, create a **Long-Lived Access Token**: Profile → Security → *Create Token*.
2. In the app's **Settings** tab, enter your HA base URL (e.g. `http://homeassistant.local:8123`) and paste the token. Credentials are stored in the **Keychain**.
3. Tap **Discover Devices**.

The client looks for panels in two ways (in order):

1. `sensor.intercom_phonebook` — a `phonebook` attribute that is a comma-separated list of `name|tcp|ip|port` entries.
2. Fallback: any `sensor.*_intercom_endpoint` whose state is a single `name|tcp|ip|port` entry.

It then keeps the list live via the HA WebSocket API and re-polls every 60 s. Discovery only ever *adds* devices — it never removes one or touches a live call.

**No Home Assistant?** Add panels manually in the Devices tab (＋ button) with a name, IP, and port (default `6054`).

---

## How it works

### Component overview

```
                    ┌──────────────────────────────────────────────┐
                    │                  ContentView                  │
                    │     DevicesView · SettingsView · banners      │
                    └───────────────┬──────────────────────────────┘
                                    │ @EnvironmentObject
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
┌───────▼────────┐        ┌─────────▼─────────┐       ┌─────────▼──────────┐
│  DeviceStore   │        │  IntercomSession  │       │ HomeAssistantClient│
│ (roster, prefs)│        │  (coordinator)    │       │ (REST + WebSocket) │
└────────────────┘        └───┬─────────┬─────┘       └────────────────────┘
                              │         │
              ┌───────────────┘         └───────────────┐
     ┌────────▼─────────┐                      ┌─────────▼──────────┐
     │   AudioEngine    │                      │  IntercomServer    │
     │ (AVAudioEngine,  │                      │ (NWListener, mDNS, │
     │  mic↔speaker)    │                      │  incoming calls)   │
     └──────────────────┘                      └────────────────────┘
                              │
                    ┌─────────▼──────────┐         ┌────────────────────────┐
                    │ IntercomConnection │ ──────► │ CallActivityController  │
                    │ (one per call,     │         │ → Live Activity widget  │
                    │  NWConnection TCP) │         └────────────────────────┘
                    └────────────────────┘
```

- **`IntercomSession`** is the brain. It owns the list of live `IntercomConnection`s, drives the shared `AudioEngine`, runs the `IntercomServer` for inbound calls, and reconciles the Live Activity.
- **`IntercomConnection`** wraps one TCP socket — either outbound (we called a panel) or inbound (a panel called us) — and implements the call state machine and the wire protocol.
- **`AudioEngine`** is a single `AVAudioEngine` shared across all calls: one input tap (mic → all active calls) and one `AVAudioPlayerNode` per call (panel → speaker), mixed to the output.

### Audio path

```
mic → input tap (HW rate, format: nil) → AVAudioConverter → 16 kHz int16
    → re-frame into exactly 1024-byte chunks → AUDIO frame → each talking call

each call's RX AUDIO frame → AVAudioConverter → 16 kHz float32
    → that call's AVAudioPlayerNode → mainMixer → speaker
```

### Call flow

```
Outbound:  connect → START ─────────────►
                     ◄──── RING (optional)
                     ◄──── ANSWER            → active, audio flows
           hang up → HANGUP ───────────────►

Inbound:   ◄──── START      (panel calls us)
           RING ───────────►               → ring UI
           user answers → ANSWER ─────────► → active
```

---

## Protocol reference

Raw TCP on **port 6054**. Every message is a 3-byte header followed by a payload:

```
┌────────┬──────────────┬─────────────────┐
│ type   │ length        │ payload          │
│ u8     │ u16 (LE)      │ <length> bytes   │
└────────┴──────────────┴─────────────────┘
```

| Type    | Hex    | Payload                                                        |
|---------|--------|---------------------------------------------------------------|
| AUDIO   | `0x01` | Raw 16 kHz mono signed-16-bit-LE PCM, **1024 bytes** per frame |
| START   | `0x02` | `callId`, `callerRoute`, `callerName`, `destRoute`, `destName` |
| HANGUP  | `0x03` | `callId`                                                       |
| PING    | `0x04` | `0x00`                                                         |
| PONG    | `0x05` | `0x00`                                                         |
| ERROR   | `0x06` | `callId` + error code + detail                                 |
| RING    | `0x07` | `callId`                                                       |
| ANSWER  | `0x08` | `callId`                                                       |
| DECLINE | `0x09` | `callId` + reason                                              |

Strings are length-prefixed: `[len: u8][utf8 bytes]`.

**Two behaviours that aren't obvious from the table but are essential:**

1. **The caller must stream audio continuously after `ANSWER`.** This ESP firmware gracefully closes the socket a second or two after answering if it receives *no* `AUDIO` frames. Because push-to-talk starts silent, each connection runs a keepalive timer that streams zero-filled (silent) `AUDIO` frames ~10×/second whenever the call is active and the user isn't talking. The timer starts the instant the call goes active — before the audio engine has even finished starting — so the panel never sees a silent gap. (See `IntercomConnection.startAudioKeepalive`.)
2. **`AUDIO` frames must be exactly 1024 bytes.** Larger or irregular frames overflow the panel's receive buffer and it resets the connection. The mic capture is re-framed into precise 1024-byte chunks before sending. (See `AudioEngine.convertAndForward`.)
3. **A socket drop without `HANGUP`/`DECLINE` is treated as unexpected, not a real call end.** Wi-Fi blips, NAT timeouts, and ESP reboots can close the TCP connection without either side sending a teardown message. For connections we dialed out (client-side), that's recovered automatically: the connection moves to `.reconnecting` and retries with exponential backoff (up to 5 attempts), redialing once the socket is back. A deliberate hangup/decline — sent or received — skips this and tears the connection down immediately. Server-side connections (a panel called us) can't be redialed by the phone, so an unexpected drop there just ends the call; the panel has to call back. (See `IntercomConnection.handleUnexpectedDrop`.)

---

## Project layout

```
project.yml                         XcodeGen spec — source of truth for the Xcode project
Sources/
  Shared/                           Compiled into both iOS and watchOS
    AudioEngine.swift               The hardened AVAudioEngine — mic↔speaker, 16 kHz PCM
    IntercomProtocol.swift          Wire encode/decode + message factories
    IntercomConnection.swift        One TCP call: state machine, keepalive, PTT gating
    IntercomDevice.swift            Device model + DeviceStore (UserDefaults persistence)
    HomeAssistantClient.swift       REST + WebSocket discovery, Keychain helpers
    NetworkInfo.swift               Local Wi-Fi IPv4 lookup (for endpoint registration)
  iOS/
    App.swift                       @main; launch wiring + periodic rediscovery
    ContentView.swift               Tabs, active-call banner, incoming-call sheet
    DevicesView.swift               Main screen: active calls + device roster
    SettingsView.swift              Caller name + Home Assistant credentials
    ConnectionRow.swift             Per-call controls incl. push-to-talk button
    ActiveCallView.swift            Diagnostics (engine status, packet counters)
    IntercomSession.swift           Coordinator: connections, audio, server, Live Activity
    IntercomServer.swift            NWListener + Bonjour for inbound calls
    CallActivityController.swift    Starts/updates/ends the Live Activity
    Info.plist · *.entitlements
  LiveActivity/                     Shared by the app AND the widget extension (no watchOS)
    CallActivityAttributes.swift    ActivityKit attributes / content state
    ToggleTalkIntent.swift          LiveActivityIntent for the in-activity talk button
  Widgets/                          The widget extension target
    IntercomWidgetBundle.swift      @main WidgetBundle
    CallLiveActivity.swift          Lock Screen + Dynamic Island UI
    Info.plist
  watchOS/                          Independent watch app (own connections + audio)
    WatchApp.swift                  @main; HA discovery + iPhone device-list sync
    WatchContentView.swift          Device list, active call, Digital Crown volume
    WatchIntercomSession.swift      Watch coordinator + WKExtendedRuntimeSession
```

The watch app reuses `Sources/Shared` (including the same `AudioEngine`), so it gets
all of the engine hardening for free — the only platform difference is the audio
session category (no `.defaultToSpeaker` on watchOS).

---

## Configuration notes

- **Background audio** relies on `UIBackgroundModes: [audio, voip]` and an `AVAudioSession` in `.playAndRecord` with `.mixWithOthers` + `.defaultToSpeaker`. iOS keeps the app alive while that session is active.
- **Three signed targets.** The app embeds the `IntercomWidgets` extension and the `IntercomListenerWatch` app, so all three need a development team. `project.yml` intentionally leaves `DEVELOPMENT_TEAM` blank (don't bake a team ID into a shared repo). After `xcodegen generate`, set your team under **Signing & Capabilities** for `IntercomListener`, `IntercomWidgets`, and `IntercomListenerWatch`. Note this is wiped each time you regenerate — if the churn bothers you, set `DEVELOPMENT_TEAM` locally in `project.yml` and just don't commit that line.
- **Live Activities** must be allowed under Settings → Intercom → Live Activities (on by default).

---

## Known limitations

- **watchOS is less exercised than iOS.** It runs as an independent peer using the shared `AudioEngine`, so it has the same audio hardening, but it's seen far less real-world testing. Notably, the watch coordinator does not yet prune a connection when a single call drops mid-session (the happy path — call, listen, talk, End All — works); and background longevity is bounded by `WKExtendedRuntimeSession`, which the OS may end under battery/CPU pressure, dropping the call.
- **Other-audio volume.** When a call starts, mixed-in audio (e.g. an audiobook) can change level. This is iOS's output gain for record-capable (`.playAndRecord`) sessions and isn't directly settable by the app; the level returns to normal when the call ends.
- **Background recovery isn't guaranteed.** The audio engine auto-recovers from interruptions and unexpected stops via a watchdog while the app is alive. But if audio stops while the app is backgrounded, iOS may suspend the app (no audio = no background-audio entitlement to stay alive), freezing recovery until you foreground it. This is an inherent iOS background-audio constraint.
- **No CallKit / APNs.** Incoming calls only arrive while the app is running (foreground or background-audio alive); there's no push-driven wake-up. Live Activity updates are local-only (no push).
- **TCP only.** UDP transport from the firmware is not implemented.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| *"Failed to get descriptors for extensionBundleID"* on launch | You're running the **IntercomWidgets** scheme. Switch to **IntercomListener**. |
| Call connects then drops after ~1–2 s | The panel needs continuous audio after answering — ensure the silence keepalive is intact (`IntercomConnection.startAudioKeepalive`). |
| Panel resets the connection when you talk | Outgoing `AUDIO` frames must be exactly 1024 bytes (`AudioEngine` re-framing). |
| `-10868` / "formats don't match" crash | The mic tap must be installed with `format: nil` so it tracks hardware sample-rate changes. |
| Stream dies and won't recover ("engine stopped") | The engine self-heals via a watchdog + start-retry + session re-activation (`AudioEngine`). If it stopped while backgrounded, iOS may have suspended the app — foregrounding it triggers recovery. |
| Live Activity stuck on the Lock Screen | Left over from a crash/force-quit. It's ended automatically on next launch (`CallActivityController.endOrphaned`) and marked stale after a few minutes so iOS can retire it. |
| No devices discovered | Check the HA URL/token, and that `sensor.intercom_phonebook` (or `*_intercom_endpoint`) exists in HA. Or add devices manually. |

---

## Contributing

The Xcode project is generated, so:

1. Edit sources under `Sources/` and the build config in `project.yml`.
2. Run `xcodegen generate` after adding/removing files or changing targets.
3. Build with the `IntercomListener` scheme.

When touching audio or the wire protocol, read the header comments in `AudioEngine.swift` and `IntercomConnection.swift` first — several non-obvious behaviours there were hard-won against real hardware.

---

## Acknowledgements

Built against the [esphome-intercom](https://github.com/n-IA-hane/esphome-intercom) firmware and its PBX-lite protocol.

## License

[MIT](LICENSE) — see the `LICENSE` file. Update the copyright holder to your name before publishing.
