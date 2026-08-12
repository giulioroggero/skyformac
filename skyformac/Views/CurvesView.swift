import SwiftUI

/// "Curves" tab (alongside `HistogramView` in the same tabbed area below the live preview) —
/// Photoshop-style tone-curve grading: drag control points on a 256-step response curve, per
/// channel. See `ToneCurve`/`ChannelToneCurves` for the underlying model (a monotonic cubic
/// spline sampled into a lookup table) and `Shaders.metal`'s `applyToneCurveRGBA` for how it's
/// applied on the GPU path — `CGImageRenderer`'s `channelLUTs` mirrors it on the CPU path.
///
/// A post-stretch grading step, not a replacement for the Black/White Point stretch: the stretch
/// sets the overall exposure range, curves shape tonality within it (lift shadows, roll off
/// highlights) — the same two-stage division most photo tools make between "levels" and
/// "curves".
struct CurvesView: View {
    var cameraManager: CameraManager

    private enum Channel: String, CaseIterable, Identifiable {
        case master = "RGB"
        case red = "Red"
        case green = "Green"
        case blue = "Blue"

        var id: String { rawValue }

        var color: Color {
            switch self {
            case .master: return .white
            case .red: return .red
            case .green: return .green
            case .blue: return .blue
            }
        }
    }

    @State private var selectedChannel: Channel = .master
    @State private var selectedPointIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Curves").font(.headline)
                Spacer()
                Toggle("Enable", isOn: Binding(
                    get: { cameraManager.isToneCurveEnabled },
                    set: { cameraManager.isToneCurveEnabled = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Applies the curve(s) below as a post-stretch grading pass on the live preview — off by default, so opening this tab alone doesn't change anything until you turn it on.")
            }

            Picker("Channel", selection: $selectedChannel) {
                ForEach(Channel.allCases) { channel in
                    Text(channel.rawValue).tag(channel)
                }
            }
            .pickerStyle(.segmented)
            .help("\"RGB\" is a master curve applied to all three channels identically; Red/Green/Blue each layer their own independent curve on top of it.")

            curveCanvas
                .frame(height: 110)

            HStack {
                Button("Add Point") { addPoint() }
                Button("Remove Point") { removeSelectedPoint() }
                    .disabled(!canRemoveSelectedPoint)
                Spacer()
                Button("Reset Curve") { resetCurrentCurve() }
            }
            .font(.caption)
            .controlSize(.small)
        }
        .padding()
        .onChange(of: selectedChannel) { selectedPointIndex = nil }
    }

    // MARK: - Curve editing

    private var curveBinding: Binding<ToneCurve> {
        switch selectedChannel {
        case .master:
            return Binding(get: { cameraManager.toneCurves.master }, set: { cameraManager.toneCurves.master = $0 })
        case .red:
            return Binding(get: { cameraManager.toneCurves.red }, set: { cameraManager.toneCurves.red = $0 })
        case .green:
            return Binding(get: { cameraManager.toneCurves.green }, set: { cameraManager.toneCurves.green = $0 })
        case .blue:
            return Binding(get: { cameraManager.toneCurves.blue }, set: { cameraManager.toneCurves.blue = $0 })
        }
    }

    private var canRemoveSelectedPoint: Bool {
        guard let index = selectedPointIndex else { return false }
        let points = curveBinding.wrappedValue.points
        return points.count > 2 && index < points.count
    }

    private func addPoint() {
        var curve = curveBinding.wrappedValue
        let lut = curve.lookupTable()
        curve.points.append(CurvePoint(x: 0.5, y: Double(lut[128]) / 255.0))
        curveBinding.wrappedValue = curve
        selectedPointIndex = curve.points.count - 1
    }

    private func removeSelectedPoint() {
        guard canRemoveSelectedPoint, let index = selectedPointIndex else { return }
        var curve = curveBinding.wrappedValue
        curve.points.remove(at: index)
        curveBinding.wrappedValue = curve
        selectedPointIndex = nil
    }

    private func resetCurrentCurve() {
        curveBinding.wrappedValue = .identity
        selectedPointIndex = nil
    }

    // MARK: - Canvas

    private var curveCanvas: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Rectangle().fill(Color.black)

                Canvas { context, size in
                    // Reference diagonal (the identity curve) and a light 4x4 grid, for orientation.
                    var diagonal = Path()
                    diagonal.move(to: CGPoint(x: 0, y: size.height))
                    diagonal.addLine(to: CGPoint(x: size.width, y: 0))
                    context.stroke(diagonal, with: .color(.white.opacity(0.25)), lineWidth: 1)

                    for i in 1..<4 {
                        let x = size.width * CGFloat(i) / 4
                        let y = size.height * CGFloat(i) / 4
                        context.stroke(
                            Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                            with: .color(.white.opacity(0.1)), lineWidth: 1
                        )
                        context.stroke(
                            Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                            with: .color(.white.opacity(0.1)), lineWidth: 1
                        )
                    }

                    let lut = curveBinding.wrappedValue.lookupTable()
                    var curvePath = Path()
                    for sample in 0..<256 {
                        let x = CGFloat(sample) / 255.0 * size.width
                        let y = size.height - CGFloat(lut[sample]) / 255.0 * size.height
                        if sample == 0 { curvePath.move(to: CGPoint(x: x, y: y)) } else { curvePath.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(curvePath, with: .color(selectedChannel.color), lineWidth: 2)
                }

                ForEach(Array(curveBinding.wrappedValue.points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(selectedPointIndex == index ? Color.yellow : selectedChannel.color)
                        .frame(width: 10, height: 10)
                        .position(
                            x: CGFloat(point.x) * size.width,
                            y: size.height - CGFloat(point.y) * size.height
                        )
                        .gesture(
                            DragGesture(minimumDistance: 0).onChanged { value in
                                selectedPointIndex = index
                                let x = min(max(value.location.x / size.width, 0), 1)
                                let y = min(max(1 - value.location.y / size.height, 0), 1)
                                var curve = curveBinding.wrappedValue
                                guard index < curve.points.count else { return }
                                curve.points[index] = CurvePoint(x: Double(x), y: Double(y))
                                curveBinding.wrappedValue = curve
                            }
                        )
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
