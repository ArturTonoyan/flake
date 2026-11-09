import AppKit
import CoreVideo
import MetalKit
import QuartzCore

final class OverlayController {
    private struct ScreenOverlay {
        let panel: NSPanel
        let view: MTKView
        let renderer: SnowRenderer
        let screenID: CGDirectDisplayID
    }

    private var overlays: [ScreenOverlay] = []
    private let simulator = SnowSimulator()
    private let tracker = WindowTracker()
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var displayLink: CVDisplayLink?
    private var lastTick = CACurrentMediaTime()
    private var lastMouse = NSEvent.mouseLocation
    private var lastRender = CACurrentMediaTime()
    private let targetFrameTime: CFTimeInterval = 1.0 / 30.0
    private var tickScheduled = false
    private var mouseMonitors: [Any] = []
    private var lastScreenSignature: String = ""

    var isPaused = false
    var intensity: Double = 0.7 {
        didSet { simulator.intensity = Float(intensity) }
    }
    var mouseInteractionEnabled = true {
        didSet { simulator.mouseEnabled = mouseInteractionEnabled }
    }

    func start() {
        simulator.intensity = Float(intensity)
        simulator.mouseEnabled = mouseInteractionEnabled
        rebuildOverlays()
        startDisplayLink()
        installMouseMonitors()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildOverlays()
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.simulator.noteSpaceSwitch()
        }
    }

    func stop() {
        stopDisplayLink()
        removeMouseMonitors()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        tearDownOverlays()
    }

    private func installMouseMonitors() {
        removeMouseMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            switch event.type {
            case .leftMouseDown, .leftMouseDragged:
                self.simulator.mouseDown = true
            case .leftMouseUp:
                self.simulator.mouseDown = false
            default:
                break
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handler(event)
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func removeMouseMonitors() {
        for monitor in mouseMonitors {
            NSEvent.removeMonitor(monitor)
        }
        mouseMonitors.removeAll()
        simulator.mouseDown = false
    }

    func clearSnow() {
        simulator.clear()
    }

    private func tearDownOverlays() {
        for item in overlays {
            item.panel.orderOut(nil)
            item.view.delegate = nil
        }
        overlays.removeAll()
    }

    private func rebuildOverlays() {
        tearDownOverlays()

        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("Flake: Metal is unavailable")
            return
        }

        updateWorldBounds(force: true)

        NSLog("Flake: building overlays for \(NSScreen.screens.count) screen(s)")
        for screen in NSScreen.screens {
            let frame = screen.frame
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            NSLog("Flake: screen \(screenID) frame \(frame)")

            let panel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            // Force the panel onto this exact display (multi-monitor critical).
            panel.setFrame(frame, display: true)
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle,
            ]
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true

            let view = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
            view.autoresizingMask = [.width, .height]
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.preferredFramesPerSecond = 30
            view.wantsLayer = true
            view.layer?.isOpaque = false
            view.layer?.backgroundColor = NSColor.clear.cgColor
            if let metalLayer = view.layer as? CAMetalLayer {
                metalLayer.isOpaque = false
                metalLayer.backgroundColor = NSColor.clear.cgColor
                metalLayer.contentsScale = screen.backingScaleFactor
            }

            panel.contentView = view

            guard let renderer = SnowRenderer(view: view, simulator: simulator, screenFrame: frame) else {
                NSLog("Flake: failed to create renderer for screen \(screenID)")
                continue
            }

            view.delegate = renderer
            overlays.append(ScreenOverlay(panel: panel, view: view, renderer: renderer, screenID: screenID))
            panel.orderFrontRegardless()
        }
        NSLog("Flake: active overlays=\(overlays.count)")
    }

    private func updateWorldBounds(force: Bool = false) {
        var union = NSRect.zero
        var frames: [NSRect] = []
        var signature = "\(NSScreen.screens.count)"
        for screen in NSScreen.screens {
            frames.append(screen.frame)
            signature += "|\(Int(screen.frame.minX)),\(Int(screen.frame.minY)),\(Int(screen.frame.width)),\(Int(screen.frame.height))"
            union = union.isEmpty ? screen.frame : union.union(screen.frame)
        }
        if !force, signature == lastScreenSignature { return }
        lastScreenSignature = signature
        if union.isEmpty {
            let fallback = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            frames = [fallback]
            union = fallback
        }
        simulator.setWorldBounds(
            minX: Float(union.minX),
            minY: Float(union.minY),
            maxX: Float(union.maxX),
            maxY: Float(union.maxY)
        )
        simulator.setScreenFrames(frames)
    }

    private func startDisplayLink() {
        stopDisplayLink()
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        displayLink = link

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let controller = Unmanaged<OverlayController>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                guard !controller.tickScheduled else { return }
                controller.tickScheduled = true
                controller.tick()
                controller.tickScheduled = false
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(
            link,
            callback,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        CVDisplayLinkStart(link)
    }

    private func stopDisplayLink() {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        displayLink = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        guard now - lastRender >= targetFrameTime - 0.001 else { return }
        let dt = Float(now - lastTick)
        lastTick = now
        lastRender = now

        let mouse = NSEvent.mouseLocation
        let prev = lastMouse
        lastMouse = mouse
        let moveX = mouse.x - prev.x
        let moveY = mouse.y - prev.y
        simulator.mouseX = Float(mouse.x)
        simulator.mouseY = Float(mouse.y)
        simulator.mouseVX = Float(moveX) / max(dt, 0.001)
        simulator.mouseVY = Float(moveY) / max(dt, 0.001)
        // Source of truth — event monitors alone miss buttons across some apps.
        let pressed = (NSEvent.pressedMouseButtons & (1 << 0)) != 0
        simulator.mouseDown = pressed
        simulator.mouseEnabled = mouseInteractionEnabled
        let trackingActive = pressed || hypot(moveX, moveY) > 0.5

        if !isPaused {
            updateWorldBounds()
            simulator.update(dt: dt, windows: tracker.windows(active: trackingActive))
        }

        for item in overlays {
            // Maximized / fullscreen on this display → hide the whole overlay so flakes
            // never flicker in the menu-bar strip or along the window edges.
            let blocked = simulator.isSnowBlocked(screenFrame: item.renderer.screenFrame)
            if blocked {
                if item.panel.alphaValue != 0 {
                    item.panel.alphaValue = 0
                }
                continue
            }
            if item.panel.alphaValue != 1 {
                item.panel.alphaValue = 1
            }
            item.renderer.render(into: item.view)
        }
    }
}
