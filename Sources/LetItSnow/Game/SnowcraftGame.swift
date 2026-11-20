import CoreGraphics
import Foundation

public enum SnowballPhase: Sendable {
    case resting
    case rolling
    case thrownByPlayer
    case thrownByEnemy
}

public struct Snowball: Identifiable, Sendable {
    public let id: UUID
    public var x: Float
    public var y: Float
    public var vx: Float
    public var vy: Float
    public var radius: Float
    public var rotation: Float
    public var phase: SnowballPhase
    public var age: Float

    public init(
        id: UUID = UUID(),
        x: Float,
        y: Float,
        vx: Float = 0,
        vy: Float = 0,
        radius: Float = 7.0,
        rotation: Float = 0,
        phase: SnowballPhase = .resting,
        age: Float = 0
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.vx = vx
        self.vy = vy
        self.radius = radius
        self.rotation = rotation
        self.phase = phase
        self.age = age
    }
}

public enum SnowcraftDudeState: Sendable {
    case walking
    case aiming
    case throwing
    case knockedOut
}

public struct SnowcraftDude: Identifiable, Sendable {
    public let id: UUID
    public var x: Float
    public var y: Float
    public var vx: Float
    /// +1 facing right, -1 facing left
    public var facing: Float
    public var walkPhase: Float
    public var state: SnowcraftDudeState
    public var stateTimer: Float
    public var hitTilt: Float
    public var opacity: Float
    public var hp: Int
    public var scale: Float
    public var throwCooldown: Float
    public var preferredRange: Float

    public init(
        id: UUID = UUID(),
        x: Float,
        y: Float,
        vx: Float,
        facing: Float,
        scale: Float = 1.0
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.vx = vx
        self.facing = facing
        self.walkPhase = Float.random(in: 0...(Float.pi * 2))
        self.state = .walking
        self.stateTimer = Float.random(in: 1.0...2.4)
        self.hitTilt = 0
        self.opacity = 1.0
        self.hp = 1
        self.scale = scale
        self.throwCooldown = Float.random(in: 1.2...2.6)
        self.preferredRange = Float.random(in: 180...540)
    }

    public var bobOffset: Float {
        state == .walking ? abs(sin(walkPhase)) * 3.5 * scale : 0
    }

    public var centerHitY: Float {
        y - 26.0 * scale
    }
}

public struct ChargeAimState: Sendable {
    public var isActive: Bool = false
    public var anchorX: Float = 0
    public var anchorY: Float = 0
    public var cursorX: Float = 0
    public var cursorY: Float = 0
    public var power: Float = 0
    public var snowballRadius: Float = 10
    public var grabbedBallID: UUID? = nil
    public var launchVelocity: (vx: Float, vy: Float) = (0, 0)
    public var previewPoints: [(x: Float, y: Float)] = []
}

public struct GameStepOutput {
    public var spawnedParticles: [ShedParticle] = []
    public var cursorJustHit: Bool = false
    public var shouldApplyCursorShake: Bool = false
    public var shakeOffset: (dx: Float, dy: Float) = (0, 0)
    public var activeDudesCount: Int = 0
    public var restingSnowballsCount: Int = 0
}

/// Manages snowball rolling, press-and-hold charging/throwing, Red Snowcraft enemy waves,
/// and cursor-hit snow splats + shake.
@MainActor
public final class SnowcraftGame {
    public private(set) var snowballs: [Snowball] = []
    public private(set) var dudes: [SnowcraftDude] = []
    public private(set) var charge = ChargeAimState()

    public private(set) var snowballsRolledTotal: Int = 0
    public private(set) var dudesKnockedOut: Int = 0
    public private(set) var playerHitsTaken: Int = 0

    public private(set) var cursorSnowTimer: Float = 0
    public private(set) var cursorShakeTimer: Float = 0
    public var cursorSplatSeed: Float = 0

    // Pointer gesture tracking
    private var mouseIsDown: Bool = false
    private var downX: Float = 0
    private var downY: Float = 0
    private var lastDragX: Float = 0
    private var lastDragY: Float = 0
    private var holdElapsed: Float = 0
    private var rollingBallID: UUID? = nil
    private var pendingHoldCandidate: Bool = false

