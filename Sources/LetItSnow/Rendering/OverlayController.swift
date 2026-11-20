import Cocoa
import Combine
import MetalKit

@MainActor
public final class OverlayController {
    private final class ScreenRig {
        let displayID: CGDirectDisplayID
        var screenFrame: CGRect
        let backingScale: CGFloat
        let simulation: SnowSimulation

        let mainWindow: NSWindow
        let mainView: MTKView
        let mainRenderer: SnowRenderer

        var dockWindow: NSWindow?
        var dockView: MTKView?
        var dockRenderer: SnowRenderer?

        init(
            displayID: CGDirectDisplayID,
            screenFrame: CGRect,
            backingScale: CGFloat,
            simulation: SnowSimulation,
            mainWindow: NSWindow,
            mainView: MTKView,
            mainRenderer: SnowRenderer
        ) {
            self.displayID = displayID
            self.screenFrame = screenFrame
            self.backingScale = backingScale
            self.simulation = simulation
            self.mainWindow = mainWindow
            self.mainView = mainView
            self.mainRenderer = mainRenderer
        }
    }

    private let settings: SnowSettings
    private let device: MTLDevice
    private let tracker: SurfaceTracker
    private let wallpaperScanner = WallpaperDepthScanner()
    private let weatherScheduler = WeatherScheduler()
    private var lastWeatherModulation: WeatherModulation = .neutral
    private var weatherIdleTimer: Timer?
    private var isDisplayAsleepOrLocked: Bool = false

    private var rigs: [CGDirectDisplayID: ScreenRig] = [:]
    private var latestSnapshots: [CGDirectDisplayID: ScreenSurfaceSnapshot] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var lastTelemetryUpdate: CFTimeInterval = 0
    private var lastMouseUpdate: CFTimeInterval = CACurrentMediaTime()

    nonisolated(unsafe) private var globalMouseMonitor: Any?
    nonisolated(unsafe) private var localMouseMonitor: Any?
    private var activeMouseRigID: CGDirectDisplayID?
    private var appliedShakeOffset: CGPoint = .zero

