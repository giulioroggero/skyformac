import SwiftUI

/// "In timeline must be evidenced if is a single capture, a ser video, a lucky image" — a small
/// always-visible badge on a timeline thumbnail showing `capture.kind` (reusing `Kind.icon`, the
/// same symbol a thumbnail without an image already falls back to — this just makes it visible
/// even when a real thumbnail image is covering that fallback). "If the user press on the icon
/// she can post process the capture" — wrapped in a `Button` when `action` is non-nil (offered
/// only for a post-processable kind, `Kind.isPostProcessable`), a plain static icon otherwise, so
/// a `.recording` capture (nothing here post-processes that kind) doesn't invite a tap that does
/// nothing.
struct CaptureKindBadge: View {
    let kind: CaptureRecord.Kind
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action, kind.isPostProcessable {
                Button(action: action) { icon }
                    .buttonStyle(.plain)
                    .help("Post-process this \(kind.displayName.lowercased()) capture")
            } else {
                icon
            }
        }
    }

    private var icon: some View {
        Image(systemName: kind.icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.6), in: Circle())
    }
}
