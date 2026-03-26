
import SwiftUI
import MapKit
import UIKit

// Simple value object describing the radar map target (center + title).

struct RadarTarget: Identifiable, Equatable {
    let id: UUID = UUID()
    let latitude: Double
    let longitude: Double
    let title: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Stage 0: fixed zoom, no interaction, single static RainViewer frame.
struct RadarView: View {
    let target: RadarTarget
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading: Bool = true
    @State private var errorText: String? = nil

    @State private var host: String? = nil
    @State private var framePath: String? = nil

    // MARK: - Stale feed banner

    @State private var staleRadarBanner: String? = nil
    @State private var tileIssueBanner: String? = nil

    private let service = RainViewerRadarService()

    private struct FrameInfo: Equatable {
        let time: Int
        let path: String
    }

    @State private var zoomStep: Int = 0
    @State private var mapCenter: CLLocationCoordinate2D
    @State private var mapTitle: String

    // Radar presentation controls
    @State private var radarPalette: RadarTileLayerView.RenderPalette = .nwsClassic

    // Reverse geocode (city/state) for title updates after pan/recenter
    @State private var geocodeTask: Task<Void, Never>? = nil
    @State private var lastGeocodedCenter: CLLocationCoordinate2D? = nil

    // Minimal animation state (Stage 1: play/pause through fetched frames)
    @State private var frames: [FrameInfo] = []
    @State private var frameIndex: Int = 0
    @State private var isPlaying: Bool = false
    @State private var playTask: Task<Void, Never>? = nil
    @State private var lastRollingPrewarmFrameIndex: Int = -1
    @State private var lastRollingPrewarmAt: CFTimeInterval = 0

    // MARK: - Debug (frame timestamp)

    #if DEBUG
    private var debugFrameTimestampText: String {
        guard !frames.isEmpty, frameIndex >= 0, frameIndex < frames.count else { return "" }
        let t = TimeInterval(frames[frameIndex].time)
        let date = Date(timeIntervalSince1970: t)
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .medium
        df.timeZone = TimeZone(secondsFromGMT: 0)

        let ageSec = Date().timeIntervalSince(date)
        let ageMin = Int(ageSec / 60)
        let ageStr = ageMin >= 0 ? "\(ageMin)m ago" : "in \(-ageMin)m"
        return "frame=\(frames[frameIndex].time) (UTC \(df.string(from: date))) • \(ageStr)"
    }
    #endif

    // MARK: - Timeline progress bar

    private var timeSpanMinutesForTimeline: Int {
        guard frames.count >= 2 else { return 0 }
        let t0 = frames.first?.time ?? 0
        let t1 = frames.last?.time ?? t0
        return Int(max(0, (t1 - t0) / 60))
    }
    private var playbackProgress: Double {
        guard frames.count >= 2 else { return 0 }
        // Clamp to [0, 1]. When looping, this still gives a stable position for the current frame.
        return min(1, max(0, Double(frameIndex) / Double(frames.count - 1)))
    }

