import Foundation
import SwiftUI

public enum SnowStyle: String, CaseIterable, Identifiable, Sendable {
    case mixed = "Mixed"
    case crystals = "Crystals"
    case powder = "Powder"
    case clumps = "Clumps"

    public var id: String { rawValue }
}

public enum SnowMood: String, CaseIterable, Identifiable, Sendable {
    case winterWhite = "Winter White"
    case arcticBlue = "Arctic Blue"
    case goldenHour = "Golden Hour"
    case aurora = "Aurora"

    public var id: String { rawValue }
}

public enum OverlayLayerMode: String, CaseIterable, Identifiable, Sendable {
    case desktopAndDock = "Desktop & Dock"
    case aboveAllWindows = "Above Windows"

    public var id: String { rawValue }
}

public enum PerformanceMode: String, CaseIterable, Identifiable, Sendable {
    case eco = "Eco"
    case balanced = "Balanced"
    case ultra = "Ultra"

    public var id: String { rawValue }

    public var preferredFPS: Int {
        switch self {
        case .eco: return 24
        case .balanced: return 30
        case .ultra: return 60
        }
    }

    /// Backing drawable scale relative to logical points (lower = dramatically less GPU & WindowServer work)
    public var maxDrawableScale: CGFloat {
        switch self {
        case .eco: return 0.85
        case .balanced: return 1.0
        case .ultra: return 2.0
        }
    }

    public var subtitle: String {
        switch self {
        case .eco: return "24 fps • lowest battery & GPU"
        case .balanced: return "30 fps • ~8x lower GPU than Retina 60"
        case .ultra: return "60 fps • full Retina resolution"
        }
    }
}

public enum SnowPreset: String, CaseIterable, Identifiable, Sendable {
    case cozyFlurry = "Cozy Flurry"
    case powderDay = "Powder Day"
    case blizzard = "Blizzard"
    case wetSticky = "Wet Sticky"
    case zenDusting = "Zen Dusting"

    public var id: String { rawValue }
    public var symbol: String {
        switch self {
        case .cozyFlurry: return "snowflake"
        case .powderDay: return "wind.snow"
        case .blizzard: return "cloud.snow.fill"
        case .wetSticky: return "mountain.2.fill"
        case .zenDusting: return "sparkles"
        }
    }
}

public struct CustomSnowPreset: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var intensity: Double
    public var flakeSize: Double
    public var snowStyleRaw: String
    public var snowMoodRaw: String
    public var gravity: Double
    public var wind: Double
    public var turbulence: Double
    public var flutter: Double
    public var accumulationEnabled: Bool
    public var accumulationRate: Double
    public var stickiness: Double
    public var maxPileHeight: Double
    public var meltRate: Double
    public var sparkleEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        intensity: Double,
        flakeSize: Double,
        snowStyleRaw: String,
        snowMoodRaw: String,
        gravity: Double,
        wind: Double,
        turbulence: Double,
        flutter: Double,
        accumulationEnabled: Bool,
        accumulationRate: Double,
        stickiness: Double,
        maxPileHeight: Double,
        meltRate: Double,
        sparkleEnabled: Bool
    ) {
        self.id = id
        self.name = name
        self.intensity = intensity
        self.flakeSize = flakeSize
        self.snowStyleRaw = snowStyleRaw
        self.snowMoodRaw = snowMoodRaw
        self.gravity = gravity
        self.wind = wind
        self.turbulence = turbulence
        self.flutter = flutter
        self.accumulationEnabled = accumulationEnabled
        self.accumulationRate = accumulationRate
        self.stickiness = stickiness
        self.maxPileHeight = maxPileHeight
        self.meltRate = meltRate
        self.sparkleEnabled = sparkleEnabled
    }
}

@MainActor
public final class SnowSettings: ObservableObject {
    public static let shared = SnowSettings()

    // Non-linear intensity curve (fine granularity from 5..250 flakes, full power up to 3500)
    public static let minIntensity: Double = 5
    public static let maxIntensity: Double = 3500
    public static let intensityCurveExponent: Double = 2.8

