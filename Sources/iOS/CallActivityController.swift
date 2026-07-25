import ActivityKit
import Foundation

// Starts, updates, and ends the call Live Activity.  Driven entirely by local
// state changes from IntercomSession — no push tokens required.
@MainActor
final class CallActivityController {
    private var activity: Activity<CallActivityAttributes>?

    // If the app dies (crash / force-quit) it never runs end(), leaving the
    // activity on the Lock Screen forever.  We mark each update stale a few
    // minutes out so iOS can retire an abandoned activity on its own; a healthy
    // call refreshes this well within the window (state changes + the periodic
    // refresh in IntercomSession).  endOrphaned() is the hard cleanup at launch.
    private let staleAfter: TimeInterval = 180

    /// End any activities left over from a previous app session.  Call once at
    /// launch — there are no live calls yet, so anything still showing is stale
    /// (e.g. from a crash or force-quit that never ran end()).
    func endOrphaned() {
        for activity in Activity<CallActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil
    }

    /// Single entry point: reconcile the Live Activity with the current call
    /// state.  Starts it on the first active call, updates it as things change,
    /// and ends it when no calls remain active.
    func sync(activeCount: Int, primaryName: String, primaryId: String, isTalking: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        guard activeCount > 0 else {
            end()
            return
        }

        // Preserve the original start time across updates so the timer is stable.
        let startedAt = activity?.content.state.startedAt ?? Date()
        let state = CallActivityAttributes.ContentState(
            activeCount: activeCount,
            primaryName: primaryName.isEmpty ? "Intercom" : primaryName,
            primaryId: primaryId,
            isTalking: isTalking,
            startedAt: startedAt
        )
        let content = ActivityContent(state: state,
                                      staleDate: Date().addingTimeInterval(staleAfter))

        if let activity {
            Task { await activity.update(content) }
        } else {
            do {
                activity = try Activity.request(
                    attributes: CallActivityAttributes(),
                    content: content,
                    pushType: nil
                )
            } catch {
                print("CallActivityController: request failed — \(error)")
            }
        }
    }

    /// End the activity immediately (e.g. all calls ended).
    func end() {
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        self.activity = nil
    }
}
