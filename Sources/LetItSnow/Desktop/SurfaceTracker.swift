import ApplicationServices
import Cocoa
import Foundation

public struct ScreenSurfaceSnapshot: Sendable {
    public let displayID: CGDirectDisplayID
    public let surfaces: [DetectedSurface]
    public let windowRects: [CGRect]
    public let iconCount: Int
    public let dockItemCount: Int
    public let windowCount: Int
    public let wallpaperLedgeCount: Int
    public let accessibilityGranted: Bool
}

public struct SurfaceTrackingOptions: Sendable, Equatable {
    public var landOnDesktopIcons: Bool
    public var landOnDesktopFolders: Bool
    public var landOnDock: Bool
    public var landOnGround: Bool
    public var landOnWindows: Bool
    public var landOnWallpaper: Bool
    public var includeWallpaperSceneLedges: Bool
    public var respectWindowOcclusion: Bool
}

public final class SurfaceTracker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.letitsnow.surfaceTracker", qos: .utility)
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var timer: DispatchSourceTimer?
    private var isRunning = false

    private let stateLock = NSLock()
    private var options: SurfaceTrackingOptions
    private var screenDescriptors: [(displayID: CGDirectDisplayID, quartzRect: CGRect, dockGapHeight: CGFloat)] = []
    private var wallpaperSurfacesByDisplay: [CGDirectDisplayID: [DetectedSurface]] = [:]
    private var latestSnapshots: [CGDirectDisplayID: ScreenSurfaceSnapshot] = [:]

    public var onUpdate: (@Sendable ([CGDirectDisplayID: ScreenSurfaceSnapshot]) -> Void)?

    public init(options: SurfaceTrackingOptions) {
        self.options = options
    }

    public func updateWallpaperSurfaces(_ surfaces: [DetectedSurface], for displayID: CGDirectDisplayID) {
        stateLock.lock()
        wallpaperSurfacesByDisplay[displayID] = surfaces
        stateLock.unlock()
        queue.async { [weak self] in
            self?.pollOnce()
        }
    }

    public func updateOptions(_ newOptions: SurfaceTrackingOptions) {
        stateLock.lock()
        self.options = newOptions
        stateLock.unlock()
        // Trigger immediate refresh on next cycle
        queue.async { [weak self] in
            self?.pollOnce()
        }
    }

    public func updateScreens(_ screens: [NSScreen]) {
        let primaryHeight = screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? screens.first?.frame.height
            ?? 1080

        let descriptors: [(CGDirectDisplayID, CGRect, CGFloat)] = screens.compactMap { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(num.uint32Value)
            let qx = screen.frame.minX
            let qy = primaryHeight - screen.frame.maxY
            let qRect = CGRect(x: qx, y: qy, width: screen.frame.width, height: screen.frame.height)
            let bottomInset = max(0, screen.visibleFrame.minY - screen.frame.minY)
            return (displayID, qRect, bottomInset)
        }

        stateLock.lock()
        self.screenDescriptors = descriptors
        stateLock.unlock()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(260), leeway: .milliseconds(80))
        t.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        t.resume()
        self.timer = t
    }

    public func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    public func snapshot(for displayID: CGDirectDisplayID) -> ScreenSurfaceSnapshot? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestSnapshots[displayID]
    }

    private func pollOnce() {
        stateLock.lock()
        let opts = self.options
        let screens = self.screenDescriptors
        let wallpaperMap = self.wallpaperSurfacesByDisplay
        stateLock.unlock()

        guard !screens.isEmpty else { return }
        let axTrusted = AXIsProcessTrusted()

        // 1. Collect Finder desktop icons & folders (global Quartz coordinates)
        let desktopItems: [(id: String, kind: SurfaceKind, rect: CGRect, label: String)]
        if (opts.landOnDesktopIcons || opts.landOnDesktopFolders) && axTrusted {
            desktopItems = fetchFinderDesktopItems().filter { item in
                item.kind == .desktopFolder ? opts.landOnDesktopFolders : opts.landOnDesktopIcons
            }
        } else {
            desktopItems = []
        }

        // 2. Collect Dock & Dock items (global Quartz coordinates)
        let dockInfo: (shelfRect: CGRect?, items: [(id: String, rect: CGRect, label: String)])
        if opts.landOnDock && axTrusted {
            dockInfo = fetchDockItems()
        } else {
            dockInfo = (nil, [])
        }

        // 3. Collect visible normal app windows front-to-back (global Quartz coordinates)
        let rawWindows: [(id: UInt32, rect: CGRect, title: String)]
        if opts.landOnWindows || opts.respectWindowOcclusion {
            rawWindows = fetchNormalWindows()
        } else {
            rawWindows = []
        }

        // 4. Project onto each display
        var results: [CGDirectDisplayID: ScreenSurfaceSnapshot] = [:]

        for (displayID, screenQ, dockGapHeight) in screens {
            var surfaces: [DetectedSurface] = []
            var iconCount = 0
            var dockCount = 0
            var winCount = 0
            var wallCount = 0

            // Windows in screen-local coords (keep front-to-back order for occlusion!)
            let localWindows: [(id: UInt32, rect: CGRect, title: String)] = rawWindows.compactMap { win in
                let inter = win.rect.intersection(screenQ)
                guard !inter.isNull, inter.width >= 40, inter.height >= 24 else { return nil }
                let localRect = CGRect(
                    x: win.rect.minX - screenQ.minX,
                    y: win.rect.minY - screenQ.minY,
                    width: win.rect.width,
                    height: win.rect.height
                )
                return (win.id, localRect, win.title)
            }

            // Desktop icons & folders
            for item in desktopItems {
                guard item.rect.intersects(screenQ) else { continue }
                let localRect = CGRect(
                    x: item.rect.minX - screenQ.minX,
                    y: item.rect.minY - screenQ.minY,
                    width: item.rect.width,
                    height: item.rect.height
                )
                // If occlusion is respected, skip icons whose top landing line is covered by an open window
                if opts.respectWindowOcclusion {
                    let probeY = localRect.minY + 6.0
                    let visibleSpans = Self.subtractOccludingRects(
                        segmentMinX: localRect.minX + 4,
                        segmentMaxX: localRect.maxX - 4,
                        y: probeY,
                        occluders: localWindows.map(\.rect)
                    )
                    if visibleSpans.isEmpty {
                        continue
                    }
                }
                surfaces.append(DetectedSurface(
                    id: item.id,
                    kind: item.kind,
                    rect: localRect,
                    label: item.label
                ))
                iconCount += 1
            }

            // Dock & Dock icons
            if opts.landOnDock {
                var addedDockViaAX = false
                if let shelfQ = dockInfo.shelfRect, shelfQ.intersects(screenQ) {
                    let shelfInter = shelfQ.intersection(screenQ)
                    if shelfInter.height >= 8 && shelfInter.width >= 20 {
                        addedDockViaAX = true
                        let localShelf = CGRect(
                            x: shelfQ.minX - screenQ.minX,
                            y: shelfQ.minY - screenQ.minY,
                            width: shelfQ.width,
                            height: shelfQ.height
                        )
                        var iconIntervals: [(CGFloat, CGFloat)] = []

                        for dItem in dockInfo.items where dItem.rect.intersects(screenQ) {
                            let localItem = CGRect(
                                x: dItem.rect.minX - screenQ.minX,
                                y: dItem.rect.minY - screenQ.minY,
                                width: dItem.rect.width,
                                height: dItem.rect.height
                            )
                            let insetItem = CGRect(
                                x: localItem.minX + 3,
                                y: localItem.minY,
                                width: max(8, localItem.width - 6),
                                height: localItem.height
                            )
                            surfaces.append(DetectedSurface(
                                id: dItem.id,
                                kind: .dockIcon,
                                rect: insetItem,
                                label: dItem.label
                            ))
                            iconIntervals.append((insetItem.minX, insetItem.maxX))
                            dockCount += 1
                        }

                        // Add Dock shelf segments in horizontal gaps (endcaps + separators) when Dock is horizontal
                        if localShelf.width > localShelf.height * 1.8 {
                            let gaps = Self.subtractHorizontalIntervals(
                                minX: localShelf.minX + 6,
                                maxX: localShelf.maxX - 6,
                                exclusions: iconIntervals
                            )
                            for (idx, span) in gaps.enumerated() where span.1 - span.0 >= 6 {
                                let gapRect = CGRect(
                                    x: span.0,
                                    y: localShelf.minY + 2,
                                    width: span.1 - span.0,
                                    height: localShelf.height
                                )
                                surfaces.append(DetectedSurface(
                                    id: "dock-shelf:\(displayID):\(idx)",
                                    kind: .dockShelf,
                                    rect: gapRect,
                                    label: "Dock"
                                ))
                            }
                        }
                    }
                }

                // Fallback Dock surface when Accessibility is not enabled and Dock is pinned visible
                if !addedDockViaAX && !axTrusted && dockGapHeight > 12 {
                    let fallbackWidth = min(screenQ.width * 0.72, 1100)
                    let fallbackX = (screenQ.width - fallbackWidth) * 0.5
                    let fallbackRect = CGRect(
                        x: fallbackX,
                        y: screenQ.height - dockGapHeight,
                        width: fallbackWidth,
                        height: dockGapHeight
                    )
                    surfaces.append(DetectedSurface(
                        id: "dock-fallback:\(displayID)",
                        kind: .dockShelf,
                        rect: fallbackRect,
                        label: "Dock"
                    ))
                    dockCount = 1
                }
            }

            // Open App Windows (only unoccluded top-edge segments!)
            if opts.landOnWindows {
                for idx in 0..<localWindows.count {
                    let win = localWindows[idx]
                    // Only visible portion of window top edge (subtract windows above index idx)
                    let frontOccluders = idx > 0 ? Array(localWindows[0..<idx].map(\.rect)) : []
                    let spans = Self.subtractOccludingRects(
                        segmentMinX: win.rect.minX,
                        segmentMaxX: win.rect.maxX,
                        y: win.rect.minY + 1.0,
                        occluders: frontOccluders
                    )
                    for (segIdx, span) in spans.enumerated() where span.1 - span.0 >= 16 {
                        let segRect = CGRect(
                            x: span.0,
                            y: win.rect.minY,
                            width: span.1 - span.0,
                            height: win.rect.height
                        )
                        surfaces.append(DetectedSurface(
                            id: "win:\(win.id):\(segIdx)",
                            kind: .window,
                            rect: segRect,
                            label: win.title
                        ))
                    }
                    if !spans.isEmpty {
                        winCount += 1
                    }
                }
            }

            // Wallpaper depthmap ledges (people, objects & ridges), occluded by open windows if enabled
            if opts.landOnWallpaper, let wallSurfaces = wallpaperMap[displayID] {
                let occluders = opts.respectWindowOcclusion ? localWindows.map(\.rect) : []
                for ws in wallSurfaces {
                    if ws.kind == .wallpaperScene && !opts.includeWallpaperSceneLedges {
                        continue
                    }
                    if occluders.isEmpty {
                        surfaces.append(ws)
                        wallCount += 1
                    } else {
                        let probeY = ws.rect.midY
                        let spans = Self.subtractOccludingRects(
                            segmentMinX: ws.rect.minX,
                            segmentMaxX: ws.rect.maxX,
                            y: probeY,
                            occluders: occluders
                        )
                        for (segIdx, span) in spans.enumerated() where span.1 - span.0 >= 14 {
                            let slicedProfile = Self.sliceProfile(
                                ws.customTopProfile,
                                fullMinX: ws.rect.minX,
                                fullMaxX: ws.rect.maxX,
                                sliceMinX: span.0,
                                sliceMaxX: span.1
                            )
                            let segRect = CGRect(
                                x: span.0,
                                y: ws.rect.minY,
                                width: span.1 - span.0,
                                height: ws.rect.height
                            )
                            surfaces.append(DetectedSurface(
                                id: "\(ws.id):\(segIdx)",
                                kind: ws.kind,
                                rect: segRect,
                                label: ws.label,
                                customTopProfile: slicedProfile
                            ))
                            wallCount += 1
                        }
                    }
                }
            }

            // Screen bottom (ground)
            if opts.landOnGround {
                let groundRect = CGRect(
                    x: 0,
                    y: screenQ.height - 1,
                    width: screenQ.width,
                    height: 12
                )
                surfaces.append(DetectedSurface(
                    id: "ground:\(displayID)",
                    kind: .ground,
                    rect: groundRect,
                    label: "Desktop Ground"
                ))
            }

            results[displayID] = ScreenSurfaceSnapshot(
                displayID: displayID,
                surfaces: surfaces,
                windowRects: localWindows.map(\.rect),
                iconCount: iconCount,
                dockItemCount: dockCount,
                windowCount: winCount,
                wallpaperLedgeCount: wallCount,
                accessibilityGranted: axTrusted
            )
        }

        stateLock.lock()
        self.latestSnapshots = results
        stateLock.unlock()

        onUpdate?(results)
    }

    // MARK: - Interval Geometry Helpers (Pure & Testable)

    /// Returns horizontal sub-intervals of [segmentMinX, segmentMaxX] at vertical position `y`
    /// that are NOT covered by any rectangle in `occluders`.
    public static func subtractOccludingRects(
        segmentMinX: CGFloat,
        segmentMaxX: CGFloat,
        y: CGFloat,
        occluders: [CGRect]
    ) -> [(CGFloat, CGFloat)] {
        guard segmentMaxX > segmentMinX else { return [] }
        var blocking: [(CGFloat, CGFloat)] = []
        for r in occluders {
            if y >= r.minY && y <= r.maxY {
                let lo = max(segmentMinX, r.minX)
                let hi = min(segmentMaxX, r.maxX)
                if hi > lo {
                    blocking.append((lo, hi))
                }
            }
        }
        return subtractHorizontalIntervals(minX: segmentMinX, maxX: segmentMaxX, exclusions: blocking)
    }

    public static func subtractHorizontalIntervals(
        minX: CGFloat,
        maxX: CGFloat,
        exclusions: [(CGFloat, CGFloat)]
    ) -> [(CGFloat, CGFloat)] {
        guard maxX > minX else { return [] }
        if exclusions.isEmpty { return [(minX, maxX)] }

        let sorted = exclusions
            .map { (max(minX, $0.0), min(maxX, $0.1)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }

        var result: [(CGFloat, CGFloat)] = []
        var cursor = minX
        for (exLo, exHi) in sorted {
            if exLo > cursor {
                result.append((cursor, exLo))
            }
            if exHi > cursor {
                cursor = exHi
            }
        }
        if cursor < maxX {
            result.append((cursor, maxX))
        }
        return result
    }

    private static func sliceProfile(
        _ profile: [Float]?,
        fullMinX: CGFloat,
        fullMaxX: CGFloat,
        sliceMinX: CGFloat,
        sliceMaxX: CGFloat
    ) -> [Float]? {
        guard let profile, !profile.isEmpty else { return nil }
        let totalW = fullMaxX - fullMinX
        guard totalW > 0 else { return profile }
        let startFrac = max(0, min(1, (sliceMinX - fullMinX) / totalW))
        let endFrac = max(0, min(1, (sliceMaxX - fullMinX) / totalW))
        let lo = max(0, min(profile.count - 1, Int(floor(startFrac * CGFloat(profile.count - 1)))))
        let hi = max(lo, min(profile.count - 1, Int(ceil(endFrac * CGFloat(profile.count - 1)))))
        return Array(profile[lo...hi])
    }

    // MARK: - macOS Accessibility & Window Queries

    private func fetchFinderDesktopItems() -> [(id: String, kind: SurfaceKind, rect: CGRect, label: String)] {
        guard let finderApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.finder"
        }) else {
            return []
        }

        let axApp = AXUIElementCreateApplication(finderApp.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)

        guard let topChildren = axAttribute(axApp, kAXChildrenAttribute) as? [AXUIElement] else {
            return []
        }

        var items: [(id: String, kind: SurfaceKind, rect: CGRect, label: String)] = []
        var titleCounts: [String: Int] = [:]

        for child in topChildren {
            guard (axAttribute(child, kAXRoleAttribute) as? String) == "AXScrollArea" else { continue }
            guard let areaChildren = axAttribute(child, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for group in areaChildren {
                guard let desktopElements = axAttribute(group, kAXChildrenAttribute) as? [AXUIElement] else { continue }
                for el in desktopElements {
                    guard let rect = axFrame(el), rect.width >= 16, rect.height >= 16, rect.width <= 260 else {
                        continue
                    }
                    let title = (axAttribute(el, kAXTitleAttribute) as? String)
                        ?? (axAttribute(el, kAXFilenameAttribute) as? String)
                        ?? "Icon"
                    let occ = titleCounts[title, default: 0]
                    titleCounts[title] = occ + 1

                    let isDir = isDirectoryElement(el)
                    let kind: SurfaceKind = isDir ? .desktopFolder : .desktopIcon
                    let id = "finder:\(title)#\(occ)"
                    items.append((id: id, kind: kind, rect: rect, label: title))
                }
            }
        }
        return items
    }

    private func isDirectoryElement(_ el: AXUIElement) -> Bool {
        if let url = axAttribute(el, kAXURLAttribute) as? URL, url.isFileURL {
            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
                // Folders are directories that are not .app bundles/packages
                return (values.isDirectory == true) && (values.isPackage != true)
            }
        }
        if let roleDesc = axAttribute(el, kAXRoleDescriptionAttribute) as? String {
            return roleDesc.localizedCaseInsensitiveContains("folder")
        }
        return false
    }

    private func fetchDockItems() -> (shelfRect: CGRect?, items: [(id: String, rect: CGRect, label: String)]) {
        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else {
            return (nil, [])
        }

        let axApp = AXUIElementCreateApplication(dockApp.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)

        guard let children = axAttribute(axApp, kAXChildrenAttribute) as? [AXUIElement] else {
            return (nil, [])
        }

        for child in children {
            guard (axAttribute(child, kAXRoleAttribute) as? String) == "AXList" else { continue }
            let shelfRect = axFrame(child)
            let dockElements = (axAttribute(child, kAXChildrenAttribute) as? [AXUIElement]) ?? []

            var items: [(id: String, rect: CGRect, label: String)] = []
            var counts: [String: Int] = [:]

            for el in dockElements {
                let subrole = axAttribute(el, kAXSubroleAttribute) as? String ?? ""
                if subrole == "AXSeparatorDockItem" {
                    continue
                }
                guard let rect = axFrame(el), rect.width >= 16, rect.height >= 16 else { continue }
                let title = (axAttribute(el, kAXTitleAttribute) as? String) ?? "DockItem"
                let occ = counts[title, default: 0]
                counts[title] = occ + 1
                items.append((id: "dock:\(title)#\(occ)", rect: rect, label: title))
            }
            return (shelfRect, items)
        }

        return (nil, [])
    }

    private func fetchNormalWindows() -> [(id: UInt32, rect: CGRect, title: String)] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var windows: [(id: UInt32, rect: CGRect, title: String)] = []
        for info in rawList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.1 else { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict),
                  rect.width >= 80, rect.height >= 40 else {
                continue
            }

            let winID = info[kCGWindowNumber as String] as? UInt32 ?? 0
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let name = info[kCGWindowName as String] as? String ?? ""
            let label = name.isEmpty ? owner : "\(owner): \(name)"
            windows.append((id: winID, rect: rect, title: label))
        }
        return windows
    }

    private func axAttribute(_ element: AXUIElement, _ attr: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        return err == .success ? value : nil
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let posVal = axAttribute(element, kAXPositionAttribute),
              let sizeVal = axAttribute(element, kAXSizeAttribute) else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: pos, size: size)
    }
}