    private var waveSpawnTimer: Float = 0
    private var waveActive: Bool = false
    private var simTime: Float = 0

    public init() {}

    public func resetGame() {
        snowballs.removeAll()
        dudes.removeAll()
        charge = ChargeAimState()
        rollingBallID = nil
        pendingHoldCandidate = false
        mouseIsDown = false
        waveActive = false
        snowballsRolledTotal = 0
        dudesKnockedOut = 0
        playerHitsTaken = 0
        cursorSnowTimer = 0
        cursorShakeTimer = 0
    }

    public func spawnWaveNow(bounds: CGSize, groundY: Float) {
        waveActive = true
        let count = Int.random(in: 2...4)
        for i in 0..<count {
            let fromLeft = (i % 2 == 0) ? Bool.random() : (i % 2 == 1)
            spawnDude(fromLeft: fromLeft, bounds: bounds, groundY: groundY, stagger: Float(i) * 28.0)
        }
    }

    public func clearSnowballsAndDudes() {
        snowballs.removeAll()
        dudes.removeAll()
        charge = ChargeAimState()
        rollingBallID = nil
        waveActive = false
    }

    // MARK: - Mouse Input Handling (screen-local top-left coordinates)

    public func handleMouseDown(
        at pt: CGPoint,
        isOverPlayableArea: Bool,
        surfaces: [SnowSurfaceState],
        bounds: CGSize,
        enabled: Bool
    ) {
        guard enabled else { return }
        let x = Float(pt.x)
        let y = Float(pt.y)
        guard x >= 0 && x <= Float(bounds.width) && y >= 0 && y <= Float(bounds.height) else { return }

        mouseIsDown = true
        downX = x
        downY = y
        lastDragX = x
        lastDragY = y
        holdElapsed = 0
        rollingBallID = nil
        pendingHoldCandidate = false

        // 1. Check if clicking near an existing resting snowball -> immediately grab & charge throw!
        if let idx = nearestRestingSnowballIndex(x: x, y: y, maxDist: 44.0) {
            beginChargingThrow(withBallAt: idx, cursorX: x, cursorY: y)
            return
        }

        // 2. If over desktop / snow surface / bottom arena -> start rolling a snowball (or hold to charge!)
        if isOverPlayableArea || isNearSnowSurface(x: x, y: y, surfaces: surfaces, maxDist: 46.0) {
            let newBall = Snowball(
                x: x,
                y: clampRollingY(x: x, y: y, surfaces: surfaces, bounds: bounds),
                radius: 7.5,
                phase: .rolling
            )
            snowballs.append(newBall)
            rollingBallID = newBall.id
            snowballsRolledTotal += 1
            activateWaveIfNeeded()
            trimOldRestingSnowballs()
            return
        }

        // 3. Over an app window: fast clicks/drags pass through untouched,
        // while pressing & holding still for >= 0.22s generates a snowball to charge & throw!
        pendingHoldCandidate = true
    }

