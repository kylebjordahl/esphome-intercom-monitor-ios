import AppIntents
import Foundation

// Notification used to bridge the Live Activity's talk button to the running
// app.  Because ToggleTalkIntent conforms to LiveActivityIntent, its perform()
// runs in the app's process — so a plain NotificationCenter post here is
// received by IntercomSession's observer (no App Group required).
extension Notification.Name {
    static let intercomToggleTalk = Notification.Name("intercomToggleTalk")
}

/// Toggles push-to-talk for a single call straight from the Live Activity.
///
/// Live Activity buttons are tap-driven (App Intents can't express press-and-
/// hold), so this is a latching toggle: tap to open the mic, tap again to close
/// it.  The app's in-process control remains true press-and-hold.
struct ToggleTalkIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle Talk"
    static var isDiscoverable = false

    @Parameter(title: "Connection ID")
    var connectionId: String

    init() {}
    init(connectionId: String) { self.connectionId = connectionId }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: .intercomToggleTalk,
            object: nil,
            userInfo: ["id": connectionId]
        )
        return .result()
    }
}
