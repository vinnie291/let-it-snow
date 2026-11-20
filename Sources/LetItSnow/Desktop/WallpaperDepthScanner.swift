import Cocoa
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

public enum WallpaperScanStatus: Equatable, Sendable {
    case idle
    case scanning
    case ready(subjectCount: Int, sceneCount: Int)
    case needsScreenAccess
    case unavailable(String)

    public var summaryText: String {
        switch self {
        case .idle:
            return "Not scanned yet"
        case .scanning:
            return "Scanning wallpaper depth..."
        case .ready(let subj, let scene):
            return "\(subj) subject + \(scene) scene ledges"
        case .needsScreenAccess:
            return "Screen Recording permission needed to scan dynamic/cached wallpaper"
        case .unavailable(let reason):
            return reason
        }
    }
}

public struct WallpaperScanResult: Sendable {
    public let displayID: CGDirectDisplayID
    public let surfaces: [DetectedSurface]
    public let subjectLedgeCount: Int
    public let sceneLedgeCount: Int
    public let status: WallpaperScanStatus
}

public final class WallpaperDepthScanner: @unchecked Sendable {
    private let scanQueue = DispatchQueue(label: "com.letitsnow.wallpaperDepth", qos: .userInitiated)
    private let lock = NSLock()
    private var isScanning = false

    public init() {}

