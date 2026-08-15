import SwiftUI

struct ContentView: View {
    @Environment(CameraManager.self) private var cameraManager
    /// Owns the floating panel's lifetime while detached — `nil` whenever
    /// `cameraManager.isHistogramPanelDetached` is `false`, created/torn down by the
    /// `.onChange` below rather than left dangling once its window closes.
    @State private var histogramPanelController: HistogramCurvesPanelController?

    /// Applied individually to every part of the window *except* the live preview (which tints
    /// only its own overlay chrome, not the image itself — see `PreviewView.nightTint`'s doc
    /// comment) — sidebar, Controls panel, Histogram/Curves all get the red dark-adaptation tint;
    /// the actual sensor image never does.
    private var nightTint: Color { cameraManager.isNightModeEnabled ? .red : .white }

    /// The open project's (and, if one's active, session's) name — shown in the window's own
    /// title bar. Falls back to a generic title only in the (never actually reachable, since
    /// `RootView` gates this whole view on `activeProject` being non-`nil`) case it's somehow
    /// `nil` here anyway.
    private var windowTitle: String {
        guard let project = cameraManager.activeProject else { return "skyformac" }
        let projectName = project.name.isEmpty ? "Untitled Project" : project.name
        guard let session = cameraManager.activeSession else { return projectName }
        return "\(projectName) — \(session.name)"
    }

