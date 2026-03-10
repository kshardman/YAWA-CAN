import Foundation
import MapKit
import UIKit

final class RainViewerCachingTileOverlay: MKTileOverlay {

    /// Pixel size RainViewer serves in the URL path.
    enum PixelSize: Int { case s256 = 256, s512 = 512 }

    /// How we post-process RainViewer tiles after download.
    enum RenderPalette {
        /// Use the tile image exactly as delivered by RainViewer.
        case native
        /// Remap Universal Blue-style intensity to an NWS-ish green/yellow/orange/red scale.
        case nwsClassic
    }

    private var host: String
    private var framePath: String
    private let colorScheme: Int
    private let smooth: Int
    private let snow: Int
    private let renderPalette: RenderPalette

    /// Bump this when changing recolor math so old cached tiles don't persist.
    private static let paletteVersion = 5

    // MARK: - Diagnostics / provider quirks

    /// Enable lightweight tile logs when debugging (kept off by default).
    static var isLoggingEnabled: Bool = false

    /// Some RainViewer responses are HTTP 200 but return a tiny PNG (often transparent/placeholder).
    /// On some devices/scales, requesting 512px tiles can yield these tiny placeholders while 256px returns real data.
    private static let tinyPNGByteThreshold = 900

    /// Max zoom we will request from RainViewer itself (clamped to provider support; RainViewer tops out at z=7).
    let providerMaxZoom: Int

    private(set) var lastRequestedZoom: Int = 0

    // IMPORTANT: tell MapKit the overlay covers the world
    override var boundingMapRect: MKMapRect { .world }

    // In-memory tile cache
    private static let memCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.countLimit = 1500
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()

    // In-flight request dedupe
    private static var inFlight: [String: [((Data?, Error?) -> Void)]] = [:]
    private static let lock = NSLock()
    
    // Negative cache for missing tiles (404) so we don't hammer the provider and create persistent gaps.
    private static var negativeCache: [String: Date] = [:]
    private static let negativeCacheTTL: TimeInterval = 45

    // Prebuilt transparent PNG tiles (used as a graceful fallback so MapKit never shows holes).
    private static var transparentTileCache: [Int: Data] = [:]

    private static func transparentPNG(pixels: Int) -> Data {
        if let d = transparentTileCache[pixels] { return d }
        let size = CGSize(width: pixels, height: pixels)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let d = img.pngData() ?? Data()
        transparentTileCache[pixels] = d
        return d
    }

    private static func isNegativelyCached(_ key: String) -> Bool {
        if let t = negativeCache[key] {
            if Date().timeIntervalSince(t) < negativeCacheTTL { return true }
            negativeCache.removeValue(forKey: key)
        }
        return false
    }

    private static func rememberNegative(_ key: String) {
        negativeCache[key] = Date()
    }

    // Signal when at least one tile has been loaded (for fade timing)
    var didLoadFirstTile: (() -> Void)?
    private var firstTileSent = false

    // Frame generation token to prevent stale in-flight tiles from firing first-tile callbacks
    // after `updateFrame(...)` switches the overlay to a new framePath.
    private var frameGeneration: UInt64 = 0

    private let session: URLSession

    init(
        host: String,
        framePath: String,
        colorScheme: Int = 2,
        smooth: Bool = true,
        snow: Bool = false,
        providerMaxZoom: Int = 7,
        uiMaxZoom: Int = 12,
        renderPalette: RenderPalette = .native
    ) {
        self.host = host
        self.framePath = framePath
        self.colorScheme = colorScheme
        self.smooth = smooth ? 1 : 0
        self.snow = snow ? 1 : 0
        self.renderPalette = renderPalette
        // RainViewer only supports up to z=7. Higher zooms will return blank tiles.
        let hardMaxZoom = 7
        self.providerMaxZoom = min(providerMaxZoom, hardMaxZoom)

        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 15
        cfg.urlCache = .shared
        // Fewer parallel connections reduces throttling / partial-tile holes.
        cfg.httpMaximumConnectionsPerHost = 4
        // Helps during Wi‑Fi/LTE transitions; the request will wait briefly for connectivity.
        if #available(iOS 11.0, *) {
            cfg.waitsForConnectivity = true
        }
        self.session = URLSession(configuration: cfg)

        super.init(urlTemplate: nil)

        // Allow MapKit to request tiles beyond RainViewer's provider max (z=7).
        // For z > providerMaxZoom, `loadTile` will fetch the parent provider tile and crop/scale it (overzoom),
        // producing crisp tiles instead of blanks.
        self.minimumZ = 0
        self.maximumZ = uiMaxZoom

        self.isGeometryFlipped = false
        self.canReplaceMapContent = false

