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
        /// The primary "call" is a one-way RTSP audio stream, so there is nothing
        /// to talk back to.  Decoded with a default so an activity persisted by an
        /// older build still renders.
        var isListenOnly: Bool = false

        // The talk button only appears when exactly one two-way call is active;
        // with multiple calls the user must talk from the app, and a monitored
        // stream has no return path at all.
        var showsTalkButton: Bool { activeCount == 1 && !isListenOnly }

        /// Subtitle under the name on the Lock Screen.
        var subtitle: String {
            if activeCount == 1 {
                return isListenOnly ? "Audio monitor" : "Intercom call"
            }
            return "\(activeCount) intercom calls"
        }

        enum CodingKeys: String, CodingKey {
            case activeCount, primaryName, primaryId, isTalking, startedAt, isListenOnly
        }
    }
}

// Hand-written decoding for the same reason IntercomDevice has it: synthesised
// Codable throws on a missing key even when the property has a default, and an
// activity encoded by the previous build (still on the Lock Screen after an
// update) carries no `isListenOnly`.  Implemented in an extension so the
// memberwise initialiser survives.
extension CallActivityAttributes.ContentState {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeCount  = try c.decode(Int.self, forKey: .activeCount)
        primaryName  = try c.decode(String.self, forKey: .primaryName)
        primaryId    = try c.decode(String.self, forKey: .primaryId)
        isTalking    = try c.decode(Bool.self, forKey: .isTalking)
        startedAt    = try c.decode(Date.self, forKey: .startedAt)
        isListenOnly = try c.decodeIfPresent(Bool.self, forKey: .isListenOnly) ?? false
    }
}
