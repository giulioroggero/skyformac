import SwiftUI

/// Milestone-1 placeholder — just confirms the target builds and runs in Simulator. Discovery,
/// pairing, and the Projects/Sessions/Gallery/Live View screens land in later milestones per
/// `specs/skyformac_Mobile_Remote_Spec.md`.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Skyformac Remote")
                .font(.title2.bold())
            Text("Not yet connected to a Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
