import Combine
import Foundation

/// Output of `WeatherScheduler.tick(dt:now:)` describing how active weather
/// patterns, Pomodoro blizzards, or snowstorm alarms modulate the snow simulation.
public struct WeatherModulation: Sendable, Equatable {
    /// Multiplier applied to the user's base flake intensity.
    public var intensityMultiplier: Double
    /// Minimum effective flake count floor (e.g., ~1800 during a blizzard/alarm storm).
    public var intensityFloor: Double
    /// Additive wind offset applied to the user's base wind, clamped to `-1...1`.
    public var windOffset: Double
    /// Minimum turbulence level enforced during storms or squalls.
    public var turbulenceFloor: Double
    /// Multiplier applied to gravity/fall speed.
    public var gravityMultiplier: Double
    /// When `true`, signals the simulation to trigger a periodic wind gust on this tick.
    public var shouldTriggerGust: Bool
    /// Optional human-readable status badge for UI display (e.g., `"Pomodoro Blizzard (0:42)"`).
    public var statusBadge: String?
    /// Whether a Pomodoro blizzard or snowstorm alarm is currently active.
    public var isStormActive: Bool

    public static let neutral = WeatherModulation()

    public init(
        intensityMultiplier: Double = 1.0,
        intensityFloor: Double = 0.0,
        windOffset: Double = 0.0,
        turbulenceFloor: Double = 0.0,
        gravityMultiplier: Double = 1.0,
        shouldTriggerGust: Bool = false,
        statusBadge: String? = nil,
        isStormActive: Bool = false
    ) {
        self.intensityMultiplier = intensityMultiplier
        self.intensityFloor = intensityFloor
        self.windOffset = min(1.0, max(-1.0, windOffset))
        self.turbulenceFloor = turbulenceFloor
        self.gravityMultiplier = gravityMultiplier
        self.shouldTriggerGust = shouldTriggerGust
        self.statusBadge = statusBadge
        self.isStormActive = isStormActive
    }
}

/// Manages organic variable weather cycles, Pomodoro break blizzards, and wall-clock snowstorm alarms.
@MainActor
public final class WeatherScheduler: ObservableObject {
    // MARK: - Variable Weather Configuration

    @Published public var dynamicWeatherEnabled: Bool = false

    // MARK: - Pomodoro Blizzard Configuration & State

    @Published public var pomodoroEnabled: Bool = false {
        didSet {
            if pomodoroEnabled && !oldValue && !pomodoroBlizzardActive && pomodoroRemainingExact <= 0 {
                resetPomodoro()
            }
        }
    }

    /// Focus interval duration in minutes (clamped to `5...90`).
    @Published public var pomodoroIntervalMinutes: Int = 25 {
        didSet {
            let clamped = Self.clamp(pomodoroIntervalMinutes, min: 5, max: 90)
            if clamped != pomodoroIntervalMinutes {
                pomodoroIntervalMinutes = clamped
                return
            }
            if !pomodoroBlizzardActive {
                let newTotal = Double(clamped * 60)
                if pomodoroRemainingExact > newTotal || !pomodoroEnabled {
                    pomodoroRemainingExact = newTotal
                    updatePublished(&pomodoroRemainingSeconds, to: clamped * 60)
                }
            }
        }
    }

    /// Blizzard break duration in seconds (clamped to `10...180`).
    @Published public var pomodoroBlizzardSeconds: Int = 60 {
        didSet {
            let clamped = Self.clamp(pomodoroBlizzardSeconds, min: 10, max: 180)
            if clamped != pomodoroBlizzardSeconds {
                pomodoroBlizzardSeconds = clamped
            }
        }
    }

    @Published public private(set) var pomodoroRemainingSeconds: Int = 25 * 60
    @Published public private(set) var pomodoroBlizzardActive: Bool = false

    // MARK: - Snowstorm Alarm Configuration & State

    @Published public var alarmEnabled: Bool = false

