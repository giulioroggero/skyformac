import SwiftUI

/// HUD overlay drawn on top of the live preview: projects `visibleObjects`' real celestial
/// coordinates onto frame pixels via `wcs`, then renders a vector badge (spec section 5.1's
/// Visual Style Guide) for each one. Click-to-inspect per spec section 6.4.
///
/// - Note: Coordinates come in as (RA, Dec); `wcs.projectToPixel` maps them into the *frame's*
///   pixel space (`0..<wcs.imageWidth`, `0..<wcs.imageHeight`), which this view then scales into
///   whatever size SwiftUI actually laid it out at — the same convention `PreviewView`'s other
///   overlays (`focusAssistOverlay`, `planetROIOverlay`) already use.
struct SkyHUDView: View {
    let wcs: WCSFrame
    let visibleObjects: [SkyObject]

    @State private var selectedObject: SkyObject?

    var body: some View {
        GeometryReader { geometry in
            let scaleX = geometry.size.width / CGFloat(wcs.imageWidth)
            let scaleY = geometry.size.height / CGFloat(wcs.imageHeight)
            let placed = projectedObjects(scaleX: scaleX, scaleY: scaleY)

            Canvas { context, _ in
                for item in placed {
                    drawBadge(context: &context, point: item.point, object: item.object, scale: scaleX)
                }
            }
            .allowsHitTesting(false)

            ForEach(placed, id: \.object.id) { item in
                Circle()
                    .fill(Color.clear)
                    .contentShape(Circle())
                    .frame(width: 28, height: 28)
                    .position(item.point)
                    .onTapGesture { selectedObject = item.object }
                    .popover(isPresented: Binding(
                        get: { selectedObject?.id == item.object.id },
                        set: { if !$0 { selectedObject = nil } }
                    )) {
                        SkyObjectDetailView(object: item.object)
                    }
                    .help(item.object.label)
            }
        }
        .allowsHitTesting(true)
    }

    private func projectedObjects(scaleX: CGFloat, scaleY: CGFloat) -> [(object: SkyObject, point: CGPoint)] {
        visibleObjects.compactMap { object in
            guard let pixel = wcs.projectToPixel(raDeg: object.raDeg, decDeg: object.decDeg) else { return nil }
            let point = CGPoint(x: pixel.x * scaleX, y: pixel.y * scaleY)
            guard point.x >= 0, point.x <= Double(wcs.imageWidth) * scaleX,
                  point.y >= 0, point.y <= Double(wcs.imageHeight) * scaleY
            else { return nil }
            return (object, point)
        }
    }

    // MARK: - Badge drawing (spec section 5.1)

    private func drawBadge(context: inout GraphicsContext, point: CGPoint, object: SkyObject, scale: CGFloat) {
        let color = badgeColor(for: object.badgeStyle)
        let radius = badgeRadius(for: object, scale: scale)

        switch object.badgeStyle {
        case .messier:
            let outer = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(outer, with: .color(color), lineWidth: 1.5)
            let inner = radius * 0.55
            context.stroke(Path(ellipseIn: CGRect(x: point.x - inner, y: point.y - inner, width: inner * 2, height: inner * 2)), with: .color(color), lineWidth: 1)
            drawCrosshair(context: &context, point: point, radius: radius * 1.4, color: color)

        case .galaxy:
            let size = object.sizeArcmin ?? CGSize(width: 10, height: 10)
            let aspect = size.height / max(size.width, 0.01)
            let rect = CGRect(x: point.x - radius, y: point.y - radius * aspect, width: radius * 2, height: radius * 2 * aspect)
            var ellipse = Path(ellipseIn: rect)
            if let angle = object.positionAngleDeg {
                let transform = CGAffineTransform(translationX: point.x, y: point.y)
                    .rotated(by: angle * .pi / 180)
                    .translatedBy(x: -point.x, y: -point.y)
                ellipse = ellipse.applying(transform)
            }
            context.stroke(ellipse, with: .color(color), lineWidth: 1.5)

        case .nebula:
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(RoundedRectangle(cornerRadius: radius * 0.3).path(in: rect), with: .color(color), lineWidth: 1.5)

        case .cluster:
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

        case .star:
            drawDiamond(context: &context, point: point, radius: max(radius, 5), color: color)
        }

        drawLabel(context: &context, point: point, object: object, color: color, radius: radius)
    }

