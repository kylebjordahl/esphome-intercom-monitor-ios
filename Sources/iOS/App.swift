import SwiftUI
import UIKit
import AppIntents

// App entry point.  Owns the three app-wide observable objects (device store,
// Home Assistant client, intercom session) and, on launch, starts the TCP
// listener, kicks off Home Assistant discovery, and runs a periodic rediscovery
// loop that keeps the device roster fresh without ever disturbing a live call.
@main
struct IntercomListenerApp: App {
    @StateObject private var deviceStore  = DeviceStore()
    @StateObject private var haClient     = HomeAssistantClient()
    @StateObject private var session      = IntercomSession()
    @AppStorage("callerName") private var callerName = ""

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deviceStore)
                .environmentObject(haClient)
                .environmentObject(session)
                .onAppear {
                    // Seed caller name from the device name on first launch.
                    if callerName.isEmpty {
                        callerName = UIDevice.current.name
                    }

                    // Refresh the Siri / Shortcuts parameter values with whatever
                    // devices are already persisted.  Without this, an App Shortcut
                    // whose only parameter (the panel) had zero suggested values at
                    // first launch stays suppressed — invisible in the Shortcuts app
                    // and unmatched by Siri — even after devices are discovered.
                    IntercomAppShortcuts.updateAppShortcutParameters()

                    let url   = keychainLoad(key: KeychainKey.haBaseURL) ?? ""
                    let token = keychainLoad(key: KeychainKey.haToken)   ?? ""
                    guard !url.isEmpty, !token.isEmpty else { return }

                    // Start the TCP listener so other devices can call us.
                    session.startServer(name: callerName,
                                        haBaseURL: url,
                                        haToken: token,
                                        haClient: haClient)

                    // Live discovery: initial fetch + persistent WebSocket
                    // subscription (the WS loop runs until the socket drops).
                    Task { await haClient.connect(baseURL: url, token: token) }

                    // Periodic rediscovery so the roster never goes stale.
                    // Runs an immediate pass, then every 60 s.  It ONLY adds
                    // newly-found devices to the store — never removes a device
                    // and never touches live connections or the audio engine, so
                    // an in-progress call is never disrupted.
                    Task {
                        while !Task.isCancelled {
                            let u = keychainLoad(key: KeychainKey.haBaseURL) ?? ""
                            let t = keychainLoad(key: KeychainKey.haToken)   ?? ""
                            if !u.isEmpty, !t.isEmpty {
                                await haClient.fetchAll(baseURL: u, token: t, silent: true)
                                mergeDiscovered()
                                session.publishDevicesToWatch(deviceStore.devices)
                            }
                            try? await Task.sleep(for: .seconds(60))
                        }
                    }
                }
                // Any roster change (discovery or manual add/edit/remove) alters
                // the valid Siri parameter values, so re-donate the shortcuts.
                .onChange(of: deviceStore.devices) {
                    IntercomAppShortcuts.updateAppShortcutParameters()
                }
        }
    }

    /// Merge any newly-discovered devices into the store without removing
    /// existing ones (matched by host so a live call's device is never dropped).
    @MainActor
    private func mergeDiscovered() {
        let existing = Set(deviceStore.devices.map { $0.host })
        haClient.discoveredDevices
            .filter { !existing.contains($0.host) }
            .forEach { deviceStore.add($0) }
    }
}
