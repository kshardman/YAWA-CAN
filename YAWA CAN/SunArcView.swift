//
//  SunArcView.swift
//  YAWA
//
//  Created by LLM on 2/22/26.
//

import SwiftUI

/// Draws an (optional) arc between the Sunrise and Sunset columns (assumes they are equal-width),
/// and places a marker (sun or moon) along that arc based on progress (0...1).
/// Can also draw a straight "horizon" line that is independent of the arc.
struct SunArcView: View {

    // Keep this order aligned with how ContentView calls it:
    // progress, arcRiseFraction, height, arcLineWidth, markerSize, isThemed, isNight, ...
    var progress: Double

    /// Arc curvature for marker placement.
    var arcRiseFraction: CGFloat = 0.22

    /// Overall height of this overlay.
    var height: CGFloat = 34

    /// Arc stroke width (use 0 to hide).
    var arcLineWidth: CGFloat = 1.0

    /// Marker icon size.
    var markerSize: CGFloat = 14

    /// Tune contrast for YAWA themed backgrounds.
    var isThemed: Bool = false

    /// If true, show a moon marker instead of the sun.
    var isNight: Bool = false

    /// Arc endpoints horizontally (fractions of available width).
    /// For two equal columns, icon centers are ~25% and ~75%.
    var leftXFraction: CGFloat = 0.25
    var rightXFraction: CGFloat = 0.75

    // MARK: - Horizon options

    /// Show curved arc stroke.
    var showsArc: Bool = true

    /// Show straight horizon line.
    var showsHorizon: Bool = false

    /// Horizon line width.
    var horizonLineWidth: CGFloat = 1.0

    /// Moves the horizon DOWN (+) or UP (-) relative to its baseline.
    /// NOTE: Y increases downward in SwiftUI.
    var horizonYOffset: CGFloat = 0

    /// Shortens the horizon so it looks like it continues the icon’s bars.
    var horizonEndpointInset: CGFloat = 14

    /// Where the horizon “wants” to sit inside the overlay, before applying horizonYOffset.
    /// Start around ~0.65–0.85 for your current `height: 72` usage.
    var horizonBaseFraction: CGFloat = 0.55

    // MARK: - Horizon decoration (daytime)

    /// Show small tree silhouettes sitting on the horizon line during daytime.
    var showsHorizonTrees: Bool = false

    /// Tree icon size (points).
    var horizonTreeSize: CGFloat = 24

    /// Additional opacity multiplier for trees (applied on top of the strokeColor).
    var horizonTreeOpacity: CGFloat = 1.0

    /// Vertical offset for trees relative to the horizon line.
    /// Increase to move trees upward (since Y grows downward in SwiftUI).
    var horizonTreeYOffset: CGFloat = 8

    // MARK: - Refresh / interaction

    /// Extends the arc endpoints DOWN (+) or UP (-). Useful when the sunrise/sunset SF icons are removed
    /// and the marker should sit closer to the horizon at t=0/1.
    var arcEndpointYOffset: CGFloat = 0

    /// Optional tap handler so a parent can refresh its "now" time and recompute sun progress.
    var onTapRefresh: (() -> Void)? = nil

    /// When true, SunArcView will accept taps and (optionally) regenerate horizon trees.
    /// Default is false so the overlay doesn't intercept map/card interactions.
    var enablesTapRefresh: Bool = false
    
    @State private var horizonTreeFractionsState: [CGFloat] = []
    
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            // MARK: - Arc (marker path)
            // Keep the arc path exactly as before so your existing tuning remains stable.
            let x0 = w * leftXFraction
            let x2 = w * rightXFraction
            let midX = (x0 + x2) * 0.5

            // Arc endpoints near bottom of overlay bounds (stable with your offset tuning)
            let yBase = (h - 2) + arcEndpointYOffset

            let span = max(1, x2 - x0)
            let rise = span * arcRiseFraction
            let yCtrl = max(2, yBase - rise)

            let p0 = CGPoint(x: x0, y: yBase)
            let p2 = CGPoint(x: x2, y: yBase)
            let p1 = CGPoint(x: midX, y: yCtrl)

            let t = Self.clamp(progress, 0, 1)
            let markerPoint = Self.quadBezierPoint(p0: p0, p1: p1, p2: p2, t: t)

            // MARK: - Horizon (independent)
            // The horizon should span the full available width of this view,
            // independent of the sunrise/sunset column centers used for the arc.
            let inset = min(max(0, horizonEndpointInset), w * 0.5)
            let hx0 = inset
            let hx2 = w - inset

            // IMPORTANT: do NOT clamp to `0...h`.
            // Your parent ZStack does not clip, so allowing overflow makes the parameter actually useful.
            let horizonY = (h * horizonBaseFraction) + horizonYOffset