    private var timeProgressBar: some View {
        Group {
            if frames.count >= 2 {
                GeometryReader { geo in
                    let w = max(geo.size.width, 1)

                    let inset: CGFloat = 10
                    let usableW = max(1, w - inset * 2)
                    let progressX = inset + (usableW * playbackProgress)

                    // Not too crowded.
                    let segments = 6
                    let spanMin = max(0, timeSpanMinutesForTimeline)

                    VStack(spacing: 4) {
                        ZStack {
                            // Single track
                            Capsule()
                                .fill(.primary.opacity(0.14))

                            // Interval tick marks
                            Canvas { context, size in
                                let tickH: CGFloat = 5
                                let y = (size.height - tickH) / 2
                                let step = usableW / CGFloat(segments)

                                var path = Path()
                                for i in 0...segments {
                                    let x = inset + (CGFloat(i) * step)
                                    path.addRoundedRect(
                                        in: CGRect(x: x - 0.5, y: y, width: 1.0, height: tickH),
                                        cornerSize: CGSize(width: 0.5, height: 0.5)
                                    )
                                }
                                context.fill(path, with: .color(.primary.opacity(0.20)))
                            }
                            .allowsHitTesting(false)

                            // Moving playhead tick
                            Rectangle()
                                .fill(.primary.opacity(0.92))
                                .frame(width: 2, height: 9)
                                .cornerRadius(1)
                                .offset(x: progressX - (w / 2))
                                .shadow(color: .black.opacity(0.14), radius: 1.5, x: 0, y: 1)
                        }
                        .frame(height: 7)

                        // Labels under ticks (sparse: every other tick)
                        HStack(spacing: 0) {
                            ForEach(0...segments, id: \.self) { i in
                                let minutesFromStart = Int(round(Double(i) * Double(spanMin) / Double(segments)))
                                let show = (i % 2 == 0) || i == segments
                                Text(show ? "-\(max(0, spanMin - minutesFromStart))m" : "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                // Keep it short and avoid collisions with attribution + right-side buttons.
                .frame(height: 7 + 4 + 12)
                .frame(maxWidth: 260)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
                .allowsHitTesting(false)
                .accessibilityLabel("Radar timeline")
                .accessibilityValue("Frame \(frameIndex + 1) of \(frames.count)")
            }
        }
    }
    
    @State private var isPreparingPlayback: Bool = false
    @State private var prewarmToken: UUID = UUID()
    @State private var rollingPrewarmPaths: [String] = []
    @State private var startupPrewarmPaths: [String] = []
    @State private var startAfterPrewarm: Bool = false

    private let frameInterval: UInt64 = 250_000_000 // 0.25s (reduce flashing)

    // Persisted radar opacity so Settings can control the default.
    @AppStorage("radarOpacity") private var radarOpacityStored: Double = 0.80

    // Token to force recentering the map view when changed.
    @State private var recenterToken: UUID = UUID()

   
   

    private struct GlassCircleButtonModifier: ViewModifier {
        let size: CGFloat

        func body(content: Content) -> some View {
            content
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
                // Slightly heavier material + shadow so the control reads like the toolbar “liquid glass” buttons.
                .background(.thickMaterial)
                .clipShape(Circle())
                // Stronger edge definition + subtle highlight.
                .overlay(
                    Circle()
                        .strokeBorder(.primary.opacity(0.18), lineWidth: 1)
                )
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                        .blendMode(.overlay)
                )
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
                .contentShape(Circle())
        }
    }

    private var radarOpacity: CGFloat {
        CGFloat(radarOpacityStored)
    }

    @Environment(\.scenePhase) private var scenePhase

    init(target: RadarTarget) {
        self.target = target
        _mapCenter = State(initialValue: target.coordinate)
        _mapTitle = State(initialValue: target.title)
    }

    private var fixedRegion: MKCoordinateRegion {
        // Base framing (your current “works” value)
        let baseLatDelta: CLLocationDegrees = 3.0

        // Each step scales span. (Negative = closer, positive = farther)
        // Tune these numbers however you like.
        let scalePerStep: Double = 1.18
        let scale = pow(scalePerStep, Double(zoomStep))

        let lat = mapCenter.latitude
        let latDelta = baseLatDelta * scale
        let lonDelta = latDelta / max(0.35, cos(lat * .pi / 180.0))

        return MKCoordinateRegion(
            center: mapCenter,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    private var shouldShowRecenterButton: Bool {
        if zoomStep != 0 { return true }

        let current = CLLocation(latitude: mapCenter.latitude, longitude: mapCenter.longitude)
        let original = CLLocation(latitude: target.coordinate.latitude, longitude: target.coordinate.longitude)

        return current.distance(from: original) > 5_000
    }

    private func stopPlayback() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    private func advanceFrame() {
        guard !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
        framePath = frames[frameIndex].path
        rollingPrewarmIfNeeded()

        #if DEBUG
        #endif
    }
    private func rollingPrewarmIfNeeded() {
        guard isPlaying else { return }
        guard host != nil else { return }
        guard !frames.isEmpty else { return }
        guard frameIndex != lastRollingPrewarmFrameIndex else { return }

        lastRollingPrewarmFrameIndex = frameIndex

        // Prefetch the next few frames (beyond the current frame) to reduce flashing.
        let count = frames.count
        let next1 = frames[(frameIndex + 1) % count].path
        let next2 = frames[(frameIndex + 2) % count].path
        let next3 = frames[(frameIndex + 3) % count].path
        let paths = [next1, next2, next3]

        // Always update the paths.
        rollingPrewarmPaths = paths

        // Throttle the heavy prewarm trigger so we don't kick a full prewarm job every frame.
        let now = CACurrentMediaTime()
        if now - lastRollingPrewarmAt >= 0.85 {
            lastRollingPrewarmAt = now
            prewarmToken = UUID()
        }
    }

    private func startPlayback() {
        guard playTask == nil else { return }
        guard !frames.isEmpty else { return }
        guard host != nil else { return }

        // Fast-start prewarm: only warm the current frame plus the next two frames.
        // This keeps startup responsive while rolling prewarm fills in the rest.
        let count = frames.count
        var paths: [String] = []

        func appendIfNeeded(_ path: String) {
            if !paths.contains(path) {
                paths.append(path)
            }
        }

        appendIfNeeded(frames[frameIndex].path)
        if count >= 2 { appendIfNeeded(frames[(frameIndex + 1) % count].path) }
        if count >= 3 { appendIfNeeded(frames[(frameIndex + 2) % count].path) }

        startupPrewarmPaths = paths

        isPreparingPlayback = true
        startAfterPrewarm = true
        prewarmToken = UUID()
    }

    private func beginPlaybackLoop() {
        // Guard again in case user hit Done while preparing.
        guard playTask == nil else { return }
        guard !frames.isEmpty else { return }
        isPlaying = true

        playTask = Task { [frameInterval] in
            let loopPause: UInt64 = 1_200_000_000 // 1.2s pause at the end before rewinding

            while !Task.isCancelled {
                // If we’re currently displaying the most recent frame (end of the timeline),
                // pause briefly before wrapping back to the start. This makes the loop feel
                // less “snappy” and gives the user time to register “now”.
                let shouldPauseAtEnd = await MainActor.run { () -> Bool in
                    guard isPlaying, frames.count >= 2 else { return false }
                    return frameIndex == (frames.count - 1)
                }

                if shouldPauseAtEnd {
                    try? await Task.sleep(nanoseconds: loopPause)
                    if Task.isCancelled { break }
                } else {
                    try? await Task.sleep(nanoseconds: frameInterval)
                    if Task.isCancelled { break }
                }

                await MainActor.run {
                    if isPlaying { advanceFrame() }
                }
            }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func rv0log(_ msg: String) {
    }

    private func stateAbbrev(_ state: String?) -> String? {
        guard let s = state?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // If already looks like an abbreviation, keep it.
        if s.count <= 3 { return s.uppercased() }
        // Fallback: keep full state name.
        return s
    }

    private struct CoordKey: Equatable {
        let lat: Double
        let lon: Double
        init(_ c: CLLocationCoordinate2D) {
            self.lat = c.latitude
            self.lon = c.longitude
        }
    }

    @MainActor
    private func scheduleTitleGeocode(for center: CLLocationCoordinate2D) {
        // Debounce + avoid spamming when center hasn’t meaningfully changed.
        let prev = lastGeocodedCenter
        lastGeocodedCenter = center

        if let prev {
            let a = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
            let b = CLLocation(latitude: center.latitude, longitude: center.longitude)
            if b.distance(from: a) < 5_000 { // <5km: ignore tiny changes
                return
            }
        }

        geocodeTask?.cancel()
        geocodeTask = Task { [center] in
            // Debounce a bit so a pan gesture only triggers once.
            try? await Task.sleep(nanoseconds: 650_000_000)
            if Task.isCancelled { return }

            let loc = CLLocation(latitude: center.latitude, longitude: center.longitude)
            let geocoder = CLGeocoder()

            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(loc)
                guard let pm = placemarks.first else { return }

                // Prefer locality (city). Fallback to subAdministrativeArea (county-ish) then administrativeArea.
                let city = pm.locality
                    ?? pm.subAdministrativeArea
                    ?? pm.name

                let state = stateAbbrev(pm.administrativeArea)

                if let city, let state {
                    mapTitle = "\(city), \(state)"
                } else if let city {
                    mapTitle = city
                } else {
                    // If we can’t resolve, keep whatever title we already have.
                }
            } catch {
                // Ignore geocode failures (offline, rate limit, etc.)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if let host, let currentFramePath = framePath {
                    RadarMapViewStage0(
                        recenterToken: recenterToken,
                        region: fixedRegion,
                        host: host,
                        framePath: currentFramePath,
                        currentCenter: $mapCenter,
                        showCrosshair: true,
                        isActive: scenePhase == .active,
                        onUserPan: {
                            stopPlayback()
                        },
                        prewarmToken: prewarmToken,
                        prewarmFramePaths: isPreparingPlayback ? startupPrewarmPaths : rollingPrewarmPaths,
                        onPrewarmFinished: { token in
                            // Only act if this is still the current request.
                            guard token == self.prewarmToken else { return }
                            guard self.isPreparingPlayback else { return }

                            self.isPreparingPlayback = false

                            if self.startAfterPrewarm {
                                self.startAfterPrewarm = false
                                self.beginPlaybackLoop()
                            }
                        },
                        onTileHealth: { health in
                            // Only surface this while playing (avoid noise while browsing).
                            guard isPlaying, !isPreparingPlayback else {
                                if tileIssueBanner != nil { tileIssueBanner = nil }
                                return
                            }

                            // Require enough samples so we don't flicker the banner.
                            guard health.requests >= 20 else {
                                if tileIssueBanner != nil { tileIssueBanner = nil }
                                return
                            }

                            if health.emptyRate >= 0.25 {
                                // Keep copy short; stale banner covers the "why" when applicable.
                                tileIssueBanner = "Some radar tiles are temporarily unavailable."
                            } else {
                                if tileIssueBanner != nil { tileIssueBanner = nil }
                            }
                        },
                        isFeedStale: staleRadarBanner != nil,
                        opacity : radarOpacity,
                        renderPalette: radarPalette
                    )
                        .ignoresSafeArea()

                    // Timeline progress bar across the bottom (kept short + centered, lifted above attribution)
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            timeProgressBar
                            Spacer()
                        }
                    }
                    .padding(.bottom, 24)

                    // Stale feed banner (when RainViewer is serving delayed frames)
                    if let msg = staleRadarBanner {
                        VStack {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .font(.caption)

                                Text(msg)
                                    .font(.caption)
                                    .lineLimit(2)

                                Spacer(minLength: 8)

                                Button {
                                    Task { await loadLatestFrame() }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Refresh radar")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                            )
                            .padding(.horizontal, 12)
                            .padding(.top, 10)

                            Spacer()
                        }
                        .zIndex(250)
                        .allowsHitTesting(true)
                    }

                    // Partial/missing tiles banner (only when it matters)
                    if let msg = tileIssueBanner {
                        VStack {
                            HStack(spacing: 10) {
                                Image(systemName: "square.grid.3x3.topleft.filled")
                                    .symbolRenderingMode(.hierarchical)
                                    .font(.caption)

                                Text(msg)
                                    .font(.caption)
                                    .lineLimit(2)

                                Spacer(minLength: 8)

                                Button {
                                    Task { await loadLatestFrame() }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Refresh radar")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                            )
                            .padding(.horizontal, 12)
                            .padding(.top, staleRadarBanner != nil ? 54 : 10)

                            Spacer()
                        }
                        .zIndex(245)
                        .allowsHitTesting(true)
                    }

                    #if DEBUG
                    // Debug: show the selected frame timestamp so we can verify we’re not seeing stale tiles.
                    VStack {
                        HStack {
                            Text(debugFrameTimestampText)
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.55))
                                .clipShape(Capsule())
                                .padding(.leading, 12)
                                .padding(.top, 10)
                            Spacer()
                        }
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    #endif

                    // Zoom controls (Stage 1B) + Recenter (Stage 1C)
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()

                            VStack(spacing: 10) {
                                // On-map Play/Pause (one-handed)
                                Button {
                                    togglePlayback()
                                } label: {
                                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                        .font(.headline.weight(.semibold))
                                }
                                .disabled(frames.isEmpty)
                                .modifier(GlassCircleButtonModifier(size: 44))
                                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                                Button {
                                    // Closer (smaller span)
                                    zoomStep = max(zoomStep - 1, -6)
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .modifier(GlassCircleButtonModifier(size: 38))
                                .accessibilityLabel("Zoom in")

                                Button {
                                    // Farther (larger span)
                                    zoomStep = min(zoomStep + 1, 6)
                                } label: {
                                    Image(systemName: "minus")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .modifier(GlassCircleButtonModifier(size: 38))
                                .accessibilityLabel("Zoom out")

                                ZStack {
                                    Button {
                                        // Recenter / reset to the default framing, and jump back
                                        // to the newest frame so the result feels deterministic.
                                        stopPlayback()
                                        zoomStep = 0
                                        mapCenter = target.coordinate
                                        if !frames.isEmpty {
                                            frameIndex = max(0, frames.count - 1)
                                            framePath = frames[frameIndex].path
                                        }
                                        recenterToken = UUID()
                                    } label: {
                                        Image(systemName: "location.fill")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .modifier(GlassCircleButtonModifier(size: 38))
                                    .accessibilityLabel("Recenter")
                                    .opacity(shouldShowRecenterButton ? 1 : 0)
                                    .allowsHitTesting(shouldShowRecenterButton)
                                }
                                .frame(width: 38, height: 38)
                            }
                            .padding(.trailing, 14)
                            .padding(.bottom, 18)
                            .animation(.easeInOut(duration: 0.18), value: shouldShowRecenterButton)
                        }
                    }
                } else {
                    Color.clear.ignoresSafeArea()
                }

                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading radar…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                
                if isPreparingPlayback {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Preparing radar…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if let errorText {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title2)

                        Text(errorText)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle(mapTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        stopPlayback()
                        dismiss()
                    }
                }
            }
            .task(id: target.id) {
                await loadLatestFrame()
            }
            .onDisappear {
                stopPlayback()
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Stop playback when the app is backgrounded or becomes inactive (e.g. screen lock).
                if newPhase != .active {
                    stopPlayback()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                stopPlayback()
            }
            .onChange(of: CoordKey(mapCenter)) { _, newKey in
                // Keep title in sync with user pan / recenter.
                scheduleTitleGeocode(for: CLLocationCoordinate2D(latitude: newKey.lat, longitude: newKey.lon))
            }
        }
    }

    @MainActor
    private func loadLatestFrame() async {
        isLoading = true
        stopPlayback()
        errorText = nil
        staleRadarBanner = nil
        host = nil
        framePath = nil
        mapTitle = target.title
        // Kick an initial geocode for the starting center.
        scheduleTitleGeocode(for: mapCenter)

        do {
            let maps = try await service.fetchWeatherMaps()

            // Detect stale / delayed feed (server-side issue, not local cache).
            // Show a small banner so users (and us during dev) know when frames are old.
            let freshness = service.radarFreshness(from: maps)
            if freshness.isStale(thresholdSeconds: 60 * 60) { // 1 hour
                let lagSec = freshness.latestFrameLagSeconds ?? freshness.generatedLagSeconds ?? 0
                let hr = Double(lagSec) / 3600.0
                let hrStr = String(format: "%.1f", hr)

                #if DEBUG
                let genHr = String(format: "%.1f", Double(freshness.generatedLagSeconds ?? 0) / 3600.0)
                let latestHr = String(format: "%.1f", Double(freshness.latestFrameLagSeconds ?? 0) / 3600.0)
                staleRadarBanner = "Radar feed delayed (~\(hrStr)h). Showing last available frames. (gen=\(genHr)h latest=\(latestHr)h)"
                #else
                staleRadarBanner = "Radar feed is delayed (~\(hrStr)h). Showing last available frames."
                #endif
            } else {
                staleRadarBanner = nil
            }

            // Stage 0/1: build a simple frame list (prefer past frames for now).
            let allPastFrames = maps.radar.past ?? []
            let nowcastFrames = maps.radar.nowcast ?? []

            // Keep the playback window tighter so the loop returns to “now” faster.
            // RainViewer past frames are typically ~10 minutes apart, so 9 frames ≈ 90 minutes.
            let maxPastFrames = 9
            let pastFrames = Array(allPastFrames.suffix(maxPastFrames))

            // Minimal plan: animate through past frames. (We can revisit nowcast later.)
            frames = pastFrames.map { FrameInfo(time: $0.time, path: $0.path) }

            // Choose initial frame: most recent past frame; if none, fall back to most recent nowcast.
            if let lastPast = pastFrames.last {
                frameIndex = max(0, frames.count - 1)
                host = maps.host
                framePath = lastPast.path
            } else if let lastNow = nowcastFrames.last {
                frames = nowcastFrames.map { FrameInfo(time: $0.time, path: $0.path) }
                frameIndex = max(0, frames.count - 1)
                host = maps.host
                framePath = lastNow.path
            } else {
                isLoading = false
                errorText = "No radar frames available."
                return
            }

            isLoading = false

        } catch {
            isLoading = false
            staleRadarBanner = nil
            errorText = "Radar unavailable. Please try again."
        }
    }
}

/// UIKit-backed map so we can hard-disable interactions and host a single MKTileOverlay.
private struct RadarMapViewStage0: UIViewRepresentable {
    let recenterToken: UUID
    let region: MKCoordinateRegion
    let host: String
    let framePath: String
    @Binding var currentCenter: CLLocationCoordinate2D
    let showCrosshair: Bool
    let isActive: Bool
    let onUserPan: () -> Void
    
    let prewarmToken: UUID
    let prewarmFramePaths: [String]
    let onPrewarmFinished: (UUID) -> Void
    let onTileHealth: (RadarTileLayerView.TileHealth) -> Void
    let isFeedStale: Bool
    let opacity: CGFloat
    let renderPalette: RadarTileLayerView.RenderPalette

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)

        // Allow panning again, but keep zoom/rotate/pitch locked so framing stays controlled.
        map.isScrollEnabled = true
        map.isZoomEnabled = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false

        // Extra hard-lock (helps on Mac Catalyst / mouse-wheel gestures).
        // Removed map.isUserInteractionEnabled = false as per instructions

        map.pointOfInterestFilter = .excludingAll

        // Increase base-map contrast (darker labels/roads) while keeping POIs/traffic off.
        if #available(iOS 17.0, *) {
            let config = MKStandardMapConfiguration(elevationStyle: .flat)
            // Muted reduces landcover/topographic shading and keeps the basemap clean under radar.
            config.emphasisStyle = .muted
            config.pointOfInterestFilter = .excludingAll
            config.showsTraffic = false
            map.preferredConfiguration = config
        } else {
            // Best available pre-iOS 17 equivalent.
            map.mapType = .mutedStandard
        }
        map.showsCompass = false
        map.showsScale = false
        map.showsUserLocation = false
        map.showsBuildings = false
        map.delegate = context.coordinator

        // Attach radar layer view under MapKit labels.
        context.coordinator.attachMapView(map)
        context.coordinator.attachRadarLayer(to: map)

        // Apply initial region after the map has a real size / window. MapKit may ignore setRegion
        // during initial creation (bounds = .zero) and keep the default world region until user interaction.
        DispatchQueue.main.async { [weak map] in
            guard let map else { return }
            context.coordinator.applyInitialRegion(map, region: region)
            // Overlay install is now handled by radarLayer
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak map] in
            guard let map else { return }
            context.coordinator.applyInitialRegion(map, region: region)
            // Overlay install is now handled by radarLayer
        }

        context.coordinator.setCurrentCenterBinding($currentCenter)
        if showCrosshair {
            context.coordinator.ensureCrosshair(on: map)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.setCurrentCenterBinding($currentCenter)
        context.coordinator.setOnUserPanHandler(onUserPan)
        context.coordinator.attachMapView(map)
        context.coordinator.setFeedStale(isFeedStale)
        context.coordinator.setActive(isActive)
        context.coordinator.setTileHealthHandler(onTileHealth)
        context.coordinator.setRenderPalette(renderPalette)

        let overlayKey = "\(host)|\(framePath)|\(opacity)"
        if context.coordinator.lastAppliedOverlayKey != overlayKey {
            context.coordinator.lastAppliedOverlayKey = overlayKey
            context.coordinator.updateRadar(host: host, framePath: framePath, opacity: opacity)
        }

        // If the map was created with zero bounds, ensure initial region gets applied once layout is real.
        context.coordinator.applyInitialRegionIfNeeded(map, region: region)
        context.coordinator.applyRecenterIfNeeded(map, region: region, token: recenterToken)

        // Apply region ONLY when it meaningfully changes (e.g., zoomStep changed).
        // This keeps Stage 0 stable while still allowing our programmatic zoom buttons.
        context.coordinator.applyRegionIfNeeded(map, region: region)

        context.coordinator.prewarmIfNeeded(token: prewarmToken, host: host, framePaths: prewarmFramePaths) {
            onPrewarmFinished(prewarmToken)
        }

        if showCrosshair {
            context.coordinator.ensureCrosshair(on: map)
        } else {
            context.coordinator.removeCrosshair(from: map)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var isActive: Bool = true
        private var onUserPanHandler: (() -> Void)?
        func setOnUserPanHandler(_ handler: @escaping () -> Void) { self.onUserPanHandler = handler }

        func setActive(_ active: Bool) {
            guard isActive != active else { return }
            isActive = active
            
            // Pause tile fetching when inactive/backgrounded to avoid churn.
            radarLayerA?.setFetchingEnabled(active)
            radarLayerB?.setFetchingEnabled(active)
        }

        private var lastRecenterToken: UUID?
        func applyRecenterIfNeeded(_ map: MKMapView, region: MKCoordinateRegion, token: UUID) {
            // Only act when the token changes.
            guard lastRecenterToken != token else { return }
            lastRecenterToken = token
            
            // Don't fight during live gestures.
            if userIsInteracting { return }
            
            // Mark programmatic so regionDidChange doesn't look like a user pan.
            isProgrammaticRegionChange = true
            lastProgrammaticRegionChangeAt = CACurrentMediaTime()
            map.setRegion(region, animated: false)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.isProgrammaticRegionChange = false
            }
            
            updateCrosshairPosition(on: map)
            updateRadarAfterLayout()
            
        }

        private var tileHealthHandler: ((RadarTileLayerView.TileHealth) -> Void)?
        
        func setTileHealthHandler(_ handler: @escaping (RadarTileLayerView.TileHealth) -> Void) {
            tileHealthHandler = handler
            radarLayerA?.onTileHealthUpdate = handler
            radarLayerB?.onTileHealthUpdate = handler
        }

        private var lastRegionSignature: String? = nil
        private var didApplyInitialRegion: Bool = false
        private var isProgrammaticRegionChange: Bool = false
        private var lastProgrammaticRegionChangeAt: CFTimeInterval = 0
        private var currentCenterBinding: Binding<CLLocationCoordinate2D>?

        private weak var mapViewRef: MKMapView?
        private var radarLayerA: RadarTileLayerView?
        private var radarLayerB: RadarTileLayerView?
        private var activeRadarIsA: Bool = true
        
        private var activeRadarLayer: RadarTileLayerView? {
            activeRadarIsA ? radarLayerA : radarLayerB
        }
        
      
        
        private var lastRadarHost: String = ""
        private var lastRadarFramePath: String = ""
        private var lastRadarOpacity: CGFloat = 0.80
        var lastAppliedOverlayKey: String = ""
        
        private weak var crosshairView: UIImageView?
        
        private var lastPrewarmToken: UUID?
        
        private var userIsInteracting: Bool = false
        private var didNotifyUserPanThisGesture: Bool = false
        
        func setFeedStale(_ stale: Bool) {
            radarLayerA?.isFeedStale = stale
            radarLayerB?.isFeedStale = stale
        }
        
        func setRenderPalette(_ palette: RadarTileLayerView.RenderPalette) {
            radarLayerA?.renderPalette = palette
            radarLayerB?.renderPalette = palette
        }
        
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // During initial setup MapKit may emit region change callbacks while still at its default
            // world/placeholder region. Don’t treat that as user interaction.
            guard didApplyInitialRegion else { return }
            if isProgrammaticRegionChange { return }

            userIsInteracting = true

            // Pause playback as soon as a real user pan gesture begins, not after the region settles.
            if !didNotifyUserPanThisGesture {
                didNotifyUserPanThisGesture = true
                onUserPanHandler?()
            }
        }
        
        func prewarmIfNeeded(token: UUID, host: String, framePaths: [String], completion: @escaping () -> Void) {
            // If we already ran this token, report completion immediately.
            if lastPrewarmToken == token {
                completion()
                return
            }
            lastPrewarmToken = token
            guard let map = mapViewRef else {
                completion()
                return
            }
            if framePaths.isEmpty {
                completion()
                return
            }
            activeRadarLayer?.prewarm(mapView: map, host: host, framePaths: framePaths, opacity: lastRadarOpacity) {
                completion()
            }
        }
        
        func setCurrentCenterBinding(_ binding: Binding<CLLocationCoordinate2D>) {
            self.currentCenterBinding = binding
        }
        
        func attachMapView(_ map: MKMapView) {
            self.mapViewRef = map
        }
        
        func attachRadarLayer(to map: MKMapView) {
            if radarLayerA != nil || radarLayerB != nil { return }

            func makeLayer() -> RadarTileLayerView {
                let v = RadarTileLayerView(frame: map.bounds)
                v.isUserInteractionEnabled = false
                v.translatesAutoresizingMaskIntoConstraints = true
                v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                v.clipsToBounds = false
                v.onTileHealthUpdate = tileHealthHandler
                return v
            }

            let a = makeLayer()
            let b = makeLayer()

            // Place under MapKit labels by inserting into the overlay container when available.
            if let overlayContainer = map.subviews.first(where: { String(describing: type(of: $0)).contains("Overlay") }) {
                a.frame = overlayContainer.bounds
                b.frame = overlayContainer.bounds
                overlayContainer.addSubview(a)
                overlayContainer.addSubview(b)
            } else {
                a.frame = map.bounds
                b.frame = map.bounds
                map.addSubview(a)
                map.addSubview(b)
            }

            a.alpha = 1.0
            b.alpha = 0.0

            radarLayerA = a
            radarLayerB = b
            activeRadarIsA = true
        }

        func layoutRadarLayers() {
            guard let map = mapViewRef else { return }

            if let overlayContainer = map.subviews.first(where: { String(describing: type(of: $0)).contains("Overlay") }) {
                radarLayerA?.frame = overlayContainer.bounds
                radarLayerB?.frame = overlayContainer.bounds
            } else {
                radarLayerA?.frame = map.bounds
                radarLayerB?.frame = map.bounds
            }
        }
        
        func updateRadar(host: String, framePath: String, opacity: CGFloat) {
            guard let map = mapViewRef else { return }
            
            // Track last requested radar params.
            lastRadarHost = host
            lastRadarFramePath = framePath
            lastRadarOpacity = opacity
            
            // Use a single active layer update. The double-buffer layer crossfade was causing
            // visible flashing when tiles arrive asynchronously.
            guard let active = activeRadarLayer else { return }
            active.update(mapView: map, host: host, framePath: framePath, opacity: opacity)
            
            updateRadarAfterLayout()
        }
        
        private func updateRadarAfterLayout() {
            guard let map = mapViewRef else { return }
            guard let active = activeRadarLayer else { return }
            guard !lastRadarHost.isEmpty, !lastRadarFramePath.isEmpty else { return }

            layoutRadarLayers()

            // Try now (if we have bounds), then again shortly after.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                active.update(mapView: map, host: self.lastRadarHost, framePath: self.lastRadarFramePath, opacity: self.lastRadarOpacity)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                active.update(mapView: map, host: self.lastRadarHost, framePath: self.lastRadarFramePath, opacity: self.lastRadarOpacity)
            }
        }
        
        func applyInitialRegionIfNeeded(_ map: MKMapView, region: MKCoordinateRegion) {
            guard !didApplyInitialRegion else { return }
            guard map.bounds.size.width > 0, map.bounds.size.height > 0 else { return }
            applyInitialRegion(map, region: region)
        }
        
        func applyInitialRegion(_ map: MKMapView, region: MKCoordinateRegion) {
            // Only apply when we have a real size.
            guard map.bounds.size.width > 0, map.bounds.size.height > 0 else { return }
            
            didApplyInitialRegion = true
            lastRegionSignature = signature(for: region)
            
            isProgrammaticRegionChange = true
            lastProgrammaticRegionChangeAt = CACurrentMediaTime()
            map.setRegion(region, animated: false)
            // Keep recenter baseline aligned with the current view lifecycle.
            if lastRecenterToken == nil { lastRecenterToken = UUID() }
            // After region is applied, keep programmatic suppression on briefly so MapKit's
            // delayed regionDidChange doesn't look like a user pan.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.isProgrammaticRegionChange = false
            }
            
            updateCrosshairPosition(on: map)
            updateRadarAfterLayout()
            
        }
        
        func applyRegionIfNeeded(_ map: MKMapView, region: MKCoordinateRegion) {
            // Don't fight live user gestures; let the map move freely.
            if userIsInteracting { return }
            
            // Don’t attempt “zoom enforcement” until we’ve successfully applied the initial region.
            // Otherwise we can fight MapKit’s initial world-region and cause redundant setRegion calls.
            guard didApplyInitialRegion else { return }
            
            // Stage 1 behavior: ONLY enforce zoom/span changes (e.g. zoomStep changes).
            // Do NOT re-apply region because the user panned (center changed), and do NOT
            // re-apply because longitudeDelta differs slightly (it can vary with latitude).
            let current = map.region
            
            // We treat latitudeDelta as the authoritative zoom signal.
            let spanEps: CLLocationDegrees = 0.00025
            let latSpanClose = abs(current.span.latitudeDelta - region.span.latitudeDelta) < spanEps
            
            if latSpanClose {
                // Still advance the signature so we don't keep re-evaluating this same zoom target.
                // Signature intentionally ignores center and longitudeDelta.
                lastRegionSignature = "latSpan=\(String(format: "%.6f", region.span.latitudeDelta))"
                return
            }
            
            // Zoom changed: apply region (center is whatever SwiftUI currently wants).
            let sig = "latSpan=\(String(format: "%.6f", region.span.latitudeDelta))"
            guard sig != lastRegionSignature else { return }
            lastRegionSignature = sig
            
            isProgrammaticRegionChange = true
            lastProgrammaticRegionChangeAt = CACurrentMediaTime()
            map.setRegion(region, animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.isProgrammaticRegionChange = false
            }
            
            updateCrosshairPosition(on: map)
            updateRadarAfterLayout()
            
        }
        
        private func signature(for region: MKCoordinateRegion) -> String {
            // Round to reduce noise from floating point and prevent thrash.
            func r(_ v: CLLocationDegrees) -> Double { (v * 10_000).rounded() / 10_000 }
            return "c=\(r(region.center.latitude)),\(r(region.center.longitude))|s=\(r(region.span.latitudeDelta)),\(r(region.span.longitudeDelta))"
        }
        
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            // Called continuously during pans/scrolls. Keep the radar compositor in sync so
            // tiles don't appear to "stick" until the gesture ends.
            layoutRadarLayers()
            updateCrosshairPosition(on: mapView)
            updateRadarAfterLayout()
        }
        
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let dt = CACurrentMediaTime() - lastProgrammaticRegionChangeAt

            layoutRadarLayers()

            // During initial setup MapKit can briefly report its default region (often centered in the US)
            // before our initial setRegion fully sticks. Never treat those as user pans.
            guard didApplyInitialRegion else {
                didNotifyUserPanThisGesture = false
                updateCrosshairPosition(on: mapView)
                updateRadarAfterLayout()
                return
            }

            // Ignore programmatic changes, and ignore delayed callbacks from a recent programmatic
            // setRegion ONLY if the user was not actively interacting.
            if isProgrammaticRegionChange || (dt <= 0.45 && !userIsInteracting) {
                didNotifyUserPanThisGesture = false
                updateCrosshairPosition(on: mapView)
                updateRadarAfterLayout()
                return
            }

            // Otherwise: treat as user-driven.
            userIsInteracting = false
            didNotifyUserPanThisGesture = false
            currentCenterBinding?.wrappedValue = mapView.region.center

            updateCrosshairPosition(on: mapView)
            updateRadarAfterLayout()
        }
        
        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            guard fullyRendered else { return }
            layoutRadarLayers()
            updateCrosshairPosition(on: mapView)
            updateRadarAfterLayout()
        }
        
