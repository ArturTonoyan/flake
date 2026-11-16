import AppKit
import ImageIO
import QuartzCore

/// Drives the photo snowplow across a tall drift, scraping snow but leaving a thin layer.
/// Can be grabbed with the mouse, thrown, resumed on the Dock, or dismissed off-screen.
final class SnowplowController {
    private enum Phase {
        case idle
        case driving
        case held
        case falling
    }

    /// Above the snow Metal overlays so flakes/drifts never paint over the car.
    private static let carWindowLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1
    )

    /// Wheel geometry in the 1024×359 car art (top-left image coords).
    private static let artWidth: CGFloat = 1024
    private static let artHeight: CGFloat = 359
    private static let wheelCenterYArt: CGFloat = 290
    private static let wheelDiameterArt: CGFloat = 145

    private var phase: Phase = .idle
    private var panel: NSPanel?
    private var rootView: SnowplowView?
    private var surfaceID: UInt32 = 0
    private var ledgeY: CGFloat = 0
    private var ledgeMinX: CGFloat = 0
    private var ledgeMaxX: CGFloat = 0
    private var finishX: CGFloat = 0
    private var carX: CGFloat = 0
    private var carY: CGFloat = 0
    private var speed: CGFloat = 0
    private var vx: CGFloat = 0
    private var vy: CGFloat = 0
    private var cooldownUntil: CFTimeInterval = 0
    private var lastPlowX: CGFloat = .nan
    private var bobPhase: CGFloat = 0
    private var hovered = false
    private var grabOffset = NSPoint.zero
    private var lastMouse = NSPoint.zero
    private var flickVX: CGFloat = 0
    private var flickVY: CGFloat = 0
    private var wasPressed = false
    /// After the user grabs and drops the car back on the Dock — strip snow clean.
    private var clearFully = false
    private var pendingEdgeExit: OutboundSnowplow?
    /// When true, throwing the car past a screen edge hands it to a LAN peer.
    var lanHandoffEnabled = false

    /// Auto-start when a drift reaches this height (window points).
    var autoTriggerPeak: Float = 12
    /// Seconds before another automatic pass on the same desktop.
    var cooldown: CFTimeInterval = 28

    var isRunning: Bool { phase != .idle }
    /// True while the user is holding the car — snow mouse should yield.
    var isHeld: Bool { phase == .held }

    func consumeEdgeExit() -> OutboundSnowplow? {
        let exit = pendingEdgeExit
        pendingEdgeExit = nil
        return exit
    }

    func dismiss() {
        stopWheels()
        panel?.orderOut(nil)
        panel = nil
        rootView = nil
        phase = .idle
        lastPlowX = .nan
        hovered = false
        wasPressed = false
        clearFully = false
        vx = 0
        vy = 0
    }

    /// Menu test — start immediately, invent a pile if needed.
    @discardableResult
    func triggerTest(simulator: SnowSimulator) -> Bool {
        cooldownUntil = 0
        guard let target = simulator.preparePlowTestDrift(minPeak: 13) ?? simulator.findPlowTarget(minPeak: 4) else {
            return false
        }
        return start(on: target, simulator: simulator, forced: true)
    }

    /// Peer threw the snowplow onto this desktop — fly in from the entry edge.
    @discardableResult
    func spawnInbound(_ inbound: InboundSnowplow, simulator: SnowSimulator) -> Bool {
        cooldownUntil = 0
        let target = simulator.findDockLedge()
            ?? simulator.preparePlowTestDrift(minPeak: 8)
            ?? simulator.findPlowTarget(minPeak: 1)
        guard let target else { return false }

        dismiss()

        let ledge = target.ledge
        let carSize = displaySize(for: ledge)
        let bounds = worldBounds()
        let h = max(1, bounds.maxY - bounds.minY)

        surfaceID = target.id
        ledgeY = CGFloat(ledge.y)
        ledgeMinX = CGFloat(ledge.x)
        ledgeMaxX = CGFloat(ledge.x + ledge.width)
        finishX = ledgeMinX - carSize.width * 1.05
        speed = max(70, min(150, (ledgeMaxX - finishX) / 8.0))
        clearFully = true
        lastPlowX = .nan
        hovered = false
        bobPhase = 0

        let midY = bounds.minY + CGFloat(inbound.normY) * h
        carY = midY - carSize.height * 0.45
        switch inbound.entryEdge {
        case .left:
            carX = bounds.minX - carSize.width * 0.85
        case .right:
            carX = bounds.maxX - carSize.width * 0.15
        }
        vx = CGFloat(max(-1_400, min(1_400, inbound.vx)))
        vy = CGFloat(max(-1_200, min(1_400, inbound.vy)))
        if abs(vx) < 80 {
            vx = inbound.entryEdge == .left ? 420 : -420
        }

        guard installPanel(size: carSize, alpha: 1) else { return false }
        rootView?.setWheelSpeed(speedPointsPerSecond: -vx)
        phase = .falling
        return true
    }

    /// Called each overlay tick while snow is simulating.
    func update(dt: Float, simulator: SnowSimulator) {
        let dtCg = CGFloat(max(0.001, min(dt, 0.05)))
        let mouse = NSEvent.mouseLocation
        let pressed = (NSEvent.pressedMouseButtons & (1 << 0)) != 0

        switch phase {
        case .idle:
            let now = CACurrentMediaTime()
            guard now >= cooldownUntil else { return }
            guard let target = simulator.findPlowTarget(minPeak: autoTriggerPeak) else { return }
            _ = start(on: target, simulator: simulator, forced: false)
        case .driving, .held, .falling:
            handleMouse(pressed: pressed, mouse: mouse, dt: dtCg)
            switch phase {
            case .driving:
                advanceDriving(dt: dtCg, simulator: simulator)
            case .held:
                advanceHeld(mouse: mouse)
            case .falling:
                advanceFalling(dt: dtCg, simulator: simulator)
            case .idle:
                break
            }
            presentPanel()
        }

        wasPressed = pressed
        lastMouse = mouse
    }

    private func start(on target: SnowSimulator.PlowTarget, simulator: SnowSimulator, forced: Bool) -> Bool {
        dismiss()

        let ledge = target.ledge
        let carSize = displaySize(for: ledge)
        guard screenCovering(ledge: ledge) != nil || NSScreen.main != nil else { return false }

        let pathMinX = CGFloat(ledge.x)
        let pathMaxX = CGFloat(ledge.x + ledge.width)
        let startX = pathMaxX + carSize.width * 0.08
        let endX = pathMinX - carSize.width * 1.05
        let travel = startX - endX
        guard travel > carSize.width * 0.75 else { return false }

        surfaceID = target.id
        ledgeY = CGFloat(ledge.y)
        ledgeMinX = pathMinX
        ledgeMaxX = pathMaxX
        finishX = endX
        carX = startX
        speed = max(70, min(150, travel / 8.0))
        carY = restingY(size: carSize, bob: 0)
        bobPhase = 0
        lastPlowX = .nan
        hovered = false
        clearFully = false
        vx = 0
        vy = 0
        wasPressed = false

        guard installPanel(size: carSize, alpha: 0) else { return false }
        rootView?.startWheelSpin(speedPointsPerSecond: speed)
        phase = .driving

        if let panel {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                panel.animator().alphaValue = 1
            }
            scrape(simulator: simulator, carFrame: panel.frame)
        }
        _ = forced
        return true
    }

    @discardableResult
    private func installPanel(size: NSSize, alpha: CGFloat) -> Bool {
        let view = SnowplowView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        rootView = view

        let panel = NSPanel(
            contentRect: NSRect(x: carX, y: carY, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.carWindowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = view
        panel.alphaValue = alpha
        panel.orderFrontRegardless()
        self.panel = panel
        return true
    }

    // MARK: - Mouse

    private func handleMouse(pressed: Bool, mouse: NSPoint, dt: CGFloat) {
        guard let panel else { return }
        let size = panel.frame.size
        let hit = NSRect(x: carX, y: carY, width: size.width, height: size.height)
            .insetBy(dx: -8, dy: -10)

        if phase == .driving || phase == .falling {
            let nowHovered = hit.contains(mouse) && !pressed
            if phase == .driving, nowHovered != hovered {
                hovered = nowHovered
                if hovered {
                    rootView?.stopWheelSpin()
                } else {
                    rootView?.setWheelSpeed(speedPointsPerSecond: speed)
                    lastPlowX = .nan
                }
            }
        }

        let justPressed = pressed && !wasPressed
        if justPressed, hit.contains(mouse), phase == .driving || phase == .falling || phase == .held {
            beginHold(mouse: mouse, size: size)
            return
        }

        if phase == .held {
            if pressed {
                let invDt = 1 / max(dt, 0.001)
                let mx = (mouse.x - lastMouse.x) * invDt
                let my = (mouse.y - lastMouse.y) * invDt
                // Blend recent motion for a punchy throw on release.
                flickVX = flickVX * 0.55 + mx * 0.45
                flickVY = flickVY * 0.55 + my * 0.45
            } else {
                releaseHold()
            }
        }
    }

    private func beginHold(mouse: NSPoint, size: NSSize) {
        phase = .held
        hovered = false
        grabOffset = NSPoint(x: mouse.x - carX, y: mouse.y - carY)
        flickVX = 0
        flickVY = 0
        vx = 0
        vy = 0
        rootView?.stopWheelSpin()
        // Slight lift so it feels picked up.
        carY = mouse.y - grabOffset.y
        carX = mouse.x - grabOffset.x
        _ = size
    }

    private func releaseHold() {
        vx = max(-1_400, min(1_400, flickVX))
        vy = max(-1_200, min(1_400, flickVY))
        // Soft drop if barely moved.
        if hypot(vx, vy) < 40 {
            vx *= 0.2
            vy = min(vy, -60)
        }
        phase = .falling
        lastPlowX = .nan
        let spin = max(abs(vx), 80)
        rootView?.setWheelSpeed(speedPointsPerSecond: spin)
    }

    private func advanceHeld(mouse: NSPoint) {
        carX = mouse.x - grabOffset.x
        carY = mouse.y - grabOffset.y
    }

    // MARK: - Driving / falling

    private func advanceDriving(dt: CGFloat, simulator: SnowSimulator) {
        guard panel != nil, rootView != nil else {
            dismiss()
            return
        }

        if !hovered {
            carX -= speed * dt
            bobPhase += dt * 7.5
        }

        let bob = hovered ? 0 : sin(bobPhase) * 0.7
        carY = restingY(size: panel!.frame.size, bob: bob)

        if !hovered {
            scrape(simulator: simulator, carFrame: NSRect(x: carX, y: carY, width: panel!.frame.width, height: panel!.frame.height))
        }

        if carX < finishX {
            finish()
            return
        }

        if !hovered {
            rootView?.setWheelSpeed(speedPointsPerSecond: speed)
        }
    }

    private func advanceFalling(dt: CGFloat, simulator: SnowSimulator) {
        guard let panel else {
            dismiss()
            return
        }
        let size = panel.frame.size

        vy -= 1_850 * dt
        vx *= pow(0.995, dt * 60)
        carX += vx * dt
        carY += vy * dt

        // Positive spin input = leftward roll (CCW); free-flight vx is Cocoa (+right).
        let spin = -vx
        let spinPass = abs(spin) < 60 ? (spin >= 0 ? 60 : -60) : spin
        rootView?.setWheelSpeed(speedPointsPerSecond: spinPass)

        let frame = NSRect(x: carX, y: carY, width: size.width, height: size.height)
        if tryHandoffOffscreen(frame: frame, size: size) {
            return
        }

        // Off any screen → vanish.
        if isOffscreen(frame: frame) {
            vanish()
            return
        }

        // Land on Dock → resume plowing.
        if tryLandOnDock(size: size, simulator: simulator) {
            return
        }
    }

    /// Fast throw past the left/right desktop edge → LAN peer (same idea as snowballs).
    private func tryHandoffOffscreen(frame: NSRect, size: NSSize) -> Bool {
        guard lanHandoffEnabled else { return false }
        let bounds = worldBounds()
        let midY = frame.midY
        let h = max(1, bounds.maxY - bounds.minY)
        let normY = Float(min(1, max(0, (midY - bounds.minY) / h)))

        if frame.maxX < bounds.minX - 8, vx < -90 {
            pendingEdgeExit = OutboundSnowplow(
                edge: .left,
                normY: normY,
                vx: Float(vx),
                vy: Float(vy)
            )
            vanishAfterHandoff()
            return true
        }
        if frame.minX > bounds.maxX + 8, vx > 90 {
            pendingEdgeExit = OutboundSnowplow(
                edge: .right,
                normY: normY,
                vx: Float(vx),
                vy: Float(vy)
            )
            vanishAfterHandoff()
            return true
        }
        _ = size
        return false
    }

    private func worldBounds() -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        var union = NSRect.null
        for screen in NSScreen.screens {
            union = union.isNull ? screen.frame : union.union(screen.frame)
        }
        if union.isNull {
            let f = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            return (f.minX, f.maxX, f.minY, f.maxY)
        }
        return (union.minX, union.maxX, union.minY, union.maxY)
    }

    private func tryLandOnDock(size: NSSize, simulator: SnowSimulator) -> Bool {
        // Prefer live Dock geometry; fall back to the ledge from this run.
        if let dock = simulator.findDockLedge() {
            surfaceID = dock.id
            ledgeY = CGFloat(dock.ledge.y)
            ledgeMinX = CGFloat(dock.ledge.x)
            ledgeMaxX = CGFloat(dock.ledge.x + dock.ledge.width)
        }

        let wheelBottom = carY + wheelBottomFromPanelBottom(size: size)
        let restY = restingY(size: size, bob: 0)
        let midX = carX + size.width * 0.5
        let onDockX = midX >= ledgeMinX - 20 && midX <= ledgeMaxX + 20
        let crossing = wheelBottom <= ledgeY + 6 && wheelBottom >= ledgeY - 28 && vy <= 120

        guard onDockX, crossing, carY <= restY + 10 else { return false }

        carY = restY
        carX = max(ledgeMinX - size.width * 0.2, min(ledgeMaxX + size.width * 0.05, carX))
        // User put the car back — clear the whole Dock shelf cleanly.
        // If little runway remains (near the left/"start" side), restart from the right entrance.
        finishX = ledgeMinX - size.width * 1.05
        let dockW = max(80, ledgeMaxX - ledgeMinX)
        let remaining = carX - finishX
        if remaining < dockW * 0.6 {
            carX = ledgeMaxX - size.width * 0.12
        }
        let travel = max(120, carX - finishX)
        speed = max(70, min(150, travel / 8.0))
        clearFully = true
        vx = 0
        vy = 0
        hovered = false
        lastPlowX = .nan
        bobPhase = 0
        phase = .driving
        rootView?.setWheelSpeed(speedPointsPerSecond: speed)
        return true
    }

    private func presentPanel() {
        guard let panel else { return }
        let size = panel.frame.size
        panel.setFrame(NSRect(x: carX, y: carY, width: size.width, height: size.height), display: true)
        if panel.level != Self.carWindowLevel {
            panel.level = Self.carWindowLevel
        }
        panel.orderFrontRegardless()
    }

    private func wheelBottomFromPanelBottom(size: NSSize) -> CGFloat {
        let wheelCenterFromTop = (Self.wheelCenterYArt / Self.artHeight) * size.height
        let wheelRadius = (Self.wheelDiameterArt / Self.artWidth) * size.width * 0.5
        let wheelBottomFromTop = wheelCenterFromTop + wheelRadius
        return size.height - wheelBottomFromTop
    }

    /// Sit tire bottoms on the ledge top (Dock / window chrome), with a tiny bounce.
    private func restingY(size: NSSize, bob: CGFloat) -> CGFloat {
        ledgeY - wheelBottomFromPanelBottom(size: size) + 3 + bob
    }

    private func isOffscreen(frame: NSRect) -> Bool {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return true }
        let pad: CGFloat = 40
        for screen in screens {
            let expanded = screen.frame.insetBy(dx: -frame.width - pad, dy: -frame.height - pad)
            if expanded.intersects(frame) { return false }
        }
        return true
    }

    private func scrape(simulator: SnowSimulator, carFrame: NSRect) {
        let bladeX = Float(carFrame.minX + carFrame.width * 0.10)
        let bladeWidth = Float(carFrame.width * 0.14)
        // First automatic pass leaves a thin film; after a manual re-drop — strip clean.
        let keep: Float = clearFully ? 0 : 0.2
        let floor: Float = clearFully ? 0 : 1.7
        if lastPlowX.isFinite {
            let a = min(lastPlowX, CGFloat(bladeX))
            let b = max(lastPlowX, CGFloat(bladeX))
            let steps = max(1, Int(ceil((b - a) / 10)))
            for i in 0...steps {
                let t = Float(i) / Float(max(steps, 1))
                let x = Float(a) + (Float(b) - Float(a)) * t
                _ = simulator.plowBlade(
                    surfaceID: surfaceID,
                    globalX: x,
                    bladeWidth: bladeWidth,
                    keepFraction: keep,
                    minLayer: floor
                )
            }
        } else {
            _ = simulator.plowBlade(
                surfaceID: surfaceID,
                globalX: bladeX,
                bladeWidth: bladeWidth,
                keepFraction: keep,
                minLayer: floor
            )
        }
        lastPlowX = CGFloat(bladeX)
    }

    private func finish() {
        guard let panel else {
            dismiss()
            return
        }
        stopWheels()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.dismiss()
        })
        phase = .idle
        cooldownUntil = CACurrentMediaTime() + cooldown
    }

    private func vanish() {
        stopWheels()
        panel?.orderOut(nil)
        dismiss()
        cooldownUntil = CACurrentMediaTime() + cooldown * 0.45
    }

    private func vanishAfterHandoff() {
        stopWheels()
        panel?.orderOut(nil)
        dismiss()
        // Short cooldown — a new local plow can still spawn if drifts rebuild.
        cooldownUntil = CACurrentMediaTime() + 6
    }

    private func stopWheels() {
        rootView?.stopWheelSpin()
    }

    private func displaySize(for ledge: SnowLedge) -> NSSize {
        let maxW = min(210, max(150, CGFloat(ledge.width) * 0.16))
        let aspect = Self.artWidth / Self.artHeight
        return NSSize(width: maxW, height: maxW / aspect)
    }

    private func screenCovering(ledge: SnowLedge) -> NSScreen? {
        let mid = NSPoint(x: CGFloat(ledge.x + ledge.width * 0.5), y: CGFloat(ledge.y + 8))
        return NSScreen.screens.first { NSMouseInRect(mid, $0.frame, false) }
    }
}

