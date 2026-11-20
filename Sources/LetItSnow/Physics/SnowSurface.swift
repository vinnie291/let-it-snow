import CoreGraphics
import Foundation

public enum SurfaceKind: String, Sendable {
    case desktopIcon
    case desktopFolder
    case dockIcon
    case dockShelf
    case window
    case wallpaperSubject
    case wallpaperScene
    case ground
}

public struct DetectedSurface: Sendable, Equatable {
    public let id: String
    public let kind: SurfaceKind
    public let rect: CGRect
    public let label: String
    public let customTopProfile: [Float]?

    public init(
        id: String,
        kind: SurfaceKind,
        rect: CGRect,
        label: String = "",
        customTopProfile: [Float]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.rect = rect
        self.label = label
        self.customTopProfile = customTopProfile
    }
}

public struct ShedParticle: Sendable {
    public let x: Float
    public let y: Float
    public let vx: Float
    public let vy: Float
    public let radius: Float
    public let isClump: Bool
}

/// Represents a physical snow-catching surface with a 1D granular heightfield.
/// Coordinates are screen-local top-left (x right, y down).
public final class SnowSurfaceState {
    public let id: String
    public let kind: SurfaceKind
    public var label: String
    public var rect: CGRect
    public var prevRect: CGRect

    public let cellWidth: Float = 2.0
    public var heights: [Float]
    public var topProfile: [Float]
    public var customProfileSource: [Float]?
    public var sparkleSeeds: [Float]
    public var baseTopY: Float
    public var maxHeight: Float = 0
    private var spilloverCooldown: Float = 0

    public init(surface: DetectedSurface, iconTopOffset: Float) {
        self.id = surface.id
        self.kind = surface.kind
        self.label = surface.label
        self.rect = surface.rect
        self.prevRect = surface.rect
        self.baseTopY = Float(surface.rect.minY)
        self.customProfileSource = surface.customTopProfile

        let count = max(4, Int(ceil(Float(surface.rect.width) / cellWidth)))
        self.heights = [Float](repeating: 0, count: count)
        self.topProfile = [Float](repeating: 0, count: count)
        self.sparkleSeeds = (0..<count).map { _ in Float.random(in: 0...100) }
        rebuildProfile(iconTopOffset: iconTopOffset)
    }

    public func updateGeometry(from surface: DetectedSurface, iconTopOffset: Float) -> [ShedParticle] {
        var shed: [ShedParticle] = []
        let dy = Float(surface.rect.minY - rect.minY)
        let dx = Float(surface.rect.minX - rect.minX)

        // If a surface drops rapidly (e.g., Dock hiding or window dragged down fast),
        // detach accumulated snow from the OLD Y position so it cascades down naturally!
        if dy > 10.0 && maxHeight > 0.6 {
            shed = convertAllSnowToParticles(extraVy: min(dy * 0.6, 45.0))
        } else if abs(dx) > 14.0 && maxHeight > 1.0 && kind == .window {
            // Sideways window drag shakes loose some trailing snow
            let count = min(20, max(4, heights.count / 24))
            for _ in 0..<count {
                let i = Int.random(in: 0..<heights.count)
                if heights[i] > 0.8 {
                    let drop = min(heights[i] * 0.45, 2.2)
                    heights[i] -= drop
                    shed.append(ShedParticle(
                        x: xForCell(i),
                        y: surfaceTopY(atCell: i) - heights[i],
                        vx: -dx * 1.4 + Float.random(in: -20...20),
                        vy: Float.random(in: 8...35),
                        radius: Float.random(in: 1.8...3.4),
                        isClump: true
                    ))
                }
            }
        }

        prevRect = rect
        rect = surface.rect
        label = surface.label
        baseTopY = Float(surface.rect.minY)
        customProfileSource = surface.customTopProfile

        let newCount = max(4, Int(ceil(Float(surface.rect.width) / cellWidth)))
        if newCount != heights.count {
            heights = resampleHeights(heights, to: newCount)
            sparkleSeeds = (0..<newCount).map { i in
                i < sparkleSeeds.count ? sparkleSeeds[i] : Float.random(in: 0...100)
            }
        }
        rebuildProfile(iconTopOffset: iconTopOffset)
        recomputeMaxHeight()
        return shed
    }

