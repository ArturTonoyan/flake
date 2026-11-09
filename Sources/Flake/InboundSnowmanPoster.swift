import AppKit
import QuartzCore

/// Floating snowman + sign that flies in from a screen edge and stays until clicked.
final class InboundSnowmanPoster {
    private var panels: [NSPanel] = []
    private var flyTimers: [ObjectIdentifier: Timer] = [:]
    private var shatterHandlers: [ObjectIdentifier: (CGPoint) -> Void] = [:]

    /// - Parameter onShatter: called with the snowman body center in Cocoa screen coords when clicked.
    func present(
        from inbound: InboundSnowman,
        peerShortName: String,
        onShatter: @escaping (CGPoint) -> Void
    ) {
        let screen = NSScreen.screens.randomElement() ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.frame
        let size = NSSize(width: 200, height: 280)
        let margin: CGFloat = 56
        let targetX = CGFloat.random(
            in: (frame.minX + margin)...max(frame.minX + margin + 1, frame.maxX - size.width - margin)
        )
        let targetY = CGFloat.random(
            in: (frame.minY + margin)...max(frame.minY + margin + 1, frame.maxY - size.height - margin)
        )
        let targetOrigin = NSPoint(x: targetX, y: targetY)

        let startOrigin: NSPoint
        switch inbound.entryEdge {
        case .left:
            startOrigin = NSPoint(
                x: frame.minX - size.width - 40,
                y: targetOrigin.y + CGFloat.random(in: -60...60)
            )
        case .right:
            startOrigin = NSPoint(
                x: frame.maxX + 40,
                y: targetOrigin.y + CGFloat.random(in: -60...60)
            )
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: startOrigin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let id = ObjectIdentifier(panel)
        shatterHandlers[id] = onShatter

        let root = PosterView(
            signText: inbound.signText,
            fromName: peerShortName
        ) { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.shatter(panel)
        }
        root.wantsLayer = true
        panel.contentView = root
        panel.alphaValue = 0.25
        panel.orderFrontRegardless()
        panels.append(panel)

        // Manual fly-in: ease-out only — stop cleanly at the target (no bounce/jerk).
        let duration: CFTimeInterval = 0.85
        let startTime = CACurrentMediaTime()
        let start = startOrigin
        let end = targetOrigin
        flyTimers[id]?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak panel] timer in
            guard let self, let panel else {
                timer.invalidate()
                return
            }
            let u = min(1, (CACurrentMediaTime() - startTime) / duration)
            let eased = 1 - pow(1 - u, 3)
            let x = start.x + (end.x - start.x) * eased
            let y = start.y + (end.y - start.y) * eased
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            panel.alphaValue = 0.25 + 0.75 * eased

            if u >= 1 {
                timer.invalidate()
                self.flyTimers[id] = nil
                panel.setFrameOrigin(end)
                panel.alphaValue = 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flyTimers[id] = timer
    }

    func dismissAll() {
        for panel in panels {
            remove(panel, animated: false)
        }
    }

    private func shatter(_ panel: NSPanel) {
        let id = ObjectIdentifier(panel)
        let frame = panel.frame
        // Body center of the drawn snowman (base ≈ y 70 in a 280-tall, bottom-origin view).
        let center = CGPoint(x: frame.midX, y: frame.minY + 118)
        let handler = shatterHandlers[id]
        remove(panel, animated: false)
        handler?(center)
    }

    private func remove(_ panel: NSPanel, animated: Bool) {
        let id = ObjectIdentifier(panel)
        flyTimers[id]?.invalidate()
        flyTimers[id] = nil
        shatterHandlers[id] = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                panel.orderOut(nil)
                self?.panels.removeAll { $0 === panel }
            })
        } else {
            panel.orderOut(nil)
            panels.removeAll { $0 === panel }
        }
    }
}

private final class PosterView: NSView {
    private let onDismiss: () -> Void
    private let signLabel = NSTextField(labelWithString: "")
    private let fromLabel = NSTextField(labelWithString: "")

    init(signText: String, fromName: String, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        fromLabel.stringValue = "от \(fromName)"
        fromLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        fromLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        fromLabel.alignment = .center
        fromLabel.drawsBackground = false
        fromLabel.isBezeled = false
        fromLabel.isEditable = false
        fromLabel.isSelectable = false
        fromLabel.shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 4
            s.shadowOffset = NSSize(width: 0, height: -1)
            s.shadowColor = NSColor.black.withAlphaComponent(0.45)
            return s
        }()

        signLabel.stringValue = signText
        signLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        signLabel.textColor = NSColor(calibratedRed: 0.25, green: 0.15, blue: 0.08, alpha: 1)
        signLabel.alignment = .center
        signLabel.drawsBackground = false
        signLabel.isBezeled = false
        signLabel.isEditable = false
        signLabel.isSelectable = false
        signLabel.maximumNumberOfLines = 3
        signLabel.lineBreakMode = .byWordWrapping
        signLabel.cell?.wraps = true

