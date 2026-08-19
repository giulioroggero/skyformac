import SwiftUI

struct CameraListView: View {
    var cameraManager: CameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cameras")
                    .font(.headline)
                Spacer()
                Button {
                    cameraManager.refreshCameraList()
                    cameraManager.refreshWebcams()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan for connected ASI cameras and iPhone/webcam sources")
            }

            if cameraManager.availableCameras.isEmpty {
                ContentUnavailableView(
                    "No ZWO Cameras Found",
                    systemImage: "camera.metering.none",
                    description: Text("Connect an ASI camera over USB, then rescan.")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(cameraManager.availableCameras) { camera in
                    cameraRow(camera)
                }
                .listStyle(.inset)
            }

            // Live Stack/Lucky Imaging/Smart Live Stack all genuinely work on a webcam/iPhone
            // source too (see `CameraManager.applyAcquisitionPreset`'s doc comment) — only
            // ROI/gain/exposure/Reduce Drift don't, and those already no-op gracefully rather
            // than needing this section hidden outright for that source.
            if cameraManager.connectedCamera != nil {
                ActivePipelinesView(cameraManager: cameraManager)
                acquisitionSection
            }

            Divider()

            webcamSection
        }
        .padding()
        .onAppear { cameraManager.refreshWebcams() }
    }

    /// Right next to the connected camera, not tucked away in the right-hand Controls panel —
    /// these three work on whatever camera is connected regardless of which sidebar tab happens
    /// to be showing, so they live where the camera itself is, not with any one tab's controls.
    /// Save/Load work standalone, without opening the Wizard sheet at all — see
    /// `CameraManager.saveCurrentSetupAsPreset`/`loadAndApplyAcquisitionPreset`'s doc comments.
    @ViewBuilder
    private var acquisitionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Acquisition").font(.headline)
                HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.acquisitionPresetStandalone")
            }
            Button {
                cameraManager.isAcquisitionWizardPresented = true
            } label: {
                Label("Wizard…", systemImage: "wand.and.rays")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help("Pick a target (Moon, a planet, or a deep-sky object) and set up Live Stack/Lucky Imaging, ROI, gain, and exposure for it in one step. ⌘⇧W")
            Button {
                cameraManager.saveCurrentSetupAsPreset()
            } label: {
                Label("Save Preset…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help("Saves whatever's currently configured (gain, exposure, ROI, Live Stack/Reduce Drift/Smart Live Stack) as its own preset file. ⌘⇧S")
            Button {
                cameraManager.loadAndApplyAcquisitionPreset()
            } label: {
                Label("Load Preset…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help("Loads a saved preset file and applies it immediately. ⌘⇧L")
            Button {
                cameraManager.resetToDefaultConfiguration()
            } label: {
                Label("Reset to Default", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help("Full sensor ROI, a safe starting gain, and every capture-affecting toggle (Live Stack, Lucky Imaging, Reduce Drift, Dark/Flat correction, Image Enhancement, the AI Suite, any active recording) back off — undoes a Wizard preset or any manual adjustment in one step.")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.vertical, 4)
    }

    /// iPhone (Continuity Camera, wired over USB or wireless) or other AVFoundation webcam as a
    /// primary capture source — e.g. holding an iPhone to a telescope eyepiece (afocal
    /// projection) for lunar/planetary shots. Separate from the ZWO SDK camera list above since
    /// it's a completely different connect path (`CameraManager.connectToWebcam`).
    @ViewBuilder
    private var webcamSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iPhone / Webcam").font(.headline)
            if cameraManager.availableWebcams.isEmpty {
                Text("No iPhone or webcam found. Connect an iPhone via USB (or have it nearby, signed into the same Apple ID, for wireless Continuity Camera) and rescan.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                // Name on its own row, buttons below — same reasoning as the ZWO `cameraRow`'s
                // own layout: a longer device name (an iPhone's full Continuity Camera name can
                // run long) crammed into one row against 1-3 buttons was truncating/wrapping
                // awkwardly instead of either getting the row's full width.
                ForEach(cameraManager.availableWebcams, id: \.uniqueID) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.localizedName).font(.callout)
                        HStack {
                            if cameraManager.connectedCamera?.name == device.localizedName && cameraManager.isExternalWebcam {
                                // Same pair of quick-access icons as the ZWO `cameraRow` below, next
                                // to its own Disconnect — Live Stack/Lucky Imaging/Smart Live Stack
                                // presets apply to a webcam/iPhone source exactly the same way (see
                                // `CameraManager.applyAcquisitionPreset`'s doc comment), so there's no
                                // reason these should only be reachable for a ZWO camera.
                                Button {
                                    cameraManager.isAcquisitionWizardPresented = true
                                } label: {
                                    Image(systemName: "wand.and.rays")
                                }
                                .help("Acquisition Wizard… (⌘⇧W)")
                                Button {
                                    cameraManager.loadAndApplyAcquisitionPreset()
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .help("Load Preset… — loads a saved setup and applies it immediately. (⌘⇧L)")
                                Button("Disconnect") { cameraManager.disconnect() }
                            } else {
                                Button("Connect") {
                                    Task { await cameraManager.connectToWebcam(device) }
                                }
                            }
                            Spacer()
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    /// Three rows, not one crammed `HStack` — the camera's name, then its spec line, then its own
    /// action buttons, each getting the row's full width instead of the name/specs competing with
    /// the buttons for horizontal space (which could truncate a longer camera name or wrap the
    /// spec line awkwardly next to 2-3 buttons in the same row).
    private func cameraRow(_ camera: ZWOCameraInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(camera.name).font(.body.bold())
            Text("\(camera.maxWidth)×\(camera.maxHeight) · \(camera.bitDepth)-bit · \(camera.isColorCamera ? "Color" : "Mono")")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if cameraManager.connectedCamera == camera {
                    // Right next to Disconnect, not only in the fuller "Acquisition" section
                    // below the list — the two fastest, most-reached-for actions (open the
                    // Wizard, load an already-saved setup) live exactly where you'd naturally
                    // look for them: right beside the button that just confirmed this is the
                    // camera you're working with.
                    Button {
                        cameraManager.isAcquisitionWizardPresented = true
                    } label: {
                        Image(systemName: "wand.and.rays")
                    }
                    .help("Acquisition Wizard… (⌘⇧W)")
                    Button {
                        cameraManager.loadAndApplyAcquisitionPreset()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Load Preset… — loads a saved setup and applies it immediately. (⌘⇧L)")
                    Button("Disconnect") { cameraManager.disconnect() }
                } else {
                    Button("Connect") {
                        Task { await cameraManager.connect(to: camera) }
                    }
                    .disabled(cameraManager.connectionState == .connecting)
                }
                Spacer()
            }
        }
        .padding(.vertical, 2)
    }
}
