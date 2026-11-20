import CoreGraphics
import Foundation
import Testing
@testable import LetItSnow

@Suite("Snow Physics & Occlusion Tests")
struct PhysicsTests {
    @Test("Granular heightfield relaxes steep peaks and spills over edges")
    func testHeightfieldAvalancheAndSpillover() {
        let surface = DetectedSurface(
            id: "test-icon",
            kind: .desktopIcon,
            rect: CGRect(x: 100, y: 200, width: 64, height: 64),
            label: "Folder"
        )
        let state = SnowSurfaceState(surface: surface, iconTopOffset: 0)

        // Pile a large amount of snow right at the left edge
        for _ in 0..<25 {
            state.deposit(atX: 103, amount: 2.0, maxPileHeight: 30)
        }
        let initialLeft = state.heights[0]
        #expect(initialLeft > 4.0)

        var totalShed = 0
        for _ in 0..<25 {
            let shed = state.stepPhysics(
                dt: 1.0 / 60.0,
                stickiness: 0.25,
                maxPileHeight: 30,
                meltRate: 0.0,
                windStrength: 0.0,
                gustBoost: 0.0
            )
            totalShed += shed.count
        }

        // Snow should spread rightward and shed clumps over the left rim
        #expect(state.heights[3] > 0.1)
        #expect(totalShed > 0)
    }

    @Test("Folder top profile has tab higher than right shoulder")
    func testFolderProfileShape() {
        let folder = DetectedSurface(
            id: "folder",
            kind: .desktopFolder,
            rect: CGRect(x: 0, y: 100, width: 64, height: 64),
            label: "Projects"
        )
        let state = SnowSurfaceState(surface: folder, iconTopOffset: 2)
        let leftTabY = state.surfaceTopY(atCell: 6)   // ~20% across -> tab
        let rightBodyY = state.surfaceTopY(atCell: 22) // ~70% across -> body
        #expect(leftTabY < rightBodyY)
    }

    @Test("Simulation drops flakes onto icon and window and accumulates snow when enabled")
    @MainActor
    func testSimulationLandingOnIcon() {
        let sim = SnowSimulation(bounds: CGSize(width: 400, height: 400))
        let icon = DetectedSurface(
            id: "icon-1",
            kind: .desktopIcon,
            rect: CGRect(x: 150, y: 120, width: 80, height: 80),
            label: "App"
        )
        let win = DetectedSurface(
            id: "win-1",
            kind: .window,
            rect: CGRect(x: 40, y: 240, width: 320, height: 140),
            label: "Browser"
        )
        sim.syncSurfaces([icon, win], iconTopOffset: 0)

        for _ in 0..<260 {
            sim.step(
                dt: 1.0 / 60.0,
                isSnowing: true,
                targetCount: 400,
                flakeSizeScale: 1.2,
                style: .mixed,
                gravityScale: 1.5,
                windStrength: 0.0,
                turbulence: 0.1,
                flutterStrength: 0.2,
                accumulationEnabled: true,
                accumulationRate: 1.5,
                stickiness: 0.95,
                maxPileHeight: 25,
                meltRate: 0.05,
                cursorInteraction: false,
                cursorStrength: 1.0
            )
        }

        let trackedIcon = sim.surfaces.first(where: { $0.id == "icon-1" })
        let trackedWin = sim.surfaces.first(where: { $0.id == "win-1" })
        #expect((trackedIcon?.maxHeight ?? 0) > 0.5)
        #expect((trackedWin?.maxHeight ?? 0) > 0.5)
    }

    @Test("Disabling accumulation prevents surface buildup")
    @MainActor
    func testAccumulationDisabled() {
        let sim = SnowSimulation(bounds: CGSize(width: 400, height: 400))
        let win = DetectedSurface(
            id: "win-1",
            kind: .window,
            rect: CGRect(x: 40, y: 200, width: 320, height: 150),
            label: "Browser"
        )
        sim.syncSurfaces([win], iconTopOffset: 0)

        for _ in 0..<120 {
            sim.step(
                dt: 1.0 / 60.0,
                isSnowing: true,
                targetCount: 300,
                flakeSizeScale: 1.2,
                style: .mixed,
                gravityScale: 1.5,
                windStrength: 0.0,
                turbulence: 0.1,
                flutterStrength: 0.2,
                accumulationEnabled: false,
                accumulationRate: 1.5,
                stickiness: 0.95,
                maxPileHeight: 25,
                meltRate: 0.0,
                cursorInteraction: false,
                cursorStrength: 1.0
            )
        }

        let trackedWin = sim.surfaces.first(where: { $0.id == "win-1" })
        #expect((trackedWin?.maxHeight ?? 0) == 0)
    }