            // Stroke color: match the sunrise/sunset icon “bar” color.
            // In Themed mode the icons use YAWATheme.textSecondary (via appTextSecondary),
            // so use that here too.
            // In System mode, `.secondary` matches SF Symbol secondary tone well.
            let strokeColor: Color = {
                // Match the Sunrise/Sunset icon stroke tone as closely as possible.
                // In Themed mode, those icons are tinted with `YAWATheme.textSecondary`.
                // In System mode, they use the semantic `.secondary`.
                if isThemed {
                    return YAWATheme.textSecondary
                } else {
                    return Color.secondary
                }
            }()
            
            let treeColor: Color = {
                if colorScheme == .light {
                    // Explicit silhouette for Light mode
                    return Color.black.opacity(0.28)
                } else {
                    // Slightly softer in Dark mode
                    return Color.primary.opacity(0.45)
                }
            }()

            ZStack {
                // Optional arc stroke
                if showsArc && arcLineWidth > 0 {
                    Path { path in
                        path.move(to: p0)
                        path.addQuadCurve(to: p2, control: p1)
                    }
                    .stroke(strokeColor, lineWidth: arcLineWidth)
                    .shadow(
                        color: isThemed ? Color.black.opacity(0.22) : .clear,
                        radius: isThemed ? 1 : 0,
                        x: 0,
                        y: isThemed ? 1 : 0
                    )
                }

                // Optional horizon stroke
                if showsHorizon && horizonLineWidth > 0 {
                    Path { path in
                        path.move(to: CGPoint(x: hx0, y: horizonY))
                        path.addLine(to: CGPoint(x: hx2, y: horizonY))
                    }
                    .stroke(strokeColor, lineWidth: horizonLineWidth)
                    .shadow(
                        color: isThemed ? Color.black.opacity(0.10) : .clear,
                        radius: isThemed ? 1 : 0,
                        x: 0,
                        y: isThemed ? 1 : 0
                    )
                }
                

                // Hole punch so the line/arc never shows through the glyph.
                Circle()
                    .fill(Color.black)
                    .frame(width: markerSize + 5, height: markerSize + 5)
                    .position(markerPoint)
                    .blendMode(.destinationOut)

                // Marker
                if isNight {
                    let moonForeground: Color = (colorScheme == .light)
                        ? Color.black.opacity(0.60)   // strong enough to show on white
                        : (isThemed ? Color.white.opacity(0.92)
                                    : Color.primary.opacity(0.90))

                    let moonShadowColor: Color = (colorScheme == .light)
                        ? Color.white.opacity(0.60)  // subtle rim so it doesn't look flat
                        : (isThemed ? Color.black.opacity(0.12)
                                    : Color.black.opacity(0.20))

                    Image(systemName: "moon.stars.fill")
                        .font(
                            .system(
                                size: (colorScheme == .light ? markerSize + 2 : markerSize + 1) + (isThemed ? 1 : 0),
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(moonForeground)
                        .shadow(
                            color: moonShadowColor,
                            radius: 1,
                            x: 0,
                            y: 0
                        )
                        .position(markerPoint)
                        .zIndex(1)
                } else {
                    Image(systemName: "sun.max.fill")
                        .font(
                            .system(
                                size: colorScheme == .light ? markerSize + 1 : markerSize,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.yellow)
                        .shadow(
                            color: isThemed ? Color.black.opacity(0.18) : .clear,
                            radius: isThemed ? 1 : 0,
                            x: 0,
                            y: isThemed ? 1 : 0
                        )
                        .position(markerPoint)
                        .zIndex(1)
                }
                // Optional horizon trees (daytime only)
                // Draw AFTER the marker so a tall tree can overlap the sun/moon.
                if showsHorizonTrees && !isNight {
                    // Random positions between 0.2 and 0.8 of the horizon span (wider spread).
                    // Generated onAppear and stored in state so it doesn't jitter during normal redraws.
                    let fracs: [CGFloat] = (horizonTreeFractionsState.count == 4)
                        ? horizonTreeFractionsState
                        // Fallback (stable) positions across the horizon.
                        : [0.22, 0.44, 0.64, 0.84]

                    // Use SF Symbols' generic tree. (There isn't a reliable evergreen symbol across iOS versions.)
                    let iconNames = ["tree.fill", "tree.fill", "tree.fill", "tree.fill"]

                    // More natural size variation: tiny shrubs + a couple taller trees.
                    // (All relative to `horizonTreeSize` so the caller can scale the whole look.)
                    let sizes: [CGFloat] = [
                        horizonTreeSize * 0.32, // shrub
                        horizonTreeSize * 0.58, // small tree
                        horizonTreeSize * 0.92, // tall tree
                        horizonTreeSize * 0.46  // medium shrub/tree
                    ]

                    // Compensate Y for varying sizes so bases feel like they sit on the horizon.
                    // Larger glyphs need to be nudged upward a bit; smaller ones downward.
                    let baselineSize = horizonTreeSize * 0.55
                    let baselineCompensation: CGFloat = 0.60

                    ForEach(0..<4, id: \.self) { i in
                        let yAdjust = (sizes[i] - baselineSize) * baselineCompensation
                        Image(systemName: iconNames[i])
                            .font(.system(size: sizes[i], weight: .regular))
                            .foregroundStyle(treeColor)
                            .position(
                                x: hx0 + (hx2 - hx0) * fracs[i],
                                y: horizonY - horizonTreeYOffset - yAdjust
                            )
                            .zIndex(10)
                    }
                }
            }
            .compositingGroup() // needed for destinationOut hole punch
            .contentShape(Rectangle())
            .onTapGesture {
                guard enablesTapRefresh else { return }

                // Let the parent refresh its notion of "now" (and therefore sun position).
                onTapRefresh?()

                // Also re-roll tree positions so the horizon decor feels alive.
                regenerateHorizonTrees()
            }
            .onAppear {
                if showsHorizonTrees {
                    regenerateHorizonTrees()
                }
            }
            .onChange(of: showsHorizonTrees) {
                if showsHorizonTrees {
                    regenerateHorizonTrees()
                }
            }
        }
        .frame(height: height)
        // Default: do not intercept touches. Enable explicitly when you want tap-to-refresh.
        .allowsHitTesting(enablesTapRefresh)
    }
    
    private func regenerateHorizonTrees() {
        // Randomize on each appearance so the trees don't feel "stuck".
        // Keep stable while this view instance is alive.
        let seed = UInt64(Date().timeIntervalSince1970 * 1000)

        // Allow trees to sit a bit closer together while still guaranteeing no overlap.
        // (minGap is in normalized horizon-width units; smaller = closer.)
        horizonTreeFractionsState = Self.randomFractions(count: 4, in: 0.08...0.92, minGap: 0.085, seed: seed)
    }

    private static func randomFractions(
        count: Int,
        in range: ClosedRange<Double>,
        minGap: Double? = nil,
        seed: UInt64
    ) -> [CGFloat] {
        guard count > 0 else { return [] }

        var s = seed &+ 0x9E3779B97F4A7C15
        func nextUnit() -> Double {
            // Simple LCG (deterministic)
            s = 6364136223846793005 &* s &+ 1442695040888963407
            // Take high bits for better distribution
            let x = (s >> 33) & 0x7FFFFFFF
            return Double(x) / Double(0x7FFFFFFF)
        }

        let lo = range.lowerBound
        let hi = range.upperBound
        let span = max(0.000_001, hi - lo)
        let gap = minGap ?? 0

        // If the requested gap is impossible for the given count/range, just ignore it.
        let maxPossibleGap = span / Double(max(count - 1, 1))
        let effectiveGap = (gap > 0 && gap <= maxPossibleGap) ? gap : 0

        // Rejection sampling: try a few times to get nicely-spaced points.
        // (Count is tiny here, so this is cheap.)
        let maxAttempts = 40
        for _ in 0..<maxAttempts {
            let vals: [Double] = (0..<count).map { _ in
                lo + span * nextUnit()
            }.sorted()

            if effectiveGap <= 0 {
                return vals.map { CGFloat($0) }
            }

            var ok = true
            for i in 1..<vals.count {
                if (vals[i] - vals[i - 1]) < effectiveGap {
                    ok = false
                    break
                }
            }

            if ok {
                return vals.map { CGFloat($0) }
            }
        }

        // Fallback: evenly spaced positions with a small deterministic jitter.
        if count == 1 {
            return [CGFloat(lo + span * 0.5)]
        }

        let usableSpan = max(0, span - effectiveGap * Double(count - 1))
        let start = lo + usableSpan * 0.5

        var out: [Double] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            // Even spacing + a tiny jitter (kept within half the slack between gaps).
            let base = start + Double(i) * effectiveGap
            let jitterSlack = max(0, usableSpan / Double(count))
            let jitter = (nextUnit() - 0.5) * min(jitterSlack, effectiveGap * 0.25)
            out.append(min(max(base + jitter, lo), hi))
        }

        // Ensure sorted + within bounds.
        out = out.sorted().map { min(max($0, lo), hi) }
        return out.map { CGFloat($0) }
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }

    private static func quadBezierPoint(p0: CGPoint, p1: CGPoint, p2: CGPoint, t: Double) -> CGPoint {
        let tt = CGFloat(t)
        let one = 1 - tt
        let x = one * one * p0.x + 2 * one * tt * p1.x + tt * tt * p2.x
        let y = one * one * p0.y + 2 * one * tt * p1.y + tt * tt * p2.y
        return CGPoint(x: x, y: y)
    }
}

/// Computes sun progress (0...1) from sunrise/sunset and current time.
func sunProgress(sunrise: Date, sunset: Date, now: Date = Date()) -> Double {
    if sunset <= sunrise { return now < sunrise ? 0 : 1 }
    if now <= sunrise { return 0 }
    if now >= sunset { return 1 }

    let total = sunset.timeIntervalSince(sunrise)
    guard total > 0 else { return 0 }

    let elapsed = now.timeIntervalSince(sunrise)
    return min(max(elapsed / total, 0), 1)
}

