import Foundation

/// Sends a capture (or a whole session's stackable frames) to Siril for further processing —
/// registration/stacking/debayering/stretch — then hands back a single result file Skyformac can
/// display. Siril itself is never bundled: a real external process dependency the user opts into
/// via Settings > Siril (`AppSettings.isSirilIntegrationEnabled`), driven headlessly through its
/// own `siril-cli` binary and generated `.ssf` scripts.
///
/// Three recipes (`ElaborationRecipe`), chosen by `resolveRecipe`, each validated end-to-end
/// against real or realistic data before being written here (a real Saturn `.ser`/FITS capture,
/// and a synthetic dithered star field for the registration path — see the actual command output
/// this was built from, not just Siril's documented syntax):
/// - `.singleImage`: exactly one raw FITS frame — `calibrate_single -debayer` (reads the camera's
///   own Bayer pattern from the FITS header) then `autostretch`. Nothing to register or stack
///   with just one frame.
/// - `.planetary`: a `.ser` video, or a FITS burst for a resolved planetary target — stacks
///   directly with rejection, deliberately *skipping* registration: Siril's only CLI-exposed
///   registration method is "Global Star Alignment," which needs a star field to align against
///   and fails outright on a starless planetary disk ("Found 0 stars in reference... Registration
///   aborted," confirmed against a real Saturn `.ser`). Debayers the stacked result once at the
///   end, not every input frame — much cheaper for a multi-thousand-frame video.
/// - `.deepSky`: a folder of individual FITS frames with an actual star field — `convert
///   -debayer`, `register`, then `stack` with rejection.
enum SirilElaborationService {
    enum SirilError: Error, LocalizedError {
        case notEnabled
        case cliNotFound(URL)
        case scriptFailed(String)
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .notEnabled:
                return "Siril integration is off — turn it on in Settings > Siril."
            case .cliNotFound(let url):
                return "Couldn't find Siril's command-line tool at \(url.path). Install Siril, or set the correct path in Settings > Siril."
            case .scriptFailed(let log):
                return "Siril reported an error — \(Self.lastMeaningfulLine(log))"
            case .outputMissing:
                return "Siril finished, but didn't produce the expected output file."
            }
        }

        /// Siril's own log is long (every intermediate progress line) — the *last* non-blank
        /// "log:" line is almost always the actual failure reason ("Registration aborted.",
        /// "Not enough star pairs", etc.), far more useful in an alert than the whole transcript.
        private static func lastMeaningfulLine(_ log: String) -> String {
            log.split(separator: "\n")
                .map(String.init)
                .last { $0.contains("log:") && !$0.contains("Setting CWD") }
                ?? log.split(separator: "\n").last.map(String.init) ?? "unknown error"
        }
    }

    static func defaultCLIPath() -> URL {
        URL(fileURLWithPath: "/Applications/Siril.app/Contents/MacOS/siril-cli")
    }

    static func resolvedCLIPath() -> URL {
        if let custom = AppSettings.sirilCLIPath, !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return defaultCLIPath()
    }

    static func isCLIAvailable(at url: URL? = nil) -> Bool {
        FileManager.default.isExecutableFile(atPath: (url ?? resolvedCLIPath()).path)
    }

    /// What kind of source material one elaboration actually has to work with — determines both
    /// the recipe (via `resolveRecipe`) and how the input gets staged into the scratch working
    /// directory before running Siril.
    enum Source {
        /// One existing FITS file — always `.singleImage`, regardless of target type: nothing to
        /// register/stack with just one frame.
        case singleFITS(URL)
        /// A `.ser` video — defaults to `.planetary` unless a resolved target says otherwise.
        case serVideo(URL)
        /// Several individual FITS frames (a "Record to Disk" folder, or multiple `.fits`
        /// captures in one session) — defaults to `.deepSky` unless a resolved target says
        /// otherwise.
        case fitsFrames([URL])
    }

    /// A pixel-space sub-rectangle of the source frame(s) — "does Siril need me to rectangle the
    /// planet?" Not strictly required (Siril's `stack`/`calibrate_single` happily process a full,
    /// uncropped frame), but cropping to just the disk first is genuinely worth doing: much less
    /// data for Siril to read/reject-stack/write, and — since this app's `.planetary` recipe
    /// deliberately skips registration (see this file's own top-level doc comment for why) — a
    /// tighter crop is the only thing keeping a slowly-drifting disk roughly centered across a
    /// long `.ser` capture at all. Same shape as `FrameCropper.crop(_:toPixelRect:)`'s own
    /// parameter, just `Equatable`/`Sendable` so it can round-trip through `ElaborateSheet`'s
    /// `@State`.
    struct PixelRect: Equatable, Sendable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        fileprivate var asCropperRect: (x: Int, y: Int, width: Int, height: Int) { (x, y, width, height) }
    }

    /// "Allow the user also to set some parameters changing the defaults" — `rejectionSigmaLow`/
    /// `rejectionSigmaHigh` are Siril's own `stack ... rej <low> <high>` sigma-clipping bounds
    /// (how many standard deviations below/above a pixel's per-stack median it can fall before
    /// being rejected from that pixel's combine) — `3 3` in every script template below before
    /// this existed, now user-adjustable instead of baked in.
    struct ElaborationParameters: Equatable, Sendable {
        var cropRect: PixelRect?
        var rejectionSigmaLow: Double = 3.0
        var rejectionSigmaHigh: Double = 3.0

        static let `default` = ElaborationParameters()
    }

    /// Picks the recipe for `source`. The resolved `AcquisitionTarget` (from a capture's own
    /// `AcquisitionPreset.targetID`, when one exists) wins over the source-kind default — "the
    /// default config depending on the object" — so, say, a planetary target recorded via
    /// "Record to Disk" (unusual, but possible) still gets the no-registration planetary recipe
    /// instead of a deep-sky one doomed to fail on a starless frame.
    static func resolveRecipe(for source: Source, target: AcquisitionTarget?) -> ElaborationRecipe {
        if case .singleFITS = source { return .singleImage }
        switch target {
        case .planetary: return .planetary
        case .deepSky: return .deepSky
        case nil:
            switch source {
            case .serVideo: return .planetary
            case .fitsFrames: return .deepSky
            case .singleFITS: return .singleImage
            }
        }
    }

    /// Runs the actual elaboration: stages `source`'s file(s) into a fresh scratch directory,
    /// writes and runs a `.ssf` script matching `recipe`, then copies the single result file into
    /// `outputDirectory` as `<outputBaseName>.tif`. The scratch directory — and every
    /// intermediate Siril creates along the way (`.seq` files, a `process`/`frames` subfolder,
    /// registered frames) — is removed afterward, so nothing from this ever lands in the
    /// project's own session folder.
    static func elaborate(
        source: Source, recipe: ElaborationRecipe, outputDirectory: URL, outputBaseName: String,
        parameters: ElaborationParameters = .default,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        guard AppSettings.isSirilIntegrationEnabled else { throw SirilError.notEnabled }
        let cliPath = resolvedCLIPath()
        guard isCLIAvailable(at: cliPath) else { throw SirilError.cliNotFound(cliPath) }

        let fileManager = FileManager.default
        let scratchDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("skyformac-siril-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratchDirectory) }

        let script: String
        let outputSubpath: String
        switch (source, recipe) {
        case (.singleFITS(let fileURL), _):
            let basename = fileURL.deletingPathExtension().lastPathComponent
            try stageFITS(from: fileURL, to: scratchDirectory.appendingPathComponent(fileURL.lastPathComponent), cropRect: parameters.cropRect)
            script = singleImageScript(basename: basename, workingDirectory: scratchDirectory, outputBaseName: outputBaseName)
            outputSubpath = "\(outputBaseName).tif"
        case (.serVideo(let fileURL), _):
            let basename = fileURL.deletingPathExtension().lastPathComponent
            try stageSER(from: fileURL, to: scratchDirectory.appendingPathComponent(fileURL.lastPathComponent), cropRect: parameters.cropRect)
            script = planetaryScript(
                basename: basename, workingDirectory: scratchDirectory, outputBaseName: outputBaseName, parameters: parameters
            )
            outputSubpath = "\(outputBaseName).tif"
        case (.fitsFrames(let fileURLs), .planetary):
            for fileURL in fileURLs {
                try stageFITS(from: fileURL, to: scratchDirectory.appendingPathComponent(fileURL.lastPathComponent), cropRect: parameters.cropRect)
            }
            script = planetaryFromFramesScript(workingDirectory: scratchDirectory, outputBaseName: outputBaseName, parameters: parameters)
            outputSubpath = "frames/\(outputBaseName).tif"
        case (.fitsFrames(let fileURLs), _):
            for fileURL in fileURLs {
                try stageFITS(from: fileURL, to: scratchDirectory.appendingPathComponent(fileURL.lastPathComponent), cropRect: parameters.cropRect)
            }
            script = deepSkyScript(workingDirectory: scratchDirectory, outputBaseName: outputBaseName, parameters: parameters)
            outputSubpath = "process/\(outputBaseName).tif"
        }

        let scriptURL = scratchDirectory.appendingPathComponent("elaborate.ssf")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let log = try await runProcess(cliPath: cliPath, scriptURL: scriptURL, onLog: onLog)
        guard log.contains("Script execution finished successfully") else {
            throw SirilError.scriptFailed(log)
        }

        let resultURL = scratchDirectory.appendingPathComponent(outputSubpath)
        guard fileManager.fileExists(atPath: resultURL.path) else { throw SirilError.outputMissing }

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let finalURL = outputDirectory.appendingPathComponent("\(outputBaseName).tif")
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.copyItem(at: resultURL, to: finalURL)
        return finalURL
    }

    /// Launches `siril-cli` and blocks (on a background dispatch queue, not the calling task's
    /// own thread) until it exits, returning everything it printed. Output streams incrementally
    /// via `readabilityHandler` when `onLog` is given — that closure can be invoked from more than
    /// one thread across calls, so the growing log itself is held in `LogAccumulator`, a small
    /// lock-protected box, rather than a bare `var` a background queue would mutate unsynchronized
    /// (exactly the shared-mutable-state Swift 6's strict concurrency checking refuses to compile
    /// without one).
    private static func runProcess(cliPath: URL, scriptURL: URL, onLog: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = cliPath
                process.arguments = ["-s", scriptURL.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                let accumulator = LogAccumulator()
                if let onLog {
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { return }
                        onLog(accumulator.appending(chunk))
                    }
                }
                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                process.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                // Whatever arrived after the last readability callback but before exit.
                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                let fullLog = accumulator.appending(remaining)
                onLog?(fullLog)
                continuation.resume(returning: fullLog)
            }
        }
    }

    /// Copies `sourceURL` into `destination` — cropped first, when `cropRect` is given, instead of
    /// a plain file copy. Reads the whole frame back into memory to crop it (`FITSReader`/
    /// `FrameCropper`/`FITSWriter`, all already used elsewhere for exactly this shape of work),
    /// which is fine at FITS's usual single-frame scale.
    private static func stageFITS(from sourceURL: URL, to destination: URL, cropRect: PixelRect?) throws {
        guard let cropRect else {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return
        }
        let parsed = try FITSReader.read(from: sourceURL)
        guard let cropped = FrameCropper.crop(parsed.frame, toPixelRect: cropRect.asCropperRect) else {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return
        }
        try FITSWriter.write(
            frame: cropped, instrumentName: parsed.instrumentName ?? "skyformac",
            isColorCamera: parsed.isColorCamera, bayerPattern: parsed.bayerPattern, to: destination
        )
    }

    /// Same idea as `stageFITS(from:to:cropRect:)`, for a `.ser` video — reads every frame
    /// (`SERReader`), crops each one (`FrameCropper`), and re-encodes through `SERWriter` rather
    /// than attempting to crop the container in place. Loads the whole video into memory; see
    /// `SERReader.read(from:)`'s own doc comment for why that's an acceptable trade-off for this
    /// format's actual (ROI-sized, not deep-sky-scale) use case.
    private static func stageSER(from sourceURL: URL, to destination: URL, cropRect: PixelRect?) throws {
        guard let cropRect else {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return
        }
        let parsed = try SERReader.read(from: sourceURL)
        guard let firstCropped = parsed.frames.first.flatMap({ FrameCropper.crop($0, toPixelRect: cropRect.asCropperRect) }) else {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return
        }
        let writer = try SERWriter(
            firstFrame: firstCropped, isColorCamera: parsed.isColorCamera, bayerPattern: parsed.bayerPattern,
            instrumentName: "skyformac", url: destination
        )
        try writer.write(firstCropped)
        for frame in parsed.frames.dropFirst() {
            guard let cropped = FrameCropper.crop(frame, toPixelRect: cropRect.asCropperRect) else { continue }
            // A cropped-out blank frame (`SERWriter.write`'s own guard) is simply skipped, not a
            // hard failure — the same "one bad frame doesn't sink the whole stack" reasoning
            // `SmartLiveStackGate` already applies live; sigma-clipped `stack` downstream tolerates
            // a shorter sequence just fine.
            try? writer.write(cropped)
        }
        try writer.close()
    }

    /// A lock-protected growing byte buffer — `runProcess`'s own log accumulator, safe to mutate
    /// from `Pipe.readabilityHandler`'s callback regardless of which thread it's invoked on.
    private final class LogAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func appending(_ chunk: Data) -> String {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    // MARK: - Script templates

    private static func singleImageScript(basename: String, workingDirectory: URL, outputBaseName: String) -> String {
        """
        requires 1.2.0
        cd "\(workingDirectory.path)"
        calibrate_single \(basename) -debayer -prefix=deb_
        load deb_\(basename)
        autostretch
        savetif \(outputBaseName)
        """
    }

    private static func planetaryScript(basename: String, workingDirectory: URL, outputBaseName: String, parameters: ElaborationParameters) -> String {
        """
        requires 1.2.0
        cd "\(workingDirectory.path)"
        stack \(basename) rej \(rejectionArgs(parameters)) -norm=no -out=stacked_raw
        calibrate_single stacked_raw -debayer -prefix=deb_
        load deb_stacked_raw
        autostretch
        savetif \(outputBaseName)
        """
    }

    private static func planetaryFromFramesScript(workingDirectory: URL, outputBaseName: String, parameters: ElaborationParameters) -> String {
        """
        requires 1.2.0
        cd "\(workingDirectory.path)"
        convert light -out=frames
        cd frames
        stack light rej \(rejectionArgs(parameters)) -norm=no -out=stacked_raw
        calibrate_single stacked_raw -debayer -prefix=deb_
        load deb_stacked_raw
        autostretch
        savetif \(outputBaseName)
        """
    }

    private static func deepSkyScript(workingDirectory: URL, outputBaseName: String, parameters: ElaborationParameters) -> String {
        """
        requires 1.2.0
        cd "\(workingDirectory.path)"
        convert light -debayer -out=process
        cd process
        register light
        stack r_light rej \(rejectionArgs(parameters)) -norm=addscale -out=stacked
        load stacked
        autostretch
        savetif \(outputBaseName)
        """
    }

    /// Formats `parameters`' sigma-clipping bounds for `stack ... rej <low> <high>` — Siril's
    /// script parser wants plain decimal numbers, and `%.1f` keeps them readable in a saved
    /// `.ssf`/log without depending on `Double`'s own often-many-digit string conversion.
    private static func rejectionArgs(_ parameters: ElaborationParameters) -> String {
        "\(String(format: "%.1f", parameters.rejectionSigmaLow)) \(String(format: "%.1f", parameters.rejectionSigmaHigh))"
    }
}

/// Launches Siril's own GUI app with `fileURL` pre-loaded, open for the user's own manual
/// alignment/stacking/processing — "provide the full experience" alongside this app's automated
/// recipes, not instead of them, for whenever those recipes' limited scope (no full plate
/// solving, no manual star rejection, no PixelMath) isn't enough. Siril's GUI accepts a file path
/// as a plain command-line argument (same as `open -a Siril <path>` or dragging the file onto its
/// Dock icon) and loads it directly.
enum SirilAppLauncher {
    static func open(_ fileURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Siril", fileURL.path]
        try process.run()
    }
}
