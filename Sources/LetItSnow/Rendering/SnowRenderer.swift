import Cocoa
import Metal
import MetalKit
import simd

public enum RenderPassFilter: Sendable {
    case all
    case desktopOnly
    case dockOnly
}

struct GPUUniforms {
    var viewportSize: SIMD2<Float>
    var time: Float
    var sparkleEnabled: Float
    var tintColor: SIMD4<Float>
    var shadowTint: SIMD4<Float>
}

struct GPUFlakeInstance {
    var center: SIMD2<Float>
    var radius: Float
    var rotation: Float
    var opacity: Float
    var kind: Float
    var foreground: Float
    var pad: Float = 0
}

struct GPUPileVertex {
    var pos: SIMD2<Float>
    var edgeFrac: Float
    var heightNorm: Float
    var sparkleSeed: Float
    var pad: Float = 0
}

struct GPUDebugVertex {
    var pos: SIMD2<Float>
    var color: SIMD4<Float>
}

struct GPUSnowballInstance {
    var center: SIMD2<Float>
    var radius: Float
    var rotation: Float
    var opacity: Float
    var kind: Float
    var pad: SIMD2<Float> = .zero
}

struct GPUChargeRingInstance {
    var center: SIMD2<Float>
    var radius: Float
    var power: Float
}

struct GPUDudeInstance {
    var footPos: SIMD2<Float>
    var scale: Float
    var facing: Float
    var walkPhase: Float
    var state: Float
    var hitTilt: Float
    var opacity: Float
}