        addSubview(fromLabel)
        addSubview(signLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        let w = bounds.width
        fromLabel.frame = NSRect(x: 10, y: bounds.height - 24, width: w - 20, height: 18)
        signLabel.frame = NSRect(x: 46, y: 36, width: w - 92, height: 44)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let w = bounds.width
        let cx = w * 0.5

        // Soft ground shadow.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - 48, y: 10, width: 96, height: 16))

        // Body — bottom → mid → head (no clipped gradients = no jagged artifacts).
        drawSnowBall(ctx, cx: cx, cy: 70, r: 36)
        drawSnowBall(ctx, cx: cx, cy: 118, r: 27)
        drawSnowBall(ctx, cx: cx, cy: 156, r: 19)

        // Stick arms.
        ctx.setStrokeColor(NSColor(calibratedRed: 0.42, green: 0.26, blue: 0.14, alpha: 1).cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.round)
        // Left arm
        ctx.move(to: CGPoint(x: cx - 22, y: 120))
        ctx.addLine(to: CGPoint(x: cx - 52, y: 138))
        ctx.strokePath()
        // Right arm → sign
        ctx.move(to: CGPoint(x: cx + 22, y: 118))
        ctx.addLine(to: CGPoint(x: cx + 48, y: 78))
        ctx.strokePath()

        // Face.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.88).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - 7, y: 160, width: 3.5, height: 3.5))
        ctx.fillEllipse(in: CGRect(x: cx + 3.5, y: 160, width: 3.5, height: 3.5))
        for i in -2...2 {
            let t = CGFloat(i) / 2
            ctx.fillEllipse(in: CGRect(x: cx + t * 7 - 1.2, y: 150 - abs(t) * 1.5, width: 2.4, height: 2.4))
        }
        // Buttons
        for dy: CGFloat in [8, -4, -16] {
            ctx.fillEllipse(in: CGRect(x: cx - 2, y: 118 + dy, width: 4, height: 4))
        }

        // Carrot nose.
        ctx.setFillColor(NSColor(calibratedRed: 1, green: 0.5, blue: 0.12, alpha: 1).cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: cx + 1, y: 157))
        ctx.addLine(to: CGPoint(x: cx + 1, y: 151))
        ctx.addLine(to: CGPoint(x: cx + 16, y: 154))
        ctx.closePath()
        ctx.fillPath()

        // Bucket hat.
        let bucket = CGRect(x: cx - 15, y: 170, width: 30, height: 20)
        ctx.setFillColor(NSColor(calibratedWhite: 0.52, alpha: 1).cgColor)
        ctx.fill(bucket)
        ctx.setFillColor(NSColor(calibratedWhite: 0.68, alpha: 1).cgColor)
        ctx.fill(CGRect(x: bucket.minX - 2, y: bucket.maxY - 3, width: bucket.width + 4, height: 5))
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.35, alpha: 0.5).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(bucket)

        // Wooden sign board.
        let board = CGRect(x: 40, y: 30, width: w - 80, height: 52)
        ctx.setFillColor(NSColor(calibratedRed: 0.62, green: 0.42, blue: 0.22, alpha: 1).cgColor)
        roundRect(ctx, board, radius: 5)
        ctx.fillPath()
        let inner = board.insetBy(dx: 4, dy: 4)
        ctx.setFillColor(NSColor(calibratedRed: 0.93, green: 0.84, blue: 0.64, alpha: 1).cgColor)
        roundRect(ctx, inner, radius: 3)
        ctx.fillPath()

        // Hint under feet.
        let hint = "нажми — разлетится" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
            .shadow: {
                let s = NSShadow()
                s.shadowBlurRadius = 3
                s.shadowOffset = .zero
                s.shadowColor = NSColor.black.withAlphaComponent(0.5)
                return s
            }()
        ]
        let hintSize = hint.size(withAttributes: attrs)
        hint.draw(at: NSPoint(x: (w - hintSize.width) * 0.5, y: 4), withAttributes: attrs)
    }

    private func drawSnowBall(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        // Solid body.
        ctx.setFillColor(NSColor(calibratedRed: 0.97, green: 0.98, blue: 1.0, alpha: 1).cgColor)
        ctx.fillEllipse(in: rect)
        // Cool shade at bottom (no clip — avoids jagged artifacts on transparent panels).
        ctx.setFillColor(NSColor(calibratedRed: 0.72, green: 0.82, blue: 0.92, alpha: 0.35).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - r * 0.78, y: cy - r * 0.85, width: r * 1.56, height: r * 1.05))
        // Highlight.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - r * 0.45, y: cy + r * 0.15, width: r * 0.7, height: r * 0.55))
        // Soft rim.
        ctx.setStrokeColor(NSColor(calibratedRed: 0.7, green: 0.8, blue: 0.9, alpha: 0.55).cgColor)
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.6, dy: 0.6))
    }

    private func roundRect(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.beginPath()
        ctx.addPath(path)
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss()
    }
}
