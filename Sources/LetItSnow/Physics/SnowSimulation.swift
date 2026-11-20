import CoreGraphics
import Foundation

public struct SnowflakeParticle {
    public var x: Float
    public var y: Float
    public var prevX: Float
    public var prevY: Float
    public var vx: Float
    public var vy: Float
    public var radius: Float
    public var massFactor: Float
    public var dragFactor: Float
    public var flutterPhase: Float
    public var flutterFreq: Float
    public var flutterAmp: Float
    public var rotation: Float
    public var spin: Float
    public var opacity: Float
    /// 0 = soft powder, 1 = 6-point crystal, 2 = clump
    public var flakeKind: UInt8
    public var isForeground: Bool
    public var isClump: Bool
}

/// Pure-Swift aerodynamic snow + granular surface accumulation simulation.
/// Screen-local top-left coordinate space (+X right, +Y down).
@MainActor
public final class SnowSimulation {
    public private(set) var bounds: CGSize
    public private(set) var flakes: [SnowflakeParticle] = []
    public private(set) var surfaces: [SnowSurfaceState] = []
    public let game = SnowcraftGame()
    public private(set) var lastGameOutput = GameStepOutput()

    private var surfaceLookup: [String: SnowSurfaceState] = [:]
    private var simTime: Float = 0
    private var gustOffset: Float = 0
    private var gustDirection: Float = 1

    // Mouse tracking in screen-local top-left coordinates
    public private(set) var hasCursor: Bool = false
    public private(set) var cursorX: Float = 0
    public private(set) var cursorY: Float = 0
    private var cursorVx: Float = 0
    private var cursorVy: Float = 0

    public init(bounds: CGSize) {
        self.bounds = bounds
    }

    public func resize(to newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0 else { return }
        self.bounds = newSize
    }

    public func updateMouse(localPoint: CGPoint?, dt: Float) {
        guard let pt = localPoint else {
            hasCursor = false
            cursorVx = 0
            cursorVy = 0
            return
        }
        let nx = Float(pt.x)
        let ny = Float(pt.y)
        if hasCursor && dt > 0.0005 {
            let instantVx = (nx - cursorX) / dt
            let instantVy = (ny - cursorY) / dt
            // Smooth exponential filter for steady fluid wake
            cursorVx = cursorVx * 0.55 + max(-1800, min(1800, instantVx)) * 0.45
            cursorVy = cursorVy * 0.55 + max(-1800, min(1800, instantVy)) * 0.45
        } else {
            cursorVx = 0
            cursorVy = 0
        }
        cursorX = nx
        cursorY = ny
        hasCursor = true
    }

    public func syncSurfaces(_ detected: [DetectedSurface], iconTopOffset: Float) {
        var nextLookup: [String: SnowSurfaceState] = [:]
        var nextList: [SnowSurfaceState] = []
        nextList.reserveCapacity(detected.count)

        for d in detected {
            if let existing = surfaceLookup[d.id] {
                let shed = existing.updateGeometry(from: d, iconTopOffset: iconTopOffset)
                spawnShedParticles(shed)
                nextLookup[d.id] = existing
                nextList.append(existing)
            } else {
                let created = SnowSurfaceState(surface: d, iconTopOffset: iconTopOffset)
                nextLookup[d.id] = created
                nextList.append(created)
            }
        }

        // Convert snow on disappeared surfaces (e.g., closed/minimized window or hidden Dock) into falling snow!
        for (oldID, oldSurface) in surfaceLookup where nextLookup[oldID] == nil {
            if oldSurface.maxHeight > 0.35 {
                let shed = oldSurface.convertAllSnowToParticles(extraVy: 14)
                spawnShedParticles(shed)
            }
        }

        // Sort surfaces top-to-bottom by baseTopY so collision checks are predictable
        nextList.sort { $0.baseTopY < $1.baseTopY }
        self.surfaceLookup = nextLookup
        self.surfaces = nextList
    }

    public func triggerGust(directionHint: Float = 0) {
        let dir: Float
        if abs(directionHint) > 0.1 {
            dir = directionHint > 0 ? 1 : -1
        } else {
            dir = Bool.random() ? 1 : -1
        }
        gustDirection = dir
        gustOffset = 1.65
    }

    public func shakeSurfaces() {
        for s in surfaces where s.kind != .ground && s.maxHeight > 0.8 {
            let shed = s.convertAllSnowToParticles(extraVy: -15)
            spawnShedParticles(shed)
        }
    }

    public func clearAccumulation() {
        for s in surfaces {
            s.clearSnow()
        }
        flakes.removeAll(keepingCapacity: true)
        game.clearSnowballsAndDudes()
    }