        // MARK: - Crosshair
        
        func ensureCrosshair(on map: MKMapView) {
            if crosshairView != nil { return }
            
            // Simple center reticle: a plain plus sign (less visually loud than the red scope).
            let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            let iv = UIImageView(image: UIImage(systemName: "plus", withConfiguration: cfg))
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.tintColor = .black
            iv.isUserInteractionEnabled = false
            iv.backgroundColor = .clear
            iv.isOpaque = false
            iv.layer.zPosition = 10_000
            
            map.addSubview(iv)
            crosshairView = iv
            
            updateCrosshairPosition(on: map)
        }
        
        func updateCrosshairPosition(on map: MKMapView) {
            guard let iv = crosshairView else { return }
            let centerPoint = map.convert(map.region.center, toPointTo: map)
            iv.center = centerPoint
        }
        
        func removeCrosshair(from _: MKMapView) {
            crosshairView?.removeFromSuperview()
            crosshairView = nil
        }
    }
}

// Hybrid radar tile compositor view (for Stage 0, under MapKit labels)
final class RadarTileLayerView: UIView {
    struct TileHealth: Equatable {
        let requests: Int
        let empties: Int
        var emptyRate: Double {
            guard requests > 0 else { return 0 }
            return Double(empties) / Double(requests)
        }
    }

