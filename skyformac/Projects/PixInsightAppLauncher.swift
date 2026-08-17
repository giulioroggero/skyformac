import Foundation

/// Launches PixInsight's own GUI app with a file pre-loaded — GUI hand-off only, unlike Siril/
/// GraXpert/StarNet. PixInsight's scripting (PJSR) can only be driven from its own already-running
/// Process Console, not via a plain command-line flag — there's no safe, honest way to build a
/// headless "run this and get a result back" integration the way this app's other three tools
/// support, without writing and maintaining real PJSR script content against a copy of PixInsight
/// to test it, which nobody here has done. No Settings toggle either: this is exactly as
/// consequence-free as "Show in Finder," not a real automation the user needs to opt into.
enum PixInsightAppLauncher {
    static func open(_ fileURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "PixInsight", fileURL.path]
        try process.run()
    }
}