    public func step(
        dt rawDt: Float,
        isSnowing: Bool,
        targetCount: Int,
        flakeSizeScale: Float,
        style: SnowStyle,
        gravityScale: Float,
        windStrength: Float,
        turbulence: Float,
        flutterStrength: Float,
        accumulationEnabled: Bool,
        accumulationRate: Float,
        stickiness: Float,
        maxPileHeight: Float,
        meltRate: Float,
        cursorInteraction: Bool,
        cursorStrength: Float,
        snowcraftEnabled: Bool = true,
        enemySpeedScale: Float = 1.0
    ) {
        let dt = min(max(rawDt, 0.001), 1.0 / 28.0)
        simTime += dt

        // Decay gust smoothly
        if gustOffset > 0.001 {
            gustOffset *= exp(-1.15 * dt)
        } else {
            gustOffset = 0
        }

        let w = Float(bounds.width)
        let h = Float(bounds.height)
        guard w > 10, h > 10 else { return }

        // 1. Maintain target airborne snowflake population
        let activeTarget = isSnowing ? targetCount : 0
        maintainPopulation(
            target: activeTarget,
            width: w,
            height: h,
            flakeSizeScale: flakeSizeScale,
            style: style,
            windStrength: windStrength
        )

        // 2. Cursor brushing on snow piles
        if cursorInteraction && hasCursor {
            let cursorSpeed = hypot(cursorVx, cursorVy)
            if cursorSpeed > 35.0 {
                let brushRadius: Float = 26.0 + min(22.0, cursorSpeed * 0.015)
                for s in surfaces {
                    let kicked = s.brushWithCursor(
                        cursorX: cursorX,
                        cursorY: cursorY,
                        cursorVx: cursorVx,
                        cursorVy: cursorVy,
                        brushRadius: brushRadius,
                        strength: cursorStrength
                    )
                    spawnShedParticles(kicked)
                }
            }
        }

        // 3. Step surface granular heightfields
        let effectiveGust = gustDirection * gustOffset
        let effectiveMelt = accumulationEnabled ? meltRate : max(meltRate, 18.0)
        for s in surfaces {
            let shed = s.stepPhysics(
                dt: dt,
                stickiness: stickiness,
                maxPileHeight: maxPileHeight,
                meltRate: effectiveMelt,
                windStrength: windStrength,
                gustBoost: effectiveGust
            )
            spawnShedParticles(shed)
        }

        // 3.5 Step Snowball & Red Snowcraft Dudes mini-game
        let cursorCG: CGPoint? = hasCursor ? CGPoint(x: CGFloat(cursorX), y: CGFloat(cursorY)) : nil
        let gOut = game.step(
            dt: dt,
            bounds: bounds,
            surfaces: surfaces,
            cursorPoint: cursorCG,
            gravityScale: gravityScale,
            maxPileHeight: maxPileHeight,
            enabled: snowcraftEnabled,
            enemySpeedScale: enemySpeedScale
        )
        self.lastGameOutput = gOut
        spawnShedParticles(gOut.spawnedParticles)

        // 4. Step airborne particles with real aerodynamic drag + turbulence + collisions
        let baseGravity: Float = 155.0 * gravityScale
        let baseWindVx: Float = (windStrength * 260.0) + (effectiveGust * 340.0)
        let cursorSpeed = hypot(cursorVx, cursorVy)
        let interactCursor = cursorInteraction && hasCursor && cursorSpeed > 15.0

        var i = 0
        while i < flakes.count {
            var f = flakes[i]
            f.prevX = f.x
            f.prevY = f.y

            // Local turbulent eddy velocity (curl-like smooth wave field)
            let turb = turbulenceField(x: f.x, y: f.y, t: simTime, scale: turbulence)
            let airVx = baseWindVx + turb.x
            let airVy = turb.y

            // Relative velocity to air mass
            let relVx = f.vx - airVx
            let relVy = f.vy - airVy
            let relSpeed = hypot(relVx, relVy)

            // Linear + quadratic aerodynamic drag
            let dragMag = f.dragFactor * (1.0 + 0.015 * relSpeed)
            var ax = -dragMag * relVx
            let ay = (baseGravity * f.massFactor) - dragMag * relVy

            // Fluttering lift oscillation (lateral sinusoidal motion as crystals tumble)
            f.flutterPhase += f.flutterFreq * dt
            if !f.isClump && flutterStrength > 0.01 {
                let speedNorm = min(1.3, abs(f.vy) / 55.0)
                ax += sin(f.flutterPhase) * f.flutterAmp * flutterStrength * speedNorm
            }

            // Cursor fluid wake
            if interactCursor {
                let dx = f.x - cursorX
                let dy = f.y - cursorY
                let distSq = dx * dx + dy * dy
                let wakeRadius: Float = 85.0
                if distSq < wakeRadius * wakeRadius && distSq > 1.0 {
                    let dist = sqrt(distSq)
                    let falloff = (1.0 - dist / wakeRadius)
                    let push = falloff * falloff * 14.0 * cursorStrength
                    f.vx += (cursorVx * 0.14 + (dx / dist) * min(cursorSpeed, 450.0) * 0.25) * push * dt
                    f.vy += (cursorVy * 0.14 + (dy / dist) * min(cursorSpeed, 450.0) * 0.25) * push * dt
                }
            }

            // Semi-implicit Euler integration
            f.vx += ax * dt
            f.vy += ay * dt
            f.x += f.vx * dt
            f.y += f.vy * dt
            f.rotation += (f.spin + (f.vx - baseWindVx) * 0.008) * dt

            // Wrap horizontally so wind doesn't starve one side of screen
            let margin: Float = 24.0
            if f.x < -margin {
                f.x += w + margin * 2.0
                f.prevX = f.x
            } else if f.x > w + margin {
                f.x -= w + margin * 2.0
                f.prevX = f.x
            }

            // Check landing collision against surfaces (only if accumulation is enabled & moving downward)
            var consumed = false
            if accumulationEnabled && f.vy > 0 {
                for s in surfaces {
                    if f.isForeground && (s.kind == .desktopIcon || s.kind == .desktopFolder || s.kind == .wallpaperScene) {
                        continue
                    }
                    let minX = Float(s.rect.minX) + 1.0
                    let maxX = Float(s.rect.maxX) - 1.0
                    guard f.x >= minX && f.x <= maxX else { continue }

                    let cell = s.cellIndex(forX: f.x)
                    let surfaceY = s.surfaceTopY(atCell: cell)
                    let crest = surfaceY - s.heights[cell]
                    // Swept vertical crossing check relative to local surface contour height
                    if f.prevY <= crest + 5.0 && f.y >= crest - 1.0 && f.y <= surfaceY + 18.0 {
                        // Compute sticking probability: ground always catches; elevated icons/windows stick reliably
                        let stickProb: Float
                        if s.kind == .ground {
                            stickProb = 0.98
                        } else if f.isClump {
                            stickProb = 0.45 + 0.48 * stickiness
                        } else {
                            stickProb = 0.58 + 0.38 * stickiness
                        }

                        if Float.random(in: 0...1) < stickProb {
                            // Deposit snow volume scaled by flake radius & accumulationRate
                            let baseMass = (0.85 + f.radius * 0.42) * (f.isClump ? 1.55 : 1.0)
                            let depositMass = baseMass * max(0.1, accumulationRate)
                            s.deposit(atX: f.x, amount: depositMass, maxPileHeight: maxPileHeight)
                            consumed = true
                            break
                        } else {
                            // Deflect / bounce lightly off surface slope
                            f.y = crest - 1.5
                            f.vy = -f.vy * 0.16
                            f.vx += Float.random(in: -22...22) + baseWindVx * 0.15
                        }
                    }
                }
            }

            if consumed || f.y > h + 30.0 || f.y < -120.0 {
                if !consumed && f.y > h + 30.0 && isSnowing && flakes.count <= activeTarget && !f.isClump {
                    // Recycle smoothly at top
                    flakes[i] = makeFlake(
                        width: w,
                        height: h,
                        spawnAtTop: true,
                        flakeSizeScale: flakeSizeScale,
                        style: style,
                        windStrength: windStrength
                    )
                    i += 1
                } else {
                    flakes.swapAt(i, flakes.count - 1)
                    flakes.removeLast()
                }
            } else {
                flakes[i] = f
                i += 1
            }
        }
    }