    public func rebuildProfile(iconTopOffset: Float) {
        let n = heights.count
        if topProfile.count != n {
            topProfile = [Float](repeating: 0, count: n)
        }
        let denom = Float(max(1, n - 1))

        for i in 0..<n {
            let u = Float(i) / denom // 0..1 across width
            switch kind {
            case .desktopFolder:
                // macOS folder icon inside 64x64 AX box:
                // left tab sits higher (~u in 0.08..0.44), right shoulder ~4.5pt lower
                let tabDrop: Float
                if u < 0.06 || u > 0.94 {
                    tabDrop = 8.0
                } else if u < 0.42 {
                    tabDrop = 2.5
                } else if u < 0.48 {
                    let t = (u - 0.42) / 0.06
                    tabDrop = 2.5 + 4.5 * t
                } else {
                    tabDrop = 7.0
                }
                topProfile[i] = iconTopOffset + tabDrop

            case .desktopIcon:
                // Rounded app/document icon shoulders
                let edgeDist = min(u, 1.0 - u)
                let shoulder: Float = edgeDist < 0.14 ? (1.0 - edgeDist / 0.14) * 5.0 : 0.0
                topProfile[i] = iconTopOffset + 3.0 + shoulder

            case .dockIcon:
                // Squircle Dock icon: gentle rounded corners
                let edgeDist = min(u, 1.0 - u)
                let shoulder: Float = edgeDist < 0.16 ? pow(1.0 - edgeDist / 0.16, 1.6) * 6.0 : 0.0
                topProfile[i] = max(0, iconTopOffset * 0.5) + 3.0 + shoulder

            case .dockShelf:
                topProfile[i] = 2.5

            case .window:
                // Window corner rounding (macOS windows have ~10pt corner radius)
                // +2.5pt top bevel offset keeps snow visible even on full-height windows below Menu Bar
                let px = u * Float(rect.width)
                let rx = Float(rect.width) - px
                let corner = min(px, rx)
                let drop: Float = corner < 9.0 ? (9.0 - corner) * 0.45 : 0.0
                topProfile[i] = 2.5 + drop

            case .wallpaperSubject, .wallpaperScene:
                if let custom = customProfileSource, !custom.isEmpty {
                    if custom.count == n {
                        topProfile[i] = custom[i]
                    } else {
                        let pos = u * Float(custom.count - 1)
                        let lo = Int(floor(pos))
                        let hi = min(custom.count - 1, lo + 1)
                        let frac = pos - Float(lo)
                        topProfile[i] = custom[lo] * (1.0 - frac) + custom[hi] * frac
                    }
                } else {
                    topProfile[i] = 0.0
                }

            case .ground:
                topProfile[i] = 0.0
            }
        }
    }

    /// Surface resting Y (without snow) at screen-local X
    @inline(__always)
    public func surfaceTopY(atCell i: Int) -> Float {
        let clamped = max(0, min(heights.count - 1, i))
        return baseTopY + topProfile[clamped]
    }

    /// Snow crest Y (surface top minus snow pile height) at screen-local X
    @inline(__always)
    public func crestY(atX x: Float) -> Float {
        let i = cellIndex(forX: x)
        return surfaceTopY(atCell: i) - heights[i]
    }

    @inline(__always)
    public func cellIndex(forX x: Float) -> Int {
        let localX = x - Float(rect.minX)
        let idx = Int(localX / cellWidth)
        return max(0, min(heights.count - 1, idx))
    }

    @inline(__always)
    public func xForCell(_ i: Int) -> Float {
        return Float(rect.minX) + (Float(i) + 0.5) * cellWidth
    }

