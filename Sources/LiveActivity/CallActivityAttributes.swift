import ActivityKit
import Foundation

// Model shared between the main app (which starts / updates / ends the Live
// Activity) and the widget extension (which renders it).
//
// Deliberately placed in Sources/LiveActivity — NOT Sources/Shared — because
// the watchOS target compiles Sources/Shared and has no ActivityKit framework.
// Only the iOS app and the widget extension include this directory.
struct CallActivityAttributes: ActivityAttributes {
    // Dynamic, per-update state.
    public struct ContentState: Codable, Hashable {
        var activeCount: Int     // number of live calls
        var primaryName: String  // name shown as the headline (first call)
        var primaryId: String    // id of the primary call (for the talk button)
        var isTalking: Bool      // true while the primary call's mic is open
        var startedAt: Date      // when the first call went active (for the timer)

        // The talk button only appears when exactly one call is active; with
        // multiple calls the user must talk from the app.
        var showsTalkButton: Bool { activeCount == 1 }
    }
}
