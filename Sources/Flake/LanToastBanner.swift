import AppKit

/// Short floating status line for LAN snowball feedback.
final class LanToastBanner {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, duration: TimeInterval = 2.4) {
        DispatchQueue.main.async { [weak self] in
            self?.present(text, duration: duration)
        }
    }

    private func present(_ text: String, duration: TimeInterval) {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.drawsBackground = false
        label.sizeToFit()

        let padX: CGFloat = 22
        let padY: CGFloat = 12
        let width = min(screenFrame.width - 40, max(220, label.frame.width + padX * 2))
        let height = label.frame.height + padY * 2
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - height - 28

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        let box = NSView(frame: NSRect(origin: .zero, size: NSSize(width: width, height: height)))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.78).cgColor
        box.layer?.cornerRadius = 12

        label.frame = NSRect(
            x: padX,
            y: padY - 1,
            width: width - padX * 2,
            height: label.frame.height
        )
        box.addSubview(label)
        panel.contentView = box
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                if self?.panel === panel {
                    self?.panel = nil
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
