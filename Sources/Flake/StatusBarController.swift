import AppKit

final class StatusBarController {
    private let overlay: OverlayController
    private var item: NSStatusItem?

    init(overlay: OverlayController) {
        self.overlay = overlay
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "snowflake",
                accessibilityDescription: "Flake"
            )
            button.image?.isTemplate = true
        }
        item.menu = buildMenu()
        self.item = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let pause = NSMenuItem(
            title: overlay.isPaused ? "Продолжить снег" : "Пауза",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pause.target = self
        menu.addItem(pause)

        menu.addItem(.separator())

        let intensity = NSMenuItem(title: "Интенсивность", action: nil, keyEquivalent: "")
        let intensityMenu = NSMenu()
        for (title, value) in [("Мало", 0.35), ("Средне", 0.7), ("Много", 1.0), ("Метель", 1.4)] {
            let item = NSMenuItem(title: title, action: #selector(setIntensity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(overlay.intensity - value) < 0.01 ? .on : .off
            intensityMenu.addItem(item)
        }
        intensity.submenu = intensityMenu
        menu.addItem(intensity)

        let mouse = NSMenuItem(
            title: overlay.mouseInteractionEnabled ? "Мышь: вкл" : "Мышь: выкл",
            action: #selector(toggleMouse),
            keyEquivalent: "m"
        )
        mouse.target = self
        menu.addItem(mouse)

        menu.addItem(.separator())

        let clear = NSMenuItem(title: "Растаять всё", action: #selector(clearSnow), keyEquivalent: "r")
        clear.target = self
        menu.addItem(clear)

        let tip = NSMenuItem(
            title: "3 шара друг на друга → снеговик",
            action: nil,
            keyEquivalent: ""
        )
        tip.isEnabled = false
        menu.addItem(tip)

        let permission = NSMenuItem(
            title: "Разрешение «Запись экрана»…",
            action: #selector(openScreenRecording),
            keyEquivalent: ""
        )
        permission.target = self
        menu.addItem(permission)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func refreshMenu() {
        item?.menu = buildMenu()
    }

    @objc private func togglePause() {
        overlay.isPaused.toggle()
        refreshMenu()
    }

    @objc private func setIntensity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        overlay.intensity = value
        refreshMenu()
    }

    @objc private func toggleMouse() {
        overlay.mouseInteractionEnabled.toggle()
        refreshMenu()
    }

    @objc private func clearSnow() {
        overlay.clearSnow()
    }

    @objc private func openScreenRecording() {
        // Needed on newer macOS so window frames are visible to the snow physics.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
