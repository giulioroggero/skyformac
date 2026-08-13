import SwiftUI

/// Lists every frame captured so far in the current Lucky Imaging burst, sharpest first — the
/// exact ranking `LuckyImagingSession.stackBest` itself uses to decide which fraction to keep —
/// so one specific frame can be inspected or saved directly instead of only ever seeing the
/// averaged stack `stackLuckyImagingBest` produces.
///
/// Selecting a row is a real side effect, not a thumbnail popup: it calls `CameraManager
/// .showLuckyImagingFrame(atSortedIndex:)`, which replaces `currentFrame` and re-renders the
/// live preview to that exact frame. Closing this sheet leaves that frame showing rather than
/// reverting anything — the burst itself (if still running, and not paused) keeps capturing
/// new frames in the background regardless of what's currently previewed.
struct LuckyImagingFrameBrowserView: View {
    var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int?

    private var frames: [LuckyImagingSession.ScoredFrame] {
        cameraManager.luckyImagingSession?.framesSortedByScore ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Lucky Imaging Frames").font(.headline)
                Spacer()
                Text("\(frames.count) frame(s), sharpest first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Close") { dismiss() }
            }
            .padding()

            Divider()

            if frames.isEmpty {
                Text("No frames captured yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(frames.indices, id: \.self, selection: $selectedIndex) { index in
                    HStack {
                        Text("#\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .leading)
                        if index == 0 {
                            Text("Sharpest")
                                .font(.caption2.bold())
                                .foregroundStyle(.green)
                                .frame(width: 70, alignment: .leading)
                        } else {
                            Spacer().frame(width: 70)
                        }
                        Spacer()
                        Text(String(format: "Score %.1f", frames[index].score))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedIndex = index
                        cameraManager.showLuckyImagingFrame(atSortedIndex: index)
                    }
                }
            }

            Divider()

            HStack {
                if let selectedIndex {
                    Label("Previewing frame #\(selectedIndex + 1) — live preview updated.", systemImage: "eye")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select a frame to preview it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    cameraManager.exportCurrentFrame(as: .png)
                } label: {
                    Label("Save This Frame…", systemImage: "square.and.arrow.down")
                }
                .disabled(selectedIndex == nil)
            }
            .padding()
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 360, idealHeight: 480)
    }
}
