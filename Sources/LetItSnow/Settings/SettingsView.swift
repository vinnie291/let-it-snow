import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @ObservedObject var settings: SnowSettings
    @State private var isAddingCustomPreset = false
    @State private var newPresetName = ""

    public init(settings: SnowSettings) {
        self.settings = settings
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    if !settings.accessibilityGranted {
                        accessibilityBanner
                    }
                    if let badge = settings.weatherStatusBadge {
                        activeWeatherBanner(badge)
                    }
                    presetsSection
                    snowfallSection
                    physicsSection
                    weatherAutomationSection
                    accumulationSection
                    if settings.accumulationEnabled && settings.landOnWallpaper {
                        wallpaperDepthSection
                    }
                    snowcraftSection
                    interactivitySection
                }
                .padding(18)
            }
            Divider()
            footerBar
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 640, idealHeight: 740)
        .background(.regularMaterial)
    }

    // MARK: - Header & Footer

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.28), Color.blue.opacity(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                Image(systemName: "snowflake")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.cyan)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Let It Snow")
                    .font(.headline)
                HStack(spacing: 8) {
                    telemetryPill(icon: "sparkles", text: "\(settings.activeFlakeCount) flakes")
                    telemetryPill(icon: "macwindow", text: "\(settings.detectedWindowCount) win")
                    telemetryPill(icon: "folder", text: "\(settings.detectedIconCount) icons")
                    telemetryPill(icon: "dock.rectangle", text: "\(settings.detectedDockItemCount) dock")
                    telemetryPill(icon: "photo", text: "\(settings.detectedWallpaperLedgeCount) wall")
                }
            }

            Spacer()

            Toggle(isOn: $settings.isSnowing) {
                Text(settings.isSnowing ? "Snowing" : "Paused")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.switch)
            .tint(.cyan)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func telemetryPill(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(.secondary)
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Enable Accessibility for Desktop Icons, Folders & Dock")
                    .font(.subheadline.weight(.semibold))
                Text("Open windows & screen bottom accumulate immediately. Grant Accessibility so macOS shares exact Finder icon, folder, and Dock positions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Enable Access") {
                requestAccessibility()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button {
                settings.onTriggerGust?()
            } label: {
                Label("Wind Gust", systemImage: "wind")
            }
            .buttonStyle(.bordered)

            Button {
                settings.onShakeSurfaces?()
            } label: {
                Label("Shake Icons", systemImage: "iphone.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)

            Button {
                settings.onClearSnow?()
            } label: {
                Label("Clear Snow", systemImage: "trash")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("Reset Defaults") {
                settings.resetDefaults()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func activeWeatherBanner(_ badge: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: settings.isWeatherStormActive ? "cloud.snow.fill" : "wind.snow")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.cyan)
            Text(badge)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if settings.isWeatherStormActive {
                Button("Dismiss Storm") {
                    settings.onDismissStorm?()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.cyan.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.cyan.opacity(0.35), lineWidth: 1)
                )
        )
    }

    // MARK: - Presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Quick Presets")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isAddingCustomPreset.toggle()
                } label: {
                    Label("Save Current", systemImage: "plus.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.cyan)
            }

            HStack(spacing: 8) {
                ForEach(SnowPreset.allCases) { preset in
                    let isSelected = settings.activePreset == preset
                    Button {
                        settings.applyPreset(preset)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: preset.symbol)
                                .font(.system(size: 14))
                            Text(preset.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isSelected ? Color.cyan.opacity(0.20) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(isSelected ? Color.cyan : Color.clear, lineWidth: 1.2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if isAddingCustomPreset {
                HStack(spacing: 8) {
                    TextField("Preset name (e.g. Subtle Desk Snow)", text: $newPresetName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            saveNewPreset()
                        }
                    Button("Save") {
                        saveNewPreset()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .controlSize(.small)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Cancel") {
                        isAddingCustomPreset = false
                        newPresetName = ""
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }

            if !settings.customPresets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(settings.customPresets) { preset in
                            let isSelected = settings.activeCustomPresetID == preset.id
                            HStack(spacing: 4) {
                                Button {
                                    settings.applyCustomPreset(preset)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.cyan)
                                        Text(preset.name)
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                }
                                .buttonStyle(.plain)

                                Button {
                                    settings.deleteCustomPreset(id: preset.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Delete preset")
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.cyan.opacity(0.22) : Color.primary.opacity(0.06))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(isSelected ? Color.cyan : Color.clear, lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }

    private func saveNewPreset() {
        if settings.saveCustomPreset(name: newPresetName) != nil {
            newPresetName = ""
            isAddingCustomPreset = false
        }
    }

    // MARK: - Sections

    private var snowfallSection: some View {
        SectionCard(title: "Snowfall & Look", icon: "cloud.snow") {
            SliderRow(
                title: "Snow Intensity (Fine Low-End)",
                valueText: "\(Int(settings.intensity)) flakes",
                value: curvedIntensityBinding,
                range: 0.0...1.0,
                step: 0.005
            )
            SliderRow(
                title: "Flake Size",
                valueText: String(format: "%.2fx", settings.flakeSize),
                value: customBinding(\.flakeSize),
                range: 0.5...2.2,
                step: 0.05
            )

            HStack {
                Text("Flake Style")
                    .font(.subheadline)
                Spacer()
                Picker("", selection: customPickerBinding(\.snowStyle)) {
                    ForEach(SnowStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 290)
            }

            HStack {
                Text("Color Mood")
                    .font(.subheadline)
                Spacer()
                Picker("", selection: $settings.snowMood) {
                    ForEach(SnowMood.allCases) { mood in
                        Text(mood.rawValue).tag(mood)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }
        }
    }

    private var physicsSection: some View {
        SectionCard(title: "Physics & Wind", icon: "wind") {
            SliderRow(
                title: "Gravity / Fall Speed",
                valueText: String(format: "%.2fx", settings.gravity),
                value: customBinding(\.gravity),
                range: 0.3...2.5,
                step: 0.05
            )
            SliderRow(
                title: "Wind Speed & Direction",
                valueText: windLabel(settings.wind),
                value: customBinding(\.wind),
                range: -1.0...1.0,
                step: 0.02
            )
            SliderRow(
                title: "Gustiness & Turbulence",
                valueText: "\(Int(settings.turbulence * 100))%",
                value: customBinding(\.turbulence),
                range: 0.0...1.0,
                step: 0.02
            )
            SliderRow(
                title: "Air Drag & Flutter",
                valueText: "\(Int(settings.flutter * 100))%",
                value: customBinding(\.flutter),
                range: 0.0...1.0,
                step: 0.02
            )
        }
    }

    private var accumulationSection: some View {
        SectionCard(title: "Accumulation & Surfaces", icon: "square.stack.3d.up") {
            Toggle("Accumulate Snow on Surfaces", isOn: $settings.accumulationEnabled)
                .font(.subheadline.weight(.medium))

            if settings.accumulationEnabled {
                SliderRow(
                    title: "Accumulation Speed",
                    valueText: String(format: "%.2fx", settings.accumulationRate),
                    value: customBinding(\.accumulationRate),
                    range: 0.25...3.0,
                    step: 0.05
                )
                SliderRow(
                    title: "Snow Stickiness",
                    valueText: stickinessLabel(settings.stickiness),
                    value: customBinding(\.stickiness),
                    range: 0.0...1.0,
                    step: 0.02
                )
                SliderRow(
                    title: "Max Drift Height",
                    valueText: "\(Int(settings.maxPileHeight)) pt",
                    value: customBinding(\.maxPileHeight),
                    range: 4...48,
                    step: 1
                )
                SliderRow(
                    title: "Melt Rate",
                    valueText: settings.meltRate < 0.02 ? "Permanent" : "\(Int(settings.meltRate * 100))%",
                    value: customBinding(\.meltRate),
                    range: 0.0...1.0,
                    step: 0.02
                )

                Divider().padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Landing Surfaces")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        Toggle("Open Windows", isOn: $settings.landOnWindows)
                            .disabled(settings.overlayMode != .aboveAllWindows)
                        Toggle("Desktop Icons", isOn: $settings.landOnDesktopIcons)
                        Toggle("Desktop Folders", isOn: $settings.landOnDesktopFolders)
                        Toggle("Dock & Dock Icons", isOn: $settings.landOnDock)
                        Toggle("Wallpaper (People & Objects)", isOn: $settings.landOnWallpaper)
                        Toggle("Screen Bottom", isOn: $settings.landOnGround)
                    }
                    .font(.subheadline)
                }

                if settings.overlayMode != .aboveAllWindows && settings.landOnWindows {
                    Text("Switch Overlay Layer to \"Above Windows\" to accumulate on open app windows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SliderRow(
                    title: "Icon Top Calibration",
                    valueText: String(format: "%+.0f pt", settings.iconTopOffset),
                    value: $settings.iconTopOffset,
                    range: -8...12,
                    step: 1
                )
            }
        }
    }

    private var wallpaperDepthSection: some View {
        SectionCard(title: "Wallpaper Depth Map", icon: "person.and.background.dotted") {
            HStack(spacing: 8) {
                Circle()
                    .fill(wallpaperStatusColor)
                    .frame(width: 8, height: 8)
                Text(settings.wallpaperStatus.summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if settings.wallpaperStatus == .needsScreenAccess {
                    Button("Scan Live Wallpaper") {
                        settings.onRescanWallpaper?(true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .controlSize(.small)
                }
            }

            Toggle("Include Background Objects & Ridges", isOn: $settings.wallpaperIncludeSceneLedges)
                .font(.subheadline)

            if settings.wallpaperIncludeSceneLedges {
                SliderRow(
                    title: "Scene Depth Sensitivity",
                    valueText: "\(Int(settings.wallpaperSensitivity * 100))%",
                    value: $settings.wallpaperSensitivity,
                    range: 0.0...1.0,
                    step: 0.05
                )
            }

            HStack(spacing: 8) {
                Button {
                    settings.onRescanWallpaper?(true)
                } label: {
                    Label("Rescan Wallpaper", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    pickCustomPhoto()
                } label: {
                    Label("Choose Photo…", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if !settings.customWallpaperPath.isEmpty {
                    Button("Use Desktop") {
                        settings.customWallpaperPath = ""
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var wallpaperStatusColor: Color {
        switch settings.wallpaperStatus {
        case .ready: return .green
        case .scanning: return .cyan
        case .needsScreenAccess: return .orange
        case .idle, .unavailable: return .secondary
        }
    }

    private func pickCustomPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Choose Wallpaper or Photo for Snow Depth Scan"
        if panel.runModal() == .OK, let url = panel.url {
            settings.customWallpaperPath = url.path
        }
    }

    private var snowcraftSection: some View {
        SectionCard(title: "Snowball Fight (Snowcraft)", icon: "figure.snowboarding") {
            Toggle("Enable Snowball Rolling & Red Snowcraft Dudes", isOn: $settings.snowcraftGameEnabled)
                .font(.subheadline.weight(.medium))

            if settings.snowcraftGameEnabled {
                Text("Click & drag on snow/desktop to roll snowballs, or click & hold anywhere to generate a snowball, charge power, aim, and release to throw at the Red Snowcraft dudes!")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 14) {
                    statBadge(label: "Rolled", value: "\(settings.snowballsRolledCount)", color: .cyan)
                    statBadge(label: "KOs", value: "\(settings.dudesKnockedOutCount)", color: .green)
                    statBadge(label: "Hits Taken", value: "\(settings.playerHitsTakenCount)", color: .red)
                }

                Toggle("Shake Mouse Cursor When Hit", isOn: $settings.shakeCursorOnHit)
                    .font(.subheadline)

                Toggle("Allow Rolling Snowballs Anywhere (Even Over Windows)", isOn: $settings.snowcraftRollAnywhere)
                    .font(.subheadline)

                SliderRow(
                    title: "Snowcraft Wave Speed",
                    valueText: String(format: "%.2fx", settings.snowcraftEnemySpeed),
                    value: $settings.snowcraftEnemySpeed,
                    range: 0.5...2.0,
                    step: 0.1
                )

                HStack(spacing: 8) {
                    Button {
                        settings.onSpawnSnowcraftWave?()
                    } label: {
                        Label("Spawn Red Dudes", systemImage: "person.2.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        settings.onResetSnowcraftGame?()
                    } label: {
                        Label("Reset Score", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()
                }
            }
        }
    }

    private func statBadge(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(label):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var weatherAutomationSection: some View {
        SectionCard(title: "Weather Patterns, Pomodoro & Storm Alarm", icon: "timer") {
            Toggle("Variable Weather Patterns", isOn: $settings.dynamicWeatherEnabled)
                .font(.subheadline)
            if settings.dynamicWeatherEnabled {
                Text("Gently cycles between calm flurries, steady snowfall, and brief gusts over time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)

            Toggle("Pomodoro Blizzard Timer", isOn: $settings.pomodoroEnabled)
                .font(.subheadline)
            if settings.pomodoroEnabled {
                HStack {
                    Text(settings.pomodoroCountdownText.isEmpty ? "Ready" : settings.pomodoroCountdownText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.cyan)
                    Spacer()
                    Button("Reset") { settings.onResetPomodoro?() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    Button("Test Blizzard") { settings.onTestPomodoroBlizzard?() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }

                SliderRow(
                    title: "Work Interval",
                    valueText: "\(settings.pomodoroIntervalMinutes) min",
                    value: Binding(
                        get: { Double(settings.pomodoroIntervalMinutes) },
                        set: { settings.pomodoroIntervalMinutes = Int($0) }
                    ),
                    range: 5...90,
                    step: 5
                )
                SliderRow(
                    title: "Blizzard Duration",
                    valueText: "\(settings.pomodoroBlizzardSeconds) sec",
                    value: Binding(
                        get: { Double(settings.pomodoroBlizzardSeconds) },
                        set: { settings.pomodoroBlizzardSeconds = Int($0) }
                    ),
                    range: 10...180,
                    step: 10
                )
            }

            Divider().padding(.vertical, 2)

            Toggle("Snowstorm Alarm", isOn: $settings.alarmEnabled)
                .font(.subheadline)
            if settings.alarmEnabled {
                HStack {
                    Text("Trigger Time")
                        .font(.subheadline)
                    Spacer()
                    DatePicker("", selection: alarmDateBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .frame(width: 96)
                    Button("Test Storm") { settings.onTestAlarmStorm?() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }

                SliderRow(
                    title: "Storm Duration",
                    valueText: "\(settings.alarmDurationSeconds / 60) min",
                    value: Binding(
                        get: { Double(settings.alarmDurationSeconds) },
                        set: { settings.alarmDurationSeconds = Int($0) }
                    ),
                    range: 60...600,
                    step: 60
                )
            }
        }
    }

    private var interactivitySection: some View {
        SectionCard(title: "Efficiency, Interactivity & Display", icon: "gauge.with.dots.needle.33percent") {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mac Efficiency Mode")
                        .font(.subheadline)
                    Text(settings.performanceMode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $settings.performanceMode) {
                    ForEach(PerformanceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
            }

            Divider().padding(.vertical, 2)

            Toggle("Cursor Swirl & Brush Snow Off Icons", isOn: $settings.cursorInteraction)
                .font(.subheadline)

            if settings.cursorInteraction {
                SliderRow(
                    title: "Cursor Brush Strength",
                    valueText: String(format: "%.1fx", settings.cursorStrength),
                    value: $settings.cursorStrength,
                    range: 0.2...2.0,
                    step: 0.1
                )
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Overlay Layer")
                        .font(.subheadline)
                    Text(settings.overlayMode == .aboveAllWindows
                         ? "Falls across everything (icons, Dock & windows)"
                         : "Falls behind app windows, plus Dock snow")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $settings.overlayMode) {
                    ForEach(OverlayLayerMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)
            }

            HStack {
                Toggle("Ice Crystal Sparkle", isOn: $settings.sparkleEnabled)
                Spacer()
                Toggle("Show Collider Outlines", isOn: $settings.showColliders)
            }
            .font(.subheadline)
        }
    }

    // MARK: - Helpers

    private var curvedIntensityBinding: Binding<Double> {
        Binding(
            get: { SnowSettings.intensityToSlider(settings.intensity) },
            set: { t in
                settings.intensity = SnowSettings.sliderToIntensity(t)
                settings.activePreset = nil
                settings.activeCustomPresetID = nil
            }
        )
    }

    private var alarmDateBinding: Binding<Date> {
        Binding(
            get: {
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comps.hour = settings.alarmHour
                comps.minute = settings.alarmMinute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                settings.alarmHour = comps.hour ?? 13
                settings.alarmMinute = comps.minute ?? 0
            }
        )
    }

    private func customBinding(_ keyPath: ReferenceWritableKeyPath<SnowSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newVal in
                settings[keyPath: keyPath] = newVal
                settings.activePreset = nil
                settings.activeCustomPresetID = nil
            }
        )
    }

    private func customPickerBinding<T>(_ keyPath: ReferenceWritableKeyPath<SnowSettings, T>) -> Binding<T> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newVal in
                settings[keyPath: keyPath] = newVal
                settings.activePreset = nil
                settings.activeCustomPresetID = nil
            }
        )
    }

    private func windLabel(_ w: Double) -> String {
        let pct = Int(abs(w) * 100)
        if pct < 4 { return "Calm" }
        return w < 0 ? "← \(pct)%" : "\(pct)% →"
    }

    private func stickinessLabel(_ s: Double) -> String {
        if s < 0.25 { return "Dry Powder (\(Int(s * 100))%)" }
        if s < 0.65 { return "Balanced (\(Int(s * 100))%)" }
        return "Wet Sticky (\(Int(s * 100))%)"
    }

    private func requestAccessibility() {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let opts = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }
}

private struct SliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .tint(.cyan)
        }
    }
}