// MARK: - View

private final class SnowplowView: NSView {
    private let bodyLayer = CALayer()
    private let frontWheel = CALayer()
    private let rearWheel = CALayer()

    private let frontCenter = CGPoint(x: 335.0 / 1024.0, y: 290.0 / 359.0)
    private let rearCenter = CGPoint(x: 878.0 / 1024.0, y: 290.0 / 359.0)
    private let wheelDiameter: CGFloat = 145.0 / 1024.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor

        let body = Self.loadImage(named: "snowplow-car")
        let wheel = Self.loadImage(named: "snowplow-wheel")

        bodyLayer.contents = body
        bodyLayer.contentsGravity = .resize
        bodyLayer.magnificationFilter = .linear
        bodyLayer.minificationFilter = .linear

        for wheelLayer in [frontWheel, rearWheel] {
            wheelLayer.contents = wheel
            wheelLayer.contentsGravity = .resize
            wheelLayer.magnificationFilter = .linear
            wheelLayer.minificationFilter = .linear
        }

        layer?.addSublayer(frontWheel)
        layer?.addSublayer(rearWheel)
        layer?.addSublayer(bodyLayer)
        layoutSprites()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layoutSprites()
    }

    private func layoutSprites() {
        let b = bounds
        bodyLayer.frame = b
        let dia = wheelDiameter * b.width
        place(frontWheel, center: frontCenter, diameter: dia, in: b)
        place(rearWheel, center: rearCenter, diameter: dia, in: b)
    }

    private func place(_ layer: CALayer, center: CGPoint, diameter: CGFloat, in bounds: CGRect) {
        let cx = bounds.minX + center.x * bounds.width
        let cy = bounds.maxY - center.y * bounds.height
        layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.position = CGPoint(x: cx, y: cy)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    func startWheelSpin(speedPointsPerSecond: CGFloat) {
        setWheelSpeed(speedPointsPerSecond: speedPointsPerSecond)
    }

    func setWheelSpeed(speedPointsPerSecond: CGFloat) {
        let dia = max(8, wheelDiameter * bounds.width)
        let circumference = CGFloat.pi * dia
        let rps = max(0.18, abs(speedPointsPerSecond) / max(circumference, 1))
        let duration = CFTimeInterval(1.0 / rps)
        // Sign follows travel: left (negative vx / plow drive) → CCW; right → CW.
        let direction: CGFloat = speedPointsPerSecond >= 0 ? 1 : -1
        for (layer, key) in [(frontWheel, "spinF"), (rearWheel, "spinR")] {
            let current = layer.animation(forKey: key) as? CABasicAnimation
            if let current,
               abs(current.duration - duration) < 0.04,
               (current.toValue as? CGFloat) == direction * .pi * 2 {
                continue
            }
            let anim = CABasicAnimation(keyPath: "transform.rotation.z")
            anim.fromValue = 0
            anim.toValue = direction * CGFloat.pi * 2
            anim.duration = duration
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.removeAnimation(forKey: key)
            layer.add(anim, forKey: key)
        }
    }

    func stopWheelSpin() {
        frontWheel.removeAnimation(forKey: "spinF")
        rearWheel.removeAnimation(forKey: "spinR")
    }

    private static func loadImage(named name: String) -> CGImage? {
        let url =
            Bundle.main.url(forResource: name, withExtension: "png")
            ?? URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/\(name).png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
