import Network
import Foundation

// Listens for incoming PBX-lite TCP connections on port 6054 and advertises
// the device via mDNS as _intercom-tcp._tcp so ESP peers with mdns_discovery
// can auto-discover the iPhone.
@MainActor
final class IntercomServer: ObservableObject {

    static let listenPort: UInt16 = 6054

    @Published private(set) var isListening = false
    @Published private(set) var error: String?

    private var listener: NWListener?

    /// Called on the main actor for every new inbound TCP connection.
    var onAccepted: ((NWConnection) -> Void)?

    // MARK: - Lifecycle

    func start(deviceName: String) {
        guard listener == nil else { return }

        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.enableKeepalive = true

        do {
            let params = NWParameters(tls: nil, tcp: tcpOpts)
            let l = try NWListener(using: params,
                                   on: NWEndpoint.Port(rawValue: Self.listenPort)!)

            // Advertise via Bonjour so mDNS-capable ESP devices auto-discover us.
            l.service = NWListener.Service(name: deviceName,
                                           type: "_intercom-tcp._tcp")

            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.error = nil
                        print("IntercomServer: listening on port \(Self.listenPort)")
                    case .failed(let err):
                        self.isListening = false
                        self.error = err.localizedDescription
                        print("IntercomServer: failed — \(err)")
                        // Try again after a short delay.
                        Task {
                            try? await Task.sleep(for: .seconds(5))
                            await self.restart(deviceName: deviceName)
                        }
                    case .cancelled:
                        self.isListening = false
                    default:
                        break
                    }
                }
            }

            l.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.onAccepted?(connection)
                }
            }

            l.start(queue: .global(qos: .userInteractive))
            listener = l

        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func restart(deviceName: String) {
        stop()
        start(deviceName: deviceName)
    }
}