    public func scanDisplay(
        displayID: CGDirectDisplayID,
        screenFrame: CGRect,
        desktopImageURL: URL?,
        desktopImageOptions: [NSWorkspace.DesktopImageOptionKey: Any]?,
        customPhotoURL: URL?,
        includeSceneLedges: Bool,
        sceneSensitivity: Float,
        allowPermissionPrompt: Bool,
        completion: @escaping @Sendable (WallpaperScanResult) -> Void
    ) {
        let canStart = lock.withLock { () -> Bool in
            if isScanning { return false }
            isScanning = true
            return true
        }
        guard canStart else { return }

        let scalingRaw = (desktopImageOptions?[.imageScaling] as? NSNumber)?.uintValue
        let allowClipping = (desktopImageOptions?[.allowClipping] as? Bool) ?? true

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer { self.finishScanning() }

            let targetSize = screenFrame.size
            guard targetSize.width >= 32, targetSize.height >= 32 else {
                completion(WallpaperScanResult(
                    displayID: displayID,
                    surfaces: [],
                    subjectLedgeCount: 0,
                    sceneLedgeCount: 0,
                    status: .unavailable("Invalid screen size")
                ))
                return
            }

            // 1. Acquire wallpaper CGImage fitted to screenFrame.size
            var image: CGImage? = nil
            var permissionDenied = false

            if let customURL = customPhotoURL,
               let loaded = Self.loadFittedImage(from: customURL, targetSize: targetSize, scalingRaw: nil, allowClipping: true) {
                image = loaded
            } else if let wallURL = desktopImageURL,
                      FileManager.default.isReadableFile(atPath: wallURL.path),
                      let loaded = Self.loadFittedImage(from: wallURL, targetSize: targetSize, scalingRaw: scalingRaw, allowClipping: allowClipping) {
                image = loaded
            } else {
                // Capture the live macOS WindowManager Wallpaper window via ScreenCaptureKit
                let hasPreflight = CGPreflightScreenCaptureAccess()
                if hasPreflight || allowPermissionPrompt {
                    if !hasPreflight && allowPermissionPrompt {
                        _ = CGRequestScreenCaptureAccess()
                    }
                    do {
                        image = try await Self.captureWallpaperWindow(matching: screenFrame)
                    } catch {
                        permissionDenied = !CGPreflightScreenCaptureAccess()
                    }
                } else {
                    permissionDenied = true
                }
            }

            guard let cgImage = image else {
                let status: WallpaperScanStatus = permissionDenied
                    ? .needsScreenAccess
                    : .unavailable("Could not read current wallpaper")
                completion(WallpaperScanResult(
                    displayID: displayID,
                    surfaces: [],
                    subjectLedgeCount: 0,
                    sceneLedgeCount: 0,
                    status: status
                ))
                return
            }

            // 2. Run Apple Vision segmentation + depth/ledge extraction
            let extracted = Self.analyzeWallpaper(
                cgImage: cgImage,
                logicalSize: targetSize,
                displayID: displayID,
                includeSceneLedges: includeSceneLedges,
                sceneSensitivity: sceneSensitivity
            )
            completion(extracted)
        }
    }

    private func finishScanning() {
        lock.withLock {
            isScanning = false
        }
    }

    // MARK: - Wallpaper Image Acquisition

    private static func captureWallpaperWindow(matching screenFrame: CGRect) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let primaryHeight = await MainActor.run {
            NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                ?? NSScreen.main?.frame.height
                ?? screenFrame.height
        }
        let targetQuartzRect = CGRect(
            x: screenFrame.minX,
            y: primaryHeight - screenFrame.maxY,
            width: screenFrame.width,
            height: screenFrame.height
        )

        // Find WindowManager Wallpaper window matching this display
        let candidates = content.windows.filter { win in
            let owner = win.owningApplication?.applicationName ?? ""
            let title = win.title ?? ""
            return owner.contains("WindowManager") && title.contains("Wallpaper")
        }

        let chosen = candidates.max { a, b in
            let areaA = a.frame.intersection(targetQuartzRect).width * a.frame.intersection(targetQuartzRect).height
            let areaB = b.frame.intersection(targetQuartzRect).width * b.frame.intersection(targetQuartzRect).height
            return areaA < areaB
        } ?? candidates.first

        guard let wallWin = chosen else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: wallWin)
        let cfg = SCStreamConfiguration()
        // Cap capture width to 960px (matches 2pt grid resolution, cuts Vision RAM & time ~4x)
        let maxW: CGFloat = 960
        let scale = min(1.0, maxW / max(1.0, screenFrame.width))
        cfg.width = Int(max(128, (screenFrame.width * scale).rounded()))
        cfg.height = Int(max(128, (screenFrame.height * scale).rounded()))
        cfg.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    private static func loadFittedImage(
        from url: URL,
        targetSize: CGSize,
        scalingRaw: UInt?,
        allowClipping: Bool
    ) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }

        let maxW: CGFloat = 960
        let fitScale = min(1.0, maxW / max(1.0, targetSize.width))
        let w = max(64, Int((targetSize.width * fitScale).rounded()))
        let h = max(64, Int((targetSize.height * fitScale).rounded()))
        let canvasSize = CGSize(width: w, height: h)
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return raw
        }

        ctx.interpolationQuality = CGInterpolationQuality.high
        let imgW = CGFloat(raw.width)
        let imgH = CGFloat(raw.height)
        let allowClip = allowClipping

        // NSImageScaling.scaleProportionallyUpOrDown == 3, .scaleAxesIndependently == 1
        let drawRect: CGRect
        if scalingRaw == 1 {
            drawRect = CGRect(origin: .zero, size: canvasSize)
        } else {
            let scaleX = canvasSize.width / imgW
            let scaleY = canvasSize.height / imgH
            let scale = allowClip ? max(scaleX, scaleY) : min(scaleX, scaleY)
            let dw = imgW * scale
            let dh = imgH * scale
            drawRect = CGRect(
                x: (canvasSize.width - dw) * 0.5,
                y: (canvasSize.height - dh) * 0.5,
                width: dw,
                height: dh
            )
        }

        ctx.draw(raw, in: drawRect)
        return ctx.makeImage()
    }

    // MARK: - Apple Vision Segmentation & Depth-Ledge Extraction

    private static func analyzeWallpaper(
        cgImage: CGImage,
        logicalSize: CGSize,
        displayID: CGDirectDisplayID,
        includeSceneLedges: Bool,
        sceneSensitivity: Float
    ) -> WallpaperScanResult {
        let cellStep = 2
        let gridW = max(32, Int(logicalSize.width) / cellStep)
        let gridH = max(32, Int(logicalSize.height) / cellStep)

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let fgReq = VNGenerateForegroundInstanceMaskRequest()
        let personReq = VNGeneratePersonSegmentationRequest()
        personReq.qualityLevel = .accurate
        personReq.outputPixelFormat = kCVPixelFormatType_OneComponent8

        do {
            try handler.perform([fgReq, personReq])
        } catch {
            // Fall back to luminance scene scanning if Vision fails
            return extractFromMasks(
                cgImage: cgImage,
                fgMaskBuffer: nil,
                personMaskBuffer: nil,
                gridW: gridW,
                gridH: gridH,
                cellStep: Float(cellStep),
                displayID: displayID,
                includeSceneLedges: includeSceneLedges,
                sceneSensitivity: sceneSensitivity
            )
        }

        var fgBuffer: CVPixelBuffer? = nil
        if let fgResult = fgReq.results?.first, !fgResult.allInstances.isEmpty {
            fgBuffer = try? fgResult.generateScaledMaskForImage(forInstances: fgResult.allInstances, from: handler)
        }
        let personBuffer = personReq.results?.first?.pixelBuffer

        return extractFromMasks(
            cgImage: cgImage,
            fgMaskBuffer: fgBuffer,
            personMaskBuffer: personBuffer,
            gridW: gridW,
            gridH: gridH,
            cellStep: Float(cellStep),
            displayID: displayID,
            includeSceneLedges: includeSceneLedges,
            sceneSensitivity: sceneSensitivity
        )
    }

    private static func extractFromMasks(
        cgImage: CGImage,
        fgMaskBuffer: CVPixelBuffer?,
        personMaskBuffer: CVPixelBuffer?,
        gridW: Int,
        gridH: Int,
        cellStep: Float,
        displayID: CGDirectDisplayID,
        includeSceneLedges: Bool,
        sceneSensitivity: Float
    ) -> WallpaperScanResult {
        var subjectMask = [Float](repeating: 0, count: gridW * gridH)

        if let fg = fgMaskBuffer {
            sampleFloatMask(fg, into: &subjectMask, gridW: gridW, gridH: gridH, weight: 0.92)
        }
        if let p = personMaskBuffer {
            sampleUInt8Mask(p, into: &subjectMask, gridW: gridW, gridH: gridH, weight: 1.0)
        }

        let smoothedMask = smoothGrid(subjectMask, width: gridW, height: gridH)

        var luminance: [Float]? = nil
        if includeSceneLedges {
            luminance = renderGrayscaleGrid(cgImage: cgImage, gridW: gridW, gridH: gridH)
        }

        let (surfaces, subjCount, sceneCount) = extractLedgesFromGrids(
            subjectMask: smoothedMask,
            luminance: luminance,
            gridW: gridW,
            gridH: gridH,
            cellStep: cellStep,
            displayID: displayID,
            sceneSensitivity: sceneSensitivity
        )

        return WallpaperScanResult(
            displayID: displayID,
            surfaces: surfaces,
            subjectLedgeCount: subjCount,
            sceneLedgeCount: sceneCount,
            status: .ready(subjectCount: subjCount, sceneCount: sceneCount)
        )
    }

    /// Pure & unit-testable contour/ledge extractor over normalized subject mask & optional luminance grids.
    public static func extractLedgesFromGrids(
        subjectMask: [Float],
        luminance: [Float]?,
        gridW: Int,
        gridH: Int,
        cellStep: Float,
        displayID: CGDirectDisplayID,
        sceneSensitivity: Float
    ) -> (surfaces: [DetectedSurface], subjectCount: Int, sceneCount: Int) {
        var surfaces: [DetectedSurface] = []
        var subjectCount = 0
        var sceneCount = 0

        // 1. Multi-tier upward-facing subject ledges (heads, hats, shoulders, arms, foreground objects)
        let threshold: Float = 0.45
        var columnHits = [[Float]](repeating: [], count: gridW)

        for x in 1..<(gridW - 1) {
            var y = 3
            while y < gridH - 6 {
                let idx = y * gridW + x
                let val = subjectMask[idx]
                let above1 = subjectMask[(y - 1) * gridW + x]
                let above2 = subjectMask[(y - 2) * gridW + x]
                if val >= threshold && above1 < threshold && above2 < threshold {
                    // Require solid body support underneath (>= 5 grid cells = 10pt)
                    var solidDepth = 0
                    for dy in 1...6 where (y + dy) < gridH {
                        if subjectMask[(y + dy) * gridW + x] >= 0.38 {
                            solidDepth += 1
                        }
                    }
                    if solidDepth >= 4 {
                        // Sub-pixel linear interpolation across the 0.45 crossing
                        let frac = (threshold - above1) / max(0.001, val - above1)
                        let subY = Float(y - 1) + min(1.0, max(0.0, frac))
                        columnHits[x].append(subY)
                        // Advance past this upper contour so shoulders/arms lower down can still be detected
                        y += 14
                        continue
                    }
                }
                y += 1
            }
        }

        let subjectChains = linkContourChains(
            columnHits: columnHits,
            gridW: gridW,
            maxJumpY: 8.5,
            minChainLength: 7
        )

        for (idx, chain) in subjectChains.enumerated() {
            let smoothed = smooth1D(chain.yValues)
            guard let minGridY = smoothed.min(), let maxGridY = smoothed.max() else { continue }
            let minY = CGFloat(minGridY * cellStep)
            let maxY = CGFloat(maxGridY * cellStep)
            let startX = CGFloat(chain.startX) * CGFloat(cellStep)
            let width = CGFloat(smoothed.count) * CGFloat(cellStep)
            let rect = CGRect(
                x: startX,
                y: minY,
                width: width,
                height: max(10, (maxY - minY) + 8)
            )
            let profile = smoothed.map { ($0 - minGridY) * cellStep }
            surfaces.append(DetectedSurface(
                id: "wall-subj:\(displayID):\(idx)",
                kind: .wallpaperSubject,
                rect: rect,
                label: "Wallpaper Subject",
                customTopProfile: profile
            ))
            subjectCount += 1
        }

        // 2. Scene / Horizon / Background Object Ledges outside the subject mask
        if let lum = luminance, sceneSensitivity > 0.05 {
            var edgeStrength = [Float](repeating: 0, count: gridW * gridH)
            let gradThreshold: Float = 0.24 - sceneSensitivity * 0.14 // 0.24 (strict) .. 0.10 (detailed)

            for y in 4..<(gridH - 6) {
                for x in 2..<(gridW - 2) {
                    // Exclude inside & near subject silhouettes so clothing/faces don't get double-edges
                    if isNearSubject(subjectMask, x: x, y: y, gridW: gridW, gridH: gridH, radius: 5) {
                        continue
                    }
                    let gy = abs(lum[(y + 2) * gridW + x] - lum[(y - 2) * gridW + x]) * 0.6
                        + abs(lum[(y + 1) * gridW + x] - lum[(y - 1) * gridW + x]) * 0.4
                    let gx = abs(lum[y * gridW + (x + 2)] - lum[y * gridW + (x - 2)])
                    if gy >= gradThreshold && gy >= gx * 0.85 {
                        edgeStrength[y * gridW + x] = gy
                    }
                }
            }

            // Vertical non-maximum suppression
            var sceneHits = [[Float]](repeating: [], count: gridW)
            for x in 2..<(gridW - 2) {
                var y = 6
                while y < gridH - 8 {
                    let e = edgeStrength[y * gridW + x]
                    if e > 0
                        && e >= edgeStrength[(y - 1) * gridW + x]
                        && e >= edgeStrength[(y + 1) * gridW + x]
                        && e >= edgeStrength[(y - 2) * gridW + x]
                        && e >= edgeStrength[(y + 2) * gridW + x] {
                        sceneHits[x].append(Float(y))
                        y += 12
                        continue
                    }
                    y += 1
                }
            }

            let rawChains = linkContourChains(
                columnHits: sceneHits,
                gridW: gridW,
                maxJumpY: 4.5,
                minChainLength: 18
            )

            // Score by length & edge contrast, cap to top 18 cleanest ridges
            let scored = rawChains.map { chain -> (chain: (startX: Int, yValues: [Float]), score: Float) in
                var sum: Float = 0
                for (offset, fy) in chain.yValues.enumerated() {
                    let x = chain.startX + offset
                    let y = max(0, min(gridH - 1, Int(fy)))
                    sum += edgeStrength[y * gridW + x]
                }
                return (chain, sum)
            }.sorted { $0.score > $1.score }

            for (idx, item) in scored.prefix(18).enumerated() {
                let smoothed = smooth1D(item.chain.yValues)
                guard let minGridY = smoothed.min(), let maxGridY = smoothed.max() else { continue }
                let minY = CGFloat(minGridY * cellStep)
                let maxY = CGFloat(maxGridY * cellStep)
                let startX = CGFloat(item.chain.startX) * CGFloat(cellStep)
                let width = CGFloat(smoothed.count) * CGFloat(cellStep)
                let rect = CGRect(
                    x: startX,
                    y: minY,
                    width: width,
                    height: max(8, (maxY - minY) + 6)
                )
                let profile = smoothed.map { ($0 - minGridY) * cellStep }
                surfaces.append(DetectedSurface(
                    id: "wall-scene:\(displayID):\(idx)",
                    kind: .wallpaperScene,
                    rect: rect,
                    label: "Wallpaper Ridge",
                    customTopProfile: profile
                ))
                sceneCount += 1
            }
        }

        return (surfaces, subjectCount, sceneCount)
    }

    private static func isNearSubject(
        _ mask: [Float],
        x: Int,
        y: Int,
        gridW: Int,
        gridH: Int,
        radius: Int
    ) -> Bool {
        if mask[y * gridW + x] >= 0.25 { return true }
        let y0 = max(0, y - radius)
        let y1 = min(gridH - 1, y + radius)
        let x0 = max(0, x - radius)
        let x1 = min(gridW - 1, x + radius)
        if mask[y0 * gridW + x] >= 0.35 || mask[y1 * gridW + x] >= 0.35 { return true }
        if mask[y * gridW + x0] >= 0.35 || mask[y * gridW + x1] >= 0.35 { return true }
        return false
    }

    private static func linkContourChains(
        columnHits: [[Float]],
        gridW: Int,
        maxJumpY: Float,
        minChainLength: Int
    ) -> [(startX: Int, yValues: [Float])] {
        struct ActiveChain {
            let startX: Int
            var yValues: [Float]
            var lastX: Int
        }

        var active: [ActiveChain] = []
        var completed: [(startX: Int, yValues: [Float])] = []

        for x in 0..<gridW {
            let hits = columnHits[x]
            var usedHit = [Bool](repeating: false, count: hits.count)

            for i in 0..<active.count {
                if x - active[i].lastX > 2 { continue }
                let prevY = active[i].yValues.last!
                var bestIdx = -1
                var bestDist = maxJumpY + 0.001
                for hIdx in 0..<hits.count where !usedHit[hIdx] {
                    let d = abs(hits[hIdx] - prevY)
                    if d < bestDist {
                        bestDist = d
                        bestIdx = hIdx
                    }
                }
                if bestIdx >= 0 {
                    usedHit[bestIdx] = true
                    // Fill 1-cell gap linearly if skipped
                    if x - active[i].lastX == 2 {
                        active[i].yValues.append((prevY + hits[bestIdx]) * 0.5)
                    }
                    active[i].yValues.append(hits[bestIdx])
                    active[i].lastX = x
                }
            }

            // Retire stale chains
            var stillActive: [ActiveChain] = []
            stillActive.reserveCapacity(active.count)
            for c in active {
                if x - c.lastX >= 2 {
                    if c.yValues.count >= minChainLength {
                        completed.append((c.startX, c.yValues))
                    }
                } else {
                    stillActive.append(c)
                }
            }
            active = stillActive

            // Start new chains for unmatched hits
            for hIdx in 0..<hits.count where !usedHit[hIdx] {
                active.append(ActiveChain(startX: x, yValues: [hits[hIdx]], lastX: x))
            }
        }

        for c in active where c.yValues.count >= minChainLength {
            completed.append((c.startX, c.yValues))
        }
        return completed
    }

    private static func smooth1D(_ values: [Float]) -> [Float] {
        guard values.count >= 3 else { return values }
        var tmp = values
        for _ in 0..<2 {
            var next = tmp
            for i in 1..<(tmp.count - 1) {
                next[i] = tmp[i - 1] * 0.22 + tmp[i] * 0.56 + tmp[i + 1] * 0.22
            }
            tmp = next
        }
        return tmp
    }

    private static func smoothGrid(_ src: [Float], width: Int, height: Int) -> [Float] {
        var horiz = [Float](repeating: 0, count: src.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let l = src[row + max(0, x - 1)]
                let c = src[row + x]
                let r = src[row + min(width - 1, x + 1)]
                horiz[row + x] = l * 0.25 + c * 0.5 + r * 0.25
            }
        }
        var out = [Float](repeating: 0, count: src.count)
        for y in 0..<height {
            let ym = max(0, y - 1) * width
            let yc = y * width
            let yp = min(height - 1, y + 1) * width
            for x in 0..<width {
                out[yc + x] = horiz[ym + x] * 0.25 + horiz[yc + x] * 0.5 + horiz[yp + x] * 0.25
            }
        }
        return out
    }

    private static func sampleFloatMask(
        _ pb: CVPixelBuffer,
        into dest: inout [Float],
        gridW: Int,
        gridH: Int,
        weight: Float
    ) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let baseAddr = CVPixelBufferGetBaseAddress(pb) else { return }

        let mw = CVPixelBufferGetWidth(pb)
        let mh = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let strideFloats = bpr / MemoryLayout<Float>.stride
        let ptr = baseAddr.assumingMemoryBound(to: Float.self)

        for y in 0..<gridH {
            let sy = min(mh - 1, (y * mh) / gridH)
            let sRow = sy * strideFloats
            let dRow = y * gridW
            for x in 0..<gridW {
                let sx = min(mw - 1, (x * mw) / gridW)
                let v = ptr[sRow + sx] * weight
                if v > dest[dRow + x] {
                    dest[dRow + x] = v
                }
            }
        }
    }

    private static func sampleUInt8Mask(
        _ pb: CVPixelBuffer,
        into dest: inout [Float],
        gridW: Int,
        gridH: Int,
        weight: Float
    ) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let baseAddr = CVPixelBufferGetBaseAddress(pb) else { return }

        let mw = CVPixelBufferGetWidth(pb)
        let mh = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)

        for y in 0..<gridH {
            let sy = min(mh - 1, (y * mh) / gridH)
            let sRow = sy * bpr
            let dRow = y * gridW
            for x in 0..<gridW {
                let sx = min(mw - 1, (x * mw) / gridW)
                let v = (Float(ptr[sRow + sx]) / 255.0) * weight
                if v > dest[dRow + x] {
                    dest[dRow + x] = v
                }
            }
        }
    }

    private static func renderGrayscaleGrid(cgImage: CGImage, gridW: Int, gridH: Int) -> [Float]? {
        var bytes = [UInt8](repeating: 0, count: gridW * gridH)
        let ok = bytes.withUnsafeMutableBytes { rawPtr -> Bool in
            guard let ctx = CGContext(
                data: rawPtr.baseAddress,
                width: gridW,
                height: gridH,
                bitsPerComponent: 8,
                bytesPerRow: gridW,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = CGInterpolationQuality.medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: gridW, height: gridH))
            return true
        }
        guard ok else { return nil }
        return bytes.map { Float($0) / 255.0 }
    }
}