    public func handleMouseDragged(
        to pt: CGPoint,
        surfaces: [SnowSurfaceState],
        bounds: CGSize,
        enabled: Bool
    ) -> [ShedParticle] {
        guard enabled, mouseIsDown else { return [] }
        let x = Float(pt.x)
        let y = Float(pt.y)
        let stepDx = x - lastDragX
        let stepDy = y - lastDragY
        let stepDist = hypot(stepDx, stepDy)
        lastDragX = x
        lastDragY = y

        // If charging a throw, update aim
        if charge.isActive {
            charge.cursorX = x
            charge.cursorY = y
            return []
        }

        // If rolling a snowball, move it, spin it, scoop snow, and grow it!
        if let rollID = rollingBallID,
           let idx = snowballs.firstIndex(where: { $0.id == rollID }) {
            var kicked: [ShedParticle] = []
            let targetY = clampRollingY(x: x, y: y, surfaces: surfaces, bounds: bounds)
            snowballs[idx].x = max(8, min(Float(bounds.width) - 8, x))
            snowballs[idx].y = snowballs[idx].y * 0.45 + targetY * 0.55
            let r = max(4, snowballs[idx].radius)
            snowballs[idx].rotation += stepDx / r

            // Scoop snow from surfaces along the rolling path
            var scoopedAmount: Float = 0
            for s in surfaces where s.maxHeight > 0.1 {
                let sMinX = Float(s.rect.minX)
                let sMaxX = Float(s.rect.maxX)
                guard x >= sMinX - 18 && x <= sMaxX + 18 else { continue }
                let cellY = s.surfaceTopY(atCell: s.cellIndex(forX: x))
                if abs(y - cellY) <= 44.0 {
                    let startI = max(0, Int((x - r - sMinX) / s.cellWidth))
                    let endI = min(s.heights.count - 1, Int((x + r - sMinX) / s.cellWidth))
                    if startI <= endI {
                        for c in startI...endI where s.heights[c] > 0.15 {
                            let take = min(s.heights[c], 0.35 + stepDist * 0.04)
                            s.heights[c] -= take
                            scoopedAmount += take
                        }
                    }
                }
            }

            // Grow snowball smoothly as it rolls
            let ambientGrowth = stepDist * 0.018
            let snowGrowth = scoopedAmount * 0.14
            snowballs[idx].radius = min(22.0, snowballs[idx].radius + ambientGrowth + snowGrowth)

            if stepDist > 4 && Float.random(in: 0...1) < 0.45 {
                kicked.append(ShedParticle(
                    x: snowballs[idx].x - stepDx * 0.4,
                    y: snowballs[idx].y + snowballs[idx].radius * 0.6,
                    vx: -stepDx * 2.5 + Float.random(in: -20...20),
                    vy: -Float.random(in: 18...55),
                    radius: Float.random(in: 1.4...2.6),
                    isClump: false
                ))
            }
            return kicked
        }

        // If user moved far while waiting for a hold-charge candidate, cancel (it was a normal window drag)
        if pendingHoldCandidate && hypot(x - downX, y - downY) > 18.0 {
            pendingHoldCandidate = false
        }
        return []
    }

    public func handleMouseUp(
        at pt: CGPoint,
        bounds: CGSize,
        gravityScale: Float
    ) {
        let x = Float(pt.x)
        let y = Float(pt.y)
        mouseIsDown = false
        pendingHoldCandidate = false

        // 1. Release charged throw!
        if charge.isActive {
            charge.cursorX = x
            charge.cursorY = y
            let (vx, vy) = computePlayerLaunchVelocity(
                anchorX: charge.anchorX,
                anchorY: charge.anchorY,
                cursorX: x,
                cursorY: y,
                power: charge.power,
                gravity: 520.0 * max(0.5, gravityScale)
            )
            let launched = Snowball(
                x: charge.anchorX,
                y: charge.anchorY,
                vx: vx,
                vy: vy,
                radius: charge.snowballRadius,
                rotation: 0,
                phase: .thrownByPlayer
            )
            snowballs.append(launched)
            charge = ChargeAimState()
            return
        }

        // 2. Finish rolling a snowball -> leave it resting on the surface
        if let rollID = rollingBallID,
           let idx = snowballs.firstIndex(where: { $0.id == rollID }) {
            snowballs[idx].phase = .resting
            snowballs[idx].vx = 0
            snowballs[idx].vy = 0
            rollingBallID = nil
        }
    }

    // MARK: - Simulation Step

