import AppKit
import CoreVideo
import MetalKit
import QuartzCore

final class OverlayController {
    /// Just under pop-up menus so Flake's status menu (and system menus) stay readable.
    private static let snowOverlayLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) - 1
    )

    private struct ScreenOverlay {
        let panel: NSPanel
        let view: MTKView
        let renderer: SnowRenderer
        let screenID: CGDirectDisplayID
        let signHUD: SnowmanSignHUD
    }

    private var overlays: [ScreenOverlay] = []
    private let simulator = SnowSimulator()
    private let tracker = WindowTracker()
    let peerNetwork = PeerSnowNetwork()
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var appActivateObserver: NSObjectProtocol?
    private var lastFrontPID: pid_t = 0
    private var displayLink: CVDisplayLink?
    private var lastTick = CACurrentMediaTime()
    private var lastMouse = NSEvent.mouseLocation
    private var lastRender = CACurrentMediaTime()
    private let targetFrameTime: CFTimeInterval = 1.0 / 30.0
    private var tickScheduled = false
    private var mouseMonitors: [Any] = []
    private var lastScreenSignature: String = ""
    private(set) var lanPeers: [PeerInfo] = []
    var onLanPeersChanged: (() -> Void)?
    private let toast = LanToastBanner()
    private let snowmanPoster = InboundSnowmanPoster()
    /// Per-display overlay opacity during Space swipe (0…1). Dual monitors with
    /// separate Spaces must not fade the idle display when the other swipes.
    private var overlayFades: [CGDirectDisplayID: CGFloat] = [:]
    /// Status-item / app menu is open — keep snow from covering it.
    var menuOccludesSnow = false

    var isPaused = false

    /// Who currently receives a throw off each screen edge (for the menu).
    var throwRoute: LanThrowRoute { peerNetwork.throwRouteMain }
    var intensity: Double = 0.7 {
        didSet { simulator.intensity = Float(intensity) }
    }
    var mouseInteractionEnabled = true {
        didSet { simulator.mouseEnabled = mouseInteractionEnabled }
    }
    var lanSnowballsEnabled: Bool {
        get { peerNetwork.isEnabled }
        set {
            simulator.lanHandoffEnabled = newValue
            peerNetwork.setEnabled(newValue)
        }
    }

    func start() {
        simulator.intensity = Float(intensity)
        simulator.mouseEnabled = mouseInteractionEnabled
        rebuildOverlays()
        startDisplayLink()
        installMouseMonitors()
        wirePeerNetwork()

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
            guard let self else { return }
            self.simulator.noteSpaceSwitch()
            self.hardBlankBlockedOverlays()
        }

        appActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.simulator.noteFocusSwitch()
            // Fresh window list before the next display tick paints snow.
            let windows = self.tracker.windows(force: true, active: true)
            self.simulator.update(dt: 1.0 / 60.0, windows: windows)
            self.hardBlankBlockedOverlays()
        }
        lastFrontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    }

    func stop() {
        peerNetwork.stop()
        stopDisplayLink()
        removeMouseMonitors()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let appActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivateObserver)
        }
        tearDownOverlays()
    }

    /// Instantly clear + hide overlays on blanked displays (no fade).
    private func hardBlankBlockedOverlays() {
        for item in overlays {
            let blocked = simulator.isSnowBlocked(screenFrame: item.renderer.screenFrame)
                || simulator.isSpaceTransitioning(on: item.renderer.screenFrame)
            guard blocked else { continue }
            item.renderer.renderLanOnly = true
            if !item.view.isPaused { item.view.isPaused = true }
            item.view.draw()
            item.panel.alphaValue = 0
            overlayFades[item.screenID] = 0
        }
    }

    private func wirePeerNetwork() {
        peerNetwork.onPeersChanged = { [weak self] peers in
            guard let self else { return }
            self.lanPeers = peers
            self.onLanPeersChanged?()
        }
        peerNetwork.onInboundSnowball = { [weak self] ball in
            guard let self else { return }
            let short = Self.shortPeerName(ball.fromName)
            _ = self.simulator.spawnInboundSnowball(
                entryEdge: ball.entryEdge,
                normY: ball.normY,
                vx: ball.vx,
                vy: ball.vy,
                mass: ball.mass,
                fromName: short
            )
            self.toast.show("Снежок от \(short)")
        }
        peerNetwork.onInboundSnowman = { [weak self] man in
            guard let self else { return }
            let short = Self.shortPeerName(man.fromName)
            self.snowmanPoster.present(from: man, peerShortName: short) { [weak self] center in
                self?.simulator.shatterPosterSnowman(atX: Float(center.x), y: Float(center.y))
            }
            self.toast.show("Снеговик от \(short)")
        }
        peerNetwork.onThrowDelivered = { [weak self] name in
            self?.toast.show("Долетело → \(Self.shortPeerName(name))")
        }
        peerNetwork.onThrowMissed = { [weak self] name in
            if name.hasPrefix("никого") || name.contains("Wi‑Fi") {
                self?.toast.show("Не дошло: \(name)")
            } else {
                self?.toast.show("Не дошло до \(Self.shortPeerName(name))")
            }
        }
        let saved = UserDefaults.standard.bool(forKey: PeerSnowNetwork.defaultsKeyEnabled)
        simulator.lanHandoffEnabled = saved
        peerNetwork.restoreFromDefaults()
    }

    func setPeerSide(_ side: PeerRelativeSide, peerID: UInt64) {
        peerNetwork.setSide(side, forPeerID: peerID)
    }

    /// Local preview of the peer hit animation (fly → explode → stain).
    func previewLanSnowballHit(giant: Bool = false) {
        lanSnowballsEnabled = true
        let edge: SnowEdge = Bool.random() ? .left : .right
        let mass: Float = giant
            ? SnowSimulator.ballMaxMass
            : Float.random(in: 40...120)
        _ = simulator.spawnInboundSnowball(
            entryEdge: edge,
            normY: Float.random(in: 0.2...0.8),
            vx: edge == .left ? 400 : -400,
            vy: Float.random(in: -80...80),
            mass: mass,
            fromName: giant ? "гигант" : "тест"
        )
        toast.show(giant ? "Огромный снежок (тест)" : "Снежок от тест")
    }

    /// Drop a local snowman on a window ledge so throw animation can be checked.
    func spawnTestSnowman() {
        let mouse = NSEvent.mouseLocation
        _ = simulator.spawnTestSnowman(
            nearX: Float(mouse.x),
            nearY: Float(mouse.y),
            signText: ""
        )
        toast.show("Снеговик на окне")
    }

    /// Local preview of a signed snowman flying in (stays until click).
    func previewLanSnowmanHit() {
        lanSnowballsEnabled = true
        let edge: SnowEdge = Bool.random() ? .left : .right
        let man = InboundSnowman(
            fromPeerID: 0,
            fromName: "тест",
            entryEdge: edge,
            normY: Float.random(in: 0.3...0.7),
            vx: edge == .left ? 400 : -400,
            vy: Float.random(in: -40...40),
            signText: "Привет!"
        )
        snowmanPoster.present(from: man, peerShortName: "тест") { [weak self] center in
            self?.simulator.shatterPosterSnowman(atX: Float(center.x), y: Float(center.y))
        }
        toast.show("Снеговик от тест")
    }

    static func shortPeerName(_ name: String) -> String {
        let separators = ["—", "–", "-"]
        for sep in separators {
            if let range = name.range(of: sep) {
                let tail = name[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { return tail }
            }
        }
        return name
    }

    private func installMouseMonitors() {
        removeMouseMonitors()
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown
        ]
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            switch event.type {
            case .leftMouseDown, .leftMouseDragged:
                self.simulator.mouseDown = true
            case .leftMouseUp:
                self.simulator.mouseDown = false
            case .rightMouseDown:
                self.handleSnowmanSignClick(at: event)
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

    private func handleSnowmanSignClick(at event: NSEvent) {
        _ = event
        let screenPoint = NSEvent.mouseLocation
        guard let idx = simulator.snowmanIndexAt(x: Float(screenPoint.x), y: Float(screenPoint.y)) else {
            return
        }
        promptSnowmanSign(at: idx)
    }

    private func promptSnowmanSign(at index: Int) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Табличка снеговика"
        alert.informativeText = "Напиши текст на табличку. Потом кинь снеговика за край экрана — друг увидит надпись."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = simulator.signText(at: index) ?? ""
        field.placeholderString = "Например: Привет!"
        field.maximumNumberOfLines = 1
        alert.accessoryView = field
        alert.addButton(withTitle: "Готово")
        alert.addButton(withTitle: "Убрать табличку")
        alert.addButton(withTitle: "Отмена")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                self.simulator.setSnowmanSign(at: index, text: field.stringValue)
                if !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.toast.show("Табличка готова — кинь за край")
                }
            case .alertSecondButtonReturn:
                self.simulator.setSnowmanSign(at: index, text: "")
            default:
                break
            }
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
        snowmanPoster.dismissAll()
        for item in overlays {
            item.signHUD.clear()
        }
    }

    private func tearDownOverlays() {
        for item in overlays {
            item.signHUD.clear()
            item.panel.orderOut(nil)
            item.view.delegate = nil
        }
        overlays.removeAll()
        overlayFades.removeAll(keepingCapacity: true)
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
            // Above normal / floating app windows and the Dock, but below status-item
            // menus and system pop-ups (draggingWindow sits far above those).
            panel.level = Self.snowOverlayLevel
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
            // Manual ticks only — auto-draw + dual monitors exhausts drawable pools.
            view.isPaused = true
            view.enableSetNeedsDisplay = false
            view.preferredFramesPerSecond = 30
            view.wantsLayer = true
            view.layer?.isOpaque = false
            view.layer?.backgroundColor = NSColor.clear.cgColor
            if let metalLayer = view.layer as? CAMetalLayer {
                metalLayer.isOpaque = false
                metalLayer.backgroundColor = NSColor.clear.cgColor
                metalLayer.contentsScale = screen.backingScaleFactor
                metalLayer.allowsNextDrawableTimeout = true
            }

            panel.contentView = view

            guard let renderer = SnowRenderer(view: view, simulator: simulator, screenFrame: frame) else {
                NSLog("Flake: failed to create renderer for screen \(screenID)")
                continue
            }

            view.delegate = renderer
            let signHUD = SnowmanSignHUD()
            signHUD.attach(to: view)
            overlays.append(
                ScreenOverlay(
                    panel: panel,
                    view: view,
                    renderer: renderer,
                    screenID: screenID,
                    signHUD: signHUD
                )
            )
            overlayFades[screenID] = overlayFades[screenID] ?? 1
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

        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if frontPID != 0, frontPID != lastFrontPID {
            lastFrontPID = frontPID
            simulator.noteFocusSwitch()
        }

        if !isPaused {
            updateWorldBounds()
            // Force each tick — maximized blanking must not lag a cached window list.
            simulator.update(dt: dt, windows: tracker.windows(force: true, active: true))
            if lanSnowballsEnabled {
                for exit in simulator.consumeEdgeExits() {
                    peerNetwork.sendSnowball(exit)
                }
                for exit in simulator.consumeSnowmanExits() {
                    peerNetwork.sendSnowman(exit)
                }
            }
        } else {
            // Peer hits still animate while local snow is paused.
            simulator.tickLanImpacts(dt: dt)
        }

        let signEntries = simulator.snowmenSignHUD()
        let hasLanHits = simulator.hasActiveLanImpacts

        for item in overlays {
            item.signHUD.sync(entries: signEntries, panel: item.panel)
            // Hide immediately on Space swipe — delayed fade let snow flash on fullscreen.
            let concealSpace = simulator.isSpaceTransitioning(on: item.renderer.screenFrame)
            let spaceTarget: CGFloat = concealSpace ? 0 : 1
            var fade = overlayFades[item.screenID] ?? 1
            if concealSpace {
                fade = 0
            } else {
                let spaceSpeed: CGFloat = 5.8
                let spaceStep = min(1 as CGFloat, max(0, CGFloat(dt)) * spaceSpeed)
                fade += (spaceTarget - fade) * spaceStep
                if abs(fade - spaceTarget) < 0.012 { fade = spaceTarget }
            }
            overlayFades[item.screenID] = fade

            // Maximized / fullscreen → hide regular snow, but keep the panel up for peer hits.
            let blocked = simulator.isSnowBlocked(screenFrame: item.renderer.screenFrame)
            let showLan = hasLanHits && simulator.hasLanImpacts(in: item.renderer.screenFrame)
            let blank = (blocked || concealSpace) && !showLan
            let want: CGFloat
            if showLan {
                want = 1
            } else if blank {
                want = 0
            } else {
                want = fade
            }
            // Blanking must be instant — any fade paints snow over the app.
            let alpha: CGFloat
            if blank {
                alpha = 0
            } else {
                let cur = item.panel.alphaValue
                let panelSpeed: CGFloat = want < cur ? 8.0 : 6.0
                let panelStep = min(1 as CGFloat, max(0, CGFloat(dt)) * panelSpeed)
                alpha = abs(want - cur) < 0.012 ? want : cur + (want - cur) * panelStep
            }
            if item.panel.alphaValue != alpha {
                item.panel.alphaValue = alpha
            }
            // Keep a stable level under menus; LAN hits use the same stack (still over apps).
            if item.panel.level != Self.snowOverlayLevel {
                item.panel.level = Self.snowOverlayLevel
            }
            if !item.view.isPaused { item.view.isPaused = true }

            if blank {
                // Clear the last snow frame from the Metal layer, then stay hidden.
                item.renderer.renderLanOnly = true
                item.view.draw()
                continue
            }
            if alpha < 0.02 && !showLan {
                continue
            }
            // While the status menu is open, don't orderFrontRegardless — that can
            // cover the menu. Snow stays visible underneath (level is below pop-ups).
            if menuOccludesSnow {
                // no-op: leave current z-order alone
            } else if showLan || item.panel.isVisible || alpha > 0.02 {
                item.panel.orderFrontRegardless()
            }
            item.renderer.renderLanOnly = blocked
            item.view.draw()
        }
    }
}
