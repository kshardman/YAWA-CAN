import SwiftUI

/// Full-width arc graphic showing the sun's position through the sky.
/// progress: 0 = just risen, 1 = just set. isNight shows dashed arc + moon marker.
struct SunArcGraphic: View {
    let progress: Double
    let isNight: Bool
    let sunriseLabel: String
    let sunsetLabel: String

    private let height: CGFloat = 130
    private let horizonFraction: CGFloat = 0.64

    // Horizontal inset for the arc endpoints — labels are centered here too
    private let endpointInset: CGFloat = 48

    @Environment(\.colorScheme) private var colorScheme

    private func arcPoints(in size: CGSize) -> (p0: CGPoint, p1: CGPoint, p2: CGPoint) {
        let horizonY = size.height * horizonFraction
        let p0 = CGPoint(x: endpointInset, y: horizonY)
        let p2 = CGPoint(x: size.width - endpointInset, y: horizonY)
        let p1 = CGPoint(x: size.width / 2, y: size.height * 0.06)
        return (p0, p1, p2)
    }

    private func bezierPoint(p0: CGPoint, p1: CGPoint, p2: CGPoint, t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u*u*p0.x + 2*u*t*p1.x + t*t*p2.x,
            y: u*u*p0.y + 2*u*t*p1.y + t*t*p2.y
        )
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let (p0, p1, p2) = arcPoints(in: size)
            let horizonY = size.height * horizonFraction

            ZStack(alignment: .topLeading) {
                // ── Canvas: gradient fill + arc stroke ──────────────────────
                Canvas { ctx, _ in
                    // Sky region bounded by the arc above and horizon below
                    var sky = Path()
                    sky.move(to: p0)
                    sky.addQuadCurve(to: p2, control: p1)
                    sky.addLine(to: CGPoint(x: p2.x, y: horizonY))
                    sky.addLine(to: CGPoint(x: p0.x, y: horizonY))
                    sky.closeSubpath()

                    ctx.drawLayer { layer in
                        layer.clip(to: sky)
                        let topColor: Color = isNight
                            ? Color(white: 1, opacity: colorScheme == .dark ? 0.05 : 0.10)
                            : Color.orange.opacity(colorScheme == .dark ? 0.13 : 0.28)
                        let bottomColor = Color.clear
                        layer.fill(
                            Path(CGRect(x: 0, y: 0, width: size.width, height: horizonY)),
                            with: .linearGradient(
                                Gradient(colors: [topColor, bottomColor]),
                                startPoint: CGPoint(x: size.width / 2, y: 0),
                                endPoint: CGPoint(x: size.width / 2, y: horizonY)
                            )
                        )
                    }

                    // Arc stroke — warm gold by day, cool muted by night
                    var arcPath = Path()
                    arcPath.move(to: p0)
                    arcPath.addQuadCurve(to: p2, control: p1)

                    let arcColor: Color = isNight
                        ? Color(white: 1, opacity: colorScheme == .dark ? 0.18 : 0.35)
                        : Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.50)

                    ctx.stroke(
                        arcPath,
                        with: .color(arcColor),
                        style: StrokeStyle(
                            lineWidth: 1.0,
                            lineCap: .round,
                            dash: isNight ? [5, 5] : []
                        )
                    )
                }

                // ── Sun / moon marker ────────────────────────────────────────
                let t = CGFloat(max(0, min(1, progress)))
                let mp = bezierPoint(p0: p0, p1: p1, p2: p2, t: t)
                let lift: CGFloat = 12

                if !isNight {
                    // Soft glow halo
                    Circle()
                        .fill(Color.yellow.opacity(colorScheme == .dark ? 0.20 : 0.18))
                        .frame(width: 28, height: 28)
                        .position(x: mp.x, y: mp.y - lift)
                }

                Image(systemName: isNight ? "moon.stars.fill" : "sun.max.fill")
                    .font(.system(size: isNight ? 17 : 22, weight: .semibold))
                    .foregroundStyle(isNight
                        ? Color.primary.opacity(0.60)
                        : Color(hue: 0.12, saturation: 0.95, brightness: 1.0))
                    .shadow(color: isNight ? .clear : Color.orange.opacity(0.35), radius: 3)
                    .position(x: mp.x, y: mp.y - lift)

                // ── Labels centered at the arc endpoints ─────────────────────
                // Sunrise — centered on p0.x
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Sunrise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(sunriseLabel)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .multilineTextAlignment(.center)
                .fixedSize()
                .position(x: p0.x, y: horizonY + 26)

                // Sunset — centered on p2.x
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Sunset")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(sunsetLabel)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .multilineTextAlignment(.center)
                .fixedSize()
                .position(x: p2.x, y: horizonY + 26)
            }
        }
        .frame(height: height)
    }
}

#Preview {
    ZStack {
        Color(.systemBackground).ignoresSafeArea()
        VStack(spacing: 24) {
            Text("Day — 75%").font(.caption).foregroundStyle(.secondary)
            SunArcGraphic(progress: 0.75, isNight: false,
                          sunriseLabel: "5:58 am", sunsetLabel: "6:58 pm")
                .padding(.horizontal, 16)

            Text("Night — 40%").font(.caption).foregroundStyle(.secondary)
            SunArcGraphic(progress: 0.40, isNight: true,
                          sunriseLabel: "5:58 am", sunsetLabel: "6:58 pm")
                .padding(.horizontal, 16)
        }
        .padding()
    }
}