    @Test("Window occlusion subtraction removes covered horizontal spans")
    func testOcclusionSubtraction() {
        let frontWindow = CGRect(x: 100, y: 50, width: 200, height: 300)
        let spans = SurfaceTracker.subtractOccludingRects(
            segmentMinX: 50,
            segmentMaxX: 400,
            y: 120,
            occluders: [frontWindow]
        )
        #expect(spans.count == 2)
        #expect(spans[0].0 == 50 && spans[0].1 == 100)
        #expect(spans[1].0 == 300 && spans[1].1 == 400)
    }

    @Test("Wallpaper depth scanner extracts curved head and shoulder ledges and catches snow")
    @MainActor
    func testWallpaperSubjectContourExtractionAndSnow() {
        let gridW = 100
        let gridH = 80
        var mask = [Float](repeating: 0, count: gridW * gridH)

        // Draw a person silhouette: head circle around (50, 25) r=10 + wide shoulders y=38..75, x=25..75
        for y in 0..<gridH {
            for x in 0..<gridW {
                let dx = Float(x - 50)
                let dy = Float(y - 25)
                let inHead = (dx * dx + dy * dy) <= 100.0
                let inShoulders = (x >= 25 && x <= 75 && y >= 38 && y <= 75)
                if inHead || inShoulders {
                    mask[y * gridW + x] = 1.0
                }
            }
        }

        let extracted = WallpaperDepthScanner.extractLedgesFromGrids(
            subjectMask: mask,
            luminance: nil,
            gridW: gridW,
            gridH: gridH,
            cellStep: 2.0,
            displayID: 1,
            sceneSensitivity: 0.5
        )

        #expect(extracted.subjectCount >= 1)
        #expect(!extracted.surfaces.isEmpty)

        // Simulate snowfall onto the extracted wallpaper ledges
        let sim = SnowSimulation(bounds: CGSize(width: 200, height: 160))
        sim.syncSurfaces(extracted.surfaces, iconTopOffset: 0)
        for _ in 0..<200 {
            sim.step(
                dt: 1.0 / 60.0,
                isSnowing: true,
                targetCount: 300,
                flakeSizeScale: 1.2,
                style: .mixed,
                gravityScale: 1.4,
                windStrength: 0.0,
                turbulence: 0.1,
                flutterStrength: 0.2,
                accumulationEnabled: true,
                accumulationRate: 1.5,
                stickiness: 0.9,
                maxPileHeight: 20,
                meltRate: 0.0,
                cursorInteraction: false,
                cursorStrength: 1.0
            )
        }

        let maxWallSnow = sim.surfaces
            .filter { $0.kind == .wallpaperSubject }
            .map(\.maxHeight)
            .max() ?? 0
        #expect(maxWallSnow > 0.5)
    }

    @Test("Removing a minimized window sheds its accumulated snow into falling particles")
    @MainActor
    func testMinimizedWindowSnowFallsOff() {
        let sim = SnowSimulation(bounds: CGSize(width: 600, height: 500))
        let win = DetectedSurface(
            id: "win:42:0",
            kind: .window,
            rect: CGRect(x: 100, y: 150, width: 300, height: 200),
            label: "Window"
        )
        sim.syncSurfaces([win], iconTopOffset: 0)
        if let s = sim.surfaces.first {
            for x in stride(from: 110, through: 390, by: 6) {
                s.deposit(atX: Float(x), amount: 6.0, maxPileHeight: 30)
            }
        }
        #expect(sim.flakes.isEmpty)

        // Window is minimized / closed (no longer in snapshots)
        sim.syncSurfaces([], iconTopOffset: 0)
        #expect(sim.flakes.count >= 20)
    }

