//
//  RadarStage0View.swift
//  YAWA
//
//  Created by Keith Sharman on 2/24/26.
//


import SwiftUI
import MapKit

struct RadarStage0View: View {
    var body: some View {
        RadarStage0MapView(
            center: CLLocationCoordinate2D(latitude: 30.2672, longitude: -97.7431), // Austin-ish
            span: MKCoordinateSpan(latitudeDelta: 3.0, longitudeDelta: 3.0),
            framePath: "/v2/radar/1771905000" // TEMP: hardcode a known-good frame for Stage 0
        )
        .ignoresSafeArea()
    }
}

struct RadarStage0MapView: UIViewRepresentable {
    let center: CLLocationCoordinate2D
    let span: MKCoordinateSpan
    let framePath: String

    func makeUIView(context: Context) -> MKMapView {
        print("✅✅✅ RadarStage0View.swift makeUIView(interactive) LOADED — \(Date())")
        let map = MKMapView(frame: .zero)

        // Fixed region
        let region = MKCoordinateRegion(center: center, span: span)
        map.setRegion(region, animated: false)

        // Disable all interaction (touch + trackpad/keyboard gestures should have nothing to do)
        map.isZoomEnabled = false
        map.isScrollEnabled = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false

        // Extra hard-lock (helps on Mac Catalyst / trackpad gestures).
        map.isUserInteractionEnabled = false

        // Optional: reduce “Map” UI noise
        map.showsCompass = false
        map.showsScale = false
        map.pointOfInterestFilter = .excludingAll

        // Overlay
        let overlay = RainViewerStage0TileOverlay(framePath: framePath)
        overlay.canReplaceMapContent = false
        map.addOverlay(overlay, level: .aboveLabels)

        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Stage 0: do nothing. No churn.
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

final class RainViewerStage0TileOverlay: MKTileOverlay {
    private let host = "https://tilecache.rainviewer.com"
    private let framePath: String

    init(framePath: String) {
        self.framePath = framePath
        super.init(urlTemplate: nil)

        // Keep it simple. Start with 256pt tiles (MapKit tile grid).
        self.tileSize = CGSize(width: 256, height: 256)

        // RainViewer provider tiles only go up to z=7. If MapKit requests higher zooms
        // (which it will when the region span is small), you will get blank tiles.
        // Clamp here so MapKit never asks for unsupported provider zoom levels.
        self.minimumZ = 0
        self.maximumZ = 7

        self.canReplaceMapContent = false
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // RainViewer format you’ve been using:
        // {host}{framePath}/{tileSize}/{z}/{x}/{y}/{colorScheme}/{smooth}/{snow}.png
        let px = Int(tileSize.width)
        let colorScheme = 2
        let smooth = 1
        let snow = 0

        let urlString =
            "\(host)\(framePath)/\(px)/\(path.z)/\(path.x)/\(path.y)/\(colorScheme)/\(smooth)_\(snow).png"

        return URL(string: urlString)!
    }
}
