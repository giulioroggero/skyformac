import SwiftUI

/// Settings' "Siril" tab — opt-in, since Siril is a real external process dependency this app
/// doesn't bundle (see `SirilElaborationService`). Off by default; the user turns it on here
/// (also reachable directly from "Elaborate…" if it's off when tapped).
struct SirilSettingsView: View {
    @State private var isEnabled = AppSettings.isSirilIntegrationEnabled
    @State private var customPath = AppSettings.sirilCLIPath

    private var resolvedPath: URL {
        customPath.map { URL(fileURLWithPath: $0) } ?? SirilElaborationService.defaultCLIPath()
    }

    private var isAvailable: Bool {
        SirilElaborationService.isCLIAvailable(at: resolvedPath)
    }

    var body: some View {
        Form {
            Section("Siril Integration") {
                Toggle("Enable sending captures to Siril for further processing", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in AppSettings.isSirilIntegrationEnabled = newValue }
                Text("Siril (siril.org) is a separate, free astrophotography processing app — not bundled with Skyformac. When enabled, \"Elaborate…\" next to a session or capture can send its raw FITS/SER data to Siril's command-line tool for stacking, registration, and stretching, then bring the result back into this project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Siril Command-Line Tool") {
                Text(resolvedPath.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("Choose…") { choosePath() }
                    if customPath != nil {
                        Button("Reset to Default") {
                            customPath = nil
                            AppSettings.sirilCLIPath = nil
                        }
                    }
                    Spacer()
                    if isAvailable {
                        Label("Found", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not found", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
                Text("Defaults to the standard Siril.app install location. If Siril is installed somewhere else, point this at its \"siril-cli\" binary (inside Siril.app/Contents/MacOS/).")
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
        panel.message = "Choose Siril's \"siril-cli\" command-line tool"
        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            AppSettings.sirilCLIPath = url.path
        }
    }
}
