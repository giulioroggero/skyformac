import SwiftUI

@main
struct MacZWOApp: App {
    @State private var cameraManager = CameraManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(cameraManager)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            MacZWOCommands(cameraManager: cameraManager)
        }
    }
}