    /// Deposits snow mass from a landed flake smoothly across 3 cells.
    public func deposit(atX x: Float, amount: Float, maxPileHeight: Float) {
        let center = cellIndex(forX: x)
        let weights: [(Int, Float)] = [
            (center - 1, 0.24),
            (center, 0.52),
            (center + 1, 0.24)
        ]
        for (idx, w) in weights where idx >= 0 && idx < heights.count {
            let cap = maxPileHeight * (kind == .ground ? 1.4 : 1.0)
            heights[idx] = min(cap + 4.0, heights[idx] + amount * w)
        }
        if heights[center] > maxHeight {
            maxHeight = heights[center]
        }
    }

    /// Runs granular angle-of-repose avalanche relaxation, edge spillover, wind erosion, and melt.
    public func stepPhysics(
        dt: Float,
        stickiness: Float,
        maxPileHeight: Float,
        meltRate: Float,
        windStrength: Float,
        gustBoost: Float
    ) -> [ShedParticle] {
        let n = heights.count
        guard n >= 4 && maxHeight > 0.02 else { return [] }

        if spilloverCooldown > 0 {
            spilloverCooldown = max(0, spilloverCooldown - dt)
        }

        // 1. Melting / sublimation (gentle rate so drifts build naturally)
        if meltRate > 0.001 && maxHeight > 0 {
            let meltAmount = meltRate * 0.16 * dt
            for i in 0..<n where heights[i] > 0 {
                heights[i] = max(0, heights[i] - meltAmount)
            }
        }

        // 2. Angle of repose relaxation (taking topProfile into account so snow slides down folder steps!)
        // Dry powder (stickiness=0): ~0.65pt per 2pt cell (~18 deg)
        // Wet sticky (stickiness=1): ~2.35pt per 2pt cell (~50 deg)
        let maxSlope = 0.65 + stickiness * 1.70
        let relaxRate: Float = 0.34

        for pass in 0..<3 {
            if pass % 2 == 0 {
                for i in 0..<(n - 1) {
                    let yA = surfaceTopY(atCell: i) - heights[i]
                    let yB = surfaceTopY(atCell: i + 1) - heights[i + 1]
                    // Remember +Y is down, so higher pile = smaller Y!
                    let diff = yB - yA // positive means A is higher than B
                    if diff > maxSlope && heights[i] > 0.05 {
                        let flow = min(heights[i], (diff - maxSlope) * relaxRate)
                        heights[i] -= flow
                        heights[i + 1] += flow
                    } else if -diff > maxSlope && heights[i + 1] > 0.05 {
                        let flow = min(heights[i + 1], (-diff - maxSlope) * relaxRate)
                        heights[i + 1] -= flow
                        heights[i] += flow
                    }
                }
            } else {
                for i in stride(from: n - 2, through: 0, by: -1) {
                    let yA = surfaceTopY(atCell: i) - heights[i]
                    let yB = surfaceTopY(atCell: i + 1) - heights[i + 1]
                    let diff = yB - yA
                    if diff > maxSlope && heights[i] > 0.05 {
                        let flow = min(heights[i], (diff - maxSlope) * relaxRate)
                        heights[i] -= flow
                        heights[i + 1] += flow
                    } else if -diff > maxSlope && heights[i + 1] > 0.05 {
                        let flow = min(heights[i + 1], (-diff - maxSlope) * relaxRate)
                        heights[i + 1] -= flow
                        heights[i] += flow
                    }
                }
            }
        }

        // 3. Edge spillover (throttled & scattered so icons shed natural clumps, never a continuous ribbon)
        var shed: [ShedParticle] = []
        if kind != .ground {
            let edgeLimit = max(2.0, maxSlope * 1.25)
            // Left rim spillover
            if heights[0] > edgeLimit {
                let excess = min(heights[0] - edgeLimit * 0.72, 1.8)
                heights[0] -= excess
                if spilloverCooldown <= 0 && Float.random(in: 0...1) < 0.25 {
                    let clumpRadius = max(1.6, min(3.6, 1.4 + excess * 0.85))
                    shed.append(ShedParticle(
                        x: Float(rect.minX) + Float.random(in: -4.5...3.0),
                        y: surfaceTopY(atCell: 0) - heights[0] + Float.random(in: -2.0...2.0),
                        vx: -Float.random(in: 12...46) + windStrength * 30.0,
                        vy: Float.random(in: -6...26),
                        radius: clumpRadius,
                        isClump: true
                    ))
                    spilloverCooldown = Float.random(in: 0.22...0.52)
                }
            }
            // Right rim spillover
            if heights[n - 1] > edgeLimit {
                let excess = min(heights[n - 1] - edgeLimit * 0.72, 1.8)
                heights[n - 1] -= excess
                if spilloverCooldown <= 0 && Float.random(in: 0...1) < 0.25 {
                    let clumpRadius = max(1.6, min(3.6, 1.4 + excess * 0.85))
                    shed.append(ShedParticle(
                        x: Float(rect.maxX) + Float.random(in: -3.0...4.5),
                        y: surfaceTopY(atCell: n - 1) - heights[n - 1] + Float.random(in: -2.0...2.0),
                        vx: Float.random(in: 12...46) + windStrength * 30.0,
                        vy: Float.random(in: -6...26),
                        radius: clumpRadius,
                        isClump: true
                    ))
                    spilloverCooldown = Float.random(in: 0.22...0.52)
                }
            }

            // Cap excess above maxPileHeight cleanly (compact without pouring a constant stream)
            let cap = maxPileHeight
            for i in 0..<n where heights[i] > cap {
                let over = heights[i] - cap
                heights[i] = cap
                if over > 0.5 && spilloverCooldown <= 0 && shed.isEmpty && Float.random(in: 0...1) < 0.12 {
                    shed.append(ShedParticle(
                        x: xForCell(i) + Float.random(in: -4...4),
                        y: surfaceTopY(atCell: i) - heights[i] - 1.0,
                        vx: windStrength * 45.0 + Float.random(in: -35...35),
                        vy: Float.random(in: -14...16),
                        radius: Float.random(in: 1.5...3.0),
                        isClump: true
                    ))
                    spilloverCooldown = Float.random(in: 0.25...0.55)
                }
            }
        }

        // 4. Strong wind spindrift erosion on tall exposed peaks
        let totalWind = abs(windStrength) + abs(gustBoost)
        if totalWind > 0.55 && maxHeight > 3.0 {
            let blowChance = min(0.35, (totalWind - 0.55) * 0.35)
            if Float.random(in: 0...1) < blowChance {
                let i = Int.random(in: 0..<n)
                if heights[i] > 3.0 {
                    let take = min(heights[i] * 0.25, 1.4)
                    heights[i] -= take
                    let wDir: Float = (windStrength + gustBoost) >= 0 ? 1.0 : -1.0
                    shed.append(ShedParticle(
                        x: xForCell(i),
                        y: surfaceTopY(atCell: i) - heights[i] - 1.5,
                        vx: wDir * Float.random(in: 45...120),
                        vy: -Float.random(in: 12...45),
                        radius: Float.random(in: 1.3...2.5),
                        isClump: false
                    ))
                }
            }
        }

        recomputeMaxHeight()
        return shed
    }