    public static func sliderToIntensity(_ t: Double) -> Double {
        let clamped = min(1.0, max(0.0, t))
        let val = minIntensity + (maxIntensity - minIntensity) * pow(clamped, intensityCurveExponent)
        if val < 50 { return val.rounded() }
        if val < 300 { return (val / 5.0).rounded() * 5.0 }
        return (val / 10.0).rounded() * 10.0
    }

    public static func intensityToSlider(_ intensity: Double) -> Double {
        let norm = min(1.0, max(0.0, (intensity - minIntensity) / (maxIntensity - minIntensity)))
        return pow(norm, 1.0 / intensityCurveExponent)
    }

    private enum Keys {
        static let schemaVersion = "settingsSchemaVersion"
        static let isSnowing = "isSnowing"
        static let intensity = "intensity"
        static let flakeSize = "flakeSize"
        static let snowStyle = "snowStyle"
        static let snowMood = "snowMood"
        static let gravity = "gravity"
        static let wind = "wind"
        static let turbulence = "turbulence"
        static let flutter = "flutter"
        static let accumulationEnabled = "accumulationEnabled"
        static let accumulationRate = "accumulationRate"
        static let stickiness = "stickiness"
        static let maxPileHeight = "maxPileHeight"
        static let meltRate = "meltRate"
        static let landOnDesktopIcons = "landOnDesktopIcons"
        static let landOnDesktopFolders = "landOnDesktopFolders"
        static let landOnDock = "landOnDock"
        static let landOnGround = "landOnGround"
        static let landOnWindows = "landOnWindows"
        static let landOnWallpaper = "landOnWallpaper"
        static let wallpaperIncludeSceneLedges = "wallpaperIncludeSceneLedges"
        static let wallpaperSensitivity = "wallpaperSensitivity"
        static let customWallpaperPath = "customWallpaperPath"
        static let iconTopOffset = "iconTopOffset"
        static let cursorInteraction = "cursorInteraction"
        static let cursorStrength = "cursorStrength"
        static let overlayMode = "overlayMode"
        static let performanceMode = "performanceMode"
        static let sparkleEnabled = "sparkleEnabled"
        static let showColliders = "showColliders"
        static let snowcraftGameEnabled = "snowcraftGameEnabled"
        static let shakeCursorOnHit = "shakeCursorOnHit"
        static let snowcraftEnemySpeed = "snowcraftEnemySpeed"
        static let snowcraftRollAnywhere = "snowcraftRollAnywhere"
        static let activePreset = "activePreset"
        static let customPresets = "customPresets"
        static let dynamicWeatherEnabled = "dynamicWeatherEnabled"
        static let pomodoroEnabled = "pomodoroEnabled"
        static let pomodoroIntervalMinutes = "pomodoroIntervalMinutes"
        static let pomodoroBlizzardSeconds = "pomodoroBlizzardSeconds"
        static let alarmEnabled = "alarmEnabled"
        static let alarmHour = "alarmHour"
        static let alarmMinute = "alarmMinute"
        static let alarmDurationSeconds = "alarmDurationSeconds"
    }

    private static let currentSchemaVersion = 5
    private let defaults = UserDefaults.standard
    private var isRestoring = false

    // MARK: - Playback
    @Published public var isSnowing: Bool = true {
        didSet { save(isSnowing, forKey: Keys.isSnowing) }
    }

    // MARK: - Snowfall & Atmosphere
    @Published public var intensity: Double = 550 {
        didSet { save(intensity, forKey: Keys.intensity) }
    }
    @Published public var flakeSize: Double = 1.05 {
        didSet { save(flakeSize, forKey: Keys.flakeSize) }
    }
    @Published public var snowStyle: SnowStyle = .mixed {
        didSet { save(snowStyle.rawValue, forKey: Keys.snowStyle) }
    }
    @Published public var snowMood: SnowMood = .winterWhite {
        didSet { save(snowMood.rawValue, forKey: Keys.snowMood) }
    }

    // MARK: - Physics & Wind
    @Published public var gravity: Double = 1.0 {
        didSet { save(gravity, forKey: Keys.gravity) }
    }
    /// -1.0 (strong left) ... 0.0 (calm) ... +1.0 (strong right)
    @Published public var wind: Double = 0.15 {
        didSet { save(wind, forKey: Keys.wind) }
    }
    @Published public var turbulence: Double = 0.42 {
        didSet { save(turbulence, forKey: Keys.turbulence) }
    }
    @Published public var flutter: Double = 0.60 {
        didSet { save(flutter, forKey: Keys.flutter) }
    }