    public init?(settings: SnowSettings) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return nil
        }
        self.settings = settings
        self.device = device
        self.tracker = SurfaceTracker(options: SurfaceTrackingOptions(
            landOnDesktopIcons: settings.accumulationEnabled && settings.landOnDesktopIcons,
            landOnDesktopFolders: settings.accumulationEnabled && settings.landOnDesktopFolders,
            landOnDock: settings.accumulationEnabled && settings.landOnDock,
            landOnGround: settings.accumulationEnabled && settings.landOnGround,
            landOnWindows: settings.accumulationEnabled && settings.landOnWindows && settings.overlayMode == .aboveAllWindows,
            landOnWallpaper: settings.accumulationEnabled && settings.landOnWallpaper,
            includeWallpaperSceneLedges: settings.wallpaperIncludeSceneLedges,
            respectWindowOcclusion: settings.overlayMode == .aboveAllWindows
        ))

        syncWeatherSchedulerFromSettings()
        setupHooks()
        setupPowerAndLockObservers()
        setupMouseMonitors()
        rebuildScreens()
        tracker.start()
        triggerWallpaperScan(allowPermissionPrompt: false)
        startWeatherIdleTimer()
    }

    deinit {
        tracker.stop()
        if let g = globalMouseMonitor { NSEvent.removeMonitor(g) }
        if let l = localMouseMonitor { NSEvent.removeMonitor(l) }
    }

    private func setupHooks() {
        tracker.onUpdate = { [weak self] snapshots in
            Task { @MainActor [weak self] in
                self?.applySnapshots(snapshots)
            }
        }

        settings.onClearSnow = { [weak self] in
            self?.rigs.values.forEach { $0.simulation.clearAccumulation() }
        }
        settings.onTriggerGust = { [weak self] in
            guard let self else { return }
            let hint = Float(self.settings.wind)
            self.rigs.values.forEach { $0.simulation.triggerGust(directionHint: hint) }
        }
        settings.onShakeSurfaces = { [weak self] in
            self?.rigs.values.forEach { $0.simulation.shakeSurfaces() }
        }
        settings.onRescanWallpaper = { [weak self] allowPrompt in
            self?.triggerWallpaperScan(allowPermissionPrompt: allowPrompt)
        }
        settings.onSpawnSnowcraftWave = { [weak self] in
            guard let self else { return }
            for rig in self.rigs.values {
                let groundY = Float(rig.screenFrame.height) - 2.0
                rig.simulation.game.spawnWaveNow(bounds: rig.screenFrame.size, groundY: groundY)
            }
        }
        settings.onResetSnowcraftGame = { [weak self] in
            guard let self else { return }
            self.rigs.values.forEach { $0.simulation.game.resetGame() }
            self.settings.snowballsRolledCount = 0
            self.settings.dudesKnockedOutCount = 0
            self.settings.playerHitsTakenCount = 0
        }
        settings.onResetPomodoro = { [weak self] in
            self?.weatherScheduler.resetPomodoro()
            self?.publishWeatherTelemetry()
        }
        settings.onTestPomodoroBlizzard = { [weak self] in
            self?.weatherScheduler.triggerPomodoroBlizzardNow()
            self?.wakeRenderersIfNeeded()
            self?.publishWeatherTelemetry()
        }
        settings.onTestAlarmStorm = { [weak self] in
            self?.weatherScheduler.triggerAlarmStormNow()
            self?.wakeRenderersIfNeeded()
            self?.publishWeatherTelemetry()
        }
        settings.onDismissStorm = { [weak self] in
            self?.weatherScheduler.dismissActiveStorm()
            self?.publishWeatherTelemetry()
        }

        // Wake paused MTKViews whenever snowing, game, or storm settings turn on
        Publishers.Merge3(
            settings.$isSnowing.map { _ in () },
            settings.$snowcraftGameEnabled.map { _ in () },
            settings.$showColliders.map { _ in () }
        )
        .sink { [weak self] in
            self?.wakeRenderersIfNeeded()
        }
        .store(in: &cancellables)

        // Apply GPU/FPS performance mode live without rebuilding windows
        settings.$performanceMode
            .dropFirst()
            .sink { [weak self] _ in
                self?.applyPerformanceModeToAllRigs()
            }
            .store(in: &cancellables)

        // Sync WeatherScheduler settings
        Publishers.CombineLatest4(
            settings.$dynamicWeatherEnabled,
            settings.$pomodoroEnabled,
            settings.$pomodoroIntervalMinutes,
            settings.$pomodoroBlizzardSeconds
        )
        .combineLatest(Publishers.CombineLatest4(
            settings.$alarmEnabled,
            settings.$alarmHour,
            settings.$alarmMinute,
            settings.$alarmDurationSeconds
        ))
        .sink { [weak self] _, _ in
            self?.syncWeatherSchedulerFromSettings()
            self?.publishWeatherTelemetry()
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.rebuildScreens()
                self?.triggerWallpaperScan(allowPermissionPrompt: false)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                self?.triggerWallpaperScan(allowPermissionPrompt: false)
            }
            .store(in: &cancellables)

        // Observe tracking option changes (including immediate wallpaperIncludeSceneLedges filtering!)
        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                settings.$landOnDesktopIcons,
                settings.$landOnDesktopFolders,
                settings.$landOnDock,
                settings.$landOnGround
            ),
            Publishers.CombineLatest(
                Publishers.CombineLatest4(
                    settings.$landOnWindows,
                    settings.$landOnWallpaper,
                    settings.$accumulationEnabled,
                    settings.$overlayMode
                ),
                settings.$wallpaperIncludeSceneLedges
            )
        )
        .sink { [weak self] left, right in
            guard let self else { return }
            let (icons, folders, dock, ground) = left
            let ((windows, wallpaper, accum, mode), includeScene) = right
            self.tracker.updateOptions(SurfaceTrackingOptions(
                landOnDesktopIcons: accum && icons,
                landOnDesktopFolders: accum && folders,
                landOnDock: accum && dock,
                landOnGround: accum && ground,
                landOnWindows: accum && windows && mode == .aboveAllWindows,
                landOnWallpaper: accum && wallpaper,
                includeWallpaperSceneLedges: includeScene,
                respectWindowOcclusion: mode == .aboveAllWindows
            ))
        }
        .store(in: &cancellables)

        // Only trigger a wallpaper re-scan when sensitivity/photo changes OR when scene ledges are turned ON
        Publishers.CombineLatest(
            settings.$wallpaperSensitivity.dropFirst(),
            settings.$customWallpaperPath.dropFirst()
        )
        .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            self?.triggerWallpaperScan(allowPermissionPrompt: false)
        }
        .store(in: &cancellables)

        settings.$wallpaperIncludeSceneLedges
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.triggerWallpaperScan(allowPermissionPrompt: false)
            }
            .store(in: &cancellables)

        settings.$landOnWallpaper
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.triggerWallpaperScan(allowPermissionPrompt: false)
            }
            .store(in: &cancellables)

        settings.$overlayMode
            .dropFirst()
            .sink { [weak self] _ in
                self?.rebuildScreens()
            }
            .store(in: &cancellables)

        settings.$iconTopOffset
            .dropFirst()
            .sink { [weak self] offset in
                guard let self else { return }
                let fOffset = Float(offset)
                for rig in self.rigs.values {
                    for s in rig.simulation.surfaces {
                        s.rebuildProfile(iconTopOffset: fOffset)
                    }
                }
            }
            .store(in: &cancellables)
    }

    public func rebuildScreens() {
        for rig in rigs.values {
            rig.mainView.isPaused = true
            rig.mainWindow.orderOut(nil)
            rig.dockView?.isPaused = true
            rig.dockWindow?.orderOut(nil)
        }
        rigs.removeAll()

        let screens = NSScreen.screens
        tracker.updateScreens(screens)

        let mode = settings.overlayMode
        let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        let aboveLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        let primaryID = screens.first.flatMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }

        for screen in screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(num.uint32Value)
            let frame = screen.frame
            let backingScale = max(1.0, screen.backingScaleFactor)
            let sim = SnowSimulation(bounds: frame.size)

            let mainWin = makeOverlayWindow(
                frame: frame,
                level: mode == .aboveAllWindows ? aboveLevel : desktopLevel
            )
            let mainView = makeMetalView(frame: CGRect(origin: .zero, size: frame.size), backingScale: backingScale)
            let passFilter: RenderPassFilter = (mode == .aboveAllWindows) ? .all : .desktopOnly
            guard let mainRenderer = SnowRenderer(
                device: device,
                simulation: sim,
                settings: settings,
                passFilter: passFilter,
                isSimulationDriver: true
            ) else { continue }

            mainView.delegate = mainRenderer
            mainWin.contentView = mainView
            mainWin.orderFrontRegardless()

            let rig = ScreenRig(
                displayID: displayID,
                screenFrame: frame,
                backingScale: backingScale,
                simulation: sim,
                mainWindow: mainWin,
                mainView: mainView,
                mainRenderer: mainRenderer
            )

            // In Desktop & Dock mode, attach a lightweight Dock-band overlay at Dock+1 level
            // so snow accumulated on the Dock remains visible on top of the Dock!
            if mode == .desktopAndDock {
                let dockBand = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(160, frame.height))
                let dockWin = makeOverlayWindow(frame: dockBand, level: aboveLevel)
                let dockView = makeMetalView(frame: CGRect(origin: .zero, size: dockBand.size), backingScale: backingScale)
                if let dockRenderer = SnowRenderer(
                    device: device,
                    simulation: sim,
                    settings: settings,
                    passFilter: .dockOnly,
                    isSimulationDriver: false
                ) {
                    dockRenderer.viewportOriginInScreen = CGPoint(
                        x: 0,
                        y: frame.height - dockBand.height
                    )
                    dockView.delegate = dockRenderer
                    dockWin.contentView = dockView
                    dockWin.orderFrontRegardless()
                    rig.dockWindow = dockWin
                    rig.dockView = dockView
                    rig.dockRenderer = dockRenderer
                }
            }

            let isPrimary = (displayID == primaryID)
            mainRenderer.onBeforeStep = { [weak self, weak rig] dt in
                guard let self, let rig else { return }
                if isPrimary {
                    self.lastWeatherModulation = self.weatherScheduler.tick(dt: TimeInterval(dt))
                }
                rig.mainRenderer.currentWeatherModulation = self.lastWeatherModulation
            }
            mainRenderer.onStepComplete = { [weak self, weak rig] in
                guard let self, let rig else { return }
                self.handleStepComplete(for: rig, isPrimary: isPrimary)
            }

            rigs[displayID] = rig
        }

        if !latestSnapshots.isEmpty {
            applySnapshots(latestSnapshots)
        }
    }

    private func setupMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePointerEvent(event, isLocal: false)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handlePointerEvent(event, isLocal: true)
            return event
        }
    }

    private func handlePointerEvent(_ event: NSEvent, isLocal: Bool) {
        guard settings.snowcraftGameEnabled else { return }

        let globalMouse = NSEvent.mouseLocation

        // Ignore clicks inside our own Settings window (or other non-overlay app windows)
        if isLocal, let win = event.window, !isOverlayWindow(win) {
            return
        }
        for win in NSApp.windows where win.isVisible && !isOverlayWindow(win) {
            if win.frame.contains(globalMouse) {
                return
            }
        }

        switch event.type {
        case .leftMouseDown:
            guard let rig = rigs.values.first(where: { $0.screenFrame.contains(globalMouse) }) else {
                return
            }
            activeMouseRigID = rig.displayID
            let localPt = CGPoint(
                x: globalMouse.x - rig.screenFrame.minX,
                y: rig.screenFrame.maxY - globalMouse.y
            )
            let isOverAppWin = latestSnapshots[rig.displayID]?.windowRects.contains(where: { $0.contains(localPt) }) ?? false
            let inBottomArena = localPt.y >= rig.screenFrame.height - 170
            let playable = settings.snowcraftRollAnywhere || !isOverAppWin || inBottomArena
            rig.simulation.game.handleMouseDown(
                at: localPt,
                isOverPlayableArea: playable,
                surfaces: rig.simulation.surfaces,
                bounds: rig.screenFrame.size,
                enabled: settings.snowcraftGameEnabled
            )

        case .leftMouseDragged:
            guard let rid = activeMouseRigID, let rig = rigs[rid] else { return }
            let localPt = CGPoint(
                x: globalMouse.x - rig.screenFrame.minX,
                y: rig.screenFrame.maxY - globalMouse.y
            )
            let kicked = rig.simulation.game.handleMouseDragged(
                to: localPt,
                surfaces: rig.simulation.surfaces,
                bounds: rig.screenFrame.size,
                enabled: settings.snowcraftGameEnabled
            )
            rig.simulation.spawnExternalParticles(kicked)

        case .leftMouseUp:
            guard let rid = activeMouseRigID, let rig = rigs[rid] else { return }
            activeMouseRigID = nil
            let localPt = CGPoint(
                x: globalMouse.x - rig.screenFrame.minX,
                y: rig.screenFrame.maxY - globalMouse.y
            )
            rig.simulation.game.handleMouseUp(
                at: localPt,
                bounds: rig.screenFrame.size,
                gravityScale: Float(settings.gravity)
            )

        default:
            break
        }
    }

    private func isOverlayWindow(_ win: NSWindow) -> Bool {
        for rig in rigs.values {
            if rig.mainWindow === win || rig.dockWindow === win {
                return true
            }
        }
        return false
    }

    private func handleStepComplete(for rig: ScreenRig, isPrimary: Bool) {
        let now = CACurrentMediaTime()
        let dt = Float(max(0.001, now - lastMouseUpdate))
        if isPrimary {
            lastMouseUpdate = now
        }

        // Apply cursor shake when hit by a Red Snowcraft dude's snowball
        let gOut = rig.simulation.lastGameOutput
        if settings.shakeCursorOnHit && (gOut.shouldApplyCursorShake || appliedShakeOffset != .zero) {
            let currentCocoa = NSEvent.mouseLocation
            if rig.screenFrame.contains(currentCocoa) {
                let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                    ?? rig.screenFrame.height
                let baseCocoaX = currentCocoa.x - appliedShakeOffset.x
                let baseCocoaY = currentCocoa.y + appliedShakeOffset.y
                let newOffset = gOut.shouldApplyCursorShake
                    ? CGPoint(x: CGFloat(gOut.shakeOffset.dx), y: CGFloat(gOut.shakeOffset.dy))
                    : .zero
                let targetQuartz = CGPoint(
                    x: baseCocoaX + newOffset.x,
                    y: (primaryHeight - baseCocoaY) + newOffset.y
                )
                CGWarpMouseCursorPosition(targetQuartz)
                CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
                appliedShakeOffset = newOffset
            }
        }

        // Update mouse position in screen-local top-left coordinates
        let globalMouse = NSEvent.mouseLocation
        if rig.screenFrame.contains(globalMouse) {
            let localPt = CGPoint(
                x: globalMouse.x - rig.screenFrame.minX - appliedShakeOffset.x,
                y: rig.screenFrame.maxY - globalMouse.y - appliedShakeOffset.y
            )
            rig.simulation.updateMouse(localPoint: localPt, dt: dt)
        } else {
            rig.simulation.updateMouse(localPoint: nil, dt: dt)
        }

        // Throttle SwiftUI telemetry publishing (~4 Hz)
        if isPrimary && (now - lastTelemetryUpdate) >= 0.25 {
            lastTelemetryUpdate = now
            var totalFlakes = 0
            var totalRolled = 0
            var totalKOs = 0
            var totalHits = 0
            for r in rigs.values {
                totalFlakes += r.simulation.flakes.count
                totalRolled += r.simulation.game.snowballsRolledTotal
                totalKOs += r.simulation.game.dudesKnockedOut
                totalHits += r.simulation.game.playerHitsTaken
            }
            if settings.activeFlakeCount != totalFlakes {
                settings.activeFlakeCount = totalFlakes
            }
            if settings.snowballsRolledCount != totalRolled {
                settings.snowballsRolledCount = totalRolled
            }
            if settings.dudesKnockedOutCount != totalKOs {
                settings.dudesKnockedOutCount = totalKOs
            }
            if settings.playerHitsTakenCount != totalHits {
                settings.playerHitsTakenCount = totalHits
            }
            publishWeatherTelemetry()
            evaluateIdlePause()
        }
    }

    private func syncWeatherSchedulerFromSettings() {
        weatherScheduler.dynamicWeatherEnabled = settings.dynamicWeatherEnabled
        weatherScheduler.pomodoroEnabled = settings.pomodoroEnabled
        weatherScheduler.pomodoroIntervalMinutes = settings.pomodoroIntervalMinutes
        weatherScheduler.pomodoroBlizzardSeconds = settings.pomodoroBlizzardSeconds
        weatherScheduler.alarmEnabled = settings.alarmEnabled
        weatherScheduler.alarmHour = settings.alarmHour
        weatherScheduler.alarmMinute = settings.alarmMinute
        weatherScheduler.alarmDurationSeconds = settings.alarmDurationSeconds
    }

    private func publishWeatherTelemetry() {
        let badge = lastWeatherModulation.statusBadge
        if settings.weatherStatusBadge != badge {
            settings.weatherStatusBadge = badge
        }
        let stormActive = lastWeatherModulation.isStormActive
        if settings.isWeatherStormActive != stormActive {
            settings.isWeatherStormActive = stormActive
        }
        let rem = weatherScheduler.pomodoroRemainingSeconds
        let mins = rem / 60
        let secs = rem % 60
        let text: String
        if weatherScheduler.pomodoroBlizzardActive {
            text = String(format: "Blizzard: %d:%02d", mins, secs)
        } else if settings.pomodoroEnabled {
            text = String(format: "Next blizzard in %d:%02d", mins, secs)
        } else {
            text = ""
        }
        if settings.pomodoroCountdownText != text {
            settings.pomodoroCountdownText = text
        }
    }

    private func startWeatherIdleTimer() {
        weatherIdleTimer?.invalidate()
        weatherIdleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isDisplayAsleepOrLocked else { return }
                let allPaused = self.rigs.values.allSatisfy { $0.mainView.isPaused }
                if allPaused && (self.settings.pomodoroEnabled || self.settings.alarmEnabled) {
                    let mod = self.weatherScheduler.tick(dt: 1.0)
                    self.lastWeatherModulation = mod
                    self.publishWeatherTelemetry()
                    if mod.isStormActive {
                        self.wakeRenderersIfNeeded()
                    }
                }
            }
        }
    }

    private func setupPowerAndLockObservers() {
        let wsNC = NSWorkspace.shared.notificationCenter
        wsNC.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in
                self?.setDisplaySuspended(true)
            }
            .store(in: &cancellables)
        wsNC.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in
                self?.setDisplaySuspended(false)
            }
            .store(in: &cancellables)

        let distNC = DistributedNotificationCenter.default()
        distNC.publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setDisplaySuspended(true)
                }
            }
            .store(in: &cancellables)
        distNC.publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.setDisplaySuspended(false)
                }
            }
            .store(in: &cancellables)
    }

    private func setDisplaySuspended(_ suspended: Bool) {
        isDisplayAsleepOrLocked = suspended
        if suspended {
            tracker.stop()
            for rig in rigs.values {
                rig.mainView.isPaused = true
                rig.dockView?.isPaused = true
            }
        } else {
            tracker.start()
            wakeRenderersIfNeeded()
        }
    }

    private func evaluateIdlePause() {
        guard !isDisplayAsleepOrLocked else { return }
        let shouldRun = settings.isSnowing
            || lastWeatherModulation.isStormActive
            || settings.showColliders
            || rigs.values.contains { rig in
                !rig.simulation.flakes.isEmpty
                    || !rig.simulation.game.dudes.isEmpty
                    || !rig.simulation.game.snowballs.isEmpty
                    || rig.simulation.game.charge.isActive
                    || rig.simulation.surfaces.contains(where: { $0.maxHeight > 0.1 })
            }

        if !shouldRun {
            for rig in rigs.values {
                rig.mainView.isPaused = true
                rig.dockView?.isPaused = true
            }
        }
    }

    private func wakeRenderersIfNeeded() {
        guard !isDisplayAsleepOrLocked else { return }
        for rig in rigs.values {
            if rig.mainView.isPaused {
                rig.mainView.isPaused = false
            }
            if let dockView = rig.dockView, let dockWin = rig.dockWindow {
                dockView.isPaused = !dockWin.isVisible
            }
        }
    }

    private func applyPerformanceModeToAllRigs() {
        let mode = settings.performanceMode
        for rig in rigs.values {
            applyPerformanceMode(mode, to: rig.mainView, logicalSize: rig.screenFrame.size, backingScale: rig.backingScale)
            if let dockView = rig.dockView, let dockWin = rig.dockWindow {
                applyPerformanceMode(mode, to: dockView, logicalSize: dockWin.frame.size, backingScale: rig.backingScale)
            }
        }
    }

    private func applyPerformanceMode(
        _ mode: PerformanceMode,
        to view: MTKView,
        logicalSize: CGSize,
        backingScale: CGFloat
    ) {
        let scale = min(backingScale, mode.maxDrawableScale)
        view.preferredFramesPerSecond = mode.preferredFPS
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(
            width: max(1, (logicalSize.width * scale).rounded()),
            height: max(1, (logicalSize.height * scale).rounded())
        )
    }

    public func triggerWallpaperScan(allowPermissionPrompt: Bool) {
        guard settings.landOnWallpaper else { return }
        settings.wallpaperStatus = .scanning

        let includeScene = settings.wallpaperIncludeSceneLedges
        let sensitivity = Float(settings.wallpaperSensitivity)
        let customPath = settings.customWallpaperPath
        let customURL = customPath.isEmpty ? nil : URL(fileURLWithPath: customPath)

        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(num.uint32Value)
            let wallURL = NSWorkspace.shared.desktopImageURL(for: screen)
            let wallOpts = NSWorkspace.shared.desktopImageOptions(for: screen)

            wallpaperScanner.scanDisplay(
                displayID: displayID,
                screenFrame: screen.frame,
                desktopImageURL: wallURL,
                desktopImageOptions: wallOpts,
                customPhotoURL: customURL,
                includeSceneLedges: includeScene,
                sceneSensitivity: sensitivity,
                allowPermissionPrompt: allowPermissionPrompt
            ) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.tracker.updateWallpaperSurfaces(result.surfaces, for: result.displayID)
                    self.settings.wallpaperStatus = result.status
                    self.settings.detectedWallpaperLedgeCount = result.surfaces.count
                }
            }
        }
    }

    private func applySnapshots(_ snapshots: [CGDirectDisplayID: ScreenSurfaceSnapshot]) {
        self.latestSnapshots = snapshots
        let iconOffset = Float(settings.iconTopOffset)

        var totalIcons = 0
        var totalDock = 0
        var totalWindows = 0
        var totalWall = 0
        var axGranted = false

        for (displayID, snap) in snapshots {
            totalIcons += snap.iconCount
            totalDock += snap.dockItemCount
            totalWindows += snap.windowCount
            totalWall += snap.wallpaperLedgeCount
            axGranted = axGranted || snap.accessibilityGranted

            if let rig = rigs[displayID] {
                rig.simulation.syncSurfaces(snap.surfaces, iconTopOffset: iconOffset)
                updateDockBandIfNeeded(for: rig, surfaces: snap.surfaces)
            }
        }

        settings.detectedIconCount = totalIcons
        settings.detectedDockItemCount = totalDock
        settings.detectedWindowCount = totalWindows
        settings.detectedWallpaperLedgeCount = totalWall
        settings.accessibilityGranted = axGranted
    }

    private func updateDockBandIfNeeded(for rig: ScreenRig, surfaces: [DetectedSurface]) {
        guard let dockWin = rig.dockWindow,
              let dockRenderer = rig.dockRenderer else { return }

        let dockSurfaces = surfaces.filter { $0.kind == .dockIcon || $0.kind == .dockShelf }
        guard !dockSurfaces.isEmpty else {
            // Keep minimal bottom band if snow is still falling off a hiding Dock
            let hasDockSnow = rig.simulation.surfaces.contains {
                ($0.kind == .dockIcon || $0.kind == .dockShelf) && $0.maxHeight > 0.2
            }
            if !hasDockSnow && dockWin.isVisible {
                dockWin.orderOut(nil)
                rig.dockView?.isPaused = true
            }
            return
        }

        var unionRect = dockSurfaces[0].rect
        for s in dockSurfaces.dropFirst() {
            unionRect = unionRect.union(s.rect)
        }

        // Expand upward for tall snow piles + incoming flakes near the Dock
        let padX: CGFloat = 24
        let padTop: CGFloat = 72
        let padBottom: CGFloat = 12

        let localBand = CGRect(
            x: max(0, unionRect.minX - padX),
            y: max(0, unionRect.minY - padTop),
            width: min(rig.screenFrame.width, unionRect.width + padX * 2),
            height: min(rig.screenFrame.height, unionRect.height + padTop + padBottom)
        )
        let clippedBand = localBand.intersection(CGRect(origin: .zero, size: rig.screenFrame.size))
        guard clippedBand.width > 10, clippedBand.height > 10 else { return }

        // Convert screen-local top-left band to Cocoa global frame
        let cocoaFrame = CGRect(
            x: rig.screenFrame.minX + clippedBand.minX,
            y: rig.screenFrame.maxY - clippedBand.maxY,
            width: clippedBand.width,
            height: clippedBand.height
        )

        if abs(dockWin.frame.minX - cocoaFrame.minX) > 1
            || abs(dockWin.frame.minY - cocoaFrame.minY) > 1
            || abs(dockWin.frame.width - cocoaFrame.width) > 1
            || abs(dockWin.frame.height - cocoaFrame.height) > 1 {
            dockWin.setFrame(cocoaFrame, display: false)
            if let dockView = rig.dockView {
                applyPerformanceMode(settings.performanceMode, to: dockView, logicalSize: cocoaFrame.size, backingScale: rig.backingScale)
            }
        }
        dockRenderer.viewportOriginInScreen = clippedBand.origin
        if !dockWin.isVisible {
            dockWin.orderFrontRegardless()
            rig.dockView?.isPaused = isDisplayAsleepOrLocked
        }
    }

    private func makeOverlayWindow(frame: CGRect, level: NSWindow.Level) -> NSWindow {
        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = level
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.isReleasedWhenClosed = false
        return win
    }

    private final class TransparentMTKView: MTKView {
        override var isOpaque: Bool { false }
    }

    private func makeMetalView(frame: CGRect, backingScale: CGFloat) -> MTKView {
        let view = TransparentMTKView(frame: frame, device: device)
        view.wantsLayer = true
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = isDisplayAsleepOrLocked
        view.autoresizingMask = [.width, .height]
        applyPerformanceMode(settings.performanceMode, to: view, logicalSize: frame.size, backingScale: backingScale)
        return view
    }
}