    /// Brushes snow off the surface when the user swipes the cursor through a snowbank!
    public func brushWithCursor(
        cursorX: Float,
        cursorY: Float,
        cursorVx: Float,
        cursorVy: Float,
        brushRadius: Float,
        strength: Float
    ) -> [ShedParticle] {
        guard maxHeight > 0.25 else { return [] }
        let minX = Float(rect.minX) - brushRadius
        let maxX = Float(rect.maxX) + brushRadius
        guard cursorX >= minX && cursorX <= maxX else { return [] }
        guard cursorY >= baseTopY - maxHeight - brushRadius && cursorY <= Float(rect.maxY) + 24.0 + brushRadius else {
            return []
        }

        var kicked: [ShedParticle] = []
        let startIdx = max(0, Int((cursorX - brushRadius - Float(rect.minX)) / cellWidth))
        let endIdx = min(heights.count - 1, Int((cursorX + brushRadius - Float(rect.minX)) / cellWidth))
        guard startIdx <= endIdx else { return [] }

        for i in startIdx...endIdx where heights[i] > 0.25 {
            let cx = xForCell(i)
            let cy = surfaceTopY(atCell: i) - heights[i] * 0.5
            let dx = cx - cursorX
            let dy = cy - cursorY
            let dist = hypot(dx, dy)
            if dist < brushRadius {
                let falloff = (1.0 - dist / brushRadius) * min(1.0, strength)
                let scoop = min(heights[i], heights[i] * 0.65 * falloff + 0.5 * falloff)
                if scoop > 0.12 {
                    heights[i] -= scoop
                    if kicked.count < 14 && Float.random(in: 0...1) < 0.55 {
                        kicked.append(ShedParticle(
                            x: cx,
                            y: surfaceTopY(atCell: i) - heights[i] - 2.0,
                            vx: cursorVx * Float.random(in: 0.35...0.75) + Float.random(in: -30...30),
                            vy: min(-15.0, cursorVy * 0.45 - Float.random(in: 20...75)),
                            radius: Float.random(in: 1.6...3.4),
                            isClump: scoop > 1.2
                        ))
                    }
                }
            }
        }
        recomputeMaxHeight()
        return kicked
    }