    // MARK: - Accumulation & Surfaces
    @Published public var accumulationEnabled: Bool = true {
        didSet { save(accumulationEnabled, forKey: Keys.accumulationEnabled) }
    }
    @Published public var accumulationRate: Double = 1.35 {
        didSet { save(accumulationRate, forKey: Keys.accumulationRate) }
    }
    @Published public var stickiness: Double = 0.72 {
        didSet { save(stickiness, forKey: Keys.stickiness) }
    }
    @Published public var maxPileHeight: Double = 24.0 {
        didSet { save(maxPileHeight, forKey: Keys.maxPileHeight) }
    }
    @Published public var meltRate: Double = 0.08 {
        didSet { save(meltRate, forKey: Keys.meltRate) }
    }
    @Published public var landOnDesktopIcons: Bool = true {
        didSet { save(landOnDesktopIcons, forKey: Keys.landOnDesktopIcons) }
    }
    @Published public var landOnDesktopFolders: Bool = true {
        didSet { save(landOnDesktopFolders, forKey: Keys.landOnDesktopFolders) }
    }
    @Published public var landOnDock: Bool = true {
        didSet { save(landOnDock, forKey: Keys.landOnDock) }
    }
    @Published public var landOnGround: Bool = true {
        didSet { save(landOnGround, forKey: Keys.landOnGround) }
    }
    @Published public var landOnWindows: Bool = true {
        didSet { save(landOnWindows, forKey: Keys.landOnWindows) }
    }
    @Published public var landOnWallpaper: Bool = true {
        didSet { save(landOnWallpaper, forKey: Keys.landOnWallpaper) }
    }
    @Published public var wallpaperIncludeSceneLedges: Bool = true {
        didSet { save(wallpaperIncludeSceneLedges, forKey: Keys.wallpaperIncludeSceneLedges) }
    }
    @Published public var wallpaperSensitivity: Double = 0.55 {
        didSet { save(wallpaperSensitivity, forKey: Keys.wallpaperSensitivity) }
    }
    @Published public var customWallpaperPath: String = "" {
        didSet { save(customWallpaperPath, forKey: Keys.customWallpaperPath) }
    }
    @Published public var iconTopOffset: Double = 3.0 {
        didSet { save(iconTopOffset, forKey: Keys.iconTopOffset) }
    }

    // MARK: - Interactivity & Display
    @Published public var cursorInteraction: Bool = true {
        didSet { save(cursorInteraction, forKey: Keys.cursorInteraction) }
    }
    @Published public var cursorStrength: Double = 1.0 {
        didSet { save(cursorStrength, forKey: Keys.cursorStrength) }
    }
    @Published public var overlayMode: OverlayLayerMode = .aboveAllWindows {
        didSet { save(overlayMode.rawValue, forKey: Keys.overlayMode) }
    }
    @Published public var performanceMode: PerformanceMode = .balanced {
        didSet { save(performanceMode.rawValue, forKey: Keys.performanceMode) }
    }
    @Published public var sparkleEnabled: Bool = true {
        didSet { save(sparkleEnabled, forKey: Keys.sparkleEnabled) }
    }
    @Published public var showColliders: Bool = false {
        didSet { save(showColliders, forKey: Keys.showColliders) }
    }

    // MARK: - Snowball Rolling & Snowcraft Mini-Game (opt-in by default)
    @Published public var snowcraftGameEnabled: Bool = false {
        didSet { save(snowcraftGameEnabled, forKey: Keys.snowcraftGameEnabled) }
    }
    @Published public var shakeCursorOnHit: Bool = true {
        didSet { save(shakeCursorOnHit, forKey: Keys.shakeCursorOnHit) }
    }
    @Published public var snowcraftEnemySpeed: Double = 1.0 {
        didSet { save(snowcraftEnemySpeed, forKey: Keys.snowcraftEnemySpeed) }
    }
    @Published public var snowcraftRollAnywhere: Bool = false {
        didSet { save(snowcraftRollAnywhere, forKey: Keys.snowcraftRollAnywhere) }
    }

