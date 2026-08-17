import Foundation

/// Sends a single already-processed image (typically a Siril or GraXpert result) to StarNet2 for
/// star removal — useful for nebulosity/background compositing workflows, and something neither
/// Siril nor GraXpert do. StarNet is never bundled: a real external CLI tool the user opts into
/// via Settings > StarNet (`AppSettings.isStarNetIntegrationEnabled`).
///
/// Unlike Siril (a `.ssf` script) or GraXpert (an `.app` bundle with a CLI mode), StarNet ships as
/// a bare `starnet2` executable with no standard install location — an installer script places it
/// wherever it likes (see `AppSettings.starNetCLIPath`'s own doc comment). Flags below are taken
/// directly from StarNet's own documentation (starnetastro.com/documentation/starnet/command-line-tool/):
/// `starnet2 -i <input> -o <output> -s <stride> -q`.
enum StarNetElaborationService {
    enum StarNetError: Error, LocalizedError {
        case notEnabled
        case cliNotFound(URL)
        case processFailed(Int32, String)
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .notEnabled:
                return "StarNet integration is off — turn it on in Settings > StarNet."
            case .cliNotFound(let url):
                return "Couldn't find StarNet's \"starnet2\" tool at \(url.path). Install StarNet, or set the correct path in Settings > StarNet."
            case .processFailed(let code, let output):
                return "StarNet exited with an error (code \(code)) — \(Self.lastMeaningfulLine(output))"
            case .outputMissing:
                return "StarNet finished, but didn't produce the expected output file."
            }
        }

        private static func lastMeaningfulLine(_ log: String) -> String {
            log.split(separator: "\n").map(String.init).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "unknown error"
        }
    }

    struct Parameters: Equatable, Sendable {
        /// Must be even, 2...512 per StarNet's own documented range — larger processes faster but
        /// coarser, smaller is slower but catches smaller stars. 256 is StarNet's own suggested
        /// starting point for a typical deep-sky frame.
        var stride: Int = 256

        static let `default` = Parameters()
    }

    /// Not a guaranteed install path — see `AppSettings.starNetCLIPath`'s own doc comment for why
    /// there's no real default the way Siril/GraXpert have.
    static func defaultCLIPath() -> URL {
        URL(fileURLWithPath: "/usr/local/bin/starnet2")
    }

    static func resolvedCLIPath() -> URL {
        if let custom = AppSettings.starNetCLIPath, !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return defaultCLIPath()
    }

    static func isCLIAvailable(at url: URL? = nil) -> Bool {
        FileManager.default.isExecutableFile(atPath: (url ?? resolvedCLIPath()).path)
    }

    /// The CLI arguments for one run — split out from `run(inputURL:parameters:...)` so it's
    /// testable without spawning the actual binary, same reasoning as
    /// `GraXpertElaborationService.arguments`.
    static func arguments(inputFileName: String, outputFileName: String, parameters: Parameters) -> [String] {
        ["-i", inputFileName, "-o", outputFileName, "-s", "\(parameters.stride)", "-q"]
    }

    /// Runs StarNet on `inputURL`, then copies its starless result into `outputDirectory` as
    /// `<outputBaseName>.tif` — StarNet's own default output is a 16-bit TIFF regardless of input
    /// format, per its documentation, so the output extension is fixed rather than inherited from
    /// the input the way `GraXpertElaborationService.run` does.
    static func run(
        inputURL: URL, parameters: Parameters = .default, outputDirectory: URL, outputBaseName: String,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> URL {
        guard AppSettings.isStarNetIntegrationEnabled else { throw StarNetError.notEnabled }
        let cliPath = resolvedCLIPath()
        guard isCLIAvailable(at: cliPath) else { throw StarNetError.cliNotFound(cliPath) }

        let fileManager = FileManager.default
        let scratchDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("skyformac-starnet-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratchDirectory) }

        let stagedURL = scratchDirectory.appendingPathComponent(inputURL.lastPathComponent)
        try fileManager.copyItem(at: inputURL, to: stagedURL)
        let outputFileName = "\(outputBaseName).tif"

        let args = arguments(inputFileName: stagedURL.lastPathComponent, outputFileName: outputFileName, parameters: parameters)
        let (exitCode, log) = try await runProcess(cliPath: cliPath, workingDirectory: scratchDirectory, arguments: args, onLog: onLog)
        guard exitCode == 0 else { throw StarNetError.processFailed(exitCode, log) }

        let resultURL = scratchDirectory.appendingPathComponent(outputFileName)
        guard fileManager.fileExists(atPath: resultURL.path) else { throw StarNetError.outputMissing }

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let finalURL = outputDirectory.appendingPathComponent(outputFileName)
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.copyItem(at: resultURL, to: finalURL)
        return finalURL
    }

    /// Same `Process`/`Pipe`/`readabilityHandler`/lock-protected-accumulator shape as
    /// `GraXpertElaborationService.runProcess` — StarNet, like GraXpert, has no "finished
    /// successfully" marker line to grep for, so its exit code is the only success signal.
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
