import AppKit

/// A small process-wide cache for the thumbnail/preview images captures, sessions, and projects
/// show throughout the browser — `TimelineStripView`, `ProjectDetailPane`'s session cards,
/// `ProjectsBrowserView`'s project/session cards, and `CaptureDetailPage` each used to call
/// `NSImage(contentsOf:)` directly from their own `body`, re-decoding the same file from disk on
/// every single re-render (scrolling the timeline, or any unrelated state change re-rendering a
/// card). Keyed on the file's own modification date alongside its URL, so a thumbnail that's
/// since been regenerated (a re-exported file, say) is picked up rather than serving a stale image
/// forever.
enum ThumbnailCache {
    private final class Key: NSObject {
        let url: URL
        let modificationDate: Date?

        init(url: URL, modificationDate: Date?) {
            self.url = url
            self.modificationDate = modificationDate
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return url == other.url && modificationDate == other.modificationDate
        }

        override var hash: Int { url.hashValue }
    }

    // `NSCache` is documented by Apple as thread-safe internally, but isn't marked `Sendable` —
    // `nonisolated(unsafe)` is the standard escape hatch for exactly that situation.
    private nonisolated(unsafe) static let cache: NSCache<Key, NSImage> = {
        let cache = NSCache<Key, NSImage>()
        // Bounded by estimated byte size (via `setObject(_:forKey:cost:)` below), not just item
        // count — most callers here are small capture thumbnails, but `CaptureDetailPage` also
        // caches a full-resolution PNG/TIFF through the same cache, and a count-only limit would
        // let a handful of large images crowd out hundreds of small thumbnails (or just use way
        // more memory than intended). 256 MB comfortably holds a long thumbnail-heavy timeline
        // plus a few full-resolution previews without becoming a real memory concern.
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    /// Same semantics as `NSImage(contentsOf: url)` — `nil` for a missing/unreadable/undecodable
    /// file — just served from cache when `url` (and its modification date) hasn't changed since
    /// the last load.
    static func image(at url: URL) -> NSImage? {
        // `FileManager.attributesOfItem`, not `URL.resourceValues(forKeys:)` — `URL` caches
        // resource values per-instance, so a second call on the same `URL` value can silently
        // return a stale modification date instead of a fresh one, defeating this cache's whole
        // point of picking up a since-changed file.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = Key(url: url, modificationDate: attributes?[.modificationDate] as? Date)
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let cost = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }
}
