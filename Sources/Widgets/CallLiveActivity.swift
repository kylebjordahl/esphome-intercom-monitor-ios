import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// Live Activity shown on the Lock Screen / banner and in the Dynamic Island
// whenever one or more intercom calls are in progress.  All updates are driven
// locally by the app (no push), so this works without a paid APNs setup.
//
// Push-to-talk: when exactly one call is active the activity hosts a tap-to-talk
// button (Live Activity buttons can't express press-and-hold, so this latches).
// With multiple calls the button is hidden — talking is done from the app.
struct CallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            // ── Lock Screen / banner presentation ──────────────────────────
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.green)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(callCountText(context.state.activeCount))
                    } icon: {
                        Image(systemName: "phone.fill")
                    }
                    .foregroundStyle(.green)
                    .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .monospacedDigit()
                        .frame(maxWidth: 54)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.primaryName)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CallControls(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "phone.fill")
                    .foregroundStyle(.green)
            } compactTrailing: {
                Image(systemName: context.state.isTalking ? "mic.fill" : "waveform")
                    .foregroundStyle(context.state.isTalking ? .green : .secondary)
            } minimal: {
                Image(systemName: context.state.isTalking ? "mic.fill" : "phone.fill")
                    .foregroundStyle(.green)
            }
            .keylineTint(.green)
        }
    }

    private func callCountText(_ n: Int) -> String {
        n == 1 ? "1 call" : "\(n) calls"
    }
}

// MARK: - Interactive controls

// A single active call gets a tap-to-talk button plus a per-call hang-up button.
// With multiple calls there's no room for per-call controls (and no per-call talk
// button), so it collapses to a single aggregate "End All".
private struct CallControls: View {
    let state: CallActivityAttributes.ContentState

    var body: some View {
        if state.showsTalkButton {
            HStack(spacing: 8) {
                TalkButton(state: state)
                HangupButton(connectionId: state.primaryId, label: "End", expand: false)
            }
        } else {
            HangupButton(connectionId: "", label: "End All", expand: true)
        }
    }
}

private struct TalkButton: View {
    let state: CallActivityAttributes.ContentState

    var body: some View {
        Button(intent: ToggleTalkIntent(connectionId: state.primaryId)) {
            Label(state.isTalking ? "Talking — tap to stop" : "Tap to Talk",
                  systemImage: state.isTalking ? "mic.fill" : "mic.slash.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .tint(state.isTalking ? .green : .blue)
        .buttonStyle(.borderedProminent)
    }
}

private struct HangupButton: View {
    let connectionId: String   // empty string = hang up all
    let label: String
    var expand: Bool = true

    var body: some View {
        Button(intent: HangupIntent(connectionId: connectionId)) {
            Label(label, systemImage: "phone.down.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: expand ? .infinity : nil)
        }
        .tint(.red)
        .buttonStyle(.borderedProminent)
    }
}

// MARK: - Lock Screen view

private struct LockScreenView: View {
    let state: CallActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "phone.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 44)
                    .background(.green.opacity(0.15), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.primaryName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(state.activeCount == 1 ? "Intercom call" : "\(state.activeCount) intercom calls")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(state.startedAt, style: .timer)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.green)
            }

            CallControls(state: state)

            if !state.showsTalkButton {
                Text("Open the app to talk to a specific call")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }
}