    private func badgeColor(for style: HUDBadgeStyle) -> Color {
        switch style {
        case .messier: return Color(red: 1.0, green: 0.8, blue: 0.0)      // #FFCC00
        case .galaxy: return Color(red: 1.0, green: 0.23, blue: 0.19)     // #FF3B30
        case .nebula: return Color(red: 0.157, green: 0.804, blue: 0.255) // #28CD41
        case .cluster: return Color(red: 0.0, green: 0.478, blue: 1.0)    // #007AFF
        case .star: return Color(red: 0.353, green: 0.784, blue: 0.98)    // #5AC8FA
        }
    }

    /// Objects with a real angular size are scaled to it (arcmin -> pixels via the frame's own
    /// pixel scale); everything else (stars, sizeless catalog entries) gets a small fixed marker.
    private func badgeRadius(for object: SkyObject, scale: CGFloat) -> CGFloat {
        guard let size = object.sizeArcmin, object.badgeStyle != .star else { return 8 }
        let arcminToRadians = Double.pi / 180 / 60
        let majorRadiusRadians = (size.width / 2) * arcminToRadians
        let pixelRadius = majorRadiusRadians / wcs.radiansPerPixel * Double(scale)
        return max(6, min(CGFloat(pixelRadius), 120))
    }

    private func drawCrosshair(context: inout GraphicsContext, point: CGPoint, radius: CGFloat, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: point.x - radius, y: point.y))
        path.addLine(to: CGPoint(x: point.x + radius, y: point.y))
        path.move(to: CGPoint(x: point.x, y: point.y - radius))
        path.addLine(to: CGPoint(x: point.x, y: point.y + radius))
        context.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 1)
    }

    private func drawDiamond(context: inout GraphicsContext, point: CGPoint, radius: CGFloat, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: point.x, y: point.y - radius))
        path.addLine(to: CGPoint(x: point.x + radius, y: point.y))
        path.addLine(to: CGPoint(x: point.x, y: point.y + radius))
        path.addLine(to: CGPoint(x: point.x - radius, y: point.y))
        path.closeSubpath()
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }

    private func drawLabel(context: inout GraphicsContext, point: CGPoint, object: SkyObject, color: Color, radius: CGFloat) {
        let text = Text(object.label).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
        context.draw(context.resolve(text), at: CGPoint(x: point.x + radius + 4, y: point.y), anchor: .leading)
    }
}

/// Click-to-inspect popover content, per spec section 6.4.
private struct SkyObjectDetailView: View {
    let object: SkyObject

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(object.label).font(.headline)
            LabeledContent("Catalog", value: object.catalogNumber.map { "\(object.catalog) \($0)" } ?? object.catalog)
            LabeledContent("Type", value: typeName)
            if let magnitude = object.magnitude {
                LabeledContent("Magnitude", value: String(format: "%.1f", magnitude))
            }
            if let size = object.sizeArcmin {
                LabeledContent("Size", value: String(format: "%.1f' × %.1f'", size.width, size.height))
            }
            LabeledContent("RA / Dec", value: String(format: "%.4f°, %+.4f°", object.raDeg, object.decDeg))
        }
        .padding()
        .frame(minWidth: 220)
    }

    private var typeName: String {
        switch object.type {
        case .galaxy: return "Galaxy"
        case .planetaryNebula: return "Planetary Nebula"
        case .emissionNebula: return "Emission Nebula"
        case .openCluster: return "Open Cluster"
        case .globularCluster: return "Globular Cluster"
        case .star: return "Star"
        }
    }
}
