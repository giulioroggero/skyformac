import SwiftUI

/// Drag-to-draw crop rectangle over a preview image — "does Siril need me to rectangle the
/// planet?" (it doesn't strictly require it, but cropping to just the disk first is genuinely
/// worth doing; see `SirilElaborationService.PixelRect`'s own doc comment). Each drag replaces
/// whatever selection existed before (a fresh marquee, not draggable handles/move-in-place) —
/// simplest thing that's still genuinely useful for "draw a box around the planet."
struct CropRectangleSelector: View {
    let image: NSImage
    let pixelSize: (width: Int, height: Int)
    @Binding var cropRect: SirilElaborationService.PixelRect?

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let imageRect = Self.fittedImageRect(containerSize: geo.size, pixelSize: pixelSize)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001) // makes the whole container (not just the image) hit-testable
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                if let cropRect {
                    let viewRect = Self.viewRect(for: cropRect, imageRect: imageRect, pixelSize: pixelSize)
                    selectionOutline(viewRect)
                }
                if let dragStart, let dragCurrent {
                    selectionOutline(Self.normalized(from: dragStart, to: dragCurrent))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .local)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        defer { dragStart = nil; dragCurrent = nil }
                        guard let start = dragStart else { return }
                        let viewSelection = Self.normalized(from: start, to: value.location)
                        cropRect = Self.pixelRect(forViewRect: viewSelection, imageRect: imageRect, pixelSize: pixelSize)
                    }
            )
            // The default arrow pointer reads as "nothing to do here" — a crosshair signals
            // "draw a box" the moment the pointer enters this view, before the first drag.
            .onHover { isHovering in
                if isHovering {
                    NSCursor.crosshair.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .aspectRatio(CGFloat(pixelSize.width) / CGFloat(max(pixelSize.height, 1)), contentMode: .fit)
        .frame(maxHeight: 320)
        .background(.black.opacity(0.3))
        .clipped()
    }

    @ViewBuilder
    private func selectionOutline(_ rect: CGRect) -> some View {
        Rectangle()
            .stroke(Color.yellow, lineWidth: 2)
            .background(Color.yellow.opacity(0.15))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private nonisolated static func normalized(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
    }

    /// Where the image actually renders within `containerSize` under `.aspectRatio(contentMode:
    /// .fit)` — since this view's own `.aspectRatio(...)` modifier already matches the image's own
    /// aspect ratio, in practice `imageRect` always exactly fills `containerSize` with zero
    /// letterboxing; computed properly anyway (rather than just returning the full container)
    /// so the coordinate math stays correct if that ever changes.
    ///
    /// `nonisolated` on this and the three geometry helpers below — pure `CGRect` math with no
    /// view state, but `View` conformance otherwise infers every static member as `@MainActor`
    /// by default, which broke calling them synchronously from `SirilElaborationTests` (a plain,
    /// non-actor-isolated test type). A stricter Xcode/Swift toolchain (CI's, older than this
    /// machine's) enforces that cross-isolation call as a hard error where a newer one doesn't.
    nonisolated static func fittedImageRect(containerSize: CGSize, pixelSize: (width: Int, height: Int)) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let imageAspect = CGFloat(pixelSize.width) / CGFloat(pixelSize.height)
        let containerAspect = containerSize.width / containerSize.height
        if imageAspect > containerAspect {
            let height = containerSize.width / imageAspect
            return CGRect(x: 0, y: (containerSize.height - height) / 2, width: containerSize.width, height: height)
        } else {
            let width = containerSize.height * imageAspect
            return CGRect(x: (containerSize.width - width) / 2, y: 0, width: width, height: containerSize.height)
        }
    }

    /// View-space (points, within the container `imageRect` is itself expressed in) selection →
    /// pixel-space crop rect, clamped to the frame's actual bounds. `nil` for a degenerate
    /// selection (fully outside the image, or smaller than 4px in either dimension once mapped —
    /// an accidental click/tiny drag, not a real crop intent).
    nonisolated static func pixelRect(forViewRect viewRect: CGRect, imageRect: CGRect, pixelSize: (width: Int, height: Int)) -> SirilElaborationService.PixelRect? {
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }
        let clamped = viewRect.intersection(imageRect)
        guard !clamped.isNull, !clamped.isEmpty else { return nil }
        let scaleX = CGFloat(pixelSize.width) / imageRect.width
        let scaleY = CGFloat(pixelSize.height) / imageRect.height
        let x = Int(((clamped.minX - imageRect.minX) * scaleX).rounded())
        let y = Int(((clamped.minY - imageRect.minY) * scaleY).rounded())
        let width = Int((clamped.width * scaleX).rounded())
        let height = Int((clamped.height * scaleY).rounded())
        guard width >= 4, height >= 4 else { return nil }
        return SirilElaborationService.PixelRect(
            x: max(0, min(x, pixelSize.width - 1)), y: max(0, min(y, pixelSize.height - 1)),
            width: min(width, pixelSize.width), height: min(height, pixelSize.height)
        )
    }

    /// The inverse of `pixelRect(forViewRect:imageRect:pixelSize:)` — used to redraw a
    /// previously-set crop rect's outline (e.g. still showing after `ElaborateSheet` re-derives
    /// its preview).
    nonisolated static func viewRect(for pixelRect: SirilElaborationService.PixelRect, imageRect: CGRect, pixelSize: (width: Int, height: Int)) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        let scaleX = imageRect.width / CGFloat(pixelSize.width)
        let scaleY = imageRect.height / CGFloat(pixelSize.height)
        return CGRect(
            x: imageRect.minX + CGFloat(pixelRect.x) * scaleX,
            y: imageRect.minY + CGFloat(pixelRect.y) * scaleY,
            width: CGFloat(pixelRect.width) * scaleX,
            height: CGFloat(pixelRect.height) * scaleY
        )
    }
}