    public func step(
        dt: Float,
        bounds: CGSize,
        surfaces: [SnowSurfaceState],
        cursorPoint: CGPoint?,
        gravityScale: Float,
        maxPileHeight: Float,
        enabled: Bool,
        enemySpeedScale: Float
    ) -> GameStepOutput {
        var output = GameStepOutput()
        simTime += dt

        if cursorSnowTimer > 0 {
            cursorSnowTimer = max(0, cursorSnowTimer - dt)
        }
        if cursorShakeTimer > 0 {
            cursorShakeTimer = max(0, cursorShakeTimer - dt)
            let amp = 8.0 * (cursorShakeTimer / 0.70)
            output.shouldApplyCursorShake = true
            output.shakeOffset = (
                dx: sin(simTime * 78.0) * amp,
                dy: cos(simTime * 91.0) * amp * 0.75
            )
        }

        guard enabled else {
            if !snowballs.isEmpty || !dudes.isEmpty || charge.isActive {
                clearSnowballsAndDudes()
            }
            return output
        }

        let w = Float(bounds.width)
        let h = Float(bounds.height)
        let groundY = groundSurfaceY(surfaces: surfaces, screenHeight: h)
        let ballGravity: Float = 520.0 * max(0.5, gravityScale)

        // 1. Update mouse hold -> transition into Charge Throw Mode (or generate a fresh snowball on hold!)
        if mouseIsDown {
            holdElapsed += dt
            if let rollID = rollingBallID,
               holdElapsed >= 0.18,
               hypot(lastDragX - downX, lastDragY - downY) < 18.0,
               let idx = snowballs.firstIndex(where: { $0.id == rollID }) {
                // Held still after clicking snow/desktop: transition into Charge Throw!
                rollingBallID = nil
                beginChargingThrow(withBallAt: idx, cursorX: lastDragX, cursorY: lastDragY)
            } else if pendingHoldCandidate && holdElapsed >= 0.22 {
                pendingHoldCandidate = false
                if let idx = nearestRestingSnowballIndex(x: downX, y: downY, maxDist: 160.0) {
                    beginChargingThrow(withBallAt: idx, cursorX: lastDragX, cursorY: lastDragY)
                    charge.anchorX = downX
                    charge.anchorY = downY
                } else {
                    // Generate a brand-new snowball right in hand to charge & throw!
                    let generated = Snowball(
                        x: downX,
                        y: downY,
                        radius: 8.0,
                        phase: .resting
                    )
                    snowballsRolledTotal += 1
                    charge = ChargeAimState(
                        isActive: true,
                        anchorX: generated.x,
                        anchorY: generated.y,
                        cursorX: lastDragX,
                        cursorY: lastDragY,
                        power: 0.14,
                        snowballRadius: generated.radius,
                        grabbedBallID: generated.id,
                        launchVelocity: (0, 0),
                        previewPoints: []
                    )
                    activateWaveIfNeeded()
                }
            }
        }

        // 2. Update Charge Throw Power, Pack Size & Trajectory Preview
        if charge.isActive {
            charge.power = min(1.0, charge.power + dt * 1.15)
            charge.snowballRadius = min(14.5, charge.snowballRadius + dt * 3.5)
            let (vx, vy) = computePlayerLaunchVelocity(
                anchorX: charge.anchorX,
                anchorY: charge.anchorY,
                cursorX: charge.cursorX,
                cursorY: charge.cursorY,
                power: charge.power,
                gravity: ballGravity
            )
            charge.launchVelocity = (vx, vy)
            charge.previewPoints = buildTrajectoryPreview(
                startX: charge.anchorX,
                startY: charge.anchorY,
                vx: vx,
                vy: vy,
                gravity: ballGravity,
                steps: 14
            )
        }

        // 3. Wave spawning for Red Snowcraft Dudes
        if waveActive {
            let aliveDudes = dudes.filter { $0.state != .knockedOut }.count
            waveSpawnTimer -= dt
            if aliveDudes == 0 && waveSpawnTimer > 1.2 {
                waveSpawnTimer = 1.1
            }
            if waveSpawnTimer <= 0 && aliveDudes < 6 {
                let spawnCount = aliveDudes == 0 ? Int.random(in: 2...3) : 1
                for i in 0..<spawnCount {
                    spawnDude(
                        fromLeft: Bool.random(),
                        bounds: bounds,
                        groundY: groundY,
                        stagger: Float(i) * 32.0
                    )
                }
                waveSpawnTimer = max(2.0, Float.random(in: 3.2...5.8) / max(0.4, enemySpeedScale))
            }
        }

        // 4. Update Snowballs (gravity on resting balls if unsupported, projectile flight & hits)
        let cx = cursorPoint.map { Float($0.x) }
        let cy = cursorPoint.map { Float($0.y) }

        var bIdx = 0
        while bIdx < snowballs.count {
            var b = snowballs[bIdx]
            b.age += dt

            switch b.phase {
            case .resting:
                // Settle onto ground or supporting surface
                let supportY = supportSurfaceY(x: b.x, currentY: b.y + b.radius, surfaces: surfaces, fallbackGroundY: groundY)
                if b.y + b.radius < supportY - 1.5 {
                    b.vy += ballGravity * 0.8 * dt
                    b.y = min(supportY - b.radius, b.y + b.vy * dt)
                } else {
                    b.y = supportY - b.radius
                    b.vy = 0
                }
                snowballs[bIdx] = b
                bIdx += 1

            case .rolling:
                snowballs[bIdx] = b
                bIdx += 1

            case .thrownByPlayer:
                b.vy += ballGravity * dt
                b.x += b.vx * dt
                b.y += b.vy * dt
                b.rotation += (b.vx >= 0 ? 1 : -1) * 8.0 * dt

                var impacted = false

                // Check hit against Red Snowcraft Dudes
                for dIdx in 0..<dudes.count where dudes[dIdx].state != .knockedOut {
                    let dude = dudes[dIdx]
                    let hitDist = hypot(b.x - dude.x, b.y - dude.centerHitY)
                    if hitDist <= b.radius + 22.0 * dude.scale {
                        impacted = true
                        dudes[dIdx].hp -= (b.radius >= 14.0 ? 2 : 1)
                        if dudes[dIdx].hp <= 0 {
                            dudes[dIdx].state = .knockedOut
                            dudes[dIdx].stateTimer = 1.0
                            dudes[dIdx].vx = (b.vx >= 0 ? 1 : -1) * 85.0
                            dudesKnockedOut += 1
                        } else {
                            dudes[dIdx].vx += (b.vx >= 0 ? 1 : -1) * 55.0
                        }
                        output.spawnedParticles.append(contentsOf: makeSplatBurst(
                            x: b.x, y: b.y, count: 22, speed: 150
                        ))
                        break
                    }
                }

                // Check ground / elevated surface collision
                if !impacted && b.vy > 0 {
                    if let hitSurf = findHitSurface(x: b.x, prevY: b.y - b.vy * dt, y: b.y + b.radius, surfaces: surfaces, groundY: groundY) {
                        impacted = true
                        hitSurf?.deposit(atX: b.x, amount: b.radius * 0.45, maxPileHeight: maxPileHeight)
                        output.spawnedParticles.append(contentsOf: makeSplatBurst(
                            x: b.x, y: b.y, count: 14, speed: 100
                        ))
                    } else if b.y + b.radius >= groundY {
                        impacted = true
                        output.spawnedParticles.append(contentsOf: makeSplatBurst(
                            x: b.x, y: groundY - 2, count: 14, speed: 100
                        ))
                    }
                }

                if impacted || b.x < -60 || b.x > w + 60 || b.y > h + 60 {
                    snowballs.remove(at: bIdx)
                } else {
                    snowballs[bIdx] = b
                    bIdx += 1
                }

            case .thrownByEnemy:
                b.vy += ballGravity * dt
                b.x += b.vx * dt
                b.y += b.vy * dt
                b.rotation += 7.0 * dt

                var impacted = false

                // Check hit on player's mouse cursor!
                if let mx = cx, let my = cy, b.age > 0.08 {
                    let distToMouse = hypot(b.x - mx, b.y - my)
                    if distToMouse <= b.radius + 18.0 {
                        impacted = true
                        playerHitsTaken += 1
                        cursorSnowTimer = 1.65
                        cursorShakeTimer = 0.70
                        cursorSplatSeed = Float.random(in: 0...100)
                        output.cursorJustHit = true
                        output.spawnedParticles.append(contentsOf: makeSplatBurst(
                            x: mx, y: my, count: 24, speed: 160
                        ))
                    }
                }

                if !impacted && b.y + b.radius >= groundY && b.vy > 0 {
                    impacted = true
                    output.spawnedParticles.append(contentsOf: makeSplatBurst(
                        x: b.x, y: groundY - 2, count: 10, speed: 85
                    ))
                }

                if impacted || b.x < -80 || b.x > w + 80 || b.y > h + 80 {
                    snowballs.remove(at: bIdx)
                } else {
                    snowballs[bIdx] = b
                    bIdx += 1
                }
            }
        }

        // 5. Update Red Snowcraft Dudes AI & Animations
        var dIdx = 0
        while dIdx < dudes.count {
            var d = dudes[dIdx]
            d.y = groundY

            switch d.state {
            case .walking:
                let speed = abs(d.vx) * enemySpeedScale
                let targetX = cx ?? (w * 0.5)
                let dirToPlayer: Float = targetX >= d.x ? 1.0 : -1.0
                let distX = abs(targetX - d.x)

                // Keep dudes cleanly inside the screen after entering from left/right edges
                if d.x < 55 {
                    d.facing = 1
                    d.x += speed * dt
                } else if d.x > w - 55 {
                    d.facing = -1
                    d.x -= speed * dt
                } else if distX > d.preferredRange {
                    d.facing = dirToPlayer
                    d.x += dirToPlayer * speed * dt
                } else if distX < d.preferredRange * 0.45 {
                    // Back up a little while still looking at cursor
                    d.facing = dirToPlayer
                    d.x -= dirToPlayer * speed * 0.55 * dt
                } else {
                    d.facing = dirToPlayer
                }

                d.walkPhase += dt * 10.5 * enemySpeedScale
                d.throwCooldown -= dt * enemySpeedScale

                if d.throwCooldown <= 0 && d.x >= 24 && d.x <= w - 24 {
                    d.state = .aiming
                    d.stateTimer = 0.52 / max(0.5, enemySpeedScale)
                }
                dudes[dIdx] = d
                dIdx += 1

            case .aiming:
                if let mx = cx {
                    d.facing = mx >= d.x ? 1.0 : -1.0
                }
                d.stateTimer -= dt
                if d.stateTimer <= 0 {
                    // Throw a ballistic snowball aimed at the player's mouse!
                    let targetX = cx ?? (w * 0.5)
                    let targetY = cy ?? (h * 0.5)
                    let launchX = d.x + d.facing * 14.0 * d.scale
                    let launchY = d.y - 26.0 * d.scale
                    let (evx, evy) = computeEnemyInterceptVelocity(
                        fromX: launchX,
                        fromY: launchY,
                        toX: targetX,
                        toY: targetY,
                        gravity: ballGravity
                    )
                    snowballs.append(Snowball(
                        x: launchX,
                        y: launchY,
                        vx: evx,
                        vy: evy,
                        radius: Float.random(in: 7.0...9.5),
                        phase: .thrownByEnemy
                    ))
                    d.state = .throwing
                    d.stateTimer = 0.25
                }
                dudes[dIdx] = d
                dIdx += 1

            case .throwing:
                d.stateTimer -= dt
                if d.stateTimer <= 0 {
                    d.state = .walking
                    d.throwCooldown = Float.random(in: 1.8...3.4)
                    d.preferredRange = Float.random(in: 150...560)
                }
                dudes[dIdx] = d
                dIdx += 1

            case .knockedOut:
                d.stateTimer -= dt
                d.x += d.vx * dt
                d.vx *= exp(-4.5 * dt)
                d.hitTilt = min(Float.pi * 0.52, d.hitTilt + dt * 5.2)
                d.opacity = max(0, d.stateTimer / 0.85)
                if d.stateTimer <= 0 {
                    dudes.remove(at: dIdx)
                } else {
                    dudes[dIdx] = d
                    dIdx += 1
                }
            }
        }

        output.activeDudesCount = dudes.filter { $0.state != .knockedOut }.count
        output.restingSnowballsCount = snowballs.filter { $0.phase == .resting }.count
        return output
    }

