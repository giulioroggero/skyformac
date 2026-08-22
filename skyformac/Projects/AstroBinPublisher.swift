import AppKit

/// "Publish to AstroBin…" — hands an already-saved image off toward AstroBin
/// (https://welcome.astrobin.com/application-programming-interface) rather than uploading it
/// automatically. AstroBin's only public API is explicitly read-only ("the APIs are read-only,
/// and they allow you to get data about images... using the APIs to mercilessly scrape all the
/// available content is not allowed"), issues no write/OAuth credentials, and documents no
/// upload endpoint at all. The only way to actually automate an upload would be reverse-
/// engineering AstroBin's private logged-in web app's session/upload calls and driving them with
/// the user's own password — undocumented, unverifiable without real AstroBin credentials and a
/// live session to test against, likely to break silently whenever their frontend changes, and
/// the exact kind of automated-access-outside-the-sanctioned-API their own terms warn against.
///
/// So this does the honest version instead: reveal the file in Finder (one drag from AstroBin's
/// own upload widget) and put it on the pasteboard too (many modern upload widgets, AstroBin's
/// included, accept a pasted file), then open AstroBin's uploader in the user's default browser,
/// already signed in via their own normal browser session. No stored credentials, no private API
/// calls, no Settings toggle needed — exactly as consequence-free as "Show in Finder," the same
/// reasoning `PixInsightAppLauncher`'s own doc comment gives for skipping one too.
enum AstroBinPublisher {
    static let uploadPageURL = URL(string: "https://app.astrobin.com/uploader")!

    static func publish(_ fileURL: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        NSWorkspace.shared.open(uploadPageURL)
    }
}