    // MARK: - Dynamic Weather, Pomodoro Blizzard & Storm Alarm
    @Published public var dynamicWeatherEnabled: Bool = false {
        didSet { save(dynamicWeatherEnabled, forKey: Keys.dynamicWeatherEnabled) }
    }
    @Published public var pomodoroEnabled: Bool = false {
        didSet { save(pomodoroEnabled, forKey: Keys.pomodoroEnabled) }
    }
    @Published public var pomodoroIntervalMinutes: Int = 25 {
        didSet { save(pomodoroIntervalMinutes, forKey: Keys.pomodoroIntervalMinutes) }
    }
    @Published public var pomodoroBlizzardSeconds: Int = 60 {
        didSet { save(pomodoroBlizzardSeconds, forKey: Keys.pomodoroBlizzardSeconds) }
    }
    @Published public var alarmEnabled: Bool = false {
        didSet { save(alarmEnabled, forKey: Keys.alarmEnabled) }
    }
    @Published public var alarmHour: Int = 13 {
        didSet { save(alarmHour, forKey: Keys.alarmHour) }
    }
    @Published public var alarmMinute: Int = 0 {
        didSet { save(alarmMinute, forKey: Keys.alarmMinute) }
    }
    @Published public var alarmDurationSeconds: Int = 180 {
        didSet { save(alarmDurationSeconds, forKey: Keys.alarmDurationSeconds) }
    }

    // MARK: - Presets & Custom Presets
    @Published public var activePreset: SnowPreset? = .cozyFlurry {
        didSet { save(activePreset?.rawValue ?? "", forKey: Keys.activePreset) }
    }
    @Published public var activeCustomPresetID: UUID? = nil
    @Published public var customPresets: [CustomSnowPreset] = [] {
        didSet { saveCustomPresets() }
    }

    // MARK: - Live Telemetry (updated by simulation / scheduler)
    @Published public var activeFlakeCount: Int = 0
    @Published public var detectedIconCount: Int = 0
    @Published public var detectedDockItemCount: Int = 0
    @Published public var detectedWindowCount: Int = 0
    @Published public var detectedWallpaperLedgeCount: Int = 0
    @Published public var wallpaperStatus: WallpaperScanStatus = .idle
    @Published public var accessibilityGranted: Bool = false
    @Published public var snowballsRolledCount: Int = 0
    @Published public var dudesKnockedOutCount: Int = 0
    @Published public var playerHitsTakenCount: Int = 0
    @Published public var weatherStatusBadge: String? = nil
    @Published public var isWeatherStormActive: Bool = false
    @Published public var pomodoroCountdownText: String = ""

    // MARK: - One-shot Action Hooks
    public var onClearSnow: (() -> Void)?
    public var onTriggerGust: (() -> Void)?
    public var onShakeSurfaces: (() -> Void)?
    public var onRescanWallpaper: ((Bool) -> Void)?
    public var onSpawnSnowcraftWave: (() -> Void)?
    public var onResetSnowcraftGame: (() -> Void)?
    public var onResetPomodoro: (() -> Void)?
    public var onTestPomodoroBlizzard: (() -> Void)?
    public var onTestAlarmStorm: (() -> Void)?
    public var onDismissStorm: (() -> Void)?
    public var onCustomPresetsChanged: (() -> Void)?

    private init() {
        load()
    }

    private func save(_ value: Any, forKey key: String) {
        guard !isRestoring else { return }
        defaults.set(value, forKey: key)
    }

    private func saveCustomPresets() {
        guard !isRestoring else { return }
        if let data = try? JSONEncoder().encode(customPresets) {
            defaults.set(data, forKey: Keys.customPresets)
        }
        onCustomPresetsChanged?()
    }

