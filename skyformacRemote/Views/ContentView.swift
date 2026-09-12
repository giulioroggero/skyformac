import SwiftUI

/// Top-level screen — discovery/pairing per `specs/skyformac_Mobile_Remote_Spec.md` milestone 5.
/// Projects/Sessions/Gallery browsing, live view, and capture control (later milestones) will
/// replace the plain "Connected" placeholder below once `client.phase` is `.connected`.
struct ContentView: View {
    @State private var client = RemoteClient()
    @State private var pairingCodeInput = ""

    var body: some View {
        VStack(spacing: 20) {
            switch client.phase {
            case .idle:
                idleState
            case .browsing:
                browsingState
            case .connecting(let name):
                statusState(icon: "antenna.radiowaves.left.and.right", title: "Connecting to \(name)…", showsSpinner: true)
            case .awaitingPairingCode(let name):
                pairingState(serverName: name)
            case .connected(let name):
                connectedState(serverName: name)
            case .failed(let message):
                failedState(message: message)
            }
        }
        .padding()
        .animation(.default, value: phaseIdentity)
    }

    /// `Phase` isn't itself Hashable (it carries associated `String`s that don't need to
    /// participate in view identity) — this just needs to change whenever the *kind* of phase
    /// does, so the transition animates between states rather than only within one.
    private var phaseIdentity: Int {
        switch client.phase {
        case .idle: return 0
        case .browsing: return 1
        case .connecting: return 2
        case .awaitingPairingCode: return 3
        case .connected: return 4
        case .failed: return 5
        }
    }

    private var idleState: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Skyformac Remote")
                .font(.title2.bold())
            Text("Not yet connected to a Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Find My Mac") { client.startBrowsing() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var browsingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Looking for Skyformac on your network…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if client.discoveredServers.isEmpty {
                Text("Make sure your Mac and this device are on the same Wi-Fi network, and that Skyformac is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                List(client.discoveredServers) { server in
                    Button(server.name) { client.connect(to: server) }
                }
                .listStyle(.plain)
                .frame(maxHeight: 240)
            }
            Button("Cancel") { client.stopBrowsing() }
        }
    }

    private func statusState(icon: String, title: String, showsSpinner: Bool) -> some View {
        VStack(spacing: 12) {
            if showsSpinner {
                ProgressView()
            } else {
                Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            }
            Text(title).font(.headline)
        }
    }

    private func pairingState(serverName: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.circle").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Enter the code shown on \(serverName)").font(.headline).multilineTextAlignment(.center)
            TextField("000000", text: $pairingCodeInput)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .font(.title2.monospacedDigit())
                .frame(maxWidth: 160)
            Button("Pair") {
                client.submitPairingCode(pairingCodeInput)
                pairingCodeInput = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(pairingCodeInput.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { client.disconnect() }
        }
    }

    private func connectedState(serverName: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
            Text("Connected to \(serverName)").font(.headline)
            Text("Projects, Gallery, and Live View land here in the next milestones.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Disconnect") { client.disconnect() }
        }
    }

    private func failedState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.orange)
            Text("Couldn't connect").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try Again") { client.startBrowsing() }
        }
    }
}

#Preview {
    ContentView()
}
