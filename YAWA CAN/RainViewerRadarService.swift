//
//  RainViewerRadarService.swift
//

import Foundation

/// RainViewer weather-maps endpoint:
/// https://api.rainviewer.com/public/weather-maps.json
final class RainViewerRadarService {

    private let endpoint = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!
    private let session: URLSession

    struct RadarFreshness: Equatable {
        /// Seconds between now and the provider's `generated` timestamp.
        let generatedLagSeconds: Int?
        /// Seconds between now and the newest frame time found in `past` + `nowcast`.
        let latestFrameLagSeconds: Int?

        /// True when either lag exceeds the threshold.
        func isStale(thresholdSeconds: Int) -> Bool {
            if let g = generatedLagSeconds, g > thresholdSeconds { return true }
            if let f = latestFrameLagSeconds, f > thresholdSeconds { return true }
            return false
        }

        var summary: String {
            let g = generatedLagSeconds.map { "\($0)s" } ?? "-"
            let f = latestFrameLagSeconds.map { "\($0)s" } ?? "-"
            return "generatedLag=\(g) latestFrameLag=\(f)"
        }
    }

    /// Computes how stale the provider feed is.
    /// - Parameter thresholdSeconds: Recommended default: 3600 (1 hour).
    func radarFreshness(from maps: RainViewerWeatherMapsResponse, now: Int = Int(Date().timeIntervalSince1970)) -> RadarFreshness {
        let generated = maps.generated
        let past = maps.radar.past ?? []
        let nowcast = maps.radar.nowcast ?? []
        let latest = (past + nowcast).map { $0.time }.max()

        let genLag: Int? = {
            guard let generated, generated > 0 else { return nil }
            return max(0, now - generated)
        }()

        let latestLag: Int? = {
            guard let latest, latest > 0 else { return nil }
            return max(0, now - latest)
        }()

        return RadarFreshness(generatedLagSeconds: genLag, latestFrameLagSeconds: latestLag)
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchWeatherMaps() async throws -> RainViewerWeatherMapsResponse {
        // Cache-bust the URL so CDNs/proxies are less likely to hand us a stored object.
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970))))
        comps?.queryItems = items

        guard let url = comps?.url else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15

        // Stronger “don’t serve me cached” signals (helps with some CDNs/proxies).
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")

        let (data, resp) = try await session.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys

        let decoded = try decoder.decode(RainViewerWeatherMapsResponse.self, from: data)

        return decoded
    }

}

// MARK: - Models

struct RainViewerWeatherMapsResponse: Decodable {
    let version: String?
    let generated: Int?
    let host: String
    let radar: Radar

    struct Radar: Decodable {
        let past: [Frame]?
        let nowcast: [Frame]?
    }

    struct Frame: Decodable, Equatable {
        let time: Int
        let path: String
    }
}