    /// Scheduled alarm hour in 24-hour format (`0...23`).
    @Published public var alarmHour: Int = 17 {
        didSet {
            let clamped = Self.clamp(alarmHour, min: 0, max: 23)
            if clamped != alarmHour {
                alarmHour = clamped
            }
        }
    }

    /// Scheduled alarm minute (`0...59`).
    @Published public var alarmMinute: Int = 0 {
        didSet {
            let clamped = Self.clamp(alarmMinute, min: 0, max: 59)
            if clamped != alarmMinute {
                alarmMinute = clamped
            }
        }
    }

    /// Duration of the alarm snowstorm in seconds (clamped to `10...600`).
    @Published public var alarmDurationSeconds: Int = 180 {
        didSet {
            let clamped = Self.clamp(alarmDurationSeconds, min: 10, max: 600)
            if clamped != alarmDurationSeconds {
                alarmDurationSeconds = clamped
            }
        }
    }

    @Published public private(set) var alarmStormActive: Bool = false
    @Published public private(set) var alarmRemainingSeconds: Int = 0

    // MARK: - Private Simulation State

    private let calendar: Calendar

    private var weatherPhase: Double = 0.0
    private var stormBlend: Double = 0.0
    private var lastStormWasAlarm: Bool = false

    private var pomodoroRemainingExact: Double = 25.0 * 60.0
    private var alarmRemainingExact: Double = 0.0
    private var lastTriggeredDayMinuteKey: String?

    private var gustElapsed: Double = 0.0
    private var nextGustInterval: Double = 5.5
    private var gustSequenceIndex: Int = 0

    // MARK: - Constants

    private static let stormRampDuration: Double = 2.5
    private static let stormIntensityFloorTarget: Double = 1800.0
    private static let pomodoroIntensityMultiplier: Double = 2.0
    private static let alarmIntensityMultiplier: Double = 2.25
    private static let stormTurbulenceFloorTarget: Double = 0.65
    private static let stormGravityMultiplierTarget: Double = 1.35
    private static let gustIntervals: [Double] = [5.5, 7.2, 6.1, 7.8, 5.2, 6.7]

