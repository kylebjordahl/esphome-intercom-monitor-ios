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
    @State private var showAddSheet   = false
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
                            description: Text("Add devices manually or configure Home Assistant in Settings.")
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
                        Button { showAddSheet = true } label: {
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
                            Label(callButtonLabel, systemImage: "phone.fill")
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
            .sheet(item: $editingDevice) { device in
                DeviceEditSheet(device: device) { updated in
                    deviceStore.update(updated)
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
        return n == 1 ? "Call" : "Call \(n)"
    }

    private func activeConnectionState(for device: IntercomDevice) -> ConnectionState? {
        session.connections.first { $0.device.id == device.id }?.state
    }

    private func callSelected() {
        let targets = deviceStore.devices.filter { selectedIds.contains($0.id) }
        session.startCall(to: targets, callerName: callerName)
        selectedIds.removeAll()
    }
}

// MARK: - Device row

private struct DeviceRow: View {
    let device: IntercomDevice
    let isActive: ConnectionState?

    var body: some View {
        HStack {
            if let groupKind = device.groupKind {
                Image(systemName: groupKind == .ring ? "person.2.wave.2" : "person.3")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        ForEach(DeviceProtocol.allCases, id: \.self) { kind in
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
