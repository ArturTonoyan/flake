import AppKit

/// Tiny floating labels that follow local snowmen holding a sign board.
final class SnowmanSignHUD {
    private var labels: [NSTextField] = []
    private weak var host: NSView?

    func attach(to view: NSView) {
        host = view
    }

    func sync(entries: [(x: Float, y: Float, text: String)], panel: NSPanel) {
        guard let content = panel.contentView else { return }
        while labels.count < entries.count {
            let field = NSTextField(labelWithString: "")
            field.font = .systemFont(ofSize: 11, weight: .semibold)
            field.textColor = NSColor(calibratedRed: 0.18, green: 0.12, blue: 0.06, alpha: 1)
            field.backgroundColor = NSColor(calibratedRed: 0.93, green: 0.85, blue: 0.68, alpha: 0.95)
            field.drawsBackground = true
            field.isBezeled = false
            field.isEditable = false
            field.isSelectable = false
            field.alignment = .center
            field.wantsLayer = true
            field.layer?.cornerRadius = 3
            content.addSubview(field)
            labels.append(field)
        }
        while labels.count > entries.count {
            labels.removeLast().removeFromSuperview()
        }

        for (i, entry) in entries.enumerated() {
            let field = labels[i]
            field.stringValue = " \(entry.text) "
            field.sizeToFit()
            var f = field.frame
            f.size.width = max(f.width + 6, 28)
            f.size.height = max(f.height, 16)

            let screenPoint = NSPoint(x: CGFloat(entry.x), y: CGFloat(entry.y))
            let windowPoint = panel.convertPoint(fromScreen: screenPoint)
            let local = content.convert(windowPoint, from: nil)
            // Only show on this panel's screen.
            if local.x < -40 || local.x > content.bounds.width + 40
                || local.y < -40 || local.y > content.bounds.height + 40
            {
                field.isHidden = true
                continue
            }
            field.isHidden = false
            f.origin = NSPoint(x: local.x - f.width * 0.5, y: local.y - f.height * 0.5)
            field.frame = f
        }
    }

    func clear() {
        labels.forEach { $0.removeFromSuperview() }
        labels.removeAll()
    }
}
