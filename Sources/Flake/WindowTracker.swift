import AppKit
import CoreGraphics

/// Full window rectangle in global Cocoa points (y grows up; `y` is the TOP edge).
struct SnowWindow: Equatable {
    let id: UInt32
    let x: Float
    let y: Float
    let width: Float
    let height: Float
    let z: Int
    let isDock: Bool
    let isMaximized: Bool
    /// Snow may pile on the top edge.
    let canAccumulate: Bool

    var bottom: Float { y - height }
    var right: Float { x + width }

    var ledge: SnowLedge {
        SnowLedge(id: id, x: x, y: y, width: width, z: z, isDock: isDock)
    }

    /// True if point is inside the window body (not on/above the top edge).
    func occludes(x px: Float, y py: Float) -> Bool {
        guard px >= x, px <= right else { return false }
        return py < y - 1 && py >= bottom
    }
}

struct SnowLedge: Equatable {
    let id: UInt32
    let x: Float
    let y: Float
    let width: Float
    let z: Int
    let isDock: Bool
}

final class WindowTracker {
    private var cached: [SnowWindow] = []
    private var lastUpdate: CFTimeInterval = 0
    /// Idle desktops don't need 30Hz window scans — bump while the user moves things.
    private let idleInterval: CFTimeInterval = 1.0 / 12.0
    private let activeInterval: CFTimeInterval = 1.0 / 30.0
    private let ourPID = ProcessInfo.processInfo.processIdentifier

    /// Pass `active: true` while the mouse moves / drags so ledge tracking stays snappy.
    func windows(force: Bool = false, active: Bool = false) -> [SnowWindow] {
        let now = CACurrentMediaTime()
        let interval = active ? activeInterval : idleInterval
        if !force, now - lastUpdate < interval {
            return cached
        }
        lastUpdate = now
        cached = fetchWindows()
        return cached
    }

    func ledges(force: Bool = false) -> [SnowLedge] {
        windows(force: force).compactMap { $0.canAccumulate ? $0.ledge : nil }
    }

    private func fetchWindows() -> [SnowWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return appendDockLedges(onto: [])
        }

        // Quartz origin = top-left of the display with Cocoa origin (0,0).
        let screens = NSScreen.screens
        let primaryScreen =
            screens.first(where: { $0.frame.origin == .zero })
            ?? screens.first(where: { abs($0.frame.minX) < 1 && abs($0.frame.minY) < 1 })
            ?? NSScreen.main
            ?? screens.first
        let primaryHeight = Float(primaryScreen?.frame.height ?? 0)
        guard primaryHeight > 1 else { return appendDockLedges(onto: []) }

        var raw: [SnowWindow] = []
        raw.reserveCapacity(32)

        for (index, window) in info.enumerated() {
            guard
                let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID != ourPID,
                let layer = window[kCGWindowLayer as String] as? Int,
                layer <= 25,
                let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
                let alpha = window[kCGWindowAlpha as String] as? CGFloat,
                alpha > 0.05,
                let windowNumber = window[kCGWindowNumber as String] as? UInt32
            else { continue }

            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let windowName = window[kCGWindowName as String] as? String ?? ""

            // Dock is handled via synthetic ledges from visibleFrame (more stable).
            if owner == "Dock" || owner == "Dock Helper" { continue }

            if owner == "Window Server"
                || owner == "Control Center"
                || owner == "Notification Center"
                || owner == "SystemUIServer"
                || owner == "Spotlight"
                || owner == "TextInputMenuAgent"
            {
                continue
            }

            if isWidgetProcess(owner: owner) { continue }
            if layer > 0 { continue }

            let x = Float(boundsDict["X"] ?? 0)
            let yTopQuartz = Float(boundsDict["Y"] ?? 0)
            let w = Float(boundsDict["Width"] ?? 0)
            let h = Float(boundsDict["Height"] ?? 0)

            if w < 48 || h < 28 { continue }

            let topY = primaryHeight - yTopQuartz

            // Desktop widgets: ignore completely — no occlusion, no drifts (snow falls through).
            if isDesktopWidget(owner: owner, name: windowName, width: w, height: h) {
                continue
            }

            if isMenuBarStrip(x: x, topY: topY, width: w, height: h, screens: screens) {
                continue
            }

            // Bottom-edge chrome (except our synthetic Dock) must not become a floor.
            if isBottomEdgeStrip(x: x, topY: topY, width: w, height: h, screens: screens) {
                continue
            }

            let maximized = isMaximizedWindow(x: x, topY: topY, width: w, height: h)

            raw.append(
                SnowWindow(
                    id: windowNumber,
                    x: x,
                    y: topY,
                    width: w,
                    height: h,
                    z: index,
                    isDock: false,
                    isMaximized: maximized,
                    canAccumulate: false
                )
            )
        }

        let windows = raw.map { win -> SnowWindow in
            let nested = raw.contains { other in
                other.id != win.id
                    && other.width * other.height > win.width * win.height * 1.05
                    && win.x >= other.x - 2
                    && win.right <= other.right + 2
                    && win.bottom >= other.bottom - 2
                    && win.y <= other.y + 2
            }
            let canAccumulate = !win.isMaximized && !nested && win.height >= 100 && win.width >= 220
            return SnowWindow(
                id: win.id,
                x: win.x,
                y: win.y,
                width: win.width,
                height: win.height,
                z: win.z,
                isDock: false,
                isMaximized: win.isMaximized,
                canAccumulate: canAccumulate
            )
        }