        // MKTileOverlay.tileSize is in *points*.
        // Keep it 256pt so MapKit uses a normal tile grid.
        self.tileSize = CGSize(width: 256, height: 256)
    }

    /// Update the tile source for a new radar frame without recreating the overlay.
    /// Call `MKTileOverlayRenderer.reloadData()` on the renderer after updating.
    func updateFrame(host: String, framePath: String) {
        self.host = host
        self.framePath = framePath
        // Bump generation so any in-flight callbacks from the prior frame can't trigger UI fades.
        self.frameGeneration &+= 1
        // Reset first-tile signal so the fade logic can wait on the new frame.
        self.firstTileSent = false
        // NOTE: Do not clear memCache on every frame change. Animation relies on tile reuse across frames;
        // clearing here forces full re-download storms and increases 429/timeout "holes".
        // If you ever need a hard reset (palette/host changes, debugging), do it explicitly elsewhere.
    }

    private func fireFirstTileIfNeeded(generation: UInt64) {
        // Ignore tiles that belong to a previous frame generation.
        guard generation == frameGeneration else { return }
        guard !firstTileSent else { return }
        firstTileSent = true
        DispatchQueue.main.async { self.didLoadFirstTile?() }
    }

    // MARK: - MKTileOverlay

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        #if DEBUG
        print("[RVCTO] loadTile z=\(path.z) x=\(path.x) y=\(path.y) scale=\(path.contentScaleFactor) maxProv=\(providerMaxZoom)")
        #endif
        lastRequestedZoom = path.z
        let generation = frameGeneration

        // Decide pixel size to request (always 256 for Stage 0)
        let pixelSize: PixelSize = .s256

        // Cache key MUST include the REQUESTED z/x/y because MapKit is placing into that slot.
        let outKey = "\(framePath)|OUT|\(pixelSize.rawValue)|\(path.z)|\(path.x)|\(path.y)|\(colorScheme)|\(smooth)_\(snow)|PAL=\(renderPalette)|V=\(Self.paletteVersion)" as NSString
        let outKeyString = outKey as String

        // 1) Output cache (already cropped/scaled if needed)
        if let cached = Self.memCache.object(forKey: outKey) {
            fireFirstTileIfNeeded(generation: generation)
            result(cached as Data, nil)
            return
        }

        // 2) Dedupe in-flight on the OUTPUT key
        Self.lock.lock()
        if Self.inFlight[outKeyString] != nil {
            Self.inFlight[outKeyString]?.append(result)
            Self.lock.unlock()
            return
        } else {
            Self.inFlight[outKeyString] = [result]
            Self.lock.unlock()
        }

        // Stage 0: MapKit may still request z>7 on some regions/device sizes when maximumZ allows it.
        // Handle via overzoom: fetch the parent provider tile (z=providerMaxZoom) and crop/scale.
        if path.z > providerMaxZoom {
            let dz = path.z - providerMaxZoom
            let parts = 1 << dz

            let parentX = path.x >> dz
            let parentY = path.y >> dz

            let mask = parts - 1
            let subX = path.x & mask
            let subY = path.y & mask

            #if DEBUG
            print("[RVCTO] overzoom reqZ=\(path.z) -> parentZ=\(providerMaxZoom) parent=(\(parentX),\(parentY)) sub=(\(subX),\(subY)) parts=\(parts)")
            #endif

            fetchProviderTile(
                pixelSize: pixelSize,
                z: providerMaxZoom,
                x: parentX,
                y: parentY
            ) { data, error in
                guard let data else {
                    self.finish(key: outKeyString, data: Self.transparentPNG(pixels: pixelSize.rawValue), error: nil, generation: generation)
                    return
                }

                guard let cropped = self.cropAndScaleOverzoom(
                    parentTileData: data,
                    parts: parts,
                    subX: subX,
                    subY: subY,
                    outputPixels: pixelSize.rawValue
                ) else {
                    self.finish(key: outKeyString, data: Self.transparentPNG(pixels: pixelSize.rawValue), error: nil, generation: generation)
                    return
                }

                let ns = cropped as NSData
                Self.memCache.setObject(ns, forKey: outKey, cost: ns.length)
                self.finish(key: outKeyString, data: cropped, error: nil, generation: generation)
            }

            return
        }

        // If MapKit asks for z <= providerMaxZoom, fetch directly and return.
        if path.z <= providerMaxZoom {
            fetchProviderTile(pixelSize: pixelSize, z: path.z, x: path.x, y: path.y) { data, error in
                // Do NOT cache tiny placeholder tiles (they cause persistent holes).
                if let d = data, d.count > Self.tinyPNGByteThreshold {
                    let ns = d as NSData
                    Self.memCache.setObject(ns, forKey: outKey, cost: ns.length)
                }
                if let data {
                    self.finish(key: outKeyString, data: data, error: nil, generation: generation)
                } else {
                    self.finish(key: outKeyString, data: Self.transparentPNG(pixels: pixelSize.rawValue), error: nil, generation: generation)
                }
            }
            return
        }

        // Stage 0: no overzoom path.
        result(nil, nil)
        return
    }

    // MARK: - Provider fetch

    private func fetchProviderTile(
        pixelSize: PixelSize,
        z: Int,
        x: Int,
        y: Int,
        completion: @escaping (Data?, Error?) -> Void
    ) {
        let key = "\(framePath)|PROV|\(pixelSize.rawValue)|\(z)|\(x)|\(y)|\(colorScheme)|\(smooth)_\(snow)|PAL=\(renderPalette)|V=\(Self.paletteVersion)" as NSString
        let keyString = key as String

        // Cache hit
        if let cached = Self.memCache.object(forKey: key) {
            completion(cached as Data, nil)
            return
        }

        // In-flight request dedupe on provider key
        Self.lock.lock()
        if Self.inFlight[keyString] != nil {
            Self.inFlight[keyString]?.append(completion)
            Self.lock.unlock()
            return
        } else {
            Self.inFlight[keyString] = [completion]
            Self.lock.unlock()
        }

        // Negative-cache: recently missing tile -> return transparent immediately.
        Self.lock.lock()
        let isNeg = Self.isNegativelyCached(keyString)
        Self.lock.unlock()
        if isNeg {
            self.finish(key: keyString, data: Self.transparentPNG(pixels: pixelSize.rawValue), error: nil, generation: self.frameGeneration)
            return
        }

        let urlString = "\(host)\(framePath)/\(pixelSize.rawValue)/\(z)/\(x)/\(y)/\(colorScheme)/\(smooth)_\(snow).png"

        if Self.isLoggingEnabled {
            print("[RV] REQ px=\(pixelSize.rawValue) z=\(z) x=\(x) y=\(y) frame=\(framePath)")
        }

        guard let url = URL(string: urlString) else {
            self.finish(key: keyString, data: Self.transparentPNG(pixels: pixelSize.rawValue), error: nil, generation: self.frameGeneration)
            return
        }

        func shouldRetry(statusCode: Int?, error: Error?) -> Bool {
            if let statusCode {
                if statusCode == 429 { return true }
                if (500...599).contains(statusCode) { return true }
                if statusCode == 408 { return true }
            }
            if let urlErr = error as? URLError {
                switch urlErr.code {
                case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed:
                    return true
                default:
                    break
                }
            }
            return false
        }

        func attempt(_ n: Int) {
            var req = URLRequest(url: url)
            req.cachePolicy = (n == 0) ? .returnCacheDataElseLoad : .reloadIgnoringLocalCacheData

            let task = session.dataTask(with: req) { [weak self] data, resp, error in
                guard let self else { return }

                let status = (resp as? HTTPURLResponse)?.statusCode

                if let status, status != 200 {
                    // 404: missing tile. Retry once, then negative-cache and return transparent.
                    if status == 404 {
                        #if DEBUG
                        print("[RVCTO] HTTP status=404 px=\(pixelSize.rawValue) z=\(z) x=\(x) y=\(y) attempt=\(n)")
                        #endif

                        if n == 0 {
                            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.35) {
                                attempt(1)
                            }
                            return
                        }

                        Self.lock.lock()
                        Self.rememberNegative(keyString)
                        Self.lock.unlock()

                        self.finish(key: keyString, data: Self.transparentPNG(pixels: pixelSize.rawValue), error: nil, generation: self.frameGeneration)
                        return
                    }

                    let httpErr = URLError(.badServerResponse)
                    if n < 2 && shouldRetry(statusCode: status, error: httpErr) {
                        let delay: TimeInterval = (n == 0) ? 0.15 : 0.35
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                            attempt(n + 1)
                        }
                        return
                    }

                    // Fail closed with transparent tile.
                    self.finish(key: keyString, data: Self.transparentPNG(pixels: pixelSize.rawValue), error: nil, generation: self.frameGeneration)
                    return
                }

                if let error {
                    if n < 2 && shouldRetry(statusCode: status, error: error) {
                        let delay: TimeInterval = (n == 0) ? 0.15 : 0.35
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                            attempt(n + 1)
                        }
                        return
                    }

                    self.finish(key: keyString, data: Self.transparentPNG(pixels: pixelSize.rawValue), error: nil, generation: self.frameGeneration)
                    return
                }

                guard let data else {
                    self.finish(key: keyString, data: Self.transparentPNG(pixels: pixelSize.rawValue), error: nil, generation: self.frameGeneration)
                    return
                }

                // Handle tiny placeholder PNGs.
                if data.count > 0, data.count <= Self.tinyPNGByteThreshold {
                    if Self.isLoggingEnabled {
                        print("[RV] TINY-200 bytes=\(data.count) px=\(pixelSize.rawValue) z=\(z) x=\(x) y=\(y) attempt=\(n) frame=\(self.framePath)")
                    }

                    if n < 2 {
                        let delay: TimeInterval = (n == 0) ? 0.15 : 0.35
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                            attempt(n + 1)
                        }
                        return
                    }

                    self.finish(key: keyString, data: Self.transparentPNG(pixels: pixelSize.rawValue), error: nil, generation: self.frameGeneration)
                    return
                }

                let remapped = self.applyRenderPaletteIfNeeded(to: data)

                if Self.isLoggingEnabled {
                    print("[RV] OK bytes=\(remapped.count) px=\(pixelSize.rawValue) z=\(z) x=\(x) y=\(y)")
                }

                let ns = remapped as NSData
                Self.memCache.setObject(ns, forKey: key, cost: ns.length)
                self.finish(key: keyString, data: remapped, error: nil, generation: self.frameGeneration)
            }

            task.resume()
        }

        attempt(0)
    }

    // MARK: - Overzoom crop+scale

    private func cropAndScaleOverzoom(
        parentTileData: Data,
        parts: Int,
        subX: Int,
        subY: Int,
        outputPixels: Int
    ) -> Data? {
        guard let img = UIImage(data: parentTileData),
              let cg = img.cgImage
        else { return nil }

        let cropSize = outputPixels / parts
        let cropX = subX * cropSize
        let cropY = subY * cropSize

        let rect = CGRect(x: cropX, y: cropY, width: cropSize, height: cropSize).integral
        guard let cropped = cg.cropping(to: rect) else { return nil }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputPixels, height: outputPixels))
        let out = renderer.image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0, width: outputPixels, height: outputPixels))
        }

        if let png = out.pngData() {
            return applyRenderPaletteIfNeeded(to: png)
        }
        return nil
    }

    // MARK: - Palette remap (NWS-ish)

    private func applyRenderPaletteIfNeeded(to pngData: Data) -> Data {
        guard renderPalette == .nwsClassic else { return pngData }

        return autoreleasepool {
            guard let img = UIImage(data: pngData) else { return pngData }
            guard let recolored = recolorToNWSClassic(img) else { return pngData }
            return recolored.pngData() ?? pngData
        }
    }

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

        let bitsPerComponent = 8

        // RGBA8
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let buf = ctx.data else { return nil }
        let ptr = buf.bindMemory(to: UInt8.self, capacity: totalBytes)

        // NWS-ish stops tuned for darker greens and reduced halo.
        struct Stop { let t: Float; let r: Float; let g: Float; let b: Float }
        let stops: [Stop] = [
            .init(t: 0.00, r: 0.68, g: 0.88, b: 0.68),
            .init(t: 0.40, r: 0.02, g: 0.62, b: 0.06),
            .init(t: 0.70, r: 0.98, g: 0.92, b: 0.15),
            .init(t: 0.84, r: 0.98, g: 0.60, b: 0.12),
            .init(t: 0.93, r: 0.92, g: 0.15, b: 0.15),
            .init(t: 1.00, r: 0.58, g: 0.08, b: 0.74)
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

        autoreleasepool {
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
                intensity = pow(intensity, 1.18)

                if nearGray {
                    intensity = min(intensity, 0.22)
                }

                let (nr, ng, nb) = mapIntensity(intensity)

                let af = Float(a) / 255.0
                let scale = (0.52 + 0.38 * af)
                let rr = max(0, min(1, nr * scale))
                let gg = max(0, min(1, ng * scale))
                let bb = max(0, min(1, nb * scale))

                ptr[o]     = UInt8(max(0, min(255, Int(rr * 255.0))))
                ptr[o + 1] = UInt8(max(0, min(255, Int(gg * 255.0))))
                ptr[o + 2] = UInt8(max(0, min(255, Int(bb * 255.0))))
                // alpha unchanged
            }
        }

        guard let outCG = ctx.makeImage() else { return nil }
        return UIImage(cgImage: outCG, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Helpers

    /// Upscales a PNG (typically 256px) to the requested pixel dimension (typically 512px).
    private func upscalePNGIfNeeded(_ pngData: Data, toPixels: Int) -> Data? {
        guard let img = UIImage(data: pngData) else { return nil }

        if Int(img.size.width * img.scale) == toPixels {
            return pngData
        }

        let size = CGSize(width: toPixels, height: toPixels)
        let renderer = UIGraphicsImageRenderer(size: size)
        let out = renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        return out.pngData()
    }

    // MARK: - Finish / drain

    private func finish(key: String, data: Data?, error: Error?, generation: UInt64) {
        if data != nil { fireFirstTileIfNeeded(generation: generation) }

        Self.lock.lock()
        let callbacks = Self.inFlight.removeValue(forKey: key) ?? []
        Self.lock.unlock()

        for cb in callbacks { cb(data, error) }
    }
}