    // MARK: - Helpers

    private func activateWaveIfNeeded() {
        if !waveActive {
            waveActive = true
            waveSpawnTimer = 0.45
        }
    }

    private func spawnDude(fromLeft: Bool, bounds: CGSize, groundY: Float, stagger: Float = 0) {
        let w = Float(bounds.width)
        let startX: Float = fromLeft ? (-24.0 - stagger) : (w + 24.0 + stagger)
        let facing: Float = fromLeft ? 1.0 : -1.0
        let speed = Float.random(in: 44...72)
        dudes.append(SnowcraftDude(
            x: startX,
            y: groundY,
            vx: speed,
            facing: facing,
            scale: Float.random(in: 0.94...1.08)
        ))
    }

    private func beginChargingThrow(withBallAt idx: Int, cursorX: Float, cursorY: Float) {
        let ball = snowballs.remove(at: idx)
        charge = ChargeAimState(
            isActive: true,
            anchorX: ball.x,
            anchorY: ball.y,
            cursorX: cursorX,
            cursorY: cursorY,
            power: 0.14,
            snowballRadius: ball.radius,
            grabbedBallID: ball.id,
            launchVelocity: (0, 0),
            previewPoints: []
        )
        activateWaveIfNeeded()
    }

    private func nearestRestingSnowballIndex(x: Float, y: Float, maxDist: Float) -> Int? {
        var bestIdx: Int? = nil
        var bestDist = maxDist
        for i in 0..<snowballs.count where snowballs[i].phase == .resting {
            let d = hypot(snowballs[i].x - x, snowballs[i].y - y)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        return bestIdx
    }

    private func trimOldRestingSnowballs() {
        let maxResting = 12
        var restingIndices = snowballs.indices.filter { snowballs[$0].phase == .resting }
        while restingIndices.count > maxResting {
            let drop = restingIndices.removeFirst()
            snowballs.remove(at: drop)
            restingIndices = snowballs.indices.filter { snowballs[$0].phase == .resting }
        }
    }

    private func isNearSnowSurface(x: Float, y: Float, surfaces: [SnowSurfaceState], maxDist: Float) -> Bool {
        for s in surfaces {
            guard x >= Float(s.rect.minX) - 10 && x <= Float(s.rect.maxX) + 10 else { continue }
            let cy = s.crestY(atX: x)
            if abs(y - cy) <= maxDist {
                return true
            }
        }
        return false
    }

    private func clampRollingY(x: Float, y: Float, surfaces: [SnowSurfaceState], bounds: CGSize) -> Float {
        let groundY = groundSurfaceY(surfaces: surfaces, screenHeight: Float(bounds.height))
        var bestY = min(y, groundY - 6.0)
        // Snap lightly to nearby elevated snowy ledge if rolling right along it
        for s in surfaces where s.kind != .ground && x >= Float(s.rect.minX) && x <= Float(s.rect.maxX) {
            let sy = s.crestY(atX: x)
            if abs(y - sy) <= 22.0 {
                bestY = sy - 6.0
                break
            }
        }
        return max(12.0, bestY)
    }

    private func groundSurfaceY(surfaces: [SnowSurfaceState], screenHeight: Float) -> Float {
        if let ground = surfaces.first(where: { $0.kind == .ground }) {
            let avg = ground.heights.isEmpty ? 0 : ground.heights[ground.heights.count / 2]
            return Float(ground.rect.minY) - min(8.0, avg * 0.3)
        }
        return screenHeight - 2.0
    }

    private func supportSurfaceY(
        x: Float,
        currentY: Float,
        surfaces: [SnowSurfaceState],
        fallbackGroundY: Float
    ) -> Float {
        var best = fallbackGroundY
        for s in surfaces where x >= Float(s.rect.minX) && x <= Float(s.rect.maxX) {
            let sy = s.crestY(atX: x)
            if sy >= currentY - 12.0 && sy < best {
                best = sy
            }
        }
        return best
    }

    private func findHitSurface(
        x: Float,
        prevY: Float,
        y: Float,
        surfaces: [SnowSurfaceState],
        groundY: Float
    ) -> SnowSurfaceState?? {
        for s in surfaces {
            guard x >= Float(s.rect.minX) && x <= Float(s.rect.maxX) else { continue }
            let crest = s.crestY(atX: x)
            if prevY <= crest + 6.0 && y >= crest - 2.0 && y <= crest + 24.0 {
                return s
            }
        }
        if y >= groundY { return nil }
        return .none
    }

    private func computePlayerLaunchVelocity(
        anchorX: Float,
        anchorY: Float,
        cursorX: Float,
        cursorY: Float,
        power: Float,
        gravity: Float
    ) -> (vx: Float, vy: Float) {
        let dx = cursorX - anchorX
        let dy = cursorY - anchorY
        let dist = hypot(dx, dy)
        let speed = 260.0 + power * 880.0

        if dist < 14.0 {
            // Held mostly in place: lob an arc toward the nearest Snowcraft dude (or forward)
            if let nearest = dudes.filter({ $0.state != .knockedOut })
                .min(by: { hypot($0.x - anchorX, $0.centerHitY - anchorY) < hypot($1.x - anchorX, $1.centerHitY - anchorY) }) {
                return computeBallisticArc(
                    fromX: anchorX,
                    fromY: anchorY,
                    toX: nearest.x,
                    toY: nearest.centerHitY,
                    speed: speed,
                    gravity: gravity
                )
            }
            return (vx: 140.0, vy: -speed * 0.55)
        }

        // Aim from anchor toward cursor with ballistic gravity lift
        let nx = dx / dist
        let ny = dy / dist
        let lift = max(45.0, min(260.0, dist * 0.28 + power * 120.0))
        return (vx: nx * speed, vy: ny * speed - lift)
    }

    private func computeBallisticArc(
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        speed: Float,
        gravity: Float
    ) -> (vx: Float, vy: Float) {
        let dx = toX - fromX
        let dy = toY - fromY
        let dist = max(40.0, hypot(dx, dy))
        let flightTime = max(0.22, min(1.35, dist / max(220.0, speed)))
        let vx = dx / flightTime
        let vy = (dy - 0.5 * gravity * flightTime * flightTime) / flightTime
        return (vx, vy)
    }

    private func computeEnemyInterceptVelocity(
        fromX: Float,
        fromY: Float,
        toX: Float,
        toY: Float,
        gravity: Float
    ) -> (vx: Float, vy: Float) {
        // Add tiny natural scatter so Snowcraft throws feel playful and dodgeable
        let aimX = toX + Float.random(in: -22...22)
        let aimY = toY + Float.random(in: -18...18)
        let dx = aimX - fromX
        let dy = aimY - fromY
        let dist = max(60.0, hypot(dx, dy))
        let flightTime = max(0.45, min(1.25, dist / 620.0))
        let vx = dx / flightTime
        let vy = (dy - 0.5 * gravity * flightTime * flightTime) / flightTime
        return (vx, vy)
    }

    private func buildTrajectoryPreview(
        startX: Float,
        startY: Float,
        vx: Float,
        vy: Float,
        gravity: Float,
        steps: Int
    ) -> [(x: Float, y: Float)] {
        var pts: [(Float, Float)] = []
        pts.reserveCapacity(steps)
        let stepDt: Float = 0.045
        for i in 1...steps {
            let t = Float(i) * stepDt
            let px = startX + vx * t
            let py = startY + vy * t + 0.5 * gravity * t * t
            pts.append((px, py))
        }
        return pts
    }

    private func makeSplatBurst(x: Float, y: Float, count: Int, speed: Float) -> [ShedParticle] {
        var burst: [ShedParticle] = []
        burst.reserveCapacity(count)
        for _ in 0..<count {
            let ang = Float.random(in: 0...(Float.pi * 2))
            let spd = Float.random(in: (speed * 0.35)...speed)
            burst.append(ShedParticle(
                x: x + Float.random(in: -4...4),
                y: y + Float.random(in: -4...4),
                vx: cos(ang) * spd,
                vy: sin(ang) * spd - Float.random(in: 20...75),
                radius: Float.random(in: 1.8...3.8),
                isClump: Bool.random()
            ))
        }
        return burst
    }
}