    private func maintainPopulation(
        target: Int,
        width: Float,
        height: Float,
        flakeSizeScale: Float,
        style: SnowStyle,
        windStrength: Float
    ) {
        let nonClumpCount = flakes.reduce(0) { $0 + ($1.isClump ? 0 : 1) }
        if nonClumpCount < target {
            // Spawn smoothly (capped per frame so bursts feel organic, except on initial warm-up)
            let deficit = target - nonClumpCount
            let isInitialWarmup = flakes.isEmpty && deficit > 40
            let spawnNow = isInitialWarmup ? min(deficit, 1200) : min(deficit, max(4, target / 25))
            for _ in 0..<spawnNow {
                flakes.append(makeFlake(
                    width: width,
                    height: height,
                    spawnAtTop: !isInitialWarmup,
                    flakeSizeScale: flakeSizeScale,
                    style: style,
                    windStrength: windStrength
                ))
            }
        } else if nonClumpCount > target + 40 {
            // Gently trim excess non-clump flakes
            var toRemove = min(nonClumpCount - target, 25)
            var idx = flakes.count - 1
            while idx >= 0 && toRemove > 0 {
                if !flakes[idx].isClump {
                    flakes.swapAt(idx, flakes.count - 1)
                    flakes.removeLast()
                    toRemove -= 1
                }
                idx -= 1
            }
        }
    }

