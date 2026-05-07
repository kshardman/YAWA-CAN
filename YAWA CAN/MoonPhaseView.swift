import SwiftUI

/// Renders a moon disc with the correct illuminated/shadowed region.
/// phase: 0 = new moon, 0.25 = first quarter, 0.5 = full moon, 0.75 = last quarter
struct MoonPhaseView: View {
    let phase: Double
    var size: CGFloat = 58

    // True when phase is in the waxing half (lit on right side)
    private var isWaxing: Bool { phase < 0.5 }

    // How much the terminator ellipse deviates from a straight line.
    // 0 at quarter moons (straight terminator), 1 at new/full.
    private var limbScale: CGFloat {
        let t = phase <= 0.5 ? phase * 2 : (phase - 0.5) * 2
        return CGFloat(abs(t * 2 - 1))
    }

    // Which phase range are we in
    private var isCrescent: Bool { phase < 0.25 || phase >= 0.75 }

    var body: some View {
        Canvas { ctx, canvasSize in
            let r  = min(canvasSize.width, canvasSize.height) / 2
            let cx = canvasSize.width  / 2
            let cy = canvasSize.height / 2
            let disc = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)

            let shadowFill = GraphicsContext.Shading.color(Color(white: 0.14, opacity: 0.95))
            let litFill    = GraphicsContext.Shading.color(Color(white: 0.93, opacity: 0.97))

            // 1. Full dark disc
            ctx.fill(Path(ellipseIn: disc), with: shadowFill)

            // 2. Lit semicircle — clipped to the appropriate half
            let litHalf = CGRect(
                x:      isWaxing ? cx : cx - r,
                y:      cy - r,
                width:  r,
                height: r * 2
            )
            ctx.drawLayer { layer in
                layer.clip(to: Path(litHalf))
                layer.fill(Path(ellipseIn: disc), with: litFill)
            }

            // 3. Terminator ellipse — blends crescent / gibbous shape
            let tw = r * limbScale
            let termRect = CGRect(x: cx - tw, y: cy - r, width: tw * 2, height: r * 2)

            if isCrescent {
                // Crescent: shadow ellipse overlays the lit half
                let clipHalf = litHalf
                ctx.drawLayer { layer in
                    layer.clip(to: Path(clipHalf))
                    layer.fill(Path(ellipseIn: termRect), with: shadowFill)
                }
            } else {
                // Gibbous: lit ellipse extends into the shadow half
                let shadowHalf = CGRect(
                    x:      isWaxing ? cx - r : cx,
                    y:      cy - r,
                    width:  r,
                    height: r * 2
                )
                ctx.drawLayer { layer in
                    layer.clip(to: Path(shadowHalf))
                    layer.fill(Path(ellipseIn: termRect), with: litFill)
                }
            }

            // 4. Subtle rim
            ctx.stroke(
                Path(ellipseIn: disc.insetBy(dx: 0.5, dy: 0.5)),
                with: .color(Color.white.opacity(0.15)),
                lineWidth: 1
            )
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    ZStack {
        Color(white: 0.12).ignoresSafeArea()
        VStack(spacing: 24) {
            HStack(spacing: 20) {
                ForEach([0.0, 0.125, 0.25, 0.375], id: \.self) { p in
                    VStack(spacing: 6) {
                        MoonPhaseView(phase: p, size: 52)
                        Text(MoonCalculator.moonPhaseName(phase: p))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .frame(width: 60)
                    }
                }
            }
            HStack(spacing: 20) {
                ForEach([0.5, 0.625, 0.75, 0.875], id: \.self) { p in
                    VStack(spacing: 6) {
                        MoonPhaseView(phase: p, size: 52)
                        Text(MoonCalculator.moonPhaseName(phase: p))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .frame(width: 60)
                    }
                }
            }
        }
        .padding()
    }
}
