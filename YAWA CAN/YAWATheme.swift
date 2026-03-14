//
//  YAWATheme.swift
//  YAWA
//
//  Created by xcode and chatgpt on 1/10/26.
//


import SwiftUI

enum YAWATheme {

    // MARK: - Brand (shared)

    /// Primary branded sky/background used across YAWA.
    static let sky = Color(red: 0.03, green: 0.10, blue: 0.24)

    static let card2 = Color(red: 0.05, green: 0.11, blue: 0.20)

    // MARK: - Surfaces

    static let card    = Color(red: 0.02, green: 0.06, blue: 0.13).opacity(0.88)
    static let divider = Color.white.opacity(0.10)
    static let cardStroke = Color.white.opacity(0.22)

    // MARK: - Text (default for themed/dark)

    static let textPrimary   = Color.white
    static let textSecondary = Color.white.opacity(0.80)
    static let textTertiary  = Color.white.opacity(0.65)

    // MARK: - Accent / Alerts

    static let accent      = Color.yellow.opacity(0.95)
    static let alertIcon   = Color.red
    static let alertHeader = Color.yellow.opacity(0.95)
    static let alert       = Color.yellow.opacity(0.95)

    // MARK: - Semantic (adaptive) — mirrors YAWA-PWS

    static func background(for scheme: ColorScheme) -> Color {
        scheme == .dark ? sky : Color(.systemBackground)
    }

    /// Alias used by some views (e.g. NOAA/CAN ContentView) — matches `cardFill`.
    static func cardBackground(for scheme: ColorScheme) -> Color {
        cardFill(for: scheme)
    }

    /// Convenience divider color that matches the current scheme.
    static func divider(for scheme: ColorScheme) -> Color {
        scheme == .dark ? divider : Color.black.opacity(0.08)
    }

    static func cardFill(for scheme: ColorScheme) -> Color {
        scheme == .dark
        ? Color(red: 0.02, green: 0.06, blue: 0.13).opacity(0.88)
        : Color.black.opacity(0.035)   // 👈 Apple Weather-ish
    }

    static func cardStroke(for scheme: ColorScheme) -> Color {
        scheme == .dark
        ? Color.white.opacity(0.22)
        : Color.black.opacity(0.08) // softer edge in light mode
    }

    // MARK: - SF Symbol Colors (match YAWA NOAA)

    /// Returns a consistent accent color for common SF Symbols used in the UI.
    /// Colors are chosen to read well in both light and dark modes.
    static func symbolColor(_ systemName: String, scheme: ColorScheme) -> Color {
        // Normalize common variants so they share a color.
        let base = systemName
            .replacingOccurrences(of: ".circle.fill", with: "")
            .replacingOccurrences(of: ".circle", with: "")
            .replacingOccurrences(of: ".fill", with: "")
            .replacingOccurrences(of: ".slash", with: "")

        switch base {
        // Toolbar / UI
        case "gearshape":
            return scheme == .dark ? Color.gray.opacity(0.90) : Color.gray.opacity(0.85)
        case "location":
            return scheme == .dark ? Color.cyan.opacity(0.95) : Color.cyan

        // Temperature / heat
        case "thermometer", "thermometer.sun", "thermometer.high", "thermometer.medium", "thermometer.low":
            return scheme == .dark ? Color.red.opacity(0.95) : Color.red

        // Wind
        case "wind":
            return scheme == .dark ? Color.cyan.opacity(0.95) : Color.cyan

        // Humidity / precip chance
        case "drop", "drop.degreesign", "drop.percent", "humidity":
            return scheme == .dark ? Color.blue.opacity(0.95) : Color.blue

        // Pressure / gauge
        case "gauge", "gauge.medium", "barometer":
            return scheme == .dark ? Color.orange.opacity(0.95) : Color.orange

        // Sun / clear
        case "sun.max", "sun.min", "sunrise", "sunset":
            return scheme == .dark ? Color.yellow.opacity(0.95) : Color.yellow

        // Cloudy / sky
        case "cloud", "cloud.fill":
            return scheme == .dark ? Color.gray.opacity(0.90) : Color.gray.opacity(0.85)

        // Partly cloudy: bias toward the sun/moon accent
        case "cloud.sun", "cloud.sun.fill":
            return scheme == .dark ? Color.yellow.opacity(0.95) : Color.yellow

        case "cloud.moon", "cloud.moon.fill":
            return scheme == .dark ? Color.indigo.opacity(0.95) : Color.indigo

        case "cloud.fog", "cloud.fog.fill":
            return scheme == .dark ? Color.gray.opacity(0.90) : Color.gray.opacity(0.85)

        // Rain
        case "cloud.rain", "cloud.drizzle", "cloud.heavyrain", "cloud.rainbow", "cloud.sun.rain", "cloud.moon.rain":
            return scheme == .dark ? Color.blue.opacity(0.95) : Color.blue

        // Snow
        case "cloud.snow", "snowflake":
            return scheme == .dark ? Color.teal.opacity(0.95) : Color.teal

        // Thunder
        case "cloud.bolt", "cloud.bolt.rain":
            return scheme == .dark ? Color.purple.opacity(0.95) : Color.purple
            
        // Moons
        case "moon", "moon.stars":
            return scheme == .dark ? Color.yellow.opacity(0.95) : Color.yellow

        default:
            return textSecondary(for: scheme)
        }
    }

    static func textPrimary(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white : Color.primary
    }

    static func textSecondary(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.84) : Color.secondary
    }

    static func textTertiary(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.70) : Color.secondary.opacity(0.85)
    }
}