    private func load() {
        isRestoring = true
        defer { isRestoring = false }

        let storedVersion = defaults.integer(forKey: Keys.schemaVersion)

        if defaults.object(forKey: Keys.isSnowing) != nil {
            isSnowing = defaults.bool(forKey: Keys.isSnowing)
        }
        if defaults.object(forKey: Keys.intensity) != nil {
            intensity = max(Self.minIntensity, min(Self.maxIntensity, defaults.double(forKey: Keys.intensity)))
        }
        if defaults.object(forKey: Keys.flakeSize) != nil {
            flakeSize = defaults.double(forKey: Keys.flakeSize)
        }
        if let raw = defaults.string(forKey: Keys.snowStyle), let v = SnowStyle(rawValue: raw) {
            snowStyle = v
        }
        if let raw = defaults.string(forKey: Keys.snowMood), let v = SnowMood(rawValue: raw) {
            snowMood = v
        }
        if defaults.object(forKey: Keys.gravity) != nil {
            gravity = defaults.double(forKey: Keys.gravity)
        }
        if defaults.object(forKey: Keys.wind) != nil {
            wind = defaults.double(forKey: Keys.wind)
        }
        if defaults.object(forKey: Keys.turbulence) != nil {
            turbulence = defaults.double(forKey: Keys.turbulence)
        }
        if defaults.object(forKey: Keys.flutter) != nil {
            flutter = defaults.double(forKey: Keys.flutter)
        }
        if defaults.object(forKey: Keys.accumulationEnabled) != nil {
            accumulationEnabled = defaults.bool(forKey: Keys.accumulationEnabled)
        }
        if defaults.object(forKey: Keys.accumulationRate) != nil {
            accumulationRate = defaults.double(forKey: Keys.accumulationRate)
        }
        if defaults.object(forKey: Keys.stickiness) != nil {
            stickiness = defaults.double(forKey: Keys.stickiness)
        }
        if defaults.object(forKey: Keys.maxPileHeight) != nil {
            maxPileHeight = defaults.double(forKey: Keys.maxPileHeight)
        }
        if defaults.object(forKey: Keys.meltRate) != nil {
            meltRate = defaults.double(forKey: Keys.meltRate)
        }
        if defaults.object(forKey: Keys.landOnDesktopIcons) != nil {
            landOnDesktopIcons = defaults.bool(forKey: Keys.landOnDesktopIcons)
        }
        if defaults.object(forKey: Keys.landOnDesktopFolders) != nil {
            landOnDesktopFolders = defaults.bool(forKey: Keys.landOnDesktopFolders)
        }
        if defaults.object(forKey: Keys.landOnDock) != nil {
            landOnDock = defaults.bool(forKey: Keys.landOnDock)
        }
        if defaults.object(forKey: Keys.landOnGround) != nil {
            landOnGround = defaults.bool(forKey: Keys.landOnGround)
        }
        if defaults.object(forKey: Keys.landOnWindows) != nil {
            landOnWindows = defaults.bool(forKey: Keys.landOnWindows)
        }
        if defaults.object(forKey: Keys.landOnWallpaper) != nil {
            landOnWallpaper = defaults.bool(forKey: Keys.landOnWallpaper)
        }
        if defaults.object(forKey: Keys.wallpaperIncludeSceneLedges) != nil {
            wallpaperIncludeSceneLedges = defaults.bool(forKey: Keys.wallpaperIncludeSceneLedges)
        }
        if defaults.object(forKey: Keys.wallpaperSensitivity) != nil {
            wallpaperSensitivity = defaults.double(forKey: Keys.wallpaperSensitivity)
        }
        if let path = defaults.string(forKey: Keys.customWallpaperPath) {
            customWallpaperPath = path
        }
        if defaults.object(forKey: Keys.iconTopOffset) != nil {
            iconTopOffset = defaults.double(forKey: Keys.iconTopOffset)
        }
        if defaults.object(forKey: Keys.cursorInteraction) != nil {
            cursorInteraction = defaults.bool(forKey: Keys.cursorInteraction)
        }
        if defaults.object(forKey: Keys.cursorStrength) != nil {
            cursorStrength = defaults.double(forKey: Keys.cursorStrength)
        }
        if let raw = defaults.string(forKey: Keys.overlayMode), let v = OverlayLayerMode(rawValue: raw) {
            overlayMode = v
        }
        if let raw = defaults.string(forKey: Keys.performanceMode), let v = PerformanceMode(rawValue: raw) {
            performanceMode = v
        }
        if defaults.object(forKey: Keys.sparkleEnabled) != nil {
            sparkleEnabled = defaults.bool(forKey: Keys.sparkleEnabled)
        }
        if defaults.object(forKey: Keys.showColliders) != nil {
            showColliders = defaults.bool(forKey: Keys.showColliders)
        }
        if defaults.object(forKey: Keys.snowcraftGameEnabled) != nil {
            snowcraftGameEnabled = defaults.bool(forKey: Keys.snowcraftGameEnabled)
        }
        if defaults.object(forKey: Keys.shakeCursorOnHit) != nil {
            shakeCursorOnHit = defaults.bool(forKey: Keys.shakeCursorOnHit)
        }
        if defaults.object(forKey: Keys.snowcraftEnemySpeed) != nil {
            snowcraftEnemySpeed = defaults.double(forKey: Keys.snowcraftEnemySpeed)
        }
        if defaults.object(forKey: Keys.snowcraftRollAnywhere) != nil {
            snowcraftRollAnywhere = defaults.bool(forKey: Keys.snowcraftRollAnywhere)
        }
        if defaults.object(forKey: Keys.dynamicWeatherEnabled) != nil {
            dynamicWeatherEnabled = defaults.bool(forKey: Keys.dynamicWeatherEnabled)
        }
        if defaults.object(forKey: Keys.pomodoroEnabled) != nil {
            pomodoroEnabled = defaults.bool(forKey: Keys.pomodoroEnabled)
        }
        if defaults.object(forKey: Keys.pomodoroIntervalMinutes) != nil {
            pomodoroIntervalMinutes = max(1, defaults.integer(forKey: Keys.pomodoroIntervalMinutes))
        }
        if defaults.object(forKey: Keys.pomodoroBlizzardSeconds) != nil {
            pomodoroBlizzardSeconds = max(10, defaults.integer(forKey: Keys.pomodoroBlizzardSeconds))
        }
        if defaults.object(forKey: Keys.alarmEnabled) != nil {
            alarmEnabled = defaults.bool(forKey: Keys.alarmEnabled)
        }
        if defaults.object(forKey: Keys.alarmHour) != nil {
            alarmHour = max(0, min(23, defaults.integer(forKey: Keys.alarmHour)))
        }
        if defaults.object(forKey: Keys.alarmMinute) != nil {
            alarmMinute = max(0, min(59, defaults.integer(forKey: Keys.alarmMinute)))
        }
        if defaults.object(forKey: Keys.alarmDurationSeconds) != nil {
            alarmDurationSeconds = max(15, defaults.integer(forKey: Keys.alarmDurationSeconds))
        }
        if let raw = defaults.string(forKey: Keys.activePreset) {
            activePreset = SnowPreset(rawValue: raw)
        }
        if let data = defaults.data(forKey: Keys.customPresets),
           let decoded = try? JSONDecoder().decode([CustomSnowPreset].self, from: data) {
            customPresets = decoded
        }

        if storedVersion < Self.currentSchemaVersion {
            if storedVersion < 2 {
                landOnWindows = true
                landOnDesktopIcons = true
                landOnDesktopFolders = true
                accumulationEnabled = true
                accumulationRate = 1.35
                meltRate = 0.08
                stickiness = 0.72
            }
            if storedVersion < 3 {
                landOnWallpaper = true
                wallpaperIncludeSceneLedges = true
                wallpaperSensitivity = 0.55
            }
            if storedVersion < 5 {
                // Default Snowcraft mini-game to opt-in & Balanced GPU efficiency
                snowcraftGameEnabled = false
                performanceMode = .balanced
                defaults.set(false, forKey: Keys.snowcraftGameEnabled)
                defaults.set(PerformanceMode.balanced.rawValue, forKey: Keys.performanceMode)
            }
            defaults.set(Self.currentSchemaVersion, forKey: Keys.schemaVersion)
        }
    }

