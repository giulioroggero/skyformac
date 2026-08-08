import Foundation

/// Real, documented `URLResourceKey` for available disk space
/// (`NSURLVolumeAvailableCapacityForImportantUsageKey`, macOS 10.13+) — used by the continuous
/// recording feature's guardrail so an unbounded FITS-per-frame recording session can't silently
/// fill the disk.
enum DiskSpaceChecker {
    static func availableBytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }
}
