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
    static let sky = Color(red: 0.05, green: 0.13, blue: 0.28)

    /// Used in a few places as the “deep surface” color. In NOAA this previously skewed a bit too blue;
    /// tune it closer to the PWS look (deeper + less saturated).
    static let card2 = Color(red: 0.08, green: 0.14, blue: 0.25)

    // MARK: - Surfaces

    static let card    = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.26)
    static let cardStroke = Color.white.opacity(0.20)

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

    static func cardFill(for scheme: ColorScheme) -> Color {
        scheme == .dark
        ? Color.white.opacity(0.08)
        : Color.black.opacity(0.04)
    }

    static func cardStroke(for scheme: ColorScheme) -> Color {
        scheme == .dark
        ? Color.white.opacity(0.20)
        : Color.black.opacity(0.12)
    }

    static func textPrimary(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white : Color.primary
    }

    static func textSecondary(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.80) : Color.secondary
    }

    static func textTertiary(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.65) : Color.secondary.opacity(0.85)
    }
}