    public func spawnExternalParticles(_ particles: [ShedParticle]) {
        spawnShedParticles(particles)
    }

    private func spawnShedParticles(_ shed: [ShedParticle]) {
        guard !shed.isEmpty else { return }
        // Cap total particles safely
        let maxTotal = 4500
        for p in shed {
            guard flakes.count < maxTotal else { break }
            flakes.append(SnowflakeParticle(
                x: p.x,
                y: p.y,
                prevX: p.x,
                prevY: p.y,
                vx: p.vx,
                vy: p.vy,
                radius: p.radius,
                massFactor: p.isClump ? Float.random(in: 0.95...1.95) : Float.random(in: 0.65...1.25),
                dragFactor: p.isClump ? Float.random(in: 0.85...2.20) : Float.random(in: 1.60...2.90),
                flutterPhase: Float.random(in: 0...(Float.pi * 2)),
                flutterFreq: Float.random(in: 1.6...4.8),
                flutterAmp: p.isClump ? Float.random(in: 22...78) : Float.random(in: 45...110),
                rotation: Float.random(in: 0...(Float.pi * 2)),
                spin: Float.random(in: -3.5...3.5),
                opacity: Float.random(in: 0.78...0.98),
                flakeKind: p.isClump ? 2 : 0,
                isForeground: false,
                isClump: p.isClump
            ))
        }
    }

    private func makeFlake(
        width: Float,
        height: Float,
        spawnAtTop: Bool,
        flakeSizeScale: Float,
        style: SnowStyle,
        windStrength: Float
    ) -> SnowflakeParticle {
        let isForeground = Float.random(in: 0...1) < 0.12
        let depthBoost: Float = isForeground ? 1.38 : 1.0

        let kind: UInt8
        switch style {
        case .mixed:
            let r = Float.random(in: 0...1)
            kind = r < 0.58 ? 0 : (r < 0.88 ? 1 : 2)
        case .crystals:
            kind = 1
        case .powder:
            kind = 0
        case .clumps:
            kind = Float.random(in: 0...1) < 0.7 ? 2 : 0
        }

        let baseR: Float
        let mass: Float
        let drag: Float
        switch kind {
        case 1: // delicate crystal
            baseR = Float.random(in: 2.4...5.2)
            mass = Float.random(in: 0.55...0.95)
            drag = Float.random(in: 2.0...3.1)
        case 2: // heavy snow clump
            baseR = Float.random(in: 2.2...4.5)
            mass = Float.random(in: 1.05...1.60)
            drag = Float.random(in: 1.3...2.1)
        default: // soft powder
            baseR = Float.random(in: 1.2...3.3)
            mass = Float.random(in: 0.65...1.15)
            drag = Float.random(in: 1.8...2.8)
        }

        let radius = max(1.0, baseR * flakeSizeScale * depthBoost)
        let x = Float.random(in: -16...(width + 16))
        let y = spawnAtTop ? Float.random(in: -32 ... -4) : Float.random(in: 0...(height * 0.88))

        return SnowflakeParticle(
            x: x,
            y: y,
            prevX: x,
            prevY: y,
            vx: windStrength * 120.0 + Float.random(in: -14...14),
            vy: Float.random(in: 30...80),
            radius: radius,
            massFactor: mass * (isForeground ? 1.15 : 1.0),
            dragFactor: drag,
            flutterPhase: Float.random(in: 0...(Float.pi * 2)),
            flutterFreq: Float.random(in: 1.8...4.6),
            flutterAmp: Float.random(in: 45...120),
            rotation: Float.random(in: 0...(Float.pi * 2)),
            spin: Float.random(in: -2.2...2.2),
            opacity: isForeground ? Float.random(in: 0.38...0.65) : Float.random(in: 0.68...0.96),
            flakeKind: kind,
            isForeground: isForeground,
            isClump: false
        )
    }

    @inline(__always)
    private func turbulenceField(x: Float, y: Float, t: Float, scale: Float) -> (x: Float, y: Float) {
        guard scale > 0.005 else { return (0, 0) }
        // Multi-octave smooth swirl field
        let nx = x * 0.0045
        let ny = y * 0.0045
        let vx = sin(ny * 1.7 + t * 0.85) * 62.0
            + cos(nx * 1.3 - ny * 2.1 + t * 1.4) * 34.0
        let vy = cos(nx * 1.6 - t * 0.72) * 38.0
            + sin(nx * 2.3 + ny * 1.1 + t * 1.25) * 22.0
        return (vx * scale, vy * scale)
    }
}
