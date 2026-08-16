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
        source: Source, recipe: ElaborationRecipe, outputDirectory: URL, outputBaseName: String
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
            try fileManager.copyItem(at: fileURL, to: scratchDirectory.appendingPathComponent(fileURL.lastPathComponent))
            script = singleImageScript(basename: basename, workingDirectory: scratchDirectory, outputBaseName: outputBaseName)
            outputSubpath = "\(outputBaseName).tif"
        case (.serVideo(let fileURL), _):
            let basename = fileURL.deletingPathExtension().lastPathComponent
            try fileManager.copyItem(at: fileURL, to: scratchDirectory.appendingPathComponent(fileURL.lastPathComponent))
            script = planetaryScript(basename: basename, workingDirectory: scratchDirectory, outputBaseName: outputBaseName)
            outputSubpath = "\(outputBaseName).tif"
        case (.fitsFrames(let fileURLs), .planetary):
            for fileURL in fileURLs {
                try fileManager.copyItem(at: fileURL, to: scratchDirectory.appendingPathComponent(fileURL.lastPathComponent))
            }
            script = planetaryFromFramesScript(workingDirectory: scratchDirectory, outputBaseName: outputBaseName)
            outputSubpath = "frames/\(outputBaseName).tif"
        case (.fitsFrames(let fileURLs), _):
            for fileURL in fileURLs {
                try fileManager.copyItem(at: fileURL, to: scratchDirectory.appendingPathComponent(fileURL.lastPathComponent))
            }
            script = deepSkyScript(workingDirectory: scratchDirectory, outputBaseName: outputBaseName)
            outputSubpath = "process/\(outputBaseName).tif"
        }

        let scriptURL = scratchDirectory.appendingPathComponent("elaborate.ssf")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let log = try await runProcess(cliPath: cliPath, scriptURL: scriptURL)
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
    /// own thread) until it exits, returning everything it printed. A blocking
    /// `readDataToEndOfFile()` rather than an incremental `readabilityHandler` deliberately — the
    /// latter's closure gets invoked repeatedly from a background queue, which means mutating a
    /// shared accumulator `Data` across those calls, exactly the kind of shared-mutable-state
    /// Swift 6's strict concurrency checking (correctly) refuses to compile.
    private static func runProcess(cliPath: URL, scriptURL: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = cliPath
                process.arguments = ["-s", scriptURL.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
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

    private static func planetaryScript(basename: String, workingDirectory: URL, outputBaseName: String) -> String {
        """
        requires 1.2.0
        cd "\(workingDirectory.path)"
        stack \(basename) rej 3 3 -norm=no -out=stacked_raw
        calibrate_single stacked_raw -debayer -prefix=deb_
        load deb_stacked_raw
        autostretch
        savetif \(outputBaseName)
        """
    }

    private static func planetaryFromFramesScript(workingDirectory: URL, outputBaseName: String) -> String {
        """
        requires 1.2.0
        cd "\(workingDirectory.path)"
        convert light -out=frames
        cd frames
        stack light rej 3 3 -norm=no -out=stacked_raw
        calibrate_single stacked_raw -debayer -prefix=deb_
        load deb_stacked_raw
        autostretch
        savetif \(outputBaseName)
        """
    }

    private static func deepSkyScript(workingDirectory: URL, outputBaseName: String) -> String {
        """
        requires 1.2.0
        cd "\(workingDirectory.path)"
        convert light -debayer -out=process
        cd process
        register light
        stack r_light rej 3 3 -norm=addscale -out=stacked
        load stacked
        autostretch
        savetif \(outputBaseName)
        """
    }
}