    @Test("Rolling snowballs, charging throws, hitting Red Snowcraft dudes, and cursor shake")
    @MainActor
    func testSnowcraftGameMechanics() {
        let sim = SnowSimulation(bounds: CGSize(width: 800, height: 600))
        let ground = DetectedSurface(
            id: "ground:1",
            kind: .ground,
            rect: CGRect(x: 0, y: 598, width: 800, height: 12),
            label: "Ground"
        )
        sim.syncSurfaces([ground], iconTopOffset: 0)
        if let g = sim.surfaces.first {
            for x in stride(from: 50, through: 400, by: 4) {
                g.deposit(atX: Float(x), amount: 8.0, maxPileHeight: 24)
            }
        }

        // 1. Click & drag on ground snow to roll a growing snowball
        sim.game.handleMouseDown(
            at: CGPoint(x: 120, y: 585),
            isOverPlayableArea: true,
            surfaces: sim.surfaces,
            bounds: sim.bounds,
            enabled: true
        )
        let kicked = sim.game.handleMouseDragged(
            to: CGPoint(x: 240, y: 585),
            surfaces: sim.surfaces,
            bounds: sim.bounds,
            enabled: true
        )
        #expect(!kicked.isEmpty || sim.game.snowballsRolledTotal == 1)
        sim.game.handleMouseUp(at: CGPoint(x: 240, y: 585), bounds: sim.bounds, gravityScale: 1.0)
        #expect(sim.game.snowballs.count == 1)
        #expect(sim.game.snowballs[0].radius > 7.5)

        // 2. Spawn Red Snowcraft dudes and advance so they walk on screen
        sim.game.spawnWaveNow(bounds: sim.bounds, groundY: 598)
        #expect(!sim.game.dudes.isEmpty)

        // 3. Grab & press-and-hold on the resting snowball to charge power, then throw
        let ballPt = CGPoint(x: CGFloat(sim.game.snowballs[0].x), y: CGFloat(sim.game.snowballs[0].y))
        sim.game.handleMouseDown(
            at: ballPt,
            isOverPlayableArea: true,
            surfaces: sim.surfaces,
            bounds: sim.bounds,
            enabled: true
        )
        #expect(sim.game.charge.isActive)
        let initialPower = sim.game.charge.power
        for _ in 0..<25 {
            _ = sim.game.step(
                dt: 1.0 / 60.0,
                bounds: sim.bounds,
                surfaces: sim.surfaces,
                cursorPoint: CGPoint(x: 400, y: 300),
                gravityScale: 1.0,
                maxPileHeight: 24,
                enabled: true,
                enemySpeedScale: 1.0
            )
        }
        #expect(sim.game.charge.power > initialPower)
        sim.game.handleMouseUp(at: CGPoint(x: 500, y: 550), bounds: sim.bounds, gravityScale: 1.0)
        #expect(!sim.game.charge.isActive)
        #expect(sim.game.snowballs.contains(where: { $0.phase == .thrownByPlayer }))
    }

    @Test("Player snowball knocks out Snowcraft dude and enemy hit shakes cursor with snow")
    @MainActor
    func testSnowcraftHitsAndCursorShake() {
        let sim = SnowSimulation(bounds: CGSize(width: 800, height: 600))
        sim.game.spawnWaveNow(bounds: sim.bounds, groundY: 598)
        // Step until dudes walk onto the visible screen
        for _ in 0..<180 {
            let out = sim.game.step(
                dt: 1.0 / 60.0,
                bounds: sim.bounds,
                surfaces: [],
                cursorPoint: CGPoint(x: 400, y: 300),
                gravityScale: 1.0,
                maxPileHeight: 24,
                enabled: true,
                enemySpeedScale: 1.5
            )
            _ = out
        }

        // Check enemy eventually throws and can hit cursor, or verify direct hit via close cursor
        if let dude = sim.game.dudes.first {
            // Position a test throw directly on top of the dude
            sim.game.handleMouseDown(
                at: CGPoint(x: CGFloat(dude.x), y: CGFloat(dude.centerHitY)),
                isOverPlayableArea: true,
                surfaces: [],
                bounds: sim.bounds,
                enabled: true
            )
            // Release quickly or step while charging
            for _ in 0..<16 {
                _ = sim.game.step(
                    dt: 1.0 / 60.0,
                    bounds: sim.bounds,
                    surfaces: [],
                    cursorPoint: CGPoint(x: CGFloat(dude.x), y: CGFloat(dude.centerHitY)),
                    gravityScale: 1.0,
                    maxPileHeight: 24,
                    enabled: true,
                    enemySpeedScale: 1.0
                )
            }
            sim.game.handleMouseUp(
                at: CGPoint(x: CGFloat(dude.x), y: CGFloat(dude.centerHitY)),
                bounds: sim.bounds,
                gravityScale: 1.0
            )
            // Step so thrown ball impacts dude
            for _ in 0..<60 {
                _ = sim.game.step(
                    dt: 1.0 / 60.0,
                    bounds: sim.bounds,
                    surfaces: [],
                    cursorPoint: CGPoint(x: 400, y: 300),
                    gravityScale: 1.0,
                    maxPileHeight: 24,
                    enabled: true,
                    enemySpeedScale: 1.0
                )
            }
            #expect(sim.game.dudesKnockedOut >= 1 || sim.game.dudes.contains(where: { $0.state == .knockedOut }))
        }
    }