    // MARK: - Initialization

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
        self.pomodoroRemainingExact = Double(pomodoroIntervalMinutes * 60)
        self.pomodoroRemainingSeconds = pomodoroIntervalMinutes * 60
    }

    // MARK: - Public Controls

    /// Resets the Pomodoro timer back to a full focus interval and ends any active Pomodoro blizzard.
    public func resetPomodoro() {
        updatePublished(&pomodoroBlizzardActive, to: false)
        let fullSeconds = pomodoroIntervalMinutes * 60
        pomodoroRemainingExact = Double(fullSeconds)
        updatePublished(&pomodoroRemainingSeconds, to: fullSeconds)
    }

    /// Immediately starts a Pomodoro blizzard for `pomodoroBlizzardSeconds`.
    public func triggerPomodoroBlizzardNow() {
        let duration = Self.clamp(pomodoroBlizzardSeconds, min: 10, max: 180)
        pomodoroRemainingExact = Double(duration)
        updatePublished(&pomodoroRemainingSeconds, to: duration)
        updatePublished(&pomodoroBlizzardActive, to: true)
        lastStormWasAlarm = false
        resetGustCycle()
    }

    /// Immediately starts a snowstorm alarm for `alarmDurationSeconds`.
    public func triggerAlarmStormNow() {
        let duration = Self.clamp(alarmDurationSeconds, min: 10, max: 600)
        alarmRemainingExact = Double(duration)
        updatePublished(&alarmRemainingSeconds, to: duration)
        updatePublished(&alarmStormActive, to: true)
        lastStormWasAlarm = true
        resetGustCycle()
    }

    /// Dismisses any currently active Pomodoro blizzard or snowstorm alarm.
    /// The storm intensity smoothly ramps back down on subsequent ticks.
    public func dismissActiveStorm() {
        if pomodoroBlizzardActive {
            resetPomodoro()
        }
        if alarmStormActive {
            alarmRemainingExact = 0.0
            updatePublished(&alarmRemainingSeconds, to: 0)
            updatePublished(&alarmStormActive, to: false)
        }
    }

    // MARK: - Simulation Tick

    /// Advances all weather timers and organic cycles by `dt` seconds and returns the current modulation.
    public func tick(dt: TimeInterval, now: Date = Date()) -> WeatherModulation {
        let clampedDt = max(0.0, dt)

        // 1. Advance organic weather phase
        weatherPhase += clampedDt

        // 2. Advance Pomodoro countdown / blizzard
        advancePomodoro(dt: clampedDt)

        // 3. Check wall-clock alarm and advance active alarm storm
        advanceAlarm(dt: clampedDt, now: now)

        // 4. Smoothly ramp storm blend in/out over ~2.5 seconds
        let stormActive = pomodoroBlizzardActive || alarmStormActive
        let rampStep = clampedDt / Self.stormRampDuration
        if stormActive {
            stormBlend = min(1.0, stormBlend + rampStep)
        } else {
            stormBlend = max(0.0, stormBlend - rampStep)
        }
        let easedBlend = stormBlend * stormBlend * (3.0 - 2.0 * stormBlend)

        // 5. Periodic wind gusts during active storms (every ~5–8 seconds)
        let shouldTriggerGust = advanceGusts(dt: clampedDt, stormActive: stormActive)

        // 6. Compute base dynamic weather modulation
        var baseIntensity = 1.0
        var baseWind = 0.0
        var baseTurbulence = 0.0
        var isPassingSquall = false

        if dynamicWeatherEnabled {
            // Multi-frequency sine waves with ~3–6 minute periods (187s, 240s, 353s)
            let twoPi = 2.0 * Double.pi
            let rawIntensity =
                0.55 * sin(twoPi * weatherPhase / 240.0) +
                0.30 * sin(twoPi * weatherPhase / 353.0 + 1.3) +
                0.15 * sin(twoPi * weatherPhase / 187.0 + 2.7)
            // Maps [-1, 1] -> [0.55, 1.55]
            baseIntensity = 1.05 + 0.50 * rawIntensity

            // Multi-frequency wind drift with ~3.5–4.9 minute periods (211s, 293s)
            let rawWind =
                0.60 * sin(twoPi * weatherPhase / 293.0 + 0.7) +
                0.40 * sin(twoPi * weatherPhase / 211.0 + 2.1)
            // Maps [-1, 1] -> [-0.25, 0.25]
            baseWind = 0.25 * rawWind

            if baseIntensity >= 1.35 {
                isPassingSquall = true
                baseTurbulence = min(0.30, (baseIntensity - 1.35) / 0.20 * 0.25)
            }
        }

        // 7. Blend active/ramping storm modulation
        let intensityMultiplier: Double
        let intensityFloor: Double
        let windOffset: Double
        let turbulenceFloor: Double
        let gravityMultiplier: Double

        if easedBlend > 0.0 {
            let stormMult = (alarmStormActive || lastStormWasAlarm)
                ? Self.alarmIntensityMultiplier
                : Self.pomodoroIntensityMultiplier
            let stormWind = 0.55 + 0.15 * sin(weatherPhase * 0.7)

            intensityMultiplier = Self.lerp(baseIntensity, stormMult, easedBlend)
            intensityFloor = Self.stormIntensityFloorTarget * easedBlend
            windOffset = Self.clamp(Self.lerp(baseWind, stormWind, easedBlend), min: -1.0, max: 1.0)
            turbulenceFloor = max(baseTurbulence, Self.stormTurbulenceFloorTarget * easedBlend)
            gravityMultiplier = Self.lerp(1.0, Self.stormGravityMultiplierTarget, easedBlend)
        } else {
            intensityMultiplier = baseIntensity
            intensityFloor = 0.0
            windOffset = Self.clamp(baseWind, min: -1.0, max: 1.0)
            turbulenceFloor = baseTurbulence
            gravityMultiplier = 1.0
        }

        // 8. Compute status badge
        let statusBadge: String?
        if alarmStormActive {
            statusBadge = "Storm Alarm! (\(Self.formatTime(alarmRemainingSeconds)))"
        } else if pomodoroBlizzardActive {
            statusBadge = "Pomodoro Blizzard (\(Self.formatTime(pomodoroRemainingSeconds)))"
        } else if isPassingSquall {
            statusBadge = "Passing Squall"
        } else {
            statusBadge = nil
        }

        return WeatherModulation(
            intensityMultiplier: intensityMultiplier,
            intensityFloor: intensityFloor,
            windOffset: windOffset,
            turbulenceFloor: turbulenceFloor,
            gravityMultiplier: gravityMultiplier,
            shouldTriggerGust: shouldTriggerGust,
            statusBadge: statusBadge,
            isStormActive: stormActive
        )
    }

    // MARK: - Private Helpers

    private func advancePomodoro(dt: TimeInterval) {
        if pomodoroBlizzardActive {
            pomodoroRemainingExact -= dt
            if pomodoroRemainingExact <= 0.0 {
                // Blizzard finished; transition back to focus interval
                updatePublished(&pomodoroBlizzardActive, to: false)
                let nextInterval = Double(pomodoroIntervalMinutes * 60)
                pomodoroRemainingExact = nextInterval
                updatePublished(&pomodoroRemainingSeconds, to: pomodoroIntervalMinutes * 60)
            } else {
                updatePublished(&pomodoroRemainingSeconds, to: Int(ceil(pomodoroRemainingExact)))
            }
            return
        }

        guard pomodoroEnabled else { return }

        pomodoroRemainingExact -= dt
        if pomodoroRemainingExact <= 0.0 {
            triggerPomodoroBlizzardNow()
        } else {
            updatePublished(&pomodoroRemainingSeconds, to: Int(ceil(pomodoroRemainingExact)))
        }
    }

    private func advanceAlarm(dt: TimeInterval, now: Date) {
        if alarmStormActive {
            alarmRemainingExact -= dt
            if alarmRemainingExact <= 0.0 {
                alarmRemainingExact = 0.0
                updatePublished(&alarmRemainingSeconds, to: 0)
                updatePublished(&alarmStormActive, to: false)
            } else {
                updatePublished(&alarmRemainingSeconds, to: Int(ceil(alarmRemainingExact)))
            }
            return
        }

        guard alarmEnabled else { return }

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute
        else {
            return
        }

        if hour == alarmHour && minute == alarmMinute {
            let key = "\(year)-\(month)-\(day)-\(hour):\(minute)"
            if lastTriggeredDayMinuteKey != key {
                lastTriggeredDayMinuteKey = key
                triggerAlarmStormNow()
            }
        }
    }

    private func advanceGusts(dt: TimeInterval, stormActive: Bool) -> Bool {
        guard stormActive else {
            gustElapsed = 0.0
            return false
        }

        gustElapsed += dt
        if gustElapsed >= nextGustInterval {
            gustElapsed = 0.0
            gustSequenceIndex = (gustSequenceIndex + 1) % Self.gustIntervals.count
            nextGustInterval = Self.gustIntervals[gustSequenceIndex]
            return true
        }
        return false
    }

    private func resetGustCycle() {
        gustElapsed = 0.0
        nextGustInterval = Self.gustIntervals[gustSequenceIndex]
    }

    private func updatePublished<T: Equatable>(_ target: inout T, to newValue: T) {
        if target != newValue {
            target = newValue
        }
    }

    private static func formatTime(_ totalSeconds: Int) -> String {
        let clamped = max(0, totalSeconds)
        let minutes = clamped / 60
        let seconds = clamped % 60
        let paddedSeconds = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        return "\(minutes):\(paddedSeconds)"
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private static func clamp<T: Comparable>(_ value: T, min minVal: T, max maxVal: T) -> T {
        Swift.min(maxVal, Swift.max(minVal, value))
    }
}
