import AVFoundation
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

/// Pure, `nonisolated` value transforms for "import media I already have into this session" —
/// Finder files/folders or Apple Photos — kept separate from `CameraManager.importMedia` (the
/// actual `ProjectsLibrary`-mutating entry point) so the file-type/thumbnail logic is unit-
/// testable without a whole `CameraManager` in play, the same separation `MosaicComposer`/
/// `StillImageStacker` keep from the views that drive them.
enum MediaImporter {
    /// Every extension this recognizes as importable, still image or video — anything else is
    /// silently skipped by `expand`/left for `CameraManager.importMedia` to report as skipped,
    /// rather than failing an otherwise-good batch outright.
    static let supportedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "fits", "fit"]
    static let supportedVideoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// `nil` for an extension this doesn't recognize at all — `CameraManager.importMedia` treats
    /// that file as skipped rather than guessing. A `.jpg`/`.jpeg`/`.heic` still image is tagged
    /// `.png` (this app's general "viewable still image" kind, not a literal format claim —
    /// `CGImageRenderer.loadDisplayImage`/`ThumbnailCache` both decode by the file's own real
    /// extension already, never by `kind`, so nothing downstream is misled by this).
    static func kind(for url: URL) -> CaptureRecord.Kind? {
        switch url.pathExtension.lowercased() {
        case "fits", "fit": return .fits
        case "tiff", "tif": return .tiff
        case "png", "jpg", "jpeg", "heic": return .png
        case "mov", "mp4", "m4v": return .video
        default: return nil
        }
    }

    /// Expands a mix of file and folder `URL`s (from an `NSOpenPanel` with
    /// `canChooseDirectories = true`, or a drag-and-drop) into the actual importable files inside
    /// — someone importing "this whole folder of photos" means every supported file directly in
    /// it, not picking each one by hand. Non-recursive (a folder's own subfolders are skipped,
    /// not walked) — matches what Finder's own "flatten" expectation would be for a folder of
    /// captures, and avoids accidentally pulling in an entire deep directory tree by mistake.
    /// Silently drops anything unreadable or unsupported; order is preserved for supported files,
    /// folders expanded in place.
    static func expand(_ urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let contents = (try? fileManager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )) ?? []
                result.append(contentsOf: contents.filter { kind(for: $0) != nil }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            } else if kind(for: url) != nil {
                result.append(url)
            }
        }
        return result
    }

    /// A representative thumbnail for `url` — decodes+downscales a still image via the same
    /// `ThumbnailGenerator` every real capture already uses, or grabs a frame from partway into a
    /// video via `AVAssetImageGenerator` (a live capture's own thumbnail has no video-frame
    /// equivalent to reuse, so this is new). `nil` if the file can't be read at all — not a reason
    /// to fail the whole import, just a capture that ends up without a thumbnail.
    static func makeThumbnail(for url: URL, kind: CaptureRecord.Kind) async -> Data? {
        switch kind {
        case .video:
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            guard let duration = try? await asset.load(.duration) else { return nil }
            let midpoint = CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2)
            guard let frame = try? await generator.image(at: midpoint).image else { return nil }
            return ThumbnailGenerator.makeThumbnail(from: frame)
        case .fits, .png, .tiff, .serVideo, .recording:
            guard let image = try? CGImageRenderer.loadDisplayImage(from: url) else { return nil }
            return ThumbnailGenerator.makeThumbnail(from: image)
        }
    }

    /// The file's own actual capture date — read from embedded metadata where the format carries
    /// one (EXIF `DateTimeOriginal`/TIFF `DateTime` for a still image, QuickTime's own
    /// creation-date metadata for a video), falling back to the file's own filesystem dates, and
    /// only to "now" if neither is available. This is the whole point of importing existing media
    /// rather than capturing it fresh: an old astrophoto imported today should still sort into the
    /// session timeline at when it was actually taken, not at import time. A `PhotosPickerItem`'s
    /// exported data keeps this same embedded metadata (Photos re-encodes the original, not a
    /// stripped copy), so this works identically for a Photos import as for a Finder file — the
    /// temp file `importFromPhotosPicker` writes it to has a fresh *filesystem* date, but the
    /// bytes inside still carry the real one.
    static func captureDate(for url: URL, kind: CaptureRecord.Kind) async -> Date {
        switch kind {
        case .video:
            if let date = await videoCreationDate(for: url) { return date }
        case .fits, .png, .tiff, .serVideo, .recording:
            if let date = imageMetadataDate(for: url) { return date }
        }
        return fileSystemDate(for: url) ?? Date()
    }

    private static func imageMetadataDate(for url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String,
           let date = formatter.date(from: raw) {
            return date
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let raw = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = formatter.date(from: raw) {
            return date
        }
        return nil
    }

    private static func videoCreationDate(for url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return try? await item.load(.dateValue)
    }

    /// Only reached for FITS (this app's own `FITSWriter` never embeds a capture date at all) or
    /// when a still image/video's own metadata is missing/unreadable — still meaningfully better
    /// than "the moment Import was clicked" for a genuine Finder file, even though it's useless
    /// for the Photos-picker path's own freshly-written temp file (which `captureDate` never
    /// reaches for those formats unless the embedded metadata lookup already failed).
    private static func fileSystemDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    /// The file extension a `PhotosPicker`-loaded item's own `UTType` should be saved with —
    /// `UTType.preferredFilenameExtension` already knows this for every real Photos export
    /// (`public.jpeg` → `jpg`, `com.apple.quicktime-movie` → `mov`, etc.); `"dat"` for the rare
    /// case it doesn't, which `kind(for:)` above then correctly treats as unsupported/skipped
    /// rather than guessing at a format.
    static func fileExtension(for type: UTType?) -> String {
        type?.preferredFilenameExtension ?? "dat"
    }
}