    // Called (throttled) on the main thread with recent tile health stats.
    var onTileHealthUpdate: ((TileHealth) -> Void)?
    private struct TileKey: Hashable {
        let host: String
        let framePath: String
        let z: Int
        let x: Int
        let y: Int
        let px: Int

        var urlString: String {
            "\(host)\(framePath)/\(px)/\(z)/\(x)/\(y)/2/1_0.png"
        }

        // Stable view identity (does NOT include framePath) so tiles can keep their previous
        // image while a new frame is loading (reduces flashing / blank squares).
        var viewKey: String {
            "Z=\(z)|X=\(x)|Y=\(y)|PX=\(px)"
        }

        // Cache identity MUST include framePath so we don't mix frames.
        var cacheKey: String {
            "\(host)|\(framePath)|\(px)|\(z)|\(x)|\(y)"
        }
    }

    enum RenderPalette {
        case native
        case nwsClassic
    }

    // Default to the previous look.
    var renderPalette: RenderPalette = .nwsClassic

    private let memCache = NSCache<NSString, UIImage>()

    // Memory guardrails: prevent unbounded growth if the user pans/zooms around for a long time.
    // NSCache will still evict under memory pressure, but explicit caps keep behavior predictable.
    private let memCacheCountLimit: Int = 900
    private let memCacheTotalCostLimitBytes: Int = 72 * 1024 * 1024 // ~72 MB
    override init(frame: CGRect) {
        super.init(frame: frame)
        memCache.countLimit = memCacheCountLimit
        memCache.totalCostLimit = memCacheTotalCostLimitBytes
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        memCache.countLimit = memCacheCountLimit
        memCache.totalCostLimit = memCacheTotalCostLimitBytes
    }