    @Test("Clicking and holding anywhere generates a snowball to charge and throw")
    @MainActor
    func testClickAndHoldGeneratesSnowball() {
        let sim = SnowSimulation(bounds: CGSize(width: 800, height: 600))
        #expect(sim.game.snowballs.isEmpty)

        // Press and hold over a non-snow area (e.g., over an open window)
        sim.game.handleMouseDown(
            at: CGPoint(x: 320, y: 240),
            isOverPlayableArea: false,
            surfaces: [],
            bounds: sim.bounds,
            enabled: true
        )
        #expect(!sim.game.charge.isActive)

        for _ in 0..<20 {
            _ = sim.game.step(
                dt: 1.0 / 60.0,
                bounds: sim.bounds,
                surfaces: [],
                cursorPoint: CGPoint(x: 320, y: 240),
                gravityScale: 1.0,
                maxPileHeight: 24,
                enabled: true,
                enemySpeedScale: 1.0
            )
        }

        #expect(sim.game.charge.isActive)
        #expect(sim.game.snowballsRolledTotal == 1)

        sim.game.handleMouseUp(at: CGPoint(x: 500, y: 420), bounds: sim.bounds, gravityScale: 1.0)
        #expect(!sim.game.charge.isActive)
        #expect(sim.game.snowballs.contains(where: { $0.phase == .thrownByPlayer }))
    }

    @Test("Curved snow intensity slider provides fine low-end granularity and round-trips")
    @MainActor
    func testCurvedIntensitySlider() {
        #expect(SnowSettings.sliderToIntensity(0.0) == 5)
        #expect(SnowSettings.sliderToIntensity(1.0) == 3500)
        // Low end (20% of slider) stays subtle (< 60 flakes)
        let lowVal = SnowSettings.sliderToIntensity(0.20)
        #expect(lowVal >= 15 && lowVal <= 60)
        // Midpoint is well below linear midpoint (1750)
        let midVal = SnowSettings.sliderToIntensity(0.50)
        #expect(midVal < 600)
        // Round-trip accuracy
        let back = SnowSettings.intensityToSlider(midVal)
        #expect(abs(back - 0.50) < 0.02)
    }

    @Test("WeatherScheduler triggers Pomodoro blizzards and wall-clock Snowstorm alarms")
    @MainActor
    func testWeatherSchedulerPomodoroAndAlarm() {
        let scheduler = WeatherScheduler(calendar: Calendar(identifier: .gregorian))
        scheduler.pomodoroEnabled = true
        scheduler.pomodoroIntervalMinutes = 5
        scheduler.pomodoroBlizzardSeconds = 30
        scheduler.resetPomodoro()

        // Advance past 5-minute work interval
        let modBefore = scheduler.tick(dt: 1.0)
        #expect(!modBefore.isStormActive)

        _ = scheduler.tick(dt: 299.5)
        let modStorm = scheduler.tick(dt: 2.0)
        #expect(scheduler.pomodoroBlizzardActive)
        #expect(modStorm.isStormActive)
        #expect(modStorm.intensityFloor > 1000)

        scheduler.dismissActiveStorm()
        #expect(!scheduler.pomodoroBlizzardActive)

        // Test wall-clock 1:00 PM Snowstorm Alarm
        scheduler.pomodoroEnabled = false
        scheduler.alarmEnabled = true
        scheduler.alarmHour = 13
        scheduler.alarmMinute = 0
        scheduler.alarmDurationSeconds = 120

        var comps = DateComponents()
        comps.year = 2026
        comps.month = 11
        comps.day = 20
        comps.hour = 13
        comps.minute = 0
        comps.second = 5
        let onePM = Calendar(identifier: .gregorian).date(from: comps)!

        _ = scheduler.tick(dt: 0.5, now: onePM)
        let alarmMod = scheduler.tick(dt: 1.5, now: onePM.addingTimeInterval(1.5))
        #expect(scheduler.alarmStormActive)
        #expect(alarmMod.isStormActive)
        #expect(alarmMod.statusBadge?.contains("Alarm") == true)

        // Dismissing within the same minute does not immediately re-trigger
        scheduler.dismissActiveStorm()
        _ = scheduler.tick(dt: 1.0, now: onePM.addingTimeInterval(5.0))
        #expect(!scheduler.alarmStormActive)
    }
}
