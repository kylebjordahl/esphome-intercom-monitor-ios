import AppIntents
import Foundation

// Bridges the Live Activity's hang-up button to the running app (see
// ToggleTalkIntent for the same pattern — LiveActivityIntent.perform() runs in
// the app's process, so a default-center post reaches IntercomSession).
extension Notification.Name {
    static let intercomHangup = Notification.Name("intercomHangup")
}

/// Ends a call from the Live Activity.  A non-empty `connectionId` hangs up that
/// one call; an empty string hangs up every active call ("End All").
struct HangupIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Hang Up"
    static var isDiscoverable = false

    @Parameter(title: "Connection ID")
    var connectionId: String

    init() {}
    init(connectionId: String) { self.connectionId = connectionId }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: .intercomHangup,
            object: nil,
            userInfo: ["id": connectionId]
        )
        return .result()
    }
}
