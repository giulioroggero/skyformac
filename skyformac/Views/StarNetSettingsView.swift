import SwiftUI

/// Settings' "StarNet" tab — same opt-in reasoning as `SirilSettingsView`/`GraXpertSettingsView`.
/// Unlike those two, StarNet has no standard install location at all (see
/// `AppSettings.starNetCLIPath`'s own doc comment), so the path field starts empty far more often
/// and "Not found" at the guessed default is the expected first-run state, not a red flag.
struct StarNetSettingsView: View {
    @State private var isEnabled = AppSettings.isStarNetIntegrationEnabled
    @State private var customPath = AppSettings.starNetCLIPath

    private var resolvedPath: URL {
        customPath.map { URL(fileURLWithPath: $0) } ?? StarNetElaborationService.defaultCLIPath()
    }

    private var isAvailable: Bool {
        StarNetElaborationService.isCLIAvailable(at: resolvedPath)
    }

    var body: some View {
        Form {
            Section("StarNet Integration") {
                Toggle("Enable sending elaborated images to StarNet", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in AppSettings.isStarNetIntegrationEnabled = newValue }
                Text("StarNet (starnetastro.com) is a separate, free star-removal tool — not bundled with Skyformac. When enabled, \"Remove Stars…\" on an elaborated image can run it, producing a starless version for nebulosity/background compositing, then bring the result back into this project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("StarNet Command-Line Tool") {
                Text(resolvedPath.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("Choose…") { choosePath() }
                    if customPath != nil {
                        Button("Reset to Default") {
                            customPath = nil
                            AppSettings.starNetCLIPath = nil
                        }
                    }
                    Spacer()
                    if isAvailable {
                        Label("Found", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not found", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
                Text("Unlike Siril or GraXpert, StarNet has no standard install location — its installer places the \"starnet2\" binary wherever it likes. Point this at that file directly; check StarNet's own installer output if you're not sure where it landed.")
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
        panel.message = "Choose StarNet's \"starnet2\" command-line tool"
        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            AppSettings.starNetCLIPath = url.path
        }
    }
}
