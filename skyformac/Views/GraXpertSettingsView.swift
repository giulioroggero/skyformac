import SwiftUI

/// Settings' "GraXpert" tab — same opt-in reasoning as `SirilSettingsView`: GraXpert is a real
/// external process dependency this app doesn't bundle (see `GraXpertElaborationService`). Off by
/// default; the user turns it on here (also reachable directly from "Send to GraXpert…" if it's
/// off when tapped).
struct GraXpertSettingsView: View {
    @State private var isEnabled = AppSettings.isGraXpertIntegrationEnabled
    @State private var customPath = AppSettings.graXpertCLIPath

    private var resolvedPath: URL {
        customPath.map { URL(fileURLWithPath: $0) } ?? GraXpertElaborationService.defaultCLIPath()
    }

    private var isAvailable: Bool {
        GraXpertElaborationService.isCLIAvailable(at: resolvedPath)
    }

    var body: some View {
        Form {
            Section("GraXpert Integration") {
                Toggle("Enable sending elaborated images to GraXpert", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in AppSettings.isGraXpertIntegrationEnabled = newValue }
                Text("GraXpert (graxpert.com) is a separate, free astrophotography tool — not bundled with Skyformac. When enabled, \"Send to GraXpert…\" on an elaborated image can run its AI-based gradient/light-pollution removal or denoising, then bring the result back into this project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("GraXpert Command-Line Tool") {
                Text(resolvedPath.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("Choose…") { choosePath() }
                    if customPath != nil {
                        Button("Reset to Default") {
                            customPath = nil
                            AppSettings.graXpertCLIPath = nil
                        }
                    }
                    Spacer()
                    if isAvailable {
                        Label("Found", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not found", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
                Text("Defaults to the standard GraXpert.app install location. If GraXpert is installed somewhere else, point this at its executable (inside GraXpert.app/Contents/MacOS/).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose GraXpert's command-line executable"
        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            AppSettings.graXpertCLIPath = url.path
        }
    }
}
