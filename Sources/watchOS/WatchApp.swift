import SwiftUI

@main
struct IntercomWatchApp: App {
    @StateObject private var deviceStore  = DeviceStore()
    @StateObject private var haClient     = HomeAssistantClient()
    @StateObject private var watchSession = WatchIntercomSession()
    @AppStorage("callerName") private var callerName = "Watch"

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(deviceStore)
                .environmentObject(haClient)
                .environmentObject(watchSession)
                .onAppear {
                    Task {
                        // Try HA discovery directly; fall back to iPhone-synced list.
                        let url   = keychainLoad(key: KeychainKey.haBaseURL) ?? ""
                        let token = keychainLoad(key: KeychainKey.haToken)   ?? ""
                        if !url.isEmpty, !token.isEmpty {
                            await haClient.connect(baseURL: url, token: token)
                            let existing = Set(deviceStore.devices.map { $0.host })
                            haClient.discoveredDevices
                                .filter { !existing.contains($0.host) }
                                .forEach { deviceStore.add($0) }
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .watchDevicesUpdated)) { note in
                    guard let devs = note.object as? [IntercomDevice] else { return }
                    deviceStore.replaceAll(with: devs)
                }
        }
    }
}
