# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a native iOS app built with Xcode 26.2+. There is no Makefile, SwiftLint, or test suite.

Build from the command line:
```bash
xcodebuild -scheme "YAWA CAN" -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16'
xcodebuild -scheme "YAWA CAN" -configuration Release
```

The project has two targets:
- **YAWA CAN** — main iOS app
- **YCWidgetExtension** — WidgetKit home/lock screen widget

## Architecture

**MVVM** with SwiftUI, async/await concurrency, and protocol-based services. No third-party dependencies — pure Xcode project with system frameworks (SwiftUI, WidgetKit, CoreLocation, UserNotifications, BackgroundTasks).

### Core data flow

`ContentView` (main UI) owns a `WeatherViewModel` (@StateObject). The view model calls `WeatherServiceProtocol` (implemented by `OpenMeteoWeatherService`) to fetch data and publishes a `WeatherSnapshot` — an immutable value type holding current conditions, hourly/daily forecasts, air quality, and timezone info.

### Key source files

| File | Role |
|------|------|
| `WeatherViewModel.swift` | Central state: fetches weather, manages location changes, routes notifications |
| `ContentView.swift` | All primary UI — current conditions, hourly chart, 7-day forecast, alerts, settings sheet, radar |
| `OpenMeteoWeatherService.swift` | HTTP client for Open-Meteo API; implements `WeatherServiceProtocol` |
| `NotificationRuleEngine.swift` | Evaluates `WeatherSnapshot` against rules → produces `NotificationCandidate` list |
| `NotificationCoordinator.swift` | Schedules UNUserNotificationCenter requests, enforces cooldowns, tracks delivery |
| `FavoritesNotificationMonitor.swift` | Background task that checks all saved favorite locations for notable weather |
| `NotificationStore.swift` | Persists notification prefs, snapshots, and delivery history to UserDefaults |
| `RadarView.swift` | Interactive radar map consuming RainViewer API tile frames |
| `YCWidget.swift` | WidgetKit timeline provider and widget UI |
| `AppDelegate.swift` | BGTaskScheduler registration and background refresh dispatch |

### External APIs

- **Open-Meteo** (`https://api.open-meteo.com/v1/forecast`) — weather data (free, no key)
- **RainViewer** (`https://api.rainviewer.com`) — radar tile frames (free, no key)
- **Canada Alert Service** (`CanadaAlertService`) — weather watches/warnings for CA locations

### Widget ↔ App data sharing

App Group `group.com.widgetal.yawacan` (configured in both `.entitlements` files) is used for UserDefaults sharing between the main app and the widget extension. `ForecastNotificationSnapshot` is the serializable type written by the app and read by the widget timeline provider.

### Location & units

`CoreLocation` provides device GPS. Reverse geocoding determines whether a location is in Canada (Celsius) or the US (Fahrenheit). `SavedLocation` persists user-added favorite locations.

### Notification pipeline

1. `FavoritesNotificationMonitor` runs on a BGAppRefreshTask.
2. It fetches a `WeatherSnapshot` per favorite via `OpenMeteoWeatherService`.
3. `NotificationRuleEngine` scores the snapshot and emits `NotificationCandidate` objects.
4. `NotificationCoordinator` deduplicates (by issued-at timestamp + delivery history), then schedules via `UNUserNotificationCenter`.
5. `NotificationStore` persists state so cooldowns survive app restarts.

### Background modes

Declared in `Info.plist`: `fetch` and `processing`. `AppDelegate` registers the BGTaskScheduler identifier and schedules the next refresh after each background execution.
