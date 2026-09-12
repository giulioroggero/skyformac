import SwiftUI

/// Entry point for "Skyformac Remote" — the iOS companion app scoped in
/// `specs/skyformac_Mobile_Remote_Spec.md`. Deliberately not named "Companion" anywhere in this
/// target: that name is already used by `AllSkyMonitorView.swift`'s `AddiPhoneCompanionSheet`, an
/// unrelated Mac-side feature (an iPhone as a Continuity Camera webcam source), and this app is
/// a genuinely different thing — a remote window onto the Mac's own `CameraManager`, not a
/// second capture implementation.
@main
struct SkyformacRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
