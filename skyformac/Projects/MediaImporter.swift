import AVFoundation
import CoreGraphics
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

    /// The file extension a `PhotosPicker`-loaded item's own `UTType` should be saved with —
    /// `UTType.preferredFilenameExtension` already knows this for every real Photos export
    /// (`public.jpeg` → `jpg`, `com.apple.quicktime-movie` → `mov`, etc.); `"dat"` for the rare
    /// case it doesn't, which `kind(for:)` above then correctly treats as unsupported/skipped
    /// rather than guessing at a format.
    static func fileExtension(for type: UTType?) -> String {
        type?.preferredFilenameExtension ?? "dat"
    }
}
