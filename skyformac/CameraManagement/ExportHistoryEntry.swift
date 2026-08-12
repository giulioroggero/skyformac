import Foundation

/// One record of "skyformac wrote a file/folder here" — a single-frame FITS/PNG/TIFF export, a
/// continuous FITS recording session's destination folder, or a SER video recording. Persisted
/// (`AppSettings.exportHistory`) so "where did I just save that" survives a relaunch, not just
/// the current session — the whole point of the Exported Files section this drives.
struct ExportHistoryEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case fits
        case png
        case tiff
        case serVideo
        case recordingFolder

        var icon: String {
            switch self {
            case .fits: return "doc.badge.gearshape"
            case .png, .tiff: return "photo"
            case .serVideo: return "film"
            case .recordingFolder: return "folder"
            }
        }

        var label: String {
            switch self {
            case .fits: return "FITS"
            case .png: return "PNG"
            case .tiff: return "TIFF"
            case .serVideo: return "SER video"
            case .recordingFolder: return "Recording folder"
            }
        }

        /// Whether `ExportedFileViewerView` can actually open this in-app — a `.ser` video or a
        /// continuous-recording folder is meant for an external tool (AutoStakkert!3, PIPP,
        /// Finder), not something this app's own viewer renders.
        var isViewableInApp: Bool {
            switch self {
            case .fits, .png, .tiff: return true
            case .serVideo, .recordingFolder: return false
            }
        }
    }

    let id: UUID
    let url: URL
    let kind: Kind
    let date: Date

    init(url: URL, kind: Kind, date: Date = Date()) {
        self.id = UUID()
        self.url = url
        self.kind = kind
        self.date = date
    }
}
