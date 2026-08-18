import SwiftUI

// The main screen.  Shows live calls (with full controls) in an "Active Calls"
// section at the top, and the device roster below.  Multi-select (via Edit mode)
// lets the user call several panels at once; new selections can be added to an
// already-active call.
struct DevicesView: View {
    @EnvironmentObject private var deviceStore: DeviceStore
    @EnvironmentObject private var haClient:    HomeAssistantClient
    @EnvironmentObject private var session:     IntercomSession
    @AppStorage("callerName") private var callerName = "iPhone"

    @State private var selectedIds: Set<UUID> = []
    @State private var showAddSheet       = false
    @State private var showAddStreamSheet = false
    @State private var editingDevice: IntercomDevice? = nil
    @State private var editMode       = EditMode.inactive

    var body: some View {
        NavigationStack {
            List(selection: $selectedIds) {
                // ── Live calls: full controls right on the main page ───────────
                if !session.connections.isEmpty {
                    Section("Active Calls") {
                        ForEach(session.connections) { conn in
                            ConnectionRow(conn: conn)
                                .selectionDisabled(true)
                        }
                    }
                }

                // ── Device roster ──────────────────────────────────────────────
                Section(session.connections.isEmpty ? "" : "Devices") {
                    if deviceStore.devices.isEmpty {
                        ContentUnavailableView(
                            "No Devices",
                            systemImage: "phone.badge.plus",
                            description: Text("Add a panel or an audio stream with ＋, " +
                                              "or configure Home Assistant in Settings.")
                        )
                    } else {
                        ForEach(deviceStore.devices) { device in
                            DeviceRow(device: device, isActive: activeConnectionState(for: device))
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deviceStore.remove(id: device.id)
                                        selectedIds.remove(device.id)
                                    } label: { Label("Delete", systemImage: "trash") }

                                    Button {
                                        editingDevice = device
                                    } label: { Label("Edit", systemImage: "pencil") }
                                        .tint(.blue)
                                }
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Intercom")
            .toolbar {
                // Leading: Edit (enables multi-select checkmarks) + Add
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    // Toggle between Edit/Done to enable multi-select.
                    Button(editMode == .active ? "Done" : "Select") {
                        withAnimation {
                            editMode = editMode == .active ? .inactive : .active
                            if editMode == .inactive { selectedIds.removeAll() }
                        }
                    }
                    if editMode == .inactive {
                        // Two kinds of endpoint, added two different ways: a panel
                        // by host/port, a stream by URL (nothing discovers one).
                        Menu {
                            Button {
                                showAddSheet = true
                            } label: {
                                Label("Intercom Panel", systemImage: "phone.badge.plus")
                            }
                            Button {
                                showAddStreamSheet = true
                            } label: {
                                Label("Audio Stream by URL", systemImage: "link.badge.plus")
                            }
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                    }
                }

                // Trailing: Call button — visible whenever items are selected.
                // No disabled guard on isCallActive; startCall already skips
                // devices that already have a live connection, so pressing it
                // while a call is active simply adds the newly selected devices.
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !selectedIds.isEmpty {
                        Button {
                            callSelected()
                            // Leave edit mode after initiating the call.
                            withAnimation { editMode = .inactive }
                        } label: {
                            Label(callButtonLabel, systemImage: callButtonIcon)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                DeviceEditSheet(device: nil) { newDevice in
                    deviceStore.add(newDevice)
                }
            }
            .sheet(isPresented: $showAddStreamSheet) {
                StreamEditSheet(device: nil) { newDevice, credentials in
                    StreamCredentialStore.save(credentials, for: newDevice.id)
                    deviceStore.add(newDevice)
                }
            }
            .sheet(item: $editingDevice) { device in
                // A stream is edited by URL, a panel by host/port — same entry
                // point, different form.
                if device.isAudioStream {
                    StreamEditSheet(device: device) { updated, credentials in
                        StreamCredentialStore.save(credentials, for: updated.id)
                        deviceStore.update(updated)
                    }
                } else {
                    DeviceEditSheet(device: device) { updated in
                        deviceStore.update(updated)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var callButtonLabel: String {
        let n = selectedIds.count
        if session.isCallActive {
            return n == 1 ? "Add to Call" : "Add \(n) to Call"
        }
        // Nothing is being "called" when every selection is a one-way stream.
        if selectedDevices.allSatisfy(\.isAudioStream), !selectedDevices.isEmpty {
            return n == 1 ? "Listen" : "Listen to \(n)"
        }
        return n == 1 ? "Call" : "Call \(n)"
    }

    private var callButtonIcon: String {
        selectedDevices.allSatisfy(\.isAudioStream) && !selectedDevices.isEmpty
            ? "ear.fill" : "phone.fill"
    }

    private var selectedDevices: [IntercomDevice] {
        deviceStore.devices.filter { selectedIds.contains($0.id) }
    }

    private func activeConnectionState(for device: IntercomDevice) -> ConnectionState? {
        session.connections.first { $0.device.id == device.id }?.state
    }

    private func callSelected() {
        session.startCall(to: selectedDevices, callerName: callerName)
        selectedIds.removeAll()
    }
}

// MARK: - Device row

private struct DeviceRow: View {
    let device: IntercomDevice
    let isActive: ConnectionState?

    var body: some View {
        HStack {
            if device.isAudioStream {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            } else if let groupKind = device.groupKind {
                Image(systemName: groupKind == .ring ? "person.2.wave.2" : "person.3")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let state = isActive {
                stateIndicator(state)
            }
        }
        .padding(.vertical, 4)
    }

    // A group's `host`/`port` are Home Assistant's own SIP listener, not
    // meaningful to the user — show what the group actually is instead.
    private var subtitle: String {
        // For a stream the URL is the identity (host and port alone can't tell
        // two streams from the same camera apart).
        if device.isAudioStream {
            return device.streamURL ?? "RTSP audio stream"
        }
        guard let groupKind = device.groupKind else { return "\(device.host):\(device.port)" }
        let kind = groupKind == .ring ? "Ring group" : "Conference"
        let count = device.groupMembers.count
        return count > 0 ? "\(kind) · \(count) member\(count == 1 ? "" : "s")" : kind
    }

    @ViewBuilder
    private func stateIndicator(_ state: ConnectionState) -> some View {
        switch state {
        case .active:
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: true)
                .foregroundStyle(.green)
                .font(.caption)
        case .outgoing:
            Image(systemName: "phone.arrow.up.right")
                .foregroundStyle(.orange)
                .font(.caption)
        case .incoming:
            Image(systemName: "phone.arrow.down.left")
                .foregroundStyle(.green)
                .font(.caption)
        case .connecting, .reconnecting:
            ProgressView().scaleEffect(0.6)
        case .callFailed:
            Image(systemName: "phone.down.fill")
                .foregroundStyle(.red)
                .font(.caption)
        default:
            EmptyView()
        }
    }
}

// MARK: - Stream edit sheet

/// Add or edit an RTSP/RTSPS audio stream.
///
/// Streams are URL-based and cannot be discovered — Home Assistant knows nothing
/// about a camera's RTSP endpoint — so this is the only way one enters the roster.
/// Credentials are handed back separately from the device so they land in the
/// Keychain rather than in the plain-text roster (see `StreamCredentialStore`).
struct StreamEditSheet: View {
    let device: IntercomDevice?
    let onSave: (IntercomDevice, StreamCredentials?) -> Void

    @State private var name: String
    @State private var url: String
    @State private var username: String
    @State private var password: String
    @State private var go2rtcPort: String = String(Go2RTCStream.defaultRTSPPort)
    @Environment(\.dismiss) private var dismiss

    init(device: IntercomDevice?,
         onSave: @escaping (IntercomDevice, StreamCredentials?) -> Void) {
        self.device = device
        self.onSave = onSave
        _name = State(initialValue: device?.name ?? "")
        _url  = State(initialValue: device?.streamURL ?? "")
        let saved = device.flatMap { StreamCredentialStore.load(for: $0.id) }
        _username = State(initialValue: saved?.username ?? "")
        _password = State(initialValue: saved?.password ?? "")
    }

    /// A pasted go2rtc URL (its player is WebRTC, so that's the URL people have)
    /// is rewritten to the equivalent RTSP restream before anything else looks
    /// at it — see Go2RTCStream.
    private var go2rtc: Go2RTCStream? { Go2RTCStream.detect(url) }

    /// Blank means "use the default"; anything unparseable is a real error rather
    /// than something to silently replace with 8554.
    private var go2rtcRTSPPort: UInt16? {
        let text = go2rtcPort.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? Go2RTCStream.defaultRTSPPort : UInt16(text)
    }

    /// What actually gets dialled: the typed URL, or the go2rtc rewrite of it.
    private var effectiveURL: String {
        guard let go2rtc else { return url }
        guard let port = go2rtcRTSPPort else { return "" }
        return go2rtc.rtspURL(port: port)
    }

    /// Parsed live so the form can show what will actually be dialled — and
    /// refuse to save something that isn't a usable RTSP URL.
    private var target: RTSPTarget? { RTSPTarget.parse(effectiveURL) }

    /// The saved URL as the user should see it: credential-free, because a
    /// password doesn't belong on screen next to the field that took it.
    private var displayURL: String { target?.uri ?? "—" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("rtsp://192.168.1.20:554/audio", text: $url)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.callout.monospaced())
                } header: {
                    Text("Stream")
                } footer: {
                    Text("An rtsp:// or rtsps:// URL — or a go2rtc/Frigate stream " +
                         "URL, which is converted for you.")
                }

                if let go2rtc {
                    Section {
                        LabeledContent("Stream", value: go2rtc.streamName)
                        LabeledContent("RTSP port") {
                            TextField(String(Go2RTCStream.defaultRTSPPort), text: $go2rtcPort)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                    } header: {
                        Text("go2rtc")
                    } footer: {
                        Text("go2rtc plays in a browser over WebRTC, which needs a " +
                             "media stack this app doesn't carry — but it restreams " +
                             "the same audio over RTSP on port " +
                             "\(String(Go2RTCStream.defaultRTSPPort)) by default. " +
                             "That's what gets saved:\n\(displayURL)")
                    }
                }

                Section {
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Credentials")
                } footer: {
                    Text("Stored in the Keychain, not with the device list. " +
                         "A username and password pasted into the URL is moved " +
                         "here automatically.")
                }

                if let target {
                    Section("Will connect to") {
                        LabeledContent("Host", value: target.host)
                        LabeledContent("Port", value: String(target.port))
                        LabeledContent("Transport",
                                       value: target.isSecure ? "RTSP over TLS" : "RTSP")
                    }
                } else if !url.isEmpty {
                    Label(go2rtc == nil
                          ? "Not a valid rtsp:// or rtsps:// URL"
                          : "That go2rtc RTSP port isn't valid",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Section {
                    Text("Audio only — no video track is requested, so the camera " +
                         "sends nothing but sound. Listen-only: there is no way to " +
                         "talk back over RTSP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(device == nil ? "Add Audio Stream" : "Edit Audio Stream")
            .navigationBarTitleDisplayMode(.inline)
            // Paste a go2rtc URL into an unnamed stream and the stream's own name
            // is the obvious label — it's the one the user already knows it by.
            .onChange(of: url) { _, newValue in
                guard name.isEmpty, let detected = Go2RTCStream.detect(newValue) else { return }
                name = detected.streamName
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || target == nil)
                }
            }
        }
    }

    private func save() {
        guard let target else { return }

        // Typed fields win; otherwise fall back to credentials pasted in the URL
        // (which `target.uri` has already stripped out).
        var credentials = StreamCredentials(username: username, password: password)
        if credentials.isEmpty, let user = target.username {
            credentials = StreamCredentials(username: user, password: target.password ?? "")
        }

        var updated = device ?? IntercomDevice(name: name, host: target.host,
                                               protocolKind: .rtsp)
        updated.name         = name
        updated.host         = target.host
        updated.port         = Int(target.port)
        updated.protocolKind = .rtsp
        updated.streamURL    = target.uri
        onSave(updated, credentials.isEmpty ? nil : credentials)
        dismiss()
    }
}

// MARK: - Device edit sheet

struct DeviceEditSheet: View {
    let device: IntercomDevice?
    let onSave: (IntercomDevice) -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var protocolKind: DeviceProtocol
    @State private var sipPort: String
    @State private var sipTransport: SIPTransportKind
    @Environment(\.dismiss) private var dismiss

    init(device: IntercomDevice?, onSave: @escaping (IntercomDevice) -> Void) {
        self.device = device
        self.onSave = onSave
        _name = State(initialValue: device?.name ?? "")
        _host = State(initialValue: device?.host ?? "")
        _port = State(initialValue: device.map { String($0.port) } ?? "6054")
        _protocolKind = State(initialValue: device?.protocolKind ?? .auto)
        _sipPort = State(initialValue: String(device?.sipPort ?? Int(SIPEndpoint.defaultPort)))
        _sipTransport = State(initialValue: device?.sipTransport ?? .udp)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    TextField("Name", text: $name)
                    TextField("IP Address", text: $host)
                        .keyboardType(.decimalPad)
                }

                Section {
                    Picker("Protocol", selection: $protocolKind) {
                        // `.rtsp` is not offered here — a stream is added by URL
                        // through StreamEditSheet, not by re-typing a panel.
                        ForEach(DeviceProtocol.panelCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                } header: {
                    Text("Protocol")
                } footer: {
                    Text("ESPHome v2026.7.0 replaced the intercom protocol with SIP. " +
                         "Automatic tries the legacy port first and falls back to SIP.")
                }

                if protocolKind != .voip {
                    Section("Legacy (PBX-lite)") {
                        TextField("TCP Port", text: $port)
                            .keyboardType(.numberPad)
                    }
                }

                if protocolKind != .legacy {
                    Section("VoIP (SIP)") {
                        TextField("SIP Port", text: $sipPort)
                            .keyboardType(.numberPad)
                        Picker("Signaling", selection: $sipTransport) {
                            Text("UDP").tag(SIPTransportKind.udp)
                            Text("TCP").tag(SIPTransportKind.tcp)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .navigationTitle(device == nil ? "Add Device" : "Edit Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let p = Int(port) ?? 6054
                        var d = device ?? IntercomDevice(name: name, host: host, port: p)
                        d.name = name; d.host = host; d.port = p
                        d.protocolKind = protocolKind
                        d.sipPort      = Int(sipPort) ?? Int(SIPEndpoint.defaultPort)
                        d.sipTransport = sipTransport
                        // A hand-entered SIP endpoint has no roster URI; let
                        // SIPCall synthesise one from the host/port above.
                        if protocolKind != .voip { d.sipURI = nil }
                        onSave(d)
                        dismiss()
                    }
                    .disabled(name.isEmpty || host.isEmpty)
                }
            }
        }
    }
}
