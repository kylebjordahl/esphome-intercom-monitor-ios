import SwiftUI

// Root view: a two-tab layout (Devices / Settings) with a persistent active-call
// banner overlaid across tabs and a full-screen sheet for incoming calls.
struct ContentView: View {
    @EnvironmentObject private var session: IntercomSession

    @State private var showIncoming = false

    // First incoming connection, if any.
    private var incomingConn: IntercomConnection? {
        session.connections.first { $0.state == .incoming }
    }

    var body: some View {
        TabView {
            DevicesView()
                .tabItem { Label("Devices", systemImage: "phone.fill") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        // Active-call banner persists across tabs.
        .overlay(alignment: .bottom) {
            if session.isCallActive {
                ActiveCallBanner()
                    .padding(.bottom, 60)
            }
        }
        // Incoming-call sheet slides over everything when a remote device calls us.
        .onChange(of: session.hasIncomingCall) { _, has in
            showIncoming = has
        }
        .sheet(isPresented: $showIncoming) {
            if let conn = incomingConn {
                IncomingCallSheet(conn: conn)
                    .interactiveDismissDisabled()
            }
        }
    }
}

// MARK: - Incoming call sheet

struct IncomingCallSheet: View {
    @ObservedObject var conn: IntercomConnection
    @EnvironmentObject private var session: IntercomSession

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "phone.fill.arrow.down.left")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolEffect(.bounce.wholeSymbol.byLayer, options: .repeating)

            VStack(spacing: 8) {
                Text("Incoming Call")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(conn.device.name)
                    .font(.largeTitle.bold())
                if !conn.device.host.isEmpty {
                    Text(conn.device.host)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            HStack(spacing: 48) {
                // Decline
                Button {
                    conn.decline()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(.red, in: Circle())
                        Text("Decline")
                            .font(.caption)
                    }
                }

                // Answer
                Button {
                    conn.answer()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(.green, in: Circle())
                        Text("Answer")
                            .font(.caption)
                    }
                }
            }
            .padding(.bottom, 48)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}

// Incoming connections must be Identifiable for .sheet(item:).
// IntercomConnection is already Identifiable via its `id: UUID`.

// MARK: - Active call banner

private struct ActiveCallBanner: View {
    @EnvironmentObject private var session: IntercomSession
    @State private var showDetail = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: true)
                .foregroundStyle(.green)
            Text("\(session.connections.filter { $0.state == .active }.count) active")
                .font(.subheadline.bold())
            // Compact info button → diagnostics, leaving room for "End All".
            Button { showDetail = true } label: {
                Image(systemName: "info.circle")
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Call diagnostics")
            Spacer()
            Button(role: .destructive) { session.hangupAll() } label: {
                Label("End All", systemImage: "phone.down.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .fixedSize()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .sheet(isPresented: $showDetail) { ActiveCallView() }
    }
}