    // MARK: - Built-in & Custom Presets

    public func applyPreset(_ preset: SnowPreset) {
        activePreset = preset
        activeCustomPresetID = nil
        switch preset {
        case .cozyFlurry:
            intensity = 550
            flakeSize = 1.05
            snowStyle = .mixed
            snowMood = .winterWhite
            gravity = 1.0
            wind = 0.15
            turbulence = 0.42
            flutter = 0.60
            accumulationRate = 1.35
            stickiness = 0.72
            maxPileHeight = 24.0
            meltRate = 0.08
        case .powderDay:
            intensity = 1100
            flakeSize = 0.90
            snowStyle = .powder
            snowMood = .arcticBlue
            gravity = 0.78
            wind = -0.25
            turbulence = 0.72
            flutter = 0.85
            accumulationRate = 1.15
            stickiness = 0.40
            maxPileHeight = 26.0
            meltRate = 0.06
        case .blizzard:
            intensity = 2600
            flakeSize = 1.15
            snowStyle = .mixed
            snowMood = .arcticBlue
            gravity = 1.85
            wind = 0.85
            turbulence = 0.95
            flutter = 0.45
            accumulationRate = 1.75
            stickiness = 0.58
            maxPileHeight = 38.0
            meltRate = 0.04
        case .wetSticky:
            intensity = 900
            flakeSize = 1.45
            snowStyle = .clumps
            snowMood = .winterWhite
            gravity = 1.35
            wind = 0.08
            turbulence = 0.25
            flutter = 0.30
            accumulationRate = 1.90
            stickiness = 0.96
            maxPileHeight = 42.0
            meltRate = 0.03
        case .zenDusting:
            intensity = 85
            flakeSize = 1.15
            snowStyle = .crystals
            snowMood = .aurora
            gravity = 0.52
            wind = 0.04
            turbulence = 0.30
            flutter = 0.90
            accumulationRate = 1.00
            stickiness = 0.62
            maxPileHeight = 14.0
            meltRate = 0.12
        }
    }

