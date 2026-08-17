import Foundation

/// Sends a single already-processed image (typically a Siril elaboration's `.tif`, but any FITS/
/// TIFF file works) to GraXpert for gradient removal and/or AI denoising — the two things Siril
/// itself doesn't really cover. GraXpert is never bundled: a real external process dependency the
/// user opts into via Settings > GraXpert (`AppSettings.isGraXpertIntegrationEnabled`), driven
/// headlessly through its own CLI mode (`GraXpert.app/Contents/MacOS/GraXpert <file> -cli ...`).
///
/// Unlike `SirilElaborationService`, there's no registration/stacking recipe here — GraXpert
/// operates on one image at a time, so this is just "run one of its two CLI commands with some
/// parameters" rather than a multi-step generated script. Flags below are taken directly from
/// GraXpert's own README (github.com/Steffenhir/GraXpert) — `-cli -cmd background-extraction
/// -correction Subtraction|Division -smoothing <0-1>` for gradient removal, `-cli -cmd denoising
/// -strength <0-1>` for denoising, `-gpu true|false` either way.
enum GraXpertElaborationService {
    enum GraXpertError: Error, LocalizedError {
        case notEnabled
        case cliNotFound(URL)
        case processFailed(Int32, String)
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .notEnabled:
                return "GraXpert integration is off — turn it on in Settings > GraXpert."
            case .cliNotFound(let url):
                return "Couldn't find GraXpert at \(url.path). Install GraXpert, or set the correct path in Settings > GraXpert."
            case .processFailed(let code, let output):
                return "GraXpert exited with an error (code \(code)) — \(Self.lastMeaningfulLine(output))"
            case .outputMissing:
                return "GraXpert finished, but didn't produce the expected output file."
            }
        }

        private static func lastMeaningfulLine(_ log: String) -> String {
            log.split(separator: "\n").map(String.init).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "unknown error"
        }
    }

    /// GraXpert's two CLI operations — background extraction (gradient/light-pollution removal)
    /// and AI denoising. Each maps to `-cmd <rawValue>` directly.
    enum Operation: String, Codable, Sendable, CaseIterable, Identifiable {
        case backgroundExtraction = "background-extraction"
        case denoising

        var id: String { rawValue }

        var label: String {
            switch self {
            case .backgroundExtraction: return "Background Extraction"
            case .denoising: return "Denoising"
            }
        }
    }

    /// GraXpert's `-correction` values for background extraction — subtracting the modeled
    /// background (the common case) vs. dividing by it (better for multiplicative vignetting).
    enum Correction: String, Codable, Sendable, CaseIterable {
        case subtraction = "Subtraction"
        case division = "Division"
    }

    struct Parameters: Equatable, Sendable {
        var correction: Correction = .subtraction
        var smoothing: Double = 0.1
        var denoiseStrength: Double = 0.5
        var useGPU: Bool = true

        static let `default` = Parameters()
    }

    static func defaultCLIPath() -> URL {
        URL(fileURLWithPath: "/Applications/GraXpert.app/Contents/MacOS/GraXpert")
    }

    static func resolvedCLIPath() -> URL {
        if let custom = AppSettings.graXpertCLIPath, !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return defaultCLIPath()
    }

    static func isCLIAvailable(at url: URL? = nil) -> Bool {
        FileManager.default.isExecutableFile(atPath: (url ?? resolvedCLIPath()).path)
    }

    /// The CLI arguments for one run, everything after the executable path itself — split out from
    /// `run(inputURL:operation:parameters:...)` so it's testable without actually spawning
    /// GraXpert (mirrors `SirilElaborationService`'s own scripts being pure string-builders, just
    /// returning an argument array instead of a `.ssf` script's text).
    static func arguments(inputFileName: String, operation: Operation, parameters: Parameters, outputBaseName: String) -> [String] {
        var args = [inputFileName, "-cli", "-cmd", operation.rawValue, "-gpu", parameters.useGPU ? "true" : "false", "-output", outputBaseName]
        switch operation {
        case .backgroundExtraction:
            args += ["-correction", parameters.correction.rawValue, "-smoothing", String(format: "%.2f", parameters.smoothing)]
        case .denoising:
            args += ["-strength", String(format: "%.2f", parameters.denoiseStrength)]
        }
        return args
    }

    /// Runs GraXpert on `inputURL`, then copies its result into `outputDirectory` as
    /// `<outputBaseName>.<original extension>`. Stages the input into a scratch working directory
    /// (removed afterward) the same way `SirilElaborationService.elaborate` does, and runs GraXpert
    /// with that directory as its working directory so `-output <name>` (a bare name, no path)
    /// lands there rather than next to the original file.
    static func run(
        inputURL: URL, operation: Operation, parameters: Parameters = .default,
        outputDirectory: URL, outputBaseName: String,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        guard AppSettings.isGraXpertIntegrationEnabled else { throw GraXpertError.notEnabled }
        let cliPath = resolvedCLIPath()
        guard isCLIAvailable(at: cliPath) else { throw GraXpertError.cliNotFound(cliPath) }

        let fileManager = FileManager.default
        let scratchDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("skyformac-graxpert-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratchDirectory) }

        let stagedURL = scratchDirectory.appendingPathComponent(inputURL.lastPathComponent)
        try fileManager.copyItem(at: inputURL, to: stagedURL)

        let args = arguments(
            inputFileName: stagedURL.lastPathComponent, operation: operation, parameters: parameters, outputBaseName: outputBaseName
        )
        let (exitCode, log) = try await runProcess(cliPath: cliPath, workingDirectory: scratchDirectory, arguments: args, onLog: onLog)
        guard exitCode == 0 else { throw GraXpertError.processFailed(exitCode, log) }

        // GraXpert writes its result next to the input, keeping the input's own extension —
        // `-output <name>` only sets the base name, not the format.
        let resultURL = scratchDirectory.appendingPathComponent("\(outputBaseName).\(inputURL.pathExtension)")
        guard fileManager.fileExists(atPath: resultURL.path) else { throw GraXpertError.outputMissing }

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let finalURL = outputDirectory.appendingPathComponent("\(outputBaseName).\(inputURL.pathExtension)")
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.copyItem(at: resultURL, to: finalURL)
        return finalURL
    }

    /// Launches GraXpert and blocks (on a background dispatch queue) until it exits, returning its
    /// exit code alongside everything it printed — same `Process`/`Pipe`/`readabilityHandler`/
    /// lock-protected accumulator shape as `SirilElaborationService.runProcess`, just returning an
    /// exit code too since GraXpert (unlike Siril's `.ssf` runner) has no "Script execution
    /// finished successfully" marker line to grep for — its process exit code is the only signal.
    private static func runProcess(
        cliPath: URL, workingDirectory: URL, arguments: [String], onLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> (Int32, String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = cliPath
                process.currentDirectoryURL = workingDirectory
                process.arguments = arguments
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
                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                let fullLog = accumulator.appending(remaining)
                onLog?(fullLog)
                continuation.resume(returning: (process.terminationStatus, fullLog))
            }
        }
    }

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
}

/// Launches GraXpert's own GUI app with `fileURL` pre-loaded — same "provide the full experience
/// alongside the automated path" reasoning as `SirilAppLauncher`, for whenever the two headless
/// operations above aren't enough (manual background-point placement, inspecting the AI model's
/// output before accepting it).
enum GraXpertAppLauncher {
    static func open(_ fileURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "GraXpert", fileURL.path]
        try process.run()
    }
}
