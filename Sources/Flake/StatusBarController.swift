import AppKit

final class StatusBarController {
    private let overlay: OverlayController
    private var item: NSStatusItem?

    init(overlay: OverlayController) {
        self.overlay = overlay
        overlay.onLanPeersChanged = { [weak self] in
            self?.refreshMenu()
        }
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
        menu.addItem(buildLanMenuItem())

        menu.addItem(.separator())

        let clear = NSMenuItem(title: "Растаять всё", action: #selector(clearSnow), keyEquivalent: "r")
        clear.target = self
        menu.addItem(clear)

        let tip = NSMenuItem(
            title: "3 шара → снеговик; ПКМ → табличка",
            action: nil,
            keyEquivalent: ""
        )
        tip.isEnabled = false
        menu.addItem(tip)

        let lanTip = NSMenuItem(
            title: "Кинь снежок/снеговика за край → другу",
            action: nil,
            keyEquivalent: ""
        )
        lanTip.isEnabled = false
        menu.addItem(lanTip)

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

    private func buildLanMenuItem() -> NSMenuItem {
        let peers = overlay.lanPeers.filter(\.isReachable)
        let count = peers.count
        let title: String
        if !overlay.lanSnowballsEnabled {
            title = "Снежки по Wi‑Fi: выкл"
        } else if count == 0 {
            title = "Снежки по Wi‑Fi: ищем…"
        } else {
            title = "Снежки по Wi‑Fi: \(count)"
        }

        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let toggle = NSMenuItem(
            title: overlay.lanSnowballsEnabled ? "Выключить" : "Включить",
            action: #selector(toggleLan),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = overlay.lanSnowballsEnabled ? .on : .off
        sub.addItem(toggle)

        if overlay.lanSnowballsEnabled {
            sub.addItem(.separator())

            let header = NSMenuItem(
                title: count == 0 ? "Никого рядом в сети" : "Сейчас активны:",
                action: nil,
                keyEquivalent: ""
            )
            header.isEnabled = false
            sub.addItem(header)

            let route = overlay.throwRoute
            let leftLabel = route.leftName.map { "← влево: \(OverlayController.shortPeerName($0))" }
                ?? "← влево: никого"
            let rightLabel = route.rightName.map { "вправо: \(OverlayController.shortPeerName($0)) →" }
                ?? "вправо: никого →"
            let leftItem = NSMenuItem(title: leftLabel, action: nil, keyEquivalent: "")
            leftItem.isEnabled = false
            sub.addItem(leftItem)
            let rightItem = NSMenuItem(title: rightLabel, action: nil, keyEquivalent: "")
            rightItem.isEnabled = false
            sub.addItem(rightItem)
            sub.addItem(.separator())

            for peer in peers {
                let sideTag: String
                switch peer.side {
                case .left: sideTag = "слева"
                case .right: sideTag = "справа"
                case .auto: sideTag = "авто"
                }
                let short = OverlayController.shortPeerName(peer.name)
                let peerItem = NSMenuItem(title: "\(short) · \(sideTag)", action: nil, keyEquivalent: "")
                let peerMenu = NSMenu()

                let status = NSMenuItem(title: "Подключён", action: nil, keyEquivalent: "")
                status.isEnabled = false
                status.state = .on
                peerMenu.addItem(status)
                peerMenu.addItem(.separator())

                let sideHeader = NSMenuItem(title: "Где он относительно тебя", action: nil, keyEquivalent: "")
                sideHeader.isEnabled = false
                peerMenu.addItem(sideHeader)

                for (label, side) in [
                    ("Авто", PeerRelativeSide.auto),
                    ("Слева от меня", PeerRelativeSide.left),
                    ("Справа от меня", PeerRelativeSide.right),
                ] as [(String, PeerRelativeSide)] {
                    let item = NSMenuItem(title: label, action: #selector(setPeerSide(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = PeerSideChoice(peerID: peer.id, side: side)
                    item.state = peer.side == side ? .on : .off
                    peerMenu.addItem(item)
                }

                peerItem.submenu = peerMenu
                sub.addItem(peerItem)
            }

            let hint = NSMenuItem(
                title: "Одна сторона = один человек",
                action: nil,
                keyEquivalent: ""
            )
            hint.isEnabled = false
            sub.addItem(hint)
        }

        sub.addItem(.separator())
        let preview = NSMenuItem(
            title: "Тест обычного прилёта",
            action: #selector(previewLanHit),
            keyEquivalent: ""
        )
        preview.target = self
        sub.addItem(preview)

        let previewGiant = NSMenuItem(
            title: "Тест огромного (весь экран)",
            action: #selector(previewGiantLanHit),
            keyEquivalent: "t"
        )
        previewGiant.target = self
        sub.addItem(previewGiant)

        let previewSnowman = NSMenuItem(
            title: "Тест снеговика с табличкой",
            action: #selector(previewSnowmanHit),
            keyEquivalent: ""
        )
        previewSnowman.target = self
        sub.addItem(previewSnowman)

        root.submenu = sub
        return root
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

    @objc private func toggleLan() {
        overlay.lanSnowballsEnabled.toggle()
        refreshMenu()
    }

    @objc private func previewLanHit() {
        overlay.previewLanSnowballHit(giant: false)
    }

    @objc private func previewGiantLanHit() {
        overlay.previewLanSnowballHit(giant: true)
    }

    @objc private func previewSnowmanHit() {
        overlay.previewLanSnowmanHit()
    }

    @objc private func setPeerSide(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? PeerSideChoice else { return }
        overlay.setPeerSide(choice.side, peerID: choice.peerID)
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

/// NSMenuItem.representedObject helper for peer side picks.
private final class PeerSideChoice: NSObject {
    let peerID: UInt64
    let side: PeerRelativeSide

    init(peerID: UInt64, side: PeerRelativeSide) {
        self.peerID = peerID
        self.side = side
    }
}