    @discardableResult
    public func saveCustomPreset(name rawName: String) -> CustomSnowPreset? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let preset = CustomSnowPreset(
            name: trimmed,
            intensity: intensity,
            flakeSize: flakeSize,
            snowStyleRaw: snowStyle.rawValue,
            snowMoodRaw: snowMood.rawValue,
            gravity: gravity,
            wind: wind,
            turbulence: turbulence,
            flutter: flutter,
            accumulationEnabled: accumulationEnabled,
            accumulationRate: accumulationRate,
            stickiness: stickiness,
            maxPileHeight: maxPileHeight,
            meltRate: meltRate,
            sparkleEnabled: sparkleEnabled
        )
        customPresets.append(preset)
        activePreset = nil
        activeCustomPresetID = preset.id
        return preset
    }

    public func applyCustomPreset(_ preset: CustomSnowPreset) {
        activePreset = nil
        activeCustomPresetID = preset.id
        intensity = preset.intensity
        flakeSize = preset.flakeSize
        if let style = SnowStyle(rawValue: preset.snowStyleRaw) { snowStyle = style }
        if let mood = SnowMood(rawValue: preset.snowMoodRaw) { snowMood = mood }
        gravity = preset.gravity
        wind = preset.wind
        turbulence = preset.turbulence
        flutter = preset.flutter
        accumulationEnabled = preset.accumulationEnabled
        accumulationRate = preset.accumulationRate
        stickiness = preset.stickiness
        maxPileHeight = preset.maxPileHeight
        meltRate = preset.meltRate
        sparkleEnabled = preset.sparkleEnabled
    }

    public func deleteCustomPreset(id: UUID) {
        customPresets.removeAll { $0.id == id }
        if activeCustomPresetID == id {
            activeCustomPresetID = nil
        }
    }

    public func resetDefaults() {
        applyPreset(.cozyFlurry)
        accumulationEnabled = true
        landOnDesktopIcons = true
        landOnDesktopFolders = true
        landOnDock = true
        landOnGround = true
        landOnWindows = true
        landOnWallpaper = true
        wallpaperIncludeSceneLedges = true
        wallpaperSensitivity = 0.55
        customWallpaperPath = ""
        iconTopOffset = 3.0
        cursorInteraction = true
        cursorStrength = 1.0
        overlayMode = .aboveAllWindows
        performanceMode = .balanced
        sparkleEnabled = true
        showColliders = false
        snowcraftGameEnabled = false
        shakeCursorOnHit = true
        snowcraftEnemySpeed = 1.0
        snowcraftRollAnywhere = false
        dynamicWeatherEnabled = false
        pomodoroEnabled = false
        pomodoroIntervalMinutes = 25
        pomodoroBlizzardSeconds = 60
        alarmEnabled = false
        alarmHour = 13
        alarmMinute = 0
        alarmDurationSeconds = 180
        isSnowing = true
    }
}