    // Approximate image memory cost for NSCache accounting.
    private func imageCostBytes(_ image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        // Fallback: rough estimate for 256x256 RGBA.
        return 256 * 256 * 4
    }
    private var inFlight: [String: [((UIImage?) -> Void)]] = [:]
    private let lock = NSLock()

    private let fetchQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "radar.tiles.fetch"
        q.maxConcurrentOperationCount = 4
        return q
    }()

    func setFetchingEnabled(_ enabled: Bool) {
        fetchQueue.isSuspended = !enabled
        if !enabled {
            // Drop any queued work and callbacks so we don’t keep work alive in background.
            fetchQueue.cancelAllOperations()
            lock.lock()
            inFlight.removeAll()
            lock.unlock()
        }
    }

    private var negativeCache: [String: Date] = [:]
    private let negativeTTL: TimeInterval = 45
    private var rateLimitCache: [String: Date] = [:]
    private let rateLimitTTLNormal: TimeInterval = 25
    private let rateLimitTTLStale: TimeInterval = 45

    // Short-lived cache for "empty but 200" tiles (provider hiccup / blank PNG).
    // We treat these as a miss so we never paint blank squares.
    //
    // NOTE: We cache empties ONLY per-frame cacheKey (ck) so we don't accidentally
    // suppress tiles in new areas after panning.
    private struct EmptyTileEntry {
        var expiresAt: Date
        var count: Int
    }

    private var emptyTileCache: [String: EmptyTileEntry] = [:]

    // Rolling health window for detecting widespread missing/empty tiles.
    private let healthWindowSeconds: CFTimeInterval = 2.5
    private var healthEvents: [(t: CFTimeInterval, isEmpty: Bool)] = []
    private var lastHealthPublishAt: CFTimeInterval = 0

    // Adaptive TTLs (seconds). When the provider feed is stale, edge caches tend to serve
    // the same empty tile repeatedly; back off harder to reduce churn.
    private let emptyTileTTLNormal: TimeInterval = 5
    private let emptyTileTTLStale: TimeInterval = 18

    // Set by the representable/coordinator when RainViewer reports a delayed feed.
    var isFeedStale: Bool = false

    #if DEBUG
    private var dbgEmptyTileDetected: Int = 0
    private var dbgEmptyTileCacheHits: Int = 0
    private var dbgLastEmptyLogAt: CFTimeInterval = 0

    private func dbgLogEmpty(reason: String, cacheKey: String, ttl: TimeInterval? = nil, bytes: Int? = nil) {
        let now = CACurrentMediaTime()
        // Throttle logs so we don’t spam the console.
        if now - dbgLastEmptyLogAt < 1.0 { return }
        dbgLastEmptyLogAt = now
        _ = reason
        _ = cacheKey
        _ = ttl
        _ = bytes
    }

    private func dbgLogFinalMiss(tk: TileKey, statusCode: Int?, bytes1: Int?, bytes2: Int?) {
        let now = CACurrentMediaTime()
        // Separate throttle for final miss logging so we capture failures without flooding.
        if now - dbgLastEmptyLogAt < 0.35 { return }
        dbgLastEmptyLogAt = now
        _ = tk
        _ = statusCode
        _ = bytes1
        _ = bytes2
    }
    #endif

    private var generation: UInt64 = 0
    private var lastUpdateAt: CFTimeInterval = 0
    private var currentHost: String = ""
    private var currentFramePath: String = ""

    // Reusable image views
    private var tileViews: [String: UIImageView] = [:]

    func update(mapView: MKMapView, host: String, framePath: String, opacity: CGFloat) {
        // Throttle heavy recomputation during continuous panning.
        let now = CACurrentMediaTime()
        if now - lastUpdateAt < 0.033 { return } // ~30 fps
        lastUpdateAt = now

        // Only treat this as a new "generation" when the underlying frame changes.
        // During panning we want stable tiles (no clearing/flicker).
        let frameChanged = (host != currentHost) || (framePath != currentFramePath)
        if frameChanged {
            currentHost = host
            currentFramePath = framePath
            generation &+= 1
        }
        let gen = generation
        let shouldCrossfade = frameChanged

        // Capture the palette on the main thread so background fetch work never touches
        // the view's main-actor isolated state.
        let palette = renderPalette
        let emptyTTL: TimeInterval = isFeedStale ? emptyTileTTLStale : emptyTileTTLNormal
        
        // Determine zoom based on current region span + view width.
        let width = max(Double(mapView.bounds.width), 1)
        let lonDelta = max(mapView.region.span.longitudeDelta, 0.0000001)
        let uiZ = Int(floor(log2(360.0 * width / 256.0 / lonDelta)))
        let z = max(0, min(9, uiZ))
        let providerZ = min(7, z)

        let screenScale = window?.screen.scale ?? mapView.window?.windowScene?.screen.scale ?? 2.0
        let px = (screenScale >= 3.0) ? 256 : 256

        // Get visible bounds in lat/lon.
        let w = mapView.bounds.width
        let h = mapView.bounds.height
        guard w > 2, h > 2 else { return }

        let tl = mapView.convert(CGPoint(x: 0, y: 0), toCoordinateFrom: mapView)
        let br = mapView.convert(CGPoint(x: w, y: h), toCoordinateFrom: mapView)

        let minLat = min(tl.latitude, br.latitude)
        let maxLat = max(tl.latitude, br.latitude)
        let minLon = min(tl.longitude, br.longitude)
        let maxLon = max(tl.longitude, br.longitude)

        // Compute tile range.
        let n = Double(1 << providerZ)

        func lon2x(_ lon: Double) -> Int {
            Int(floor((lon + 180.0) / 360.0 * n))
        }

        func lat2y(_ lat: Double) -> Int {
            let latRad = lat * Double.pi / 180.0
            let v = (1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / Double.pi) / 2.0
            return Int(floor(v * n))
        }

        var x0 = lon2x(minLon)
        var x1 = lon2x(maxLon)
        var y0 = lat2y(maxLat)
        var y1 = lat2y(minLat)

        let maxIndex = (1 << providerZ) - 1

        // 1-tile padding so we prefetch just beyond the visible bounds (reduces transient blanks).
        x0 = max(0, min(maxIndex, x0 - 1))
        x1 = max(0, min(maxIndex, x1 + 1))
        y0 = max(0, min(maxIndex, y0 - 1))
        y1 = max(0, min(maxIndex, y1 + 1))

        var needed: Set<String> = []

        for x in x0...x1 {
            for y in y0...y1 {
                let tk = TileKey(host: host, framePath: framePath, z: providerZ, x: x, y: y, px: px)
                let viewKey = tk.viewKey
                let ck = tk.cacheKey
                needed.insert(viewKey)

                // Compute the tile frame in screen points.
                let tileFrame = tileFrameInView(mapView: mapView, z: providerZ, x: x, y: y)

                let iv: UIImageView
                if let existing = tileViews[viewKey] {
                    iv = existing
                } else {
                    iv = UIImageView(frame: tileFrame)
                    iv.contentMode = .scaleToFill
                    iv.clipsToBounds = true
                    iv.backgroundColor = .clear
                    tileViews[viewKey] = iv
                    addSubview(iv)
                }

                iv.frame = tileFrame
                iv.alpha = opacity

                // Set image (cached or fetch).
                if let img = memCache.object(forKey: ck as NSString) {
                    // Crossfade ONLY on frame changes (not on pan/zoom) to avoid a “milky” feel.
                    if shouldCrossfade, iv.image != nil {
                        UIView.transition(
                            with: iv,
                            duration: 0.15,
                            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
                            animations: { iv.image = img },
                            completion: nil
                        )
                    } else {
                        iv.image = img
                    }
                } else {
                    // IMPORTANT: do NOT blank. Keep whatever is currently shown until we have a real tile.
                    fetchTile(tk, generation: gen, palette: palette, emptyTTL: emptyTTL) { [weak self] img in
                        guard let self else { return }
                        guard self.generation == gen else { return }
                        DispatchQueue.main.async {
                            guard let v = self.tileViews[viewKey] else { return }
                            // Never replace an existing image with nil.
                            if let img {
                                if shouldCrossfade, v.image != nil {
                                    UIView.transition(
                                        with: v,
                                        duration: 0.15,
                                        options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
                                        animations: { v.image = img },
                                        completion: nil
                                    )
                                } else {
                                    v.image = img
                                }
                            }
                            v.alpha = opacity
                        }
                    }
                }
            }
        }

        // Remove views that are no longer needed.
        for (k, v) in tileViews {
            if !needed.contains(k) {
                v.removeFromSuperview()
                tileViews.removeValue(forKey: k)
            }
        }
    }

    private func tileFrameInView(mapView: MKMapView, z: Int, x: Int, y: Int) -> CGRect {
        // Convert tile bounds from WebMercator into coordinates, then into view points.
        let n = Double(1 << z)

        func x2lon(_ x: Double) -> Double {
            x / n * 360.0 - 180.0
        }

        func y2lat(_ y: Double) -> Double {
            let t = Double.pi * (1.0 - 2.0 * y / n)
            return (180.0 / Double.pi) * atan(sinh(t))
        }

        let lonL = x2lon(Double(x))
        let lonR = x2lon(Double(x + 1))
        let latT = y2lat(Double(y))
        let latB = y2lat(Double(y + 1))

        let tl = CLLocationCoordinate2D(latitude: latT, longitude: lonL)
        let br = CLLocationCoordinate2D(latitude: latB, longitude: lonR)

        let pTL = mapView.convert(tl, toPointTo: mapView)
        let pBR = mapView.convert(br, toPointTo: mapView)

        let x0 = min(pTL.x, pBR.x)
        let y0 = min(pTL.y, pBR.y)
        let x1 = max(pTL.x, pBR.x)
        let y1 = max(pTL.y, pBR.y)

        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func recordTileEvent(isEmpty: Bool) {
        let now = CACurrentMediaTime()
        healthEvents.append((t: now, isEmpty: isEmpty))

        // Prune old events.
        let cutoff = now - healthWindowSeconds
        if healthEvents.count > 128 {
            healthEvents = healthEvents.filter { $0.t >= cutoff }
        } else {
            while let first = healthEvents.first, first.t < cutoff {
                healthEvents.removeFirst()
            }
        }

        publishHealthIfNeeded(now: now)
    }

    private func publishHealthIfNeeded(now: CFTimeInterval) {
        // Throttle to avoid UI churn.
        if now - lastHealthPublishAt < 0.6 { return }
        lastHealthPublishAt = now

        let req = healthEvents.count
        if req == 0 { return }
        let empties = healthEvents.reduce(0) { $0 + ($1.isEmpty ? 1 : 0) }
        let health = TileHealth(requests: req, empties: empties)

        DispatchQueue.main.async { [weak self] in
            self?.onTileHealthUpdate?(health)
        }
    }

    private func fetchTile(_ tk: TileKey, generation: UInt64, palette: RenderPalette, emptyTTL: TimeInterval, ignoreGeneration: Bool = false, completion: @escaping (UIImage?) -> Void) {
        let ck = tk.cacheKey
        if fetchQueue.isSuspended {
            completion(nil)
            return
        }
        recordTileEvent(isEmpty: false)

        // Opportunistic cleanup (keeps dicts from growing unbounded).
        let now = Date()
        if emptyTileCache.count > 512 {
            emptyTileCache = emptyTileCache.filter { $0.value.expiresAt > now }
        }
        if negativeCache.count > 512 {
            negativeCache = negativeCache.filter { now.timeIntervalSince($0.value) < negativeTTL }
        }
        if rateLimitCache.count > 512 {
            let ttl = isFeedStale ? rateLimitTTLStale : rateLimitTTLNormal
            rateLimitCache = rateLimitCache.filter { now.timeIntervalSince($0.value) < ttl }
        }

        // Short-lived cache for "empty" tiles (non-404). Prevents blank squares from being painted.
        if let entry = emptyTileCache[ck] {
            let now = Date()
            if entry.expiresAt > now {
                recordTileEvent(isEmpty: true)
                #if DEBUG
                dbgEmptyTileCacheHits &+= 1
                dbgLogEmpty(reason: "cache-hit", cacheKey: ck, ttl: entry.expiresAt.timeIntervalSince(now))
                #endif
                completion(nil)
                return
            } else {
                // Expired; drop it.
                emptyTileCache.removeValue(forKey: ck)
            }
        }

        // Negative cache (404)
        if let t = negativeCache[ck], now.timeIntervalSince(t) < negativeTTL {
            completion(nil)
            return
        }

        // Rate-limit cache (429). Back off per exact tile so we do not hammer RainViewer.
        let rateLimitTTL = isFeedStale ? rateLimitTTLStale : rateLimitTTLNormal
        if let t = rateLimitCache[ck], now.timeIntervalSince(t) < rateLimitTTL {
            completion(nil)
            return
        }

        lock.lock()
        if inFlight[ck] != nil {
            inFlight[ck]?.append(completion)
            lock.unlock()
            return
        } else {
            inFlight[ck] = [completion]
            lock.unlock()
        }

        fetchQueue.addOperation { [weak self] in
            guard let self else { return }
            if !ignoreGeneration, self.generation != generation {
                self.drain(ck, img: nil)
                return
            }

            guard let url = URL(string: tk.urlString) else {
                self.drain(ck, img: nil)
                return
            }

            // Helper: fetch data with a specific cache policy and a short timeout.
            func fetchData(_ u: URL, cachePolicy: URLRequest.CachePolicy, timeout: TimeInterval) -> (Data?, Int?) {
                var req = URLRequest(url: u)
                req.cachePolicy = cachePolicy
                req.timeoutInterval = timeout

                let sem = DispatchSemaphore(value: 0)
                var outData: Data? = nil
                var outStatus: Int? = nil

                URLSession.shared.dataTask(with: req) { data, resp, _ in
                    outStatus = (resp as? HTTPURLResponse)?.statusCode
                    outData = data
                    sem.signal()
                }.resume()

                _ = sem.wait(timeout: .now() + timeout + 0.25)
                return (outData, outStatus)
            }

            // First attempt: allow cache (fast path).
            var outImg: UIImage? = nil
            var statusCode: Int? = nil

            let (data1, st1) = fetchData(url, cachePolicy: .returnCacheDataElseLoad, timeout: 3.0)
            statusCode = st1

            // If the response is 404, bail early (negative cache handled below).
            if statusCode == 404 {
                self.drain(ck, img: nil)
                return
            }

            // If RainViewer is rate-limiting us, do NOT retry with a cache-buster.
            // That only increases pressure and makes 429 storms worse.
            if statusCode == 429 {
                DispatchQueue.main.async {
                    self.rateLimitCache[ck] = Date()
                }
                self.drain(ck, img: nil)
                return
            }

            let bytes1 = data1?.count
            var bytes2: Int? = nil
            func decodeAndValidate(_ data: Data?) -> UIImage? {
                guard let data else { return nil }

                // Corruption guard: reject extremely tiny payloads.
                if data.count < 128 { return nil }

                guard let baseImg = UIImage(data: data) else { return nil }

                // Some provider responses decode as a valid image but are effectively empty
                // (all/near-all transparent or solid single-color placeholders).
                if self.isEffectivelyEmptyTile(baseImg) { return nil }

                switch palette {
                case .nwsClassic:
                    return self.recolorToNWSClassic(baseImg) ?? baseImg
                case .native:
                    return baseImg
                }
            }

            if let decoded = decodeAndValidate(data1) {
                DispatchQueue.main.async {
                    self.emptyTileCache.removeValue(forKey: ck)
                }
                outImg = decoded
            } else {
                // Second attempt: bypass local/edge caches with a cache-buster.
                var bustedURL = url
                if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    let ts = Int(Date().timeIntervalSince1970)
                    var items = comps.queryItems ?? []
                    items.append(URLQueryItem(name: "ts", value: String(ts)))
                    comps.queryItems = items
                    if let u2 = comps.url { bustedURL = u2 }
                }

                let (data2, st2) = fetchData(bustedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeout: 3.0)
                bytes2 = data2?.count
                if let st2 { statusCode = st2 }
                if statusCode == 429 {
                    DispatchQueue.main.async {
                        self.rateLimitCache[ck] = Date()
                    }
                    self.drain(ck, img: nil)
                    return
                }

                if statusCode == 404 {
                    self.drain(ck, img: nil)
                    return
                }

                if let decoded2 = decodeAndValidate(data2) {
                    DispatchQueue.main.async {
                        self.emptyTileCache.removeValue(forKey: ck)
                    }
                    outImg = decoded2
                } else {
                    #if DEBUG
                    self.dbgLogFinalMiss(tk: tk, statusCode: statusCode, bytes1: bytes1, bytes2: bytes2)
                    #endif

                    // Still empty: mark short-lived empty cache so we don't hammer.
                    DispatchQueue.main.async {
                        let now = Date()

                        // Adaptive empty-tile backoff (LESS aggressive): if a specific tile keeps coming back empty,
                        // increase the suppression window for that *exact* frame+z+x+y cacheKey.
                        let prev = self.emptyTileCache[ck]
                        let nextCount = min((prev?.count ?? 0) + 1, 4)

                        // Base TTL comes from `emptyTTL` (normal vs stale feed). Back off mildly.
                        let backoff = pow(1.20, Double(nextCount - 1))
                        let maxTTL: TimeInterval = self.isFeedStale ? 30 : 15
                        let ttl = min(maxTTL, emptyTTL * backoff)

                        self.emptyTileCache[ck] = EmptyTileEntry(expiresAt: now.addingTimeInterval(ttl), count: nextCount)

                        self.recordTileEvent(isEmpty: true)

                        #if DEBUG
                        self.dbgEmptyTileDetected &+= 1
                        // Prefer the retry payload size if present; otherwise fall back to the first attempt.
                        self.dbgLogEmpty(reason: "retry-empty", cacheKey: ck, ttl: ttl, bytes: bytes2 ?? bytes1)
                        #endif
                    }
                }
            }

            if statusCode == 404 {
                DispatchQueue.main.async {
                    self.negativeCache[ck] = Date()
                }
                self.drain(ck, img: nil)
                return
            }

            if statusCode == 429 {
                DispatchQueue.main.async {
                    self.rateLimitCache[ck] = Date()
                }
                self.drain(ck, img: nil)
                return
            }

            if let outImg {
                // Cache exactly what we display (already recolored if NWS Classic).
                // Provide a cost so totalCostLimit can evict predictably.
                let cost = self.imageCostBytes(outImg)
                self.memCache.setObject(outImg, forKey: ck as NSString, cost: cost)
            }

            self.drain(ck, img: outImg)
        }
    }

    func prewarm(mapView: MKMapView, host: String, framePaths: [String], opacity _: CGFloat, completion: (() -> Void)? = nil) {
        let width = max(Double(mapView.bounds.width), 1)
        let lonDelta = max(mapView.region.span.longitudeDelta, 0.0000001)
        let uiZ = Int(floor(log2(360.0 * width / 256.0 / lonDelta)))
        let z = max(0, min(9, uiZ))
        let providerZ = min(7, z)
        let px = 256

        let palette = renderPalette
        
        let emptyTTL: TimeInterval = isFeedStale ? emptyTileTTLStale : emptyTileTTLNormal
        
        let w = mapView.bounds.width
        let h = mapView.bounds.height
        guard w > 2, h > 2 else { completion?(); return }

        let tl = mapView.convert(CGPoint(x: 0, y: 0), toCoordinateFrom: mapView)
        let br = mapView.convert(CGPoint(x: w, y: h), toCoordinateFrom: mapView)

        let minLat = min(tl.latitude, br.latitude)
        let maxLat = max(tl.latitude, br.latitude)
        let minLon = min(tl.longitude, br.longitude)
        let maxLon = max(tl.longitude, br.longitude)

        let n = Double(1 << providerZ)

        func lon2x(_ lon: Double) -> Int {
            Int(floor((lon + 180.0) / 360.0 * n))
        }
        func lat2y(_ lat: Double) -> Int {
            let latRad = lat * Double.pi / 180.0
            let v = (1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / Double.pi) / 2.0
            return Int(floor(v * n))
        }

        var x0 = lon2x(minLon)
        var x1 = lon2x(maxLon)
        var y0 = lat2y(maxLat)
        var y1 = lat2y(minLat)

        let maxIndex = (1 << providerZ) - 1

        // Match update(): add 1-tile padding so edge tiles are warmed before playback starts.
        x0 = max(0, min(maxIndex, x0 - 1))
        x1 = max(0, min(maxIndex, x1 + 1))
        y0 = max(0, min(maxIndex, y0 - 1))
        y1 = max(0, min(maxIndex, y1 + 1))

        // Keep startup prewarm intentionally small so playback begins quickly.
        let maxFramesToPrewarm = min(3, framePaths.count)
        let paths = Array(framePaths.prefix(maxFramesToPrewarm))
        guard !paths.isEmpty else { completion?(); return }

        let gen = generation

        let group = DispatchGroup()

        for fp in paths {
            for x in x0...x1 {
                for y in y0...y1 {
                    let tk = TileKey(host: host, framePath: fp, z: providerZ, x: x, y: y, px: px)
                    let ck = tk.cacheKey
                    if memCache.object(forKey: ck as NSString) != nil { continue }

                    group.enter()
                    fetchTile(tk, generation: gen, palette: palette, emptyTTL: emptyTTL, ignoreGeneration: true) { _ in
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            completion?()
        }
    }
    
    private func drain(_ ck: String, img: UIImage?) {
        lock.lock()
        let cbs = inFlight.removeValue(forKey: ck) ?? []
        lock.unlock()
        for cb in cbs { cb(img) }
    }
    // MARK: - Palette remap (NWS-ish)

    private func recolorToNWSClassic(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }

        let width = cg.width
        let height = cg.height

        // Safety: avoid extreme allocations if a tile comes in at an unexpected size.
        if width <= 0 || height <= 0 { return nil }
        if width > 1024 || height > 1024 { return nil }

        let bytesPerPixel = 4
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
        if rowOverflow { return nil }

        let (totalBytes, totalOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        if totalOverflow { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let buf = ctx.data else { return nil }
        let ptr = buf.bindMemory(to: UInt8.self, capacity: totalBytes)

        struct Stop { let t: Float; let r: Float; let g: Float; let b: Float }
        let stops: [Stop] = [
            // Slightly darker NWS-ish palette.
            .init(t: 0.00, r: 0.62, g: 0.82, b: 0.62), // very light green (darker)
            .init(t: 0.40, r: 0.02, g: 0.56, b: 0.05), // green (darker)
            .init(t: 0.70, r: 0.90, g: 0.86, b: 0.12), // yellow (darker)
            .init(t: 0.84, r: 0.92, g: 0.50, b: 0.10), // orange (darker)
            .init(t: 0.93, r: 0.84, g: 0.12, b: 0.12), // red (darker)
            .init(t: 1.00, r: 0.52, g: 0.06, b: 0.66)  // purple (darker)
        ]

        @inline(__always)
        func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

        @inline(__always)
        func mapIntensity(_ v: Float) -> (Float, Float, Float) {
            let x = max(0, min(1, v))
            var i = 0
            while i + 1 < stops.count, x > stops[i + 1].t { i += 1 }
            let s0 = stops[i]
            let s1 = stops[min(i + 1, stops.count - 1)]
            let denom = max(0.0001, (s1.t - s0.t))
            let tt = (x - s0.t) / denom
            return (
                lerp(s0.r, s1.r, tt),
                lerp(s0.g, s1.g, tt),
                lerp(s0.b, s1.b, tt)
            )
        }

        let (count, countOverflow) = width.multipliedReportingOverflow(by: height)
        if countOverflow { return nil }

        for p in 0..<count {
            let o = p * 4
            let r = ptr[o]
            let g = ptr[o + 1]
            let b = ptr[o + 2]
            let a = ptr[o + 3]

            if a == 0 { continue }

            let maxc = max(r, max(g, b))
            let minc = min(r, min(g, b))
            let nearGray = (Int(maxc) - Int(minc)) < 18

            let bi = Int(b)
            let gi = Int(g)
            let ri = Int(r)

            let cyanEdge = (gi >= 110) && (bi >= 110) && (ri <= 140) && (abs(gi - bi) <= 70)
            let blueishEdge = (bi >= 70) && (bi >= gi) && (bi >= ri)
            let edgeLike = (nearGray && blueishEdge) || cyanEdge

            let thresh = nearGray ? 12 : 24
            let precipLike = bi >= 60 && bi > gi + thresh && bi > ri + thresh

            if !precipLike && !edgeLike { continue }

            let dom = Float(bi - max(ri, gi)) / 255.0
            var intensity = max(0, min(1, dom * 1.02))
            // Slightly higher gamma -> darker overall response.
            intensity = pow(intensity, 1.24)

            if nearGray {
                // Boundary pixels: clamp harder to reduce glow.
                intensity = min(intensity, 0.18)
            }

            let (nr, ng, nb) = mapIntensity(intensity)

            let af = Float(a) / 255.0
            // Overall brightness scale (lower = darker palette).
            let scale = (0.46 + 0.34 * af)
            let rr = max(0, min(1, nr * scale))
            let gg = max(0, min(1, ng * scale))
            let bb = max(0, min(1, nb * scale))

            ptr[o]     = UInt8(max(0, min(255, Int(rr * 255.0))))
            ptr[o + 1] = UInt8(max(0, min(255, Int(gg * 255.0))))
            ptr[o + 2] = UInt8(max(0, min(255, Int(bb * 255.0))))
            // alpha unchanged
        }

        guard let outCG = ctx.makeImage() else { return nil }
        return UIImage(cgImage: outCG, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Heuristic: returns true if the decoded tile looks like a provider "placeholder" tile
    /// (opaque/mostly-opaque and essentially a single solid color).
    ///
    /// IMPORTANT: A fully transparent tile is VALID for RainViewer (it means "no precip").
    /// We must not treat that as empty, otherwise old precip will linger and animation will look wrong.
    private func isEffectivelyEmptyTile(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }

        // Sample into a tiny buffer to keep this cheap.
        let sampleW = 32
        let sampleH = 32
        let bytesPerPixel = 4
        let bytesPerRow = sampleW * bytesPerPixel
        let totalBytes = bytesPerRow * sampleH

        var data = [UInt8](repeating: 0, count: totalBytes)
        guard let ctx = CGContext(
            data: &data,
            width: sampleW,
            height: sampleH,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))

        // Determine how much of the tile is actually opaque.
        // Fully transparent is VALID ("no precip"), so only consider placeholder detection
        // when the tile is mostly opaque.
        var opaqueCount = 0
        let opaqueAlpha: UInt8 = 250

        for i in stride(from: 0, to: totalBytes, by: 4) {
            if data[i + 3] >= opaqueAlpha { opaqueCount += 1 }
        }

        let totalPx = sampleW * sampleH
        let opaqueRatio = Double(opaqueCount) / Double(totalPx)

        // If it isn't mostly opaque, it's either real radar (often partially transparent)
        // or a legitimate "clear" tile.
        if opaqueRatio < 0.97 { return false }

        // For mostly-opaque tiles, check if RGB is essentially constant (solid-color placeholder).
        var rMin: UInt8 = 255, rMax: UInt8 = 0
        var gMin: UInt8 = 255, gMax: UInt8 = 0
        var bMin: UInt8 = 255, bMax: UInt8 = 0

        for i in stride(from: 0, to: totalBytes, by: 4) {
            if data[i + 3] < opaqueAlpha { continue }
            let r = data[i + 0]
            let g = data[i + 1]
            let b = data[i + 2]
            rMin = min(rMin, r); rMax = max(rMax, r)
            gMin = min(gMin, g); gMax = max(gMax, g)
            bMin = min(bMin, b); bMax = max(bMax, b)
        }

        let solidTolerance: UInt8 = 2
        let looksSolid =
            (rMax &- rMin) <= solidTolerance &&
            (gMax &- gMin) <= solidTolerance &&
            (bMax &- bMin) <= solidTolerance

        return looksSolid
    }
}