    /// Home (the orientation dashboard) / Project name (this project's own page) / Session name (this
    /// session's own page) — three independently clickable crumbs, since each is a genuinely
    /// different destination: "Home" drops the project entirely, the project name keeps it but
    /// drops the session (`showProjectDetail()`), the session name keeps both and remembers to
    /// reopen this exact session's history (`endActiveSession()`). Only ever missing the session
    /// crumb (never the project one) since `RootView` gates this whole view on a session running.
    @ViewBuilder
    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button("Home") { cameraManager.setActive(project: nil, session: nil) }
            if let project = cameraManager.activeProject {
                Text("›").foregroundStyle(.tertiary)
                Button(project.name.isEmpty ? "Untitled Project" : project.name) {
                    cameraManager.showProjectDetail()
                }
                if let session = cameraManager.activeSession {
                    Text("›").foregroundStyle(.tertiary)
                    Button(session.name) { cameraManager.endActiveSession() }
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    /// "In the camera view the user needs to see what to point at — like M13, M53, Polaris,
    /// the Moon — depending on the running session" — the session's own planned object list was
    /// already right there in the model (`Session.plannedObjects`), just never actually surfaced
    /// anywhere in the camera view itself, only back on the Project/Session pages you'd have
    /// already left by the time you're looking through the eyepiece/at the live preview.
    @ViewBuilder
    private var plannedObjectsHint: some View {
        if let objects = cameraManager.activeSession?.plannedObjects, !objects.isEmpty {
            Divider().frame(height: 14)
            Label(objects.joined(separator: ", "), systemImage: "scope")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("This session's planned objects: \(objects.joined(separator: ", "))")
        }
    }

    var body: some View {
        Group {
            if cameraManager.isPreviewFullScreenEnabled {
                fullScreenPreview
            } else {
                mainContent
            }
        }
        // A `.sheet` on the app's one window, not a second `Window` scene — see
        // `SkyformacApp`'s doc comment for why this app is deliberately single-window.
        .sheet(isPresented: Binding(
            get: { cameraManager.isHelpPresented },
            set: { cameraManager.isHelpPresented = $0 }
        )) {
            HelpView(initialTopicID: cameraManager.helpAnchorTopicID, initialSectionID: cameraManager.helpAnchorSectionID)
        }
        .sheet(isPresented: Binding(
            get: { cameraManager.viewingExportedFile != nil },
            set: { if !$0 { cameraManager.viewingExportedFile = nil } }
        )) {
            ExportedFileViewerView(cameraManager: cameraManager)
        }
        .sheet(isPresented: Binding(
            get: { cameraManager.isAcquisitionWizardPresented },
            set: { cameraManager.isAcquisitionWizardPresented = $0 }
        )) {
            AcquisitionWizardView(cameraManager: cameraManager)
        }
    }

    /// The live video alone, filling the entire window with its own overlay controls (zoom
    /// slider, Exit) — no sidebar, camera list, or histogram competing for attention, for
    /// actually seeing faint stars rather than just previewing framing. Reuses `PreviewView`
    /// itself rather than a separate view, so there's no second rendering path (CPU/GPU, all the
    /// Vision overlays) to keep in sync with the embedded one — see its `onExitFullScreen` doc
    /// comment for exactly what changes between the two presentations.
    private var fullScreenPreview: some View {
        PreviewView(
            cameraManager: cameraManager,
            useMetalRenderer: cameraManager.useMetalRenderer,
            onExitFullScreen: { cameraManager.isPreviewFullScreenEnabled = false }
        )
        .ignoresSafeArea()
        .background(Color.black)
        // No `.colorMultiply` here — `PreviewView` already tints its own overlay chrome (zoom
        // badge, corner controls) red in night mode internally, deliberately leaving the actual
        // live image untouched. See its `nightTint` doc comment.
        // `PreviewView`'s own `.onExitCommand` only fires while it (or a descendant) is actually
        // first responder — not guaranteed here, since nothing in this fullscreen presentation
        // necessarily holds keyboard focus. A hidden button with an explicit `.keyboardShortcut`
        // is a real menu-command-equivalent shortcut, not tied to first-responder status, so Esc
        // reliably exits regardless of what currently has focus.
        .background {
            Button("") { cameraManager.isPreviewFullScreenEnabled = false }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
    }

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { cameraManager.isCameraListSidebarVisible ? .all : .detailOnly },
            set: { cameraManager.isCameraListSidebarVisible = $0 != .detailOnly }
        )) {
            CameraListView(cameraManager: cameraManager)
                .colorMultiply(nightTint)
                // `max` matters here, not just `min`/`ideal` — the "detail" side (the HSplitView
                // below, `PreviewView`/`ControlsPanelView`) has its own real minimum width
                // (480 + 320 = 800pt). Without a cap here, dragging this sidebar wider than what
                // that leaves available forced the *whole window* to grow instead — since
                // `NavigationSplitView` won't shrink `detail` below its declared minimum, growing
                // the window was its only way to satisfy both at once, which could push the
                // window partly off-screen on a smaller display. Capped comfortably under that
                // threshold so this column always resizes within the existing window instead, the
                // same way dragging the divider between `PreviewView`/`ControlsPanelView` already
                // does (a plain `HSplitView`, which never grows the window either).
                .navigationSplitViewColumnWidth(min: 130, ideal: 150, max: 280)
        } detail: {
            HSplitView {
                // `.frame(maxHeight: .infinity)` here is what actually matters: without it,
                // whenever the window is taller than this column's own intrinsic content height
                // (e.g. a saved/restored window frame from before Histogram/Curves got shorter),
                // neither `HSplitView` nor its children stretch to fill that extra height on
                // their own — it was showing up as blank space below everything, at the very
                // bottom of the whole window, not specifically "belonging" to the histogram.
                // `PreviewView`'s own `.layoutPriority(1)` then makes sure that extra height
                // actually goes to the preview image, not back into more wasted space below the
                // tabs.
                VStack(spacing: 0) {
                    PreviewView(
                        cameraManager: cameraManager,
                        useMetalRenderer: cameraManager.useMetalRenderer,
                        onEnterFullScreen: { cameraManager.isPreviewFullScreenEnabled = true }
                    )
                        .frame(minWidth: 480, minHeight: 300)
                        .layoutPriority(1)
                        .overlay(alignment: .bottomTrailing) {
                            if cameraManager.isAllSkyMonitorVisible {
                                AllSkyMonitorView()
                                    .frame(width: 220)
                                    .padding(12)
                            }
                        }
                    // A second, harder-to-miss "End Session" directly under the live view itself
                    // — the toolbar's own copy (next to the breadcrumb) can scroll out of view or
                    // just not be where the eye is while watching the preview; this one always is.
                    HStack {
                        Spacer()
                        Button("End Session", systemImage: "stop.circle.fill") {
                            cameraManager.endActiveSession()
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    // No explicit `.frame(height:)` here on purpose — `.layoutPriority(1)` above
                    // makes the preview claim any extra vertical space first, so this only ever
                    // gets exactly what its currently-selected tab's own content actually needs
                    // (a fixed height either wastes space below shorter content, like the plain
                    // combined histogram, or clips taller content, like "By Channel" mode's extra
                    // sliders — `HistogramView`'s own `ScrollView` is the fallback for that latter
                    // case, not the normal case).
                    Group {
                        if cameraManager.isHistogramPanelDetached {
                            HStack {
                                Text("Histogram & Curves are in a separate window.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Dock") { cameraManager.isHistogramPanelDetached = false }
                                    .controlSize(.small)
                            }
                            .padding(8)
                        } else {
                            VStack(spacing: 0) {
                                HStack {
                                    Spacer()
                                    Button {
                                        cameraManager.isHistogramPanelDetached = true
                                    } label: {
                                        Image(systemName: "arrow.up.left.and.arrow.down.right.rectangle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Detach Histogram & Curves into their own floating window — it can overlap the main window, stay open while you work elsewhere, and be docked back with the same button (or by closing it).")
                                }
                                .padding(.horizontal, 8)
                                .padding(.top, 4)
                                TabView {
                                    HistogramView(cameraManager: cameraManager, useMetalRenderer: cameraManager.useMetalRenderer)
                                        .tabItem { Text("Histogram") }
                                    CurvesView(cameraManager: cameraManager)
                                        .tabItem { Text("Curves") }
                                }
                            }
                            .frame(minHeight: 150, maxHeight: 260)
                        }
                    }
                    .colorMultiply(nightTint)
                }
                .frame(maxHeight: .infinity)
                ControlsPanelView(cameraManager: cameraManager)
                    .frame(minWidth: 320, idealWidth: 340, maxHeight: .infinity)
                    .colorMultiply(nightTint)
            }
        }
        .compositingGroup()
        .navigationTitle(windowTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // Home / Project / Session, each independently clickable — pressing the project
                // name goes to its Project page, the session name to its own Session page, Home
                // all the way back to the project list. Every other project/session *management*
                // action (next, new, delete, switch) lives in the menu bar's "Project" menu
                // instead of here — this row is navigation, not a dropdown of actions. "End
                // Session" is the one exception, called out as its own button right next to the
                // breadcrumb (and again below the preview) since it's the single action anyone
                // actually running a session needs constantly, not just occasionally.
                HStack(spacing: 8) {
                    breadcrumb
                    Button("End Session", systemImage: "stop.circle") { cameraManager.endActiveSession() }
                        .help("Stop running this session and return to its Project page")
                    plannedObjectsHint
                }
            }
            ToolbarItem(placement: .principal) {
                imageTypePicker
            }
            ToolbarItem {
                Toggle(isOn: Binding(
                    get: { cameraManager.useMetalRenderer },
                    set: { cameraManager.useMetalRenderer = $0 }
                )) {
                    Label(
                        cameraManager.useMetalRenderer ? "GPU" : "CPU",
                        systemImage: cameraManager.useMetalRenderer ? "bolt.fill" : "cpu"
                    )
                    .foregroundStyle(cameraManager.useMetalRenderer ? .green : .primary)
                }
                .help(cameraManager.useMetalRenderer
                    ? "Rendering on GPU (Metal compute shaders). Click to switch to the CPU (CGImage) path."
                    : "Rendering on CPU (CGImage). Click to switch to the GPU (Metal) path.")
                .accessibilityIdentifier("RenderPathToggle")
            }
            ToolbarItem {
                Toggle("Night Mode", systemImage: "moon.stars.fill", isOn: Binding(
                    get: { cameraManager.isNightModeEnabled },
                    set: { cameraManager.isNightModeEnabled = $0 }
                ))
                    .help("Red-only UI to preserve night vision during visual observation")
            }
            ToolbarItem {
                Toggle("All-Sky Monitor", systemImage: "cloud.sun", isOn: Binding(
                    get: { cameraManager.isAllSkyMonitorVisible },
                    set: { cameraManager.isAllSkyMonitorVisible = $0 }
                ))
                    .help("Picture-in-picture feed from a secondary webcam or nearby iPhone (Continuity Camera) for watching clouds/cables")
            }
            ToolbarItem {
                if cameraManager.isExternalWebcam {
                    Button("Disconnect Camera", systemImage: "xmark.circle") {
                        cameraManager.disconnect()
                    }
                    .help("Stop the iPhone/webcam feed and return to the disconnected state")
                }
            }
        }
        .alert(
            "Camera Error",
            isPresented: errorBinding,
            presenting: cameraManager.lastErrorMessage
        ) { _ in
            Button("OK") { cameraManager.dismissError() }
        } message: { message in
            Text(message)
        }
        // Drag a FITS/PNG/TIFF/JPEG file (from Finder, or the Exported Files section's own
        // history rows) anywhere onto the window to open it — the same native "just drop it on
        // the app" interaction macOS users already expect, rather than requiring the Camera
        // Controls tab's "Open File…" button every time. `openExportedFile` already handles an
        // unsupported extension by explaining why in the viewer sheet, so no extension
        // filtering/validation is needed here.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            cameraManager.openExportedFile(url)
            return true
        }
        // Owns the floating panel's actual open/close lifecycle — `isHistogramPanelDetached`
        // itself is just a plain `Bool` on `CameraManager` (so the "Dock"/"Detach" buttons and
        // the panel's own close button can all just flip it), this is the one place that reacts
        // to it by actually creating/tearing down `HistogramCurvesPanelController`.
        .onChange(of: cameraManager.isHistogramPanelDetached) { _, isDetached in
            if isDetached {
                guard histogramPanelController == nil else { return }
                let controller = HistogramCurvesPanelController(cameraManager: cameraManager) {
                    cameraManager.isHistogramPanelDetached = false
                }
                controller.showWindow(nil)
                histogramPanelController = controller
            } else {
                histogramPanelController?.close()
                histogramPanelController = nil
            }
        }
    }

    @ViewBuilder
    private var imageTypePicker: some View {
        // RGB24-only sources (webcam/iPhone) have no RAW8/RAW16 to switch between — showing an
        // empty segmented control would be worse than showing none.
        if let camera = cameraManager.connectedCamera,
           camera.supportedVideoFormats.contains(ASI_IMG_RAW8) || camera.supportedVideoFormats.contains(ASI_IMG_RAW16) {
            Picker("Format", selection: Binding(
                get: { cameraManager.selectedImageType.rawValue },
                set: { raw in
                    cameraManager.changeImageType(ASI_IMG_TYPE(rawValue: raw))
                }
            )) {
                if camera.supportedVideoFormats.contains(ASI_IMG_RAW8) {
                    Text("RAW8").tag(ASI_IMG_RAW8.rawValue)
                }
                if camera.supportedVideoFormats.contains(ASI_IMG_RAW16) {
                    Text("RAW16").tag(ASI_IMG_RAW16.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { cameraManager.lastErrorMessage != nil },
            set: { isPresented in if !isPresented { cameraManager.dismissError() } }
        )
    }
}
