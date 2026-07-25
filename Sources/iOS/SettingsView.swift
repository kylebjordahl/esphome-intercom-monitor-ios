import SwiftUI
import UIKit

// Settings: the caller's display name (caller ID) and Home Assistant connection
// (base URL + long-lived access token, stored in the Keychain), plus a manual
// "Discover Devices" trigger.
struct SettingsView: View {
    @EnvironmentObject private var haClient:    HomeAssistantClient
    @EnvironmentObject private var deviceStore: DeviceStore
    @EnvironmentObject private var session:     IntercomSession
    @AppStorage("callerName") private var callerName = ""

    @State private var haURL   = keychainLoad(key: KeychainKey.haBaseURL) ?? "http://homeassistant.local:8123"
    @State private var haToken = keychainLoad(key: KeychainKey.haToken)   ?? ""
    @State private var isDiscovering = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case name, url, token }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Your Name (caller ID)",
                              text: $callerName,
                              prompt: Text(UIDevice.current.name))
                        .focused($focusedField, equals: .name)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                }

                Section {
                    TextField("HA URL", text: $haURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .url)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .token }
                    SecureField("Long-Lived Access Token", text: $haToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .token)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }

                    Button(action: discover) {
                        HStack {
                            if isDiscovering {
                                ProgressView().tint(.white).padding(.trailing, 4)
                            }
                            Text(isDiscovering ? "Discovering…" : "Discover Devices")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(haURL.isEmpty || haToken.isEmpty || isDiscovering)

                    if let msg = haClient.statusMessage {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: haClient.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(haClient.isError ? .red : .green)
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(haClient.isError ? .red : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if haClient.isConnected {
                                Label("Live", systemImage: "circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.caption)
                    }
                } header: {
                    Text("Home Assistant")
                } footer: {
                    Text("Generate a Long-Lived Access Token in the HA web interface under Profile → Security.")
                }

                Section("About") {
                    LabeledContent("Protocol", value: "TCP / PBX-lite")
                    LabeledContent("Audio", value: "16 kHz, 16-bit PCM")
                    LabeledContent("Background", value: "Persistent (audio mode)")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .onChange(of: haURL)   { _, v in keychainSave(key: KeychainKey.haBaseURL, value: v) }
            .onChange(of: haToken) { _, v in keychainSave(key: KeychainKey.haToken,   value: v) }
        }
    }

    private func discover() {
        isDiscovering = true
        Task {
            await haClient.fetchAll(baseURL: haURL, token: haToken)
            // Add any newly discovered devices that aren't already in the store.
            let existing = Set(deviceStore.devices.map { $0.host })
            haClient.discoveredDevices
                .filter { !existing.contains($0.host) }
                .forEach { deviceStore.add($0) }
            session.publishDevicesToWatch(deviceStore.devices)
            isDiscovering = false
        }
    }
}
