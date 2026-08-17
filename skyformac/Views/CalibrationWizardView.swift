import SwiftUI

/// Guided batch capture of dark and flat calibration frames. The "Calibration (Dark/Flat)"
/// section in Controls (`ControlsPanelView.calibrationSubsection`) captures one frame per click,
/// which is fine for a quick test shot but tedious — and easy to get wrong — for the 10-20+
/// frames a real calibration set wants. This wizard just loops `CameraManager.captureDarkFrame`/
/// `captureFlatFrame` for you, seeding the dark exposure from the light frame's own exposure (the
/// one setting that actually has to match for dark subtraction to cancel real sensor noise
/// instead of introducing new, mismatched noise).
///
/// Deliberately does not build a "master" averaged dark/flat — each captured frame lands in
/// `CalibrationLibrary` individually, exactly as `captureDarkFrame`/`captureFlatFrame` already
/// behave, and the user picks which one is active afterward in Controls. Averaging a batch into
/// one master frame would be real new stacking logic (`LiveStacker` already does running-average
/// accumulation, but nothing wires it to calibration frames); this wizard's job is only to remove
/// the tedium of clicking "Capture" 15 times in a row, not to add a new calibration technique.
struct CalibrationWizardView: View {
    var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case intro
        case darks
        case flats
        case done
    }

    @State private var step: Step = .intro
    @AppStorage("darkFrameSeconds") private var darkFrameSeconds: Double = 1.0
    @AppStorage("flatFrameSeconds") private var flatFrameSeconds: Double = 0.5
    @AppStorage("exposureSeconds") private var lightExposureSeconds: Double = 1.0
    @State private var darkCount: Int = 15
    @State private var flatCount: Int = 15
    @State private var capturedInBatch = 0
    @State private var isCapturingBatch = false
    @State private var cancelRequested = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case .intro: introContent
                    case .darks: darksContent
                    case .flats: flatsContent
                    case .done: doneContent
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 480)
        // The dark step's own exposure default only makes sense once, on arrival — after that the
        // field is the user's to edit freely without this snapping it back mid-adjustment.
        .onChange(of: step) { _, newStep in
            if newStep == .darks {
                darkFrameSeconds = lightExposureSeconds
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Calibration Session").font(.headline)
            Spacer()
            Button("Close") { dismiss() }
        }
        .padding()
    }

    private var isRealCamera: Bool {
        (cameraManager.connectedCamera?.cameraID ?? -1) >= 0
    }

    @ViewBuilder
    private var introContent: some View {
        Text("Capture a batch of dark and flat frames without clicking one at a time.")
            .font(.callout)
        VStack(alignment: .leading, spacing: 6) {
            Label("Darks cancel fixed-pattern noise and hot pixels — cap the lens/scope, same exposure and gain as your lights.", systemImage: "moon.fill")
            Label("Flats correct vignetting and dust shadows — an evenly-lit target, same focus and framing as your lights.", systemImage: "sun.max.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        if !isRealCamera {
            Label("Dark/flat calibration needs a real ASI camera's controllable exposure — not available for iPhone/webcam sources.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        Button("Start: Capture Darks") { step = .darks }
            .disabled(!isRealCamera)
    }

    @ViewBuilder
    private var darksContent: some View {
        Text("Cover the scope or lens completely — lens cap on, or cap the front of the OTA — so no light reaches the sensor.")
            .font(.callout)
        Text(String(format: "Exposure is seeded to match your last light frame (%.3fs) — a mismatched exposure won't cancel noise correctly. Adjust it if this session's lights use a different one.", lightExposureSeconds))
            .font(.caption2)
            .foregroundStyle(.secondary)

        ExposureField(seconds: $darkFrameSeconds)
        Stepper("Frames to capture: \(darkCount)", value: $darkCount, in: 3...50)

        batchControls(
            total: darkCount,
            libraryCount: cameraManager.calibrationLibrary.darkFrames.count,
            captureOne: { await cameraManager.captureDarkFrame(seconds: darkFrameSeconds) }
        )

        HStack {
            if capturedInBatch > 0 && !isCapturingBatch {
                Button("Next: Capture Flats") { advanceToFlats() }
            }
            Button("Skip to Flats") { advanceToFlats() }
                .font(.caption)
        }
    }

    @ViewBuilder
    private var flatsContent: some View {
        Text("Point at an evenly-lit target — twilight sky, or a light panel/white shirt over the aperture — keeping the same focus and framing as your lights.")
            .font(.callout)

        ExposureField(seconds: $flatFrameSeconds)
        Stepper("Frames to capture: \(flatCount)", value: $flatCount, in: 3...50)

        batchControls(
            total: flatCount,
            libraryCount: cameraManager.calibrationLibrary.flatFrames.count,
            captureOne: { await cameraManager.captureFlatFrame(seconds: flatFrameSeconds) }
        )

        if capturedInBatch > 0 && !isCapturingBatch {
            Button("Finish") { step = .done }
        }
    }

    @ViewBuilder
    private var doneContent: some View {
        Label("Calibration set captured.", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        Text("\(cameraManager.calibrationLibrary.darkFrames.count) dark frame(s) and \(cameraManager.calibrationLibrary.flatFrames.count) flat frame(s) are now in your library. Pick which ones are active, and turn on \"Subtract Active Dark\" / \"Apply Active Flat\", in the Calibration section of Controls.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Button("Close") { dismiss() }
    }

    @ViewBuilder
    private func batchControls(total: Int, libraryCount: Int, captureOne: @escaping () async -> Void) -> some View {
        HStack {
            if isCapturingBatch {
                ProgressView(value: Double(capturedInBatch), total: Double(total))
                    .frame(width: 160)
                Text("\(capturedInBatch) / \(total)")
                    .font(.caption.monospacedDigit())
                Button("Stop") { cancelRequested = true }
            } else {
                Button("Capture \(total) Frames") { runBatch(total: total, captureOne: captureOne) }
                if cameraManager.isCapturingExposure {
                    ExposureCountdownView(cameraManager: cameraManager)
                }
            }
        }
        Text("\(libraryCount) already in your library.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func advanceToFlats() {
        capturedInBatch = 0
        step = .flats
    }

    private func runBatch(total: Int, captureOne: @escaping () async -> Void) {
        capturedInBatch = 0
        cancelRequested = false
        isCapturingBatch = true
        Task {
            for _ in 0..<total {
                if cancelRequested { break }
                await captureOne()
                capturedInBatch += 1
            }
            isCapturingBatch = false
        }
    }
}
