import SwiftUI

/// "See the vector overlap" — draws the "Experimental" mesh-based drift correction's tracked
/// grid directly over the live preview: each vertex's search window (sized by
/// `MeshDriftConfig.overlap` — the actual "overlap" the toggle's help text refers to, made
/// visible instead of just described) and an arrow for its current smoothed displacement
/// (`CameraManager.meshDriftVisualization`). Purely a debugging/trust-building aid — never part
/// of the actual rendering pipeline, and only shown when `CameraManager
/// .isMeshDriftOverlayVisible` is on.
struct MeshDriftOverlayView: View {
    var cameraManager: CameraManager
    var frameWidth: Int
    var frameHeight: Int

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scaleX = size.width / CGFloat(max(frameWidth, 1))
            let scaleY = size.height / CGFloat(max(frameHeight, 1))
            let gridSize = cameraManager.meshDriftConfig.gridSize
            let vertices = MeshDriftField.vertexPositions(gridSize: gridSize, width: frameWidth, height: frameHeight)
            let roiHalf = MeshDriftField.roiHalfSize(
                gridSize: gridSize, width: frameWidth, height: frameHeight, overlap: cameraManager.meshDriftConfig.overlap
            )
            let displacements = cameraManager.meshDriftVisualization

            Canvas { context, _ in
                for (index, vertex) in vertices.enumerated() {
                    let center = CGPoint(x: CGFloat(vertex.x) * scaleX, y: CGFloat(vertex.y) * scaleY)
                    let rectSize = CGSize(width: CGFloat(roiHalf.x * 2) * scaleX, height: CGFloat(roiHalf.y * 2) * scaleY)
                    let rect = CGRect(
                        x: center.x - rectSize.width / 2, y: center.y - rectSize.height / 2,
                        width: rectSize.width, height: rectSize.height
                    )
                    context.stroke(Path(rect), with: .color(.yellow.opacity(0.6)), lineWidth: 1)

                    if let displacements, index < displacements.count {
                        let displacement = displacements[index]
                        // Multiplied for visibility — real sub-pixel/few-pixel drift would be an
                        // invisible sliver of an arrow otherwise at typical preview zoom.
                        let arrowEnd = CGPoint(
                            x: center.x + CGFloat(displacement.x) * scaleX * 8,
                            y: center.y + CGFloat(displacement.y) * scaleY * 8
                        )
                        var path = Path()
                        path.move(to: center)
                        path.addLine(to: arrowEnd)
                        context.stroke(path, with: .color(.cyan), lineWidth: 2)
                        context.fill(
                            Path(ellipseIn: CGRect(x: arrowEnd.x - 2, y: arrowEnd.y - 2, width: 4, height: 4)),
                            with: .color(.cyan)
                        )
                    }

                    context.fill(
                        Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)),
                        with: .color(.yellow)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