@MainActor
public final class SnowRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let flakePipeline: MTLRenderPipelineState
    private let pilePipeline: MTLRenderPipelineState
    private let debugPipeline: MTLRenderPipelineState
    private let snowballPipeline: MTLRenderPipelineState
    private let chargeRingPipeline: MTLRenderPipelineState
    private let dudePipeline: MTLRenderPipelineState

    private let simulation: SnowSimulation
    private let settings: SnowSettings
    private let passFilter: RenderPassFilter
    private let isSimulationDriver: Bool

    /// Origin of this view inside the screen-local top-left coordinate space.
    /// Full-screen overlays use (0,0); Dock-band sub-windows use the Dock band's top-left!
    public var viewportOriginInScreen: CGPoint = .zero
    public var currentWeatherModulation: WeatherModulation = .neutral
    public var onBeforeStep: ((Float) -> Void)?
    public var onStepComplete: (() -> Void)?

    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var elapsedTime: Float = 0

    // Reusable CPU-side vertex arrays to avoid per-frame allocations
    private var flakeInstances: [GPUFlakeInstance] = []
    private var pileVertices: [GPUPileVertex] = []
    private var pileStripRanges: [(start: Int, count: Int)] = []
    private var debugVertices: [GPUDebugVertex] = []

    private var flakeBuffer: MTLBuffer?
    private var flakeBufferCapacity: Int = 0
    private var pileBuffer: MTLBuffer?
    private var pileBufferCapacity: Int = 0
    private var debugBuffer: MTLBuffer?
    private var debugBufferCapacity: Int = 0

    private var snowballInstances: [GPUSnowballInstance] = []
    private var snowballBuffer: MTLBuffer?
    private var snowballBufferCapacity: Int = 0

    private var chargeRingInstances: [GPUChargeRingInstance] = []
    private var chargeRingBuffer: MTLBuffer?
    private var chargeRingBufferCapacity: Int = 0

    private var dudeInstances: [GPUDudeInstance] = []
    private var dudeBuffer: MTLBuffer?
    private var dudeBufferCapacity: Int = 0

    public init?(
        device: MTLDevice,
        simulation: SnowSimulation,
        settings: SnowSettings,
        passFilter: RenderPassFilter,
        isSimulationDriver: Bool
    ) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.simulation = simulation
        self.settings = settings
        self.passFilter = passFilter
        self.isSimulationDriver = isSimulationDriver

        do {
            let library = try device.makeLibrary(source: SnowShaderSource.metalLibrarySource, options: nil)
            self.flakePipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "flakeVertex",
                fragment: "flakeFragment"
            )
            self.pilePipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "pileVertex",
                fragment: "pileFragment"
            )
            self.debugPipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "debugVertex",
                fragment: "debugFragment"
            )
            self.snowballPipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "snowballVertex",
                fragment: "snowballFragment"
            )
            self.chargeRingPipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "chargeRingVertex",
                fragment: "chargeRingFragment"
            )
            self.dudePipeline = try Self.makePipeline(
                device: device,
                library: library,
                vertex: "dudeVertex",
                fragment: "dudeFragment"
            )
        } catch {
            NSLog("LetItSnow Metal shader error: \(error)")
            return nil
        }

        super.init()
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String
    ) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: vertex)
        desc.fragmentFunction = library.makeFunction(name: fragment)
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        // Premultiplied alpha blending for clean transparent overlay compositing
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Simulation tracks logical points via view.bounds.size
    }

    public func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(now - lastFrameTime)
        lastFrameTime = now
        elapsedTime += min(dt, 0.05)

        if isSimulationDriver {
            onBeforeStep?(dt)
            stepSimulation(dt: dt)
            onStepComplete?()
        }

        guard let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: renderPass) else {
            return
        }

        let logicalSize = view.bounds.size
        guard logicalSize.width > 1, logicalSize.height > 1 else {
            encoder.endEncoding()
            cmdBuf.commit()
            return
        }

        let (tint, shadow) = moodColors(settings.snowMood)
        var uniforms = GPUUniforms(
            viewportSize: SIMD2<Float>(Float(logicalSize.width), Float(logicalSize.height)),
            time: elapsedTime,
            sparkleEnabled: settings.sparkleEnabled ? 1.0 : 0.0,
            tintColor: tint,
            shadowTint: shadow
        )

        let ox = Float(viewportOriginInScreen.x)
        let oy = Float(viewportOriginInScreen.y)
        let vw = Float(logicalSize.width)
        let vh = Float(logicalSize.height)

        // 1. Draw accumulated snow caps
        buildPileGeometry(offsetX: ox, offsetY: oy, viewWidth: vw, viewHeight: vh)
        if !pileVertices.isEmpty {
            let neededBytes = pileVertices.count * MemoryLayout<GPUPileVertex>.stride
            ensureBuffer(&pileBuffer, capacity: &pileBufferCapacity, bytes: neededBytes)
            if let buf = pileBuffer {
                pileVertices.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        memcpy(buf.contents(), base, neededBytes)
                    }
                }
                encoder.setRenderPipelineState(pilePipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
                encoder.setVertexBuffer(buf, offset: 0, index: 1)
                for strip in pileStripRanges {
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: strip.start, vertexCount: strip.count)
                }
            }
        }

        // 2. Draw airborne snowflakes
        buildFlakeInstances(offsetX: ox, offsetY: oy, viewWidth: vw, viewHeight: vh)
        if !flakeInstances.isEmpty {
            let neededBytes = flakeInstances.count * MemoryLayout<GPUFlakeInstance>.stride
            ensureBuffer(&flakeBuffer, capacity: &flakeBufferCapacity, bytes: neededBytes)
            if let buf = flakeBuffer {
                flakeInstances.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        memcpy(buf.contents(), base, neededBytes)
                    }
                }
                encoder.setRenderPipelineState(flakePipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
                encoder.setVertexBuffer(buf, offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: flakeInstances.count)
            }
        }

        // 2.5 Draw Red Snowcraft Dudes, Snowballs, Charge Ring & Cursor Splat (not in dockOnly sub-pass)
        if passFilter != .dockOnly {
            drawGameEntities(
                encoder: encoder,
                uniforms: &uniforms,
                offsetX: ox,
                offsetY: oy
            )
        }

        // 3. Optional collider debug outlines
        if settings.showColliders {
            buildDebugLines(offsetX: ox, offsetY: oy)
            if !debugVertices.isEmpty {
                let neededBytes = debugVertices.count * MemoryLayout<GPUDebugVertex>.stride
                ensureBuffer(&debugBuffer, capacity: &debugBufferCapacity, bytes: neededBytes)
                if let buf = debugBuffer {
                    debugVertices.withUnsafeBytes { ptr in
                        if let base = ptr.baseAddress {
                            memcpy(buf.contents(), base, neededBytes)
                        }
                    }
                    encoder.setRenderPipelineState(debugPipeline)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
                    encoder.setVertexBuffer(buf, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: debugVertices.count)
                }
            }
        }

        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    private func stepSimulation(dt: Float) {
        let mod = currentWeatherModulation
        let modulatedIntensity = max(
            mod.intensityFloor,
            settings.intensity * mod.intensityMultiplier
        )
        let targetFlakes = Int(min(SnowSettings.maxIntensity, max(0, modulatedIntensity)))
        let effectiveWind = max(-1.0, min(1.0, settings.wind + mod.windOffset))
        let effectiveTurb = max(settings.turbulence, mod.turbulenceFloor)
        let effectiveGravity = settings.gravity * mod.gravityMultiplier

        if mod.shouldTriggerGust {
            simulation.triggerGust(directionHint: Float(effectiveWind))
        }

        simulation.step(
            dt: dt,
            isSnowing: settings.isSnowing || mod.isStormActive,
            targetCount: targetFlakes,
            flakeSizeScale: Float(settings.flakeSize),
            style: settings.snowStyle,
            gravityScale: Float(effectiveGravity),
            windStrength: Float(effectiveWind),
            turbulence: Float(effectiveTurb),
            flutterStrength: Float(settings.flutter),
            accumulationEnabled: settings.accumulationEnabled,
            accumulationRate: Float(settings.accumulationRate),
            stickiness: Float(settings.stickiness),
            maxPileHeight: Float(settings.maxPileHeight),
            meltRate: Float(settings.meltRate),
            cursorInteraction: settings.cursorInteraction,
            cursorStrength: Float(settings.cursorStrength),
            snowcraftEnabled: settings.snowcraftGameEnabled,
            enemySpeedScale: Float(settings.snowcraftEnemySpeed)
        )
    }

    private func drawGameEntities(
        encoder: MTLRenderCommandEncoder,
        uniforms: inout GPUUniforms,
        offsetX: Float,
        offsetY: Float
    ) {
        let game = simulation.game

        // 1. Red Snowcraft Dudes
        dudeInstances.removeAll(keepingCapacity: true)
        for d in game.dudes {
            let stateVal: Float
            switch d.state {
            case .walking: stateVal = 0
            case .aiming: stateVal = 1
            case .throwing: stateVal = 2
            case .knockedOut: stateVal = 3
            }
            dudeInstances.append(GPUDudeInstance(
                footPos: SIMD2<Float>(d.x - offsetX, d.y - offsetY),
                scale: d.scale,
                facing: d.facing,
                walkPhase: d.walkPhase,
                state: stateVal,
                hitTilt: d.hitTilt,
                opacity: d.opacity
            ))
        }
        if !dudeInstances.isEmpty {
            let bytes = dudeInstances.count * MemoryLayout<GPUDudeInstance>.stride
            ensureBuffer(&dudeBuffer, capacity: &dudeBufferCapacity, bytes: bytes)
            if let buf = dudeBuffer {
                dudeInstances.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress { memcpy(buf.contents(), base, bytes) }
                }
                encoder.setRenderPipelineState(dudePipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
                encoder.setVertexBuffer(buf, offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: dudeInstances.count)
            }
        }

        // 2. Snowballs + Trajectory Preview Beads + Held Ball + Cursor Snow Splatters
        snowballInstances.removeAll(keepingCapacity: true)
        for b in game.snowballs {
            let kindVal: Float = (b.phase == .thrownByEnemy) ? 1.0 : 0.0
            snowballInstances.append(GPUSnowballInstance(
                center: SIMD2<Float>(b.x - offsetX, b.y - offsetY),
                radius: b.radius,
                rotation: b.rotation,
                opacity: 1.0,
                kind: kindVal
            ))
        }

        if game.charge.isActive {
            // Held snowball at charge anchor
            snowballInstances.append(GPUSnowballInstance(
                center: SIMD2<Float>(game.charge.anchorX - offsetX, game.charge.anchorY - offsetY),
                radius: game.charge.snowballRadius,
                rotation: elapsedTime * 2.0,
                opacity: 1.0,
                kind: 0.0
            ))
            // Dotted parabolic trajectory preview
            for (idx, pt) in game.charge.previewPoints.enumerated() {
                let frac = Float(idx) / Float(max(1, game.charge.previewPoints.count))
                snowballInstances.append(GPUSnowballInstance(
                    center: SIMD2<Float>(pt.x - offsetX, pt.y - offsetY),
                    radius: max(2.2, 4.4 * (1.0 - frac * 0.55)),
                    rotation: 0,
                    opacity: 0.85 * (1.0 - frac * 0.75),
                    kind: 2.0
                ))
            }
        }

        // Snow splatters clinging to mouse cursor when hit by an enemy snowball
        if game.cursorSnowTimer > 0 && simulation.hasCursor {
            let fade = min(1.0, game.cursorSnowTimer / 0.65)
            let cx = simulation.cursorX - offsetX
            let cy = simulation.cursorY - offsetY
            let seed = game.cursorSplatSeed
            for k in 0..<7 {
                let ang = Float(k) * 0.92 + seed
                let dist = 4.0 + Float((k * 5) % 13)
                let rad = 3.2 + Float((k * 3) % 5)
                snowballInstances.append(GPUSnowballInstance(
                    center: SIMD2<Float>(cx + cos(ang) * dist, cy + sin(ang) * dist),
                    radius: rad,
                    rotation: ang,
                    opacity: 0.92 * fade,
                    kind: 3.0
                ))
            }
        }

        if !snowballInstances.isEmpty {
            let bytes = snowballInstances.count * MemoryLayout<GPUSnowballInstance>.stride
            ensureBuffer(&snowballBuffer, capacity: &snowballBufferCapacity, bytes: bytes)
            if let buf = snowballBuffer {
                snowballInstances.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress { memcpy(buf.contents(), base, bytes) }
                }
                encoder.setRenderPipelineState(snowballPipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
                encoder.setVertexBuffer(buf, offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: snowballInstances.count)
            }
        }

        // 3. Charge Power Arc around held snowball
        chargeRingInstances.removeAll(keepingCapacity: true)
        if game.charge.isActive {
            chargeRingInstances.append(GPUChargeRingInstance(
                center: SIMD2<Float>(game.charge.anchorX - offsetX, game.charge.anchorY - offsetY),
                radius: game.charge.snowballRadius + 16.0,
                power: game.charge.power
            ))
        }
        if !chargeRingInstances.isEmpty {
            let bytes = chargeRingInstances.count * MemoryLayout<GPUChargeRingInstance>.stride
            ensureBuffer(&chargeRingBuffer, capacity: &chargeRingBufferCapacity, bytes: bytes)
            if let buf = chargeRingBuffer {
                chargeRingInstances.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress { memcpy(buf.contents(), base, bytes) }
                }
                encoder.setRenderPipelineState(chargeRingPipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
                encoder.setVertexBuffer(buf, offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: chargeRingInstances.count)
            }
        }
    }

    private func shouldIncludeSurface(_ kind: SurfaceKind) -> Bool {
        switch passFilter {
        case .all:
            return true
        case .desktopOnly:
            return kind != .dockIcon && kind != .dockShelf
        case .dockOnly:
            return kind == .dockIcon || kind == .dockShelf
        }
    }

    private func buildPileGeometry(offsetX: Float, offsetY: Float, viewWidth: Float, viewHeight: Float) {
        pileVertices.removeAll(keepingCapacity: true)
        pileStripRanges.removeAll(keepingCapacity: true)

        for s in simulation.surfaces {
            guard shouldIncludeSurface(s.kind), s.maxHeight > 0.18 else { continue }
            let n = s.heights.count
            guard n >= 4 else { continue }

            // Quick viewport cull
            let sMinX = Float(s.rect.minX) - offsetX
            let sMaxX = Float(s.rect.maxX) - offsetX
            if sMaxX < -20 || sMinX > viewWidth + 20 { continue }

            let startIdx = pileVertices.count
            let maxPile = max(6.0, Float(settings.maxPileHeight))

            for i in 0..<n {
                // Visual 3-tap smoothing so snow caps look silky-smooth without mutating physics
                let hPrev = i > 0 ? s.heights[i - 1] : 0
                let hCurr = s.heights[i]
                let hNext = i + 1 < n ? s.heights[i + 1] : 0
                var smoothH = hPrev * 0.24 + hCurr * 0.52 + hNext * 0.24
                if s.kind != .ground && (i == 0 || i == n - 1) {
                    smoothH *= 0.45
                }

                let x = s.xForCell(i) - offsetX
                let surfaceY = s.surfaceTopY(atCell: i) - offsetY
                let topY = surfaceY - smoothH
                // Slight bottom lip overlap so snow hugs rounded icon tops naturally
                let bottomLip = min(2.4, smoothH * 0.45)
                let bottomY = surfaceY + bottomLip
                let hNorm = min(1.0, smoothH / max(3.0, maxPile * 0.45))
                let seed = s.sparkleSeeds[i]

                pileVertices.append(GPUPileVertex(
                    pos: SIMD2<Float>(x, topY),
                    edgeFrac: 1.0,
                    heightNorm: hNorm,
                    sparkleSeed: seed
                ))
                pileVertices.append(GPUPileVertex(
                    pos: SIMD2<Float>(x, bottomY),
                    edgeFrac: 0.0,
                    heightNorm: hNorm,
                    sparkleSeed: seed
                ))
            }

            let count = pileVertices.count - startIdx
            if count >= 4 {
                pileStripRanges.append((start: startIdx, count: count))
            }
        }
    }

    private func buildFlakeInstances(offsetX: Float, offsetY: Float, viewWidth: Float, viewHeight: Float) {
        flakeInstances.removeAll(keepingCapacity: true)
        flakeInstances.reserveCapacity(simulation.flakes.count)

        for f in simulation.flakes {
            let lx = f.x - offsetX
            let ly = f.y - offsetY
            let margin = f.radius * 2.0 + 4.0
            if lx < -margin || lx > viewWidth + margin || ly < -margin || ly > viewHeight + margin {
                continue
            }
            // In dockOnly sub-window, only render flakes near the Dock band so we don't duplicate
            // flakes already visible behind normal windows above the Dock.
            if passFilter == .dockOnly {
                guard ly >= 0 && ly <= viewHeight else { continue }
            }

            flakeInstances.append(GPUFlakeInstance(
                center: SIMD2<Float>(lx, ly),
                radius: f.radius,
                rotation: f.rotation,
                opacity: f.opacity,
                kind: Float(f.flakeKind),
                foreground: f.isForeground ? 1.0 : 0.0
            ))
        }
    }

    private func buildDebugLines(offsetX: Float, offsetY: Float) {
        debugVertices.removeAll(keepingCapacity: true)
        for s in simulation.surfaces where shouldIncludeSurface(s.kind) {
            let color: SIMD4<Float>
            switch s.kind {
            case .desktopIcon: color = SIMD4<Float>(0.25, 0.85, 1.0, 0.85)
            case .desktopFolder: color = SIMD4<Float>(1.0, 0.82, 0.25, 0.90)
            case .dockIcon: color = SIMD4<Float>(0.35, 1.0, 0.60, 0.90)
            case .dockShelf: color = SIMD4<Float>(0.40, 0.65, 1.0, 0.75)
            case .window: color = SIMD4<Float>(1.0, 0.40, 0.85, 0.80)
            case .wallpaperSubject: color = SIMD4<Float>(0.68, 0.45, 1.0, 0.92)
            case .wallpaperScene: color = SIMD4<Float>(1.0, 0.58, 0.25, 0.82)
            case .ground: color = SIMD4<Float>(1.0, 1.0, 1.0, 0.45)
            }

            let left = Float(s.rect.minX) - offsetX
            let right = Float(s.rect.maxX) - offsetX
            let bottom = Float(s.rect.maxY) - offsetY
            let topLeft = s.surfaceTopY(atCell: 0) - offsetY
            let topRight = s.surfaceTopY(atCell: s.heights.count - 1) - offsetY

            // Draw the exact landing profile polyline along top
            let n = s.heights.count
            for i in 0..<(n - 1) {
                let x0 = s.xForCell(i) - offsetX
                let y0 = s.surfaceTopY(atCell: i) - offsetY
                let x1 = s.xForCell(i + 1) - offsetX
                let y1 = s.surfaceTopY(atCell: i + 1) - offsetY
                debugVertices.append(GPUDebugVertex(pos: SIMD2<Float>(x0, y0), color: color))
                debugVertices.append(GPUDebugVertex(pos: SIMD2<Float>(x1, y1), color: color))
            }

            if s.kind != .ground {
                // Side & bottom box outline
                let dim = SIMD4<Float>(color.x, color.y, color.z, color.w * 0.42)
                let pts: [(SIMD2<Float>, SIMD2<Float>)] = [
                    (SIMD2<Float>(left, topLeft), SIMD2<Float>(left, bottom)),
                    (SIMD2<Float>(right, topRight), SIMD2<Float>(right, bottom)),
                    (SIMD2<Float>(left, bottom), SIMD2<Float>(right, bottom))
                ]
                for (a, b) in pts {
                    debugVertices.append(GPUDebugVertex(pos: a, color: dim))
                    debugVertices.append(GPUDebugVertex(pos: b, color: dim))
                }
            }
        }
    }

    private func moodColors(_ mood: SnowMood) -> (tint: SIMD4<Float>, shadow: SIMD4<Float>) {
        switch mood {
        case .winterWhite:
            return (SIMD4<Float>(0.99, 0.995, 1.0, 1.0), SIMD4<Float>(0.80, 0.88, 0.98, 1.0))
        case .arcticBlue:
            return (SIMD4<Float>(0.92, 0.97, 1.0, 1.0), SIMD4<Float>(0.68, 0.84, 0.99, 1.0))
        case .goldenHour:
            return (SIMD4<Float>(1.0, 0.96, 0.92, 1.0), SIMD4<Float>(0.85, 0.84, 0.95, 1.0))
        case .aurora:
            let pulse = (sin(elapsedTime * 0.45) + 1.0) * 0.5
            let tint = SIMD4<Float>(0.86 + 0.08 * pulse, 0.99, 0.94 + 0.05 * (1.0 - pulse), 1.0)
            let shadow = SIMD4<Float>(0.64, 0.86, 0.95, 1.0)
            return (tint, shadow)
        }
    }

    private func ensureBuffer(_ buffer: inout MTLBuffer?, capacity: inout Int, bytes: Int) {
        if bytes <= capacity && buffer != nil { return }
        let newCap = max(4096, bytes * 2)
        buffer = device.makeBuffer(length: newCap, options: .storageModeShared)
        capacity = newCap
    }
}