        return appendDockLedges(onto: windows)
    }

    /// Bottom Dock per display from visibleFrame — reliable across Spaces / magnification.
    private func appendDockLedges(onto windows: [SnowWindow]) -> [SnowWindow] {
        var result = windows
        for (index, screen) in NSScreen.screens.enumerated() {
            let frame = screen.frame
            let visible = screen.visibleFrame
            let bottomGap = visible.minY - frame.minY
            guard bottomGap >= 22, bottomGap <= 140 else { continue }

            // Prefer the floating Dock width (centered); fall back to visible width.
            let dockWidth = min(visible.width * 0.92, max(280, visible.width * 0.55))
            let dockX = visible.midX - dockWidth * 0.5
            let id: UInt32 = 0xD0C00000 | UInt32(index & 0xFFFF)

            result.append(
                SnowWindow(
                    id: id,
                    x: Float(dockX),
                    y: Float(visible.minY),
                    width: Float(dockWidth),
                    height: Float(bottomGap),
                    z: 50_000 + index,
                    isDock: true,
                    isMaximized: false,
                    canAccumulate: true
                )
            )
        }
        return result
    }

    private func isWidgetProcess(owner: String) -> Bool {
        let o = owner.lowercased()
        return o.contains("widgetkit")
            || o.contains("widget extension")
            || o == "widgets"
            || o.contains("chronod")
            || o.contains("notificationcenter")
            || o.contains("notification center")
            || o == "widgetkit simulator"
    }

    /// macOS Desktop Widgets — treat as invisible (snow falls through, no piles).
    private func isDesktopWidget(owner: String, name: String, width: Float, height: Float) -> Bool {
        let o = owner.lowercased()
        let n = name.lowercased()
        if o.contains("widget") || n.contains("widget") { return true }

        // Standard Desktop Widget size bands (points), with slack for scaling.
        let w = width
        let h = height
        let small = w >= 140 && w <= 210 && h >= 140 && h <= 210
        let medium = w >= 290 && w <= 410 && h >= 140 && h <= 210
        let large = w >= 290 && w <= 410 && h >= 290 && h <= 430
        let tall = w >= 290 && w <= 410 && h >= 560 && h <= 800
        let extra = w >= 560 && w <= 760 && h >= 290 && h <= 430
        return small || medium || large || tall || extra
    }

    private func isBottomEdgeStrip(
        x: Float,
        topY: Float,
        width: Float,
        height: Float,
        screens: [NSScreen]
    ) -> Bool {
        guard height <= 130 else { return false }
        let bottom = topY - height
        for screen in screens {
            let frame = screen.frame
            let onBottom = abs(CGFloat(bottom) - frame.minY) < 12
            let spansWidth = CGFloat(width) >= frame.width * 0.35
            if onBottom && spansWidth { return true }
        }
        return false
    }

    private func isMenuBarStrip(
        x: Float,
        topY: Float,
        width: Float,
        height: Float,
        screens: [NSScreen]
    ) -> Bool {
        if height > 40 { return false }

        for screen in screens {
            let frame = screen.frame
            let nearTop = abs(CGFloat(topY) - frame.maxY) < 6
            let spansWidth = CGFloat(width) >= frame.width * 0.7
            let alignedX = CGFloat(x) <= frame.minX + 40
                && CGFloat(x) + CGFloat(width) >= frame.maxX - 40
            if nearTop && (spansWidth || alignedX) {
                return true
            }
        }

        if height <= 28, width >= 400 {
            return true
        }
        return false
    }

    private func isMaximizedWindow(x: Float, topY: Float, width: Float, height: Float) -> Bool {
        let bottom = CGFloat(topY) - CGFloat(height)
        let cx = CGFloat(x) + CGFloat(width) * 0.5
        let cy = bottom + CGFloat(height) * 0.5

        for screen in NSScreen.screens {
            let visible = screen.visibleFrame
            let full = screen.frame
            // Only test against the display that actually hosts this window.
            let onThisScreen = full.contains(CGPoint(x: cx, y: cy))
                || visible.contains(CGPoint(x: cx, y: cy))
            guard onThisScreen else { continue }

            // Green-button zoom into the usable desktop (menu bar / Dock excluded).
            let coversVisible =
                CGFloat(x) <= visible.minX + 14
                && CGFloat(x) + CGFloat(width) >= visible.maxX - 14
                && CGFloat(width) >= visible.width - 28
                && CGFloat(height) >= visible.height - 28
                && CGFloat(topY) >= visible.maxY - 18
                && bottom <= visible.minY + 28

            // True fullscreen Space / immersive app.
            let coversFull =
                CGFloat(x) <= full.minX + 6
                && CGFloat(x) + CGFloat(width) >= full.maxX - 6
                && CGFloat(width) >= full.width - 12
                && CGFloat(height) >= full.height - 12
                && CGFloat(topY) >= full.maxY - 8

            // Near-fullscreen even with a few pixels of chrome / shadow inset.
            let coversMost =
                CGFloat(width) >= full.width * 0.92
                && CGFloat(height) >= full.height * 0.82
                && CGFloat(x) <= full.minX + full.width * 0.06
                && bottom <= full.minY + full.height * 0.12

            if coversVisible || coversFull || coversMost { return true }
        }
        return false
    }
}
