import AppIntents
import Foundation

// Siri / App Shortcuts support: "Hey Siri, listen in on <panel>" and
// "Hey Siri, stop listening".  Everything here compiles into the app target, so
// each intent's perform() runs in the app's own process — it can reach the live
// IntercomSession (which owns the network + audio) via IntercomCommandBus.

// MARK: - Command bus

/// Bridges an App Intent to the running IntercomSession.
///
/// An intent can fire while the app is cold-launching, before IntercomSession
/// exists.  submit() queues such commands; IntercomSession.attach() (called from
/// its init) drains the queue and handles everything live thereafter.
@MainActor
final class IntercomCommandBus {
    static let shared = IntercomCommandBus()

    enum Command {
        case listen(IntercomDevice)
        case stopListening
    }

    private var pending: [Command] = []
    private weak var handler: IntercomSession?

    func submit(_ command: Command) {
        if let handler {
            handler.handle(command: command)
        } else {
            pending.append(command)
        }
    }

    func attach(_ handler: IntercomSession) {
        self.handler = handler
        let queued = pending
        pending.removeAll()
        queued.forEach { handler.handle(command: $0) }
    }
}

// MARK: - Device entity

/// An intercom panel, exposed to App Intents so Siri can resolve a spoken name
/// ("listen in on Front Door") against the saved roster.
struct IntercomDeviceEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Intercom Panel")
    static var defaultQuery = IntercomDeviceQuery()

    var id: UUID
    var name: String
    var host: String
    var port: Int

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    var device: IntercomDevice { IntercomDevice(id: id, name: name, host: host, port: port) }

    init(_ device: IntercomDevice) {
        id = device.id; name = device.name; host = device.host; port = device.port
    }
}

/// Resolves device entities from the persisted roster (IntercomDevice.loadSaved).
struct IntercomDeviceQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [IntercomDeviceEntity] {
        IntercomDevice.loadSaved()
            .filter { identifiers.contains($0.id) }
            .map(IntercomDeviceEntity.init)
    }

    func suggestedEntities() async throws -> [IntercomDeviceEntity] {
        IntercomDevice.loadSaved().map(IntercomDeviceEntity.init)
    }
}

extension IntercomDeviceQuery: EntityStringQuery {
    /// Match a spoken/typed name against the roster (case- and diacritic-
    /// insensitive substring), so "listen in on front door" finds "Front Door".
    func entities(matching string: String) async throws -> [IntercomDeviceEntity] {
        IntercomDevice.loadSaved()
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(IntercomDeviceEntity.init)
    }
}

// MARK: - Intents

/// "Listen in on <panel>" — opens the app and starts a (muted, listen-only)
/// call to the named panel.  openAppWhenRun brings the app to the foreground so
/// it can use the mic, local network, and background-audio mode; from there it
/// can drop to the background and keep streaming.
struct ListenIntent: AppIntent {
    static var title: LocalizedStringResource = "Listen In"
    static var description = IntentDescription("Start listening to an intercom panel.")
    static var openAppWhenRun = true

    @Parameter(title: "Panel")
    var device: IntercomDeviceEntity

    init() {}
    init(device: IntercomDeviceEntity) { self.device = device }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntercomCommandBus.shared.submit(.listen(device.device))
        return .result(dialog: "Listening in on \(device.name)")
    }
}

/// "Stop listening" — ends every active call.  No need to foreground the app:
/// if a call is live the app is already running (background audio), so the
/// command bus reaches the session in-process.
struct StopListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Listening"
    static var description = IntentDescription("Stop listening to all intercom panels.")
    static var openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntercomCommandBus.shared.submit(.stopListening)
        return .result(dialog: "Stopped listening")
    }
}

// MARK: - App Shortcuts (Siri phrases, no user setup required)

struct IntercomAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListenIntent(),
            phrases: [
                "Listen in on \(\.$device) with \(.applicationName)",
                "Listen in with \(.applicationName) on \(\.$device)",
                "Listen to \(\.$device) with \(.applicationName)",
                "Start listening on \(\.$device) with \(.applicationName)"
            ],
            shortTitle: "Listen In",
            systemImageName: "ear"
        )
        AppShortcut(
            intent: StopListeningIntent(),
            phrases: [
                "Stop listening with \(.applicationName)",
                "Stop \(.applicationName)"
            ],
            shortTitle: "Stop Listening",
            systemImageName: "ear.slash"
        )
    }
}