    public func convertAllSnowToParticles(extraVy: Float = 0) -> [ShedParticle] {
        var out: [ShedParticle] = []
        let maxParticles = kind == .window ? 140 : 48
        let strideStep = max(1, heights.count / maxParticles)
        for i in stride(from: 0, to: heights.count, by: strideStep) where heights[i] > 0.35 {
            let h = heights[i]
            let x = xForCell(i)
            let y = surfaceTopY(atCell: i) - h * 0.5
            out.append(ShedParticle(
                x: x,
                y: y,
                vx: Float.random(in: -24...24),
                vy: extraVy + Float.random(in: 8...48),
                radius: min(4.2, 1.5 + h * 0.16),
                isClump: h > 2.0
            ))
            // Add extra powder puff for thick drifts when a window disappears
            if h > 5.0 && out.count < maxParticles {
                out.append(ShedParticle(
                    x: x + Float.random(in: -3...3),
                    y: y - h * 0.3,
                    vx: Float.random(in: -32...32),
                    vy: extraVy + Float.random(in: 2...28),
                    radius: Float.random(in: 1.3...2.5),
                    isClump: false
                ))
            }
        }
        for i in 0..<heights.count {
            heights[i] = 0
        }
        maxHeight = 0
        return out
    }

    public func clearSnow() {
        for i in 0..<heights.count {
            heights[i] = 0
        }
        maxHeight = 0
    }

    private func recomputeMaxHeight() {
        var m: Float = 0
        for h in heights where h > m {
            m = h
        }
        maxHeight = m
    }

    private func resampleHeights(_ old: [Float], to newCount: Int) -> [Float] {
        guard !old.isEmpty, newCount > 0 else { return [Float](repeating: 0, count: max(4, newCount)) }
        if old.count == newCount { return old }
        var res = [Float](repeating: 0, count: newCount)
        let scale = Float(old.count - 1) / Float(max(1, newCount - 1))
        for i in 0..<newCount {
            let pos = Float(i) * scale
            let lo = Int(floor(pos))
            let hi = min(old.count - 1, lo + 1)
            let frac = pos - Float(lo)
            res[i] = old[lo] * (1.0 - frac) + old[hi] * frac
        }
        return res
    }
}
