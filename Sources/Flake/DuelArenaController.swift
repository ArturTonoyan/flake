import AppKit
import QuartzCore

/// Snow duel window: vs bot or LAN friend, with score / rematch / lobby.
final class DuelArenaController {
    static let shared = DuelArenaController()

    private var window: NSWindow?
    private var arena: DuelArenaView?
    private weak var network: PeerSnowNetwork?
    private var peerProvider: (() -> [PeerInfo])?

    private init() {}

    func configure(network: PeerSnowNetwork, peers: @escaping () -> [PeerInfo]) {
        self.network = network
        self.peerProvider = peers
        network.duelEventHandler = { [weak self] event in
            self?.handleDuelEvent(event)
        }
    }

    func openLobby() {
        ensureWindow()
        arena?.showLobby(peers: peerProvider?() ?? [])
        present()
    }

    func openPractice() {
        ensureWindow()
        arena?.startBotMatch(resetScore: false)
        present()
    }

    func challengePeer(id: UInt64, name: String) {
        ensureWindow()
        network?.setEnabled(true)
        arena?.beginChallenge(peerID: id, name: name, network: network)
        present()
    }

    func close() {
        arena?.leaveMatch()
        arena?.stop()
        arena = nil
        window?.orderOut(nil)
        window = nil
    }

    private func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        arena?.focus()
    }

    private func ensureWindow() {
        if let window, window.isVisible, arena != nil {
            arena?.network = network
            arena?.peerProvider = peerProvider
            return
        }

        let size = NSSize(width: 820, height: 520)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 700)
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Снежный бой"
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedRed: 0.72, green: 0.84, blue: 0.94, alpha: 1)
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = ArenaWindowDelegate.shared

        let arena = DuelArenaView(frame: NSRect(origin: .zero, size: size))
        arena.network = network
        arena.peerProvider = peerProvider
        window.contentView = arena

        self.window = window
        self.arena = arena
        arena.start()
    }

    private func handleDuelEvent(_ event: DuelNetEvent) {
        ensureWindow()
        present()
        arena?.handleDuelEvent(event)
    }
}

private final class ArenaWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = ArenaWindowDelegate()

    func windowWillClose(_ notification: Notification) {
        DuelArenaController.shared.close()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let view = (notification.object as? NSWindow)?.contentView as? DuelArenaView {
            view.focus()
        }
    }
}

// MARK: - Arena (y=0 at bottom)

private final class DuelArenaView: NSView {
    weak var network: PeerSnowNetwork?
    var peerProvider: (() -> [PeerInfo])?

    private var displayLink: CVDisplayLink?
    private var lastTime: CFTimeInterval = 0

    private var player = Fighter(isPlayer: true)
    private var enemy = Fighter(isPlayer: false)
    private var balls: [Shot] = []
    private var walls: [SnowWall] = []
    private var drifts: [SnowDrift] = []
    private var flakes: [FallingFlake] = []
    private var bursts: [Burst] = []
    private var pickups: [ArenaPickup] = []
    private var hazards: [HazardBall] = []

    private var keys = Set<UInt16>()
    private var mouse = CGPoint.zero
    private var mouseDown = false

    private var gameOver = false
    private var won = false
    private var status = ""
    private var statusAge: CFTimeInterval = 99
    private var matchTime: CFTimeInterval = 0
    private var snowAcc: CFTimeInterval = 0
    private var introAge: CFTimeInterval = 0

    /// Falling snowball storm: idle → warning (red) → raining → cooldown.
    private enum StormPhase {
        case idle
        case warning
        case raining
    }
    private var stormPhase: StormPhase = .idle
    private var stormTimer: CFTimeInterval = 10
    private var stormSpawnAcc: CFTimeInterval = 0
    private var pickupSpawnTimer: CFTimeInterval = 7

    private var bot = BotBrain()

    // MARK: Match / score / LAN
    private enum MatchPhase {
        case lobby
        case waitingOpponent
        case incomingChallenge
        case playing
        case roundOver
        case rematchWait
    }
    private enum MatchMode {
        case bot
        case lan
    }
    private var phase: MatchPhase = .lobby
    private var mode: MatchMode = .bot
    private var myWins = 0
    private var theirWins = 0
    private var opponentName = "Бот"
    private var opponentPeerID: UInt64?
    private var moveSyncAcc: CFTimeInterval = 0
    private var lobbyPeers: [PeerInfo] = []
    private var challengeFromID: UInt64?
    private var challengeFromName = ""

    /// Floor line in view coords (y grows upward).
    private var groundY: CGFloat { 78 }
    private let maxHP = 6

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func focus() {
        window?.makeFirstResponder(self)
    }

    func start() {
        showLobby(peers: peerProvider?() ?? [])
        startDisplayLink()
    }

    func stop() {
        stopDisplayLink()
    }

    func showLobby(peers: [PeerInfo]) {
        lobbyPeers = peers.filter(\.isReachable)
        phase = .lobby
        mode = .bot
        gameOver = false
        setStatus("Выбери режим · счёт серии сохраняется до сброса")
        needsDisplay = true
    }

    func startBotMatch(resetScore: Bool) {
        mode = .bot
        opponentName = "Бот"
        opponentPeerID = nil
        if resetScore {
            myWins = 0
            theirWins = 0
        }
        phase = .playing
        resetRound(keepScore: true)
    }

    func beginChallenge(peerID: UInt64, name: String, network: PeerSnowNetwork?) {
        self.network = network ?? self.network
        mode = .lan
        opponentPeerID = peerID
        opponentName = OverlayController.shortPeerName(name)
        phase = .waitingOpponent
        gameOver = false
        setStatus("Ждём ответ от \(opponentName)…")
        sendDuel(.challenge)
        needsDisplay = true
    }

    func leaveMatch() {
        if mode == .lan, let id = opponentPeerID {
            network?.sendDuel(toPeerID: id, command: .leave, scoreA: UInt16(myWins), scoreB: UInt16(theirWins))
        }
        opponentPeerID = nil
        phase = .lobby
    }

    func handleDuelEvent(_ event: DuelNetEvent) {
        switch event.command {
        case .challenge:
            challengeFromID = event.fromPeerID
            challengeFromName = OverlayController.shortPeerName(event.fromName)
            phase = .incomingChallenge
            mode = .lan
            setStatus("\(challengeFromName) вызывает на бой!")
            needsDisplay = true
        case .accept:
            guard event.fromPeerID == opponentPeerID || opponentPeerID == nil else { return }
            opponentPeerID = event.fromPeerID
            opponentName = OverlayController.shortPeerName(event.fromName)
            mode = .lan
            // Align score from host if they already had series — take max view
            myWins = Int(event.scoreB)
            theirWins = Int(event.scoreA)
            phase = .playing
            resetRound(keepScore: true)
            setStatus("Бой с \(opponentName) начался!")
        case .decline:
            if event.fromPeerID == opponentPeerID {
                phase = .lobby
                setStatus("\(opponentName) отклонил вызов")
            }
        case .throwShot:
            guard mode == .lan, phase == .playing else { return }
            applyRemoteThrow(event.values)
        case .hpSync:
            guard mode == .lan, phase == .playing else { return }
            // values: [theirHP as me from their view → our enemy HP, their local HP → ignore or set player]
            if event.values.count >= 2 {
                enemy.hp = min(maxHP, max(0, Int(event.values[0])))
                // Don't overwrite local player HP from peer (desync protection) unless much lower
            }
        case .roundEnd:
            guard mode == .lan else { return }
            // Prefer higher series totals if both sides end the round.
            theirWins = max(theirWins, Int(event.scoreA))
            myWins = max(myWins, Int(event.scoreB))
            let senderWon = (event.values.first ?? 0) > 0.5
            if phase == .playing {
                gameOver = true
                won = !senderWon
                phase = .roundOver
            }
            setStatus(won ? "Раунд за тобой! \(myWins):\(theirWins)" : "Раунд за \(opponentName) · \(myWins):\(theirWins)")
        case .rematchAsk:
            if mode == .lan, phase == .roundOver || phase == .rematchWait {
                phase = .incomingChallenge
                challengeFromID = event.fromPeerID
                challengeFromName = OverlayController.shortPeerName(event.fromName)
                setStatus("\(challengeFromName) хочет ещё раз")
            }
        case .rematchOk:
            guard mode == .lan else { return }
            phase = .playing
            resetRound(keepScore: true)
            setStatus("Новый раунд!")
        case .leave:
            if event.fromPeerID == opponentPeerID {
                phase = .lobby
                setStatus("\(opponentName) вышел из боя")
                opponentPeerID = nil
                gameOver = false
            }
        case .moveSync:
            guard mode == .lan, phase == .playing, event.values.count >= 1 else { return }
            let xn = CGFloat(event.values[0])
            enemy.x = (1 - xn) * bounds.width
            enemy.x = min(max(enemy.x, 48), bounds.width - 48)
            if event.values.count >= 2 {
                enemy.ducking = event.values[1] > 0.5
            }
        }
        needsDisplay = true
    }

    private func sendDuel(_ command: DuelNetCommand, values: [Float] = []) {
        guard let id = opponentPeerID ?? challengeFromID else { return }
        network?.sendDuel(
            toPeerID: id,
            command: command,
            values: values,
            scoreA: UInt16(myWins),
            scoreB: UInt16(theirWins)
        )
    }

    private func applyRemoteThrow(_ values: [Float]) {
        guard values.count >= 5 else { return }
        // Peer coords are mirrored: they are always "left" locally.
        let xNorm = CGFloat(values[0])
        let yNorm = CGFloat(values[1])
        let vx = -CGFloat(values[2]) // mirror
        let vy = CGFloat(values[3])
        let radius = CGFloat(values[4])
        let damage = values.count > 5 ? max(1, Int(values[5])) : 1
        let isBomb = values.count > 6 && values[6] > 0.5
        let x = (1 - xNorm) * bounds.width
        let y = yNorm * bounds.height
        balls.append(
            Shot(
                x: x, y: y, vx: vx, vy: vy,
                r: radius, damage: damage,
                fromPlayer: false, age: 0, isBomb: isBomb
            )
        )
        enemy.armSwing = 1
        enemy.facing = -1
    }

    private func resetRound(keepScore: Bool) {
        let w = max(bounds.width, 820)
        player = Fighter(isPlayer: true)
        enemy = Fighter(isPlayer: false)
        player.hp = maxHP
        enemy.hp = maxHP
        player.x = w * 0.20
        enemy.x = w * 0.80
        player.facing = 1
        enemy.facing = -1
        player.ammo = 50
        enemy.ammo = 50
        balls.removeAll()
        walls.removeAll()
        bursts.removeAll()
        flakes.removeAll()
        pickups.removeAll()
        hazards.removeAll()
        drifts = [
            SnowDrift(x: w * 0.12, snow: 70),
            SnowDrift(x: w * 0.28, snow: 55),
            SnowDrift(x: w * 0.50, snow: 40),
            SnowDrift(x: w * 0.72, snow: 55),
            SnowDrift(x: w * 0.88, snow: 70),
        ]
        keys.removeAll()
        mouseDown = false
        gameOver = false
        won = false
        matchTime = 0
        snowAcc = 0
        introAge = 0
        moveSyncAcc = 0
        stormPhase = .idle
        stormTimer = Double.random(in: 9...14)
        stormSpawnAcc = 0
        pickupSpawnTimer = Double.random(in: 5...9)
        bot = BotBrain()
        if !keepScore {
            myWins = 0
            theirWins = 0
        }
        phase = .playing
        setStatus(mode == .lan
            ? "Бой с \(opponentName) · \(myWins):\(theirWins)"
            : "Подбирай бонусы · красное небо = снегопад")
        needsDisplay = true
    }

    // MARK: Loop

    private func startDisplayLink() {
        stopDisplayLink()
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        displayLink = link
        lastTime = CACurrentMediaTime()
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, ctx -> CVReturn in
            let view = Unmanaged<DuelArenaView>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { view.tick() }
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
        if let displayLink { CVDisplayLinkStop(displayLink) }
        displayLink = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var dt = now - lastTime
        lastTime = now
        dt = min(max(dt, 1.0 / 120), 1.0 / 25)
        matchTime += dt
        statusAge += dt
        introAge += dt

        if phase == .lobby || phase == .waitingOpponent || phase == .incomingChallenge {
            lobbyPeers = peerProvider?().filter(\.isReachable) ?? lobbyPeers
            needsDisplay = true
            return
        }

        spawnSnow(dt: dt)
        updateFlakes(dt: dt)

        if phase == .playing, !gameOver {
            updateStorm(dt: dt)
            updatePickups(dt: dt)
            updatePlayer(dt: dt)
            if mode == .bot {
                updateBot(dt: dt)
                updateWindup(for: &enemy, dt: dt)
            }
            integrate(&player, dt: dt)
            integrate(&enemy, dt: dt)
            tickShield(&player, dt: dt)
            tickShield(&enemy, dt: dt)
            updateShots(dt: dt)
            updateHazards(dt: dt)
            collectPickups(for: &player)
            collectPickups(for: &enemy)
            for i in walls.indices { walls[i].life -= dt }
            walls.removeAll { $0.hp <= 0 || $0.life <= 0 }

            if mode == .lan {
                moveSyncAcc += dt
                if moveSyncAcc >= 0.12 {
                    moveSyncAcc = 0
                    let xn = Float(player.x / max(1, bounds.width))
                    sendDuel(.moveSync, values: [xn, player.ducking ? 1 : 0])
                }
            }

            if player.hp <= 0 {
                finishRound(localWon: false)
            } else if enemy.hp <= 0 {
                finishRound(localWon: true)
            }
        }

        bursts = bursts.compactMap { b in
            var n = b
            n.life -= dt
            n.x += n.vx * CGFloat(dt)
            n.y += n.vy * CGFloat(dt)
            n.vy -= 220 * CGFloat(dt)
            return n.life > 0 ? n : nil
        }

        needsDisplay = true
    }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        keys.insert(event.keyCode)
        if phase != .playing {
            if event.keyCode == 49 || event.keyCode == 36 {
                handlePrimaryAction()
            }
            return
        }
        if gameOver {
            if event.keyCode == 49 || event.keyCode == 36 { handlePrimaryAction() }
            return
        }
        // Space — shield
        if event.keyCode == 49 {
            activateShield(for: &player)
            return
        }
        // W (13) or ↑ (126) — wall
        if event.keyCode == 13 || event.keyCode == 126 {
            tryPlantWall(for: &player)
        }
    }

    private func handlePrimaryAction() {
        switch phase {
        case .lobby:
            startBotMatch(resetScore: false)
        case .roundOver:
            requestRematch()
        case .incomingChallenge:
            acceptIncoming()
        default:
            break
        }
    }

    private func requestRematch() {
        if mode == .bot {
            resetRound(keepScore: true)
            return
        }
        phase = .rematchWait
        setStatus("Ждём согласие \(opponentName) на ещё один раунд…")
        sendDuel(.rematchAsk)
        needsDisplay = true
    }

    private func acceptIncoming() {
        guard let id = challengeFromID else { return }
        let isRematch = status.contains("ещё")
        opponentPeerID = id
        opponentName = challengeFromName
        mode = .lan
        challengeFromID = nil
        if isRematch {
            sendDuel(.rematchOk)
        } else {
            sendDuel(.accept)
        }
        phase = .playing
        resetRound(keepScore: true)
        setStatus("Бой с \(opponentName)!")
    }

    private func declineIncoming() {
        if let id = challengeFromID {
            network?.sendDuel(toPeerID: id, command: .decline, scoreA: UInt16(myWins), scoreB: UInt16(theirWins))
        }
        challengeFromID = nil
        phase = .lobby
        setStatus("Вызов отклонён")
        needsDisplay = true
    }

    override func keyUp(with event: NSEvent) {
        keys.remove(event.keyCode)
    }

    override func mouseDown(with event: NSEvent) {
        focus()
        mouse = convert(event.locationInWindow, from: nil)

        if phase == .lobby {
            handleLobbyClick(mouse)
            return
        }
        if phase == .incomingChallenge {
            if acceptButtonRect().contains(mouse) { acceptIncoming(); return }
            if declineButtonRect().contains(mouse) { declineIncoming(); return }
            return
        }
        if phase == .waitingOpponent || phase == .rematchWait {
            if menuButtonRect().contains(mouse) {
                leaveMatch()
                showLobby(peers: peerProvider?() ?? [])
            }
            return
        }
        if phase == .roundOver || gameOver {
            let layout = roundOverLayout()
            if layout.againButton.contains(mouse) { requestRematch(); return }
            if layout.menuButton.contains(mouse) {
                leaveMatch()
                showLobby(peers: peerProvider?() ?? [])
                return
            }
            if layout.resetButton.contains(mouse) {
                myWins = 0
                theirWins = 0
                setStatus("Счёт сброшен · \(myWins):\(theirWins)")
                needsDisplay = true
            }
            return
        }

        mouseDown = true
        beginSling(for: &player, at: mouse)
    }

    private func handleLobbyClick(_ p: CGPoint) {
        let layout = lobbyLayout()
        if layout.botButton.contains(p) {
            startBotMatch(resetScore: false)
            return
        }
        if layout.resetButton.contains(p) {
            myWins = 0
            theirWins = 0
            setStatus("Счёт серии сброшен")
            needsDisplay = true
            return
        }
        for (i, peer) in lobbyPeers.prefix(4).enumerated() {
            if layout.peerButton(index: i).contains(p) {
                beginChallenge(peerID: peer.id, name: peer.name, network: network)
                return
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        if player.slinging {
            updateSlingPull(for: &player, to: mouse)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        guard mouseDown else { return }
        mouseDown = false
        if !gameOver, player.slinging {
            updateSlingPull(for: &player, to: mouse)
            releaseSling(for: &player)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    // MARK: Player

    private let maxSlingPull: CGFloat = 130
    private let slingShotCost: CGFloat = 10
    private let wallCost: CGFloat = 6
    private let maxAmmo: CGFloat = 70
    private let gravity: CGFloat = 560
    /// Minimum time between finished throws (anti-spam).
    private let throwCooldown: CFTimeInterval = 1.35
    /// At most this many of your snowballs in the air at once.
    private let maxPlayerShotsInFlight = 1
    private let maxShotSpeed: CGFloat = 700
    private let minShotSpeed: CGFloat = 240

    private func updatePlayer(dt: CFTimeInterval) {
        let left = keys.contains(0) || keys.contains(123)
        let right = keys.contains(2) || keys.contains(124)
        let duck = keys.contains(1) || keys.contains(125)

        player.ducking = duck && player.stun <= 0 && !player.slinging
        if player.stun > 0 || player.ducking || player.slinging {
            player.move = 0
        } else {
            player.move = (right ? 1 : 0) - (left ? 1 : 0)
        }

        if player.slinging {
            // Face opposite to pull (toward shot direction)
            let pull = CGPoint(x: player.slingPull.x - player.slingAnchor.x, y: player.slingPull.y - player.slingAnchor.y)
            if abs(pull.x) > 6 { player.facing = pull.x < 0 ? 1 : -1 }
        } else if player.move != 0 {
            player.facing = player.move > 0 ? 1 : -1
        }
    }

    private func beginSling(for f: inout Fighter, at point: CGPoint) {
        guard f.stun <= 0, !f.ducking, !f.slinging else { return }

        if f.throwCD > 0 {
            if f.isPlayer {
                setStatus(String(format: "Подожди %.1f сек", f.throwCD))
            }
            return
        }

        if f.isPlayer {
            let inFlight = balls.filter(\.fromPlayer).count
            if inFlight >= maxPlayerShotsInFlight {
                setStatus("Дождись, пока снежок долетит")
                return
            }
        }

        // Must click near the snowman to grab
        let grabR: CGFloat = f.isPlayer ? 90 : 999
        if hypot(point.x - f.x, point.y - (groundY + 40)) > grabR {
            if f.isPlayer { setStatus("Кликни по своему снеговику и тяни назад") }
            return
        }

        if f.ammo < slingShotCost {
            if let i = nearestDrift(to: f.x, maxDist: 85), drifts[i].snow >= 6 {
                let take = min(22, drifts[i].snow)
                drifts[i].snow -= take
                f.ammo += take
            }
        }
        guard f.ammo >= slingShotCost else {
            if f.isPlayer { setStatus("Мало снега — подойди к сугробу") }
            return
        }

        f.ammo -= slingShotCost
        f.heldMass = slingShotCost
        f.slinging = true
        f.slingAnchor = throwOrigin(f)
        f.slingPull = f.slingAnchor
        f.pack = 0
        if f.isPlayer { setStatus("Тяни назад и отпусти") }
    }

    private func updateSlingPull(for f: inout Fighter, to point: CGPoint) {
        guard f.slinging else { return }
        let ax = f.slingAnchor.x
        let ay = f.slingAnchor.y
        var dx = point.x - ax
        var dy = point.y - ay
        let len = hypot(dx, dy)
        if len > maxSlingPull {
            dx = dx / len * maxSlingPull
            dy = dy / len * maxSlingPull
        }
        f.slingPull = CGPoint(x: ax + dx, y: ay + dy)
        f.pack = min(1, hypot(dx, dy) / maxSlingPull)
    }

    private func releaseSling(for f: inout Fighter) {
        guard f.slinging else { return }
        f.slinging = false

        let dx = f.slingPull.x - f.slingAnchor.x
        let dy = f.slingPull.y - f.slingAnchor.y
        let pull = hypot(dx, dy)

        guard f.stun <= 0, pull > 18 else {
            // Cancel — refund most snow
            f.ammo += f.heldMass * 0.7
            f.heldMass = 0
            f.pack = 0
            if f.isPlayer, pull <= 18 { setStatus("Слишком слабо — тяни сильнее") }
            return
        }

        // Angry Birds: fly opposite to the pull
        let power = pull / maxSlingPull
        let speed = minShotSpeed + power * (maxShotSpeed - minShotSpeed)
        let vx = -dx / pull * speed
        let vy = -dy / pull * speed
        var radius = 9 + power * 8
        var damage = 1 + (power > 0.55 ? 1 : 0) + (power > 0.85 ? 1 : 0)
        var isBomb = false
        if f.nextBomb {
            isBomb = true
            damage += 2
            radius += 10
            f.nextBomb = false
        }
        if f.nextMega {
            damage += 1
            radius += 5
            f.nextMega = false
        }

        balls.append(
            Shot(
                x: f.slingAnchor.x,
                y: f.slingAnchor.y,
                vx: vx,
                vy: vy,
                r: radius,
                damage: damage,
                fromPlayer: f.isPlayer,
                age: 0,
                isBomb: isBomb
            )
        )
        f.heldMass = 0
        f.pack = 0
        f.throwCD = throwCooldown
        f.windupRemaining = 0
        f.armSwing = 1.0 // visible follow-through
        if f.isPlayer {
            if mode == .lan {
                let xNorm = Float(f.slingAnchor.x / max(1, bounds.width))
                let yNorm = Float(f.slingAnchor.y / max(1, bounds.height))
                sendDuel(.throwShot, values: [
                    xNorm, yNorm, Float(vx), Float(vy), Float(radius),
                    Float(damage), isBomb ? 1 : 0,
                ])
            }
            if isBomb {
                setStatus("Бомба полетела!")
            } else if power > 0.8 {
                setStatus("Мощный бросок!")
            } else {
                setStatus("Бросок!")
            }
        }
    }

    private func finishRound(localWon: Bool) {
        guard phase == .playing else { return }
        gameOver = true
        won = localWon
        if localWon {
            myWins += 1
        } else {
            theirWins += 1
        }
        phase = .roundOver
        if mode == .lan {
            sendDuel(.roundEnd, values: [localWon ? 1 : 0])
        }
        setStatus(localWon
            ? "Победа раунда! Счёт \(myWins):\(theirWins)"
            : "Поражение раунда. Счёт \(myWins):\(theirWins)")
    }

    /// Bot starts a visible wind-up, then releases after `windupRemaining`.
    private func botStartWindup(for f: inout Fighter) {
        refillAmmoIfNeeded(for: &f)
        guard beginSlingSilent(for: &f) else { return }

        let origin = f.slingAnchor
        let leadT = abs(player.x - origin.x) / 420
        let target = CGPoint(
            x: player.x + CGFloat(player.move) * 90 * leadT,
            y: groundY + (player.ducking ? 36 : 68)
        )

        let pullTarget: CGPoint
        if let vel = ballisticVelocity(from: origin, to: target) {
            let speed = hypot(vel.x, vel.y)
            let pullLen = min(
                maxSlingPull,
                max(maxSlingPull * 0.6, (speed - minShotSpeed) / max(1, maxShotSpeed - minShotSpeed) * maxSlingPull)
            )
            let inv = max(1, speed)
            pullTarget = CGPoint(
                x: origin.x - vel.x / inv * pullLen,
                y: origin.y - vel.y / inv * pullLen
            )
        } else {
            let away = CGPoint(x: origin.x - target.x, y: origin.y - target.y - 80)
            let len = max(1, hypot(away.x, away.y))
            let pullLen = maxSlingPull * 0.95
            pullTarget = CGPoint(
                x: origin.x + away.x / len * pullLen,
                y: origin.y + away.y / len * pullLen
            )
        }

        f.windupTarget = pullTarget
        f.windupDuration = Double.random(in: 0.6...0.9)
        f.windupRemaining = f.windupDuration
        f.slingPull = origin // start from rest, animate pull-back
        f.pack = 0
        // Face the shot direction early so the wind-up reads clearly
        let shotDir = origin.x - pullTarget.x
        if abs(shotDir) > 4 { f.facing = shotDir >= 0 ? 1 : -1 }
    }

    private func updateWindup(for f: inout Fighter, dt: CFTimeInterval) {
        guard f.slinging, f.windupRemaining > 0 else { return }
        f.windupRemaining -= dt

        let total = max(0.01, f.windupDuration)
        let progress = min(1, max(0, 1 - f.windupRemaining / total))
        let ease = progress * progress * (3 - 2 * progress) // smoothstep
        f.slingPull = CGPoint(
            x: f.slingAnchor.x + (f.windupTarget.x - f.slingAnchor.x) * CGFloat(ease),
            y: f.slingAnchor.y + (f.windupTarget.y - f.slingAnchor.y) * CGFloat(ease)
        )
        let pull = hypot(f.slingPull.x - f.slingAnchor.x, f.slingPull.y - f.slingAnchor.y)
        f.pack = min(1, pull / maxSlingPull)

        if f.windupRemaining <= 0 {
            f.windupRemaining = 0
            f.slingPull = f.windupTarget
            f.pack = min(1, hypot(f.slingPull.x - f.slingAnchor.x, f.slingPull.y - f.slingAnchor.y) / maxSlingPull)
            releaseSling(for: &f)
        }
    }

    /// Required launch velocity under constant gravity to hit `to` (y-up).
    private func ballisticVelocity(from: CGPoint, to: CGPoint) -> CGPoint? {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let g = gravity
        let sx: CGFloat = dx >= 0 ? 1 : -1
        let adx = abs(dx)
        guard adx > 8 else { return nil }

        // Try several launch angles (radians from horizontal); prefer loft for range.
        let angles: [CGFloat] = [
            .pi / 5, .pi / 4, 0.35 * .pi, 0.3 * .pi, 0.22 * .pi, 0.4 * .pi, 0.18 * .pi,
        ]

        var best: (CGPoint, CGFloat)?
        for theta in angles {
            let cosT = cos(theta)
            let sinT = sin(theta)
            guard abs(cosT) > 0.05 else { continue }
            let denom = 2 * cosT * cosT * (adx * tan(theta) - dy)
            guard denom > 1 else { continue }
            let v2 = g * adx * adx / denom
            guard v2 > 0 else { continue }
            let v = sqrt(v2)
            guard v >= minShotSpeed * 0.85, v <= maxShotSpeed * 1.05 else { continue }
            let clamped = min(maxShotSpeed, max(minShotSpeed, v))
            let vel = CGPoint(x: sx * clamped * cosT, y: clamped * sinT)
            let score = abs(v - (minShotSpeed + maxShotSpeed) * 0.55)
            if best == nil || score < best!.1 {
                best = (vel, score)
            }
        }
        return best?.0
    }

    private func refillAmmoIfNeeded(for f: inout Fighter) {
        guard f.ammo < slingShotCost + wallCost else { return }
        // Scoop nearest drift on this half of the arena
        let preferLeft = f.x < bounds.width * 0.5
        var bestIdx: Int?
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for (i, d) in drifts.enumerated() where d.snow >= 4 {
            let onSide = preferLeft ? d.x <= bounds.width * 0.55 : d.x >= bounds.width * 0.45
            guard onSide else { continue }
            let dist = abs(d.x - f.x)
            if dist < bestDist {
                bestDist = dist
                bestIdx = i
            }
        }
        if let i = bestIdx {
            let take = min(28, drifts[i].snow)
            drifts[i].snow -= take
            f.ammo = min(maxAmmo, f.ammo + take)
        } else {
            f.ammo = min(maxAmmo, f.ammo + 18) // emergency top-up so bot never softlocks
        }
    }

    private func beginSlingSilent(for f: inout Fighter) -> Bool {
        guard f.stun <= 0, !f.ducking, !f.slinging, f.throwCD <= 0 else { return false }
        if !f.isPlayer {
            let inFlight = balls.filter { !$0.fromPlayer }.count
            if inFlight >= 1 { return false }
        }
        if f.ammo < slingShotCost {
            if let i = nearestDrift(to: f.x, maxDist: 85), drifts[i].snow >= 6 {
                let take = min(22, drifts[i].snow)
                drifts[i].snow -= take
                f.ammo += take
            }
        }
        guard f.ammo >= slingShotCost else { return false }
        f.ammo -= slingShotCost
        f.heldMass = slingShotCost
        f.slinging = true
        f.slingAnchor = throwOrigin(f)
        f.slingPull = f.slingAnchor
        return true
    }

    private func activateShield(for f: inout Fighter) {
        guard !gameOver, f.stun <= 0 else { return }
        guard f.shieldTime <= 0 else { return }
        guard f.shieldCD <= 0 else {
            if f.isPlayer { setStatus("Щит ещё перезаряжается") }
            return
        }
        f.shieldTime = 1.0
        f.shieldHP = 1
        f.shieldCD = 2.4
        if f.isPlayer { setStatus("Щит! 1 сек или 1 снежок") }
    }

    private func tickShield(_ f: inout Fighter, dt: CFTimeInterval) {
        if f.shieldTime > 0 {
            f.shieldTime -= dt
            if f.shieldTime <= 0 {
                f.shieldTime = 0
                f.shieldHP = 0
            }
        }
        f.shieldCD = max(0, f.shieldCD - dt)
    }

    private func tryPlantWall(for f: inout Fighter) {
        guard !gameOver, f.stun <= 0, !f.ducking, !f.slinging else { return }
        if f.wallCD > 0 {
            if f.isPlayer { setStatus(String(format: "Вал через %.1f сек", f.wallCD)) }
            return
        }
        // Auto-scoop a bit if almost enough
        if f.ammo < wallCost {
            refillAmmoIfNeeded(for: &f)
        }
        if f.ammo >= wallCost {
            f.ammo -= wallCost
        } else {
            if f.isPlayer { setStatus("Мало снега для вала (нужно \(Int(wallCost)))") }
            return
        }
        walls.append(
            SnowWall(
                x: f.x + CGFloat(f.facing) * 48,
                hp: 3,
                fromPlayer: f.isPlayer,
                life: 10
            )
        )
        f.wallCD = 2.0
        if f.isPlayer { setStatus("Снежный вал!") }
    }

    private func integrate(_ f: inout Fighter, dt: CFTimeInterval) {
        f.stun = max(0, f.stun - dt)
        f.invuln = max(0, f.invuln - dt)
        f.throwCD = max(0, f.throwCD - dt)
        f.wallCD = max(0, f.wallCD - dt)
        if f.armSwing > 0 {
            f.armSwing = max(0, f.armSwing - CGFloat(dt) * 2.8)
        }
        // Slow passive snow regen so wall/throw aren't starved
        if !f.slinging, f.ammo < maxAmmo {
            f.ammo = min(maxAmmo, f.ammo + 6 * CGFloat(dt))
        }
        let speed: CGFloat = f.slinging ? 0 : 195
        f.x += CGFloat(f.move) * speed * CGFloat(dt)
        f.x = min(max(f.x, 48), bounds.width - 48)
        f.y = groundY
        if f.slinging {
            f.slingAnchor = throwOrigin(f)
        }
    }

    private func throwOrigin(_ f: Fighter) -> CGPoint {
        let lift: CGFloat = f.ducking ? 36 : 62
        return CGPoint(x: f.x + CGFloat(f.facing) * 14, y: groundY + lift)
    }

    private func bodyRect(_ f: Fighter) -> NSRect {
        let h: CGFloat = f.ducking ? 36 : 64
        let w: CGFloat = 42
        return NSRect(x: f.x - w / 2, y: groundY, width: w, height: h)
    }

    private func headRect(_ f: Fighter) -> NSRect {
        if f.ducking {
            return NSRect(x: f.x - 13, y: groundY + 28, width: 26, height: 22)
        }
        return NSRect(x: f.x - 15, y: groundY + 60, width: 30, height: 28)
    }

    // MARK: Shots

    private func updateShots(dt: CFTimeInterval) {
        var next: [Shot] = []
        for var s in balls {
            s.vy -= gravity * CGFloat(dt)
            s.x += s.vx * CGFloat(dt)
            s.y += s.vy * CGFloat(dt)
            s.age += dt

            if s.y < -40 || s.x < -80 || s.x > bounds.width + 80 || s.age > 5 {
                continue
            }

            if s.y - s.r <= groundY, s.vy < 0 {
                deposit(at: s.x, amount: 5 + s.r * 0.35)
                spawnBurst(x: s.x, y: groundY + 8, count: 9)
                continue
            }

            var blocked = false
            for i in walls.indices where walls[i].hp > 0 {
                if circleHits(cx: s.x, cy: s.y, r: s.r, rect: wallRect(walls[i])) {
                    walls[i].hp -= 1
                    spawnBurst(x: s.x, y: s.y, count: 10)
                    blocked = true
                    break
                }
            }
            if blocked { continue }

            if s.fromPlayer {
                if enemy.invuln <= 0, enemy.hp > 0, hit(shot: s, on: &enemy) {
                    if s.isBomb { bombSplash(at: CGPoint(x: s.x, y: s.y), fromPlayer: true) }
                    continue
                }
            } else {
                if player.invuln <= 0, player.hp > 0, hit(shot: s, on: &player) {
                    if s.isBomb { bombSplash(at: CGPoint(x: s.x, y: s.y), fromPlayer: false) }
                    continue
                }
            }
            next.append(s)
        }
        balls = next
    }

    private func bombSplash(at point: CGPoint, fromPlayer: Bool) {
        spawnBurst(x: point.x, y: point.y, count: 28)
        // Extra chip damage if opponent is still nearby after the direct hit
        if fromPlayer {
            if hypot(enemy.x - point.x, (groundY + 40) - point.y) < 70, enemy.invuln <= 0 {
                enemy.hp = max(0, enemy.hp - 1)
                enemy.stun = max(enemy.stun, 0.25)
            }
        } else {
            if hypot(player.x - point.x, (groundY + 40) - point.y) < 70, player.invuln <= 0 {
                player.hp = max(0, player.hp - 1)
                player.stun = max(player.stun, 0.25)
            }
        }
        // Destroy nearby walls
        for i in walls.indices {
            if abs(walls[i].x - point.x) < 55 {
                walls[i].hp = 0
            }
        }
    }

    private func hit(shot s: Shot, on target: inout Fighter) -> Bool {
        let shieldOn = target.shieldTime > 0 && target.shieldHP > 0
        if shieldOn {
            let sc = shieldCenter(target)
            if hypot(s.x - sc.x, s.y - sc.y) <= shieldRadius(target) + s.r {
                target.shieldHP = 0
                target.shieldTime = 0
                spawnBurst(x: s.x, y: s.y, count: 18)
                if target.isPlayer {
                    setStatus("Щит разбит!")
                } else {
                    setStatus("Щит бота разбит!")
                }
                return true
            }
        }

        let headHit = circleHits(cx: s.x, cy: s.y, r: s.r, rect: headRect(target))
        let bodyHit = circleHits(cx: s.x, cy: s.y, r: s.r, rect: bodyRect(target))
        guard headHit || bodyHit else { return false }

        var dmg = s.damage
        if headHit { dmg += 1 }
        if target.ducking { dmg = max(1, dmg - 1) }

        target.hp = max(0, target.hp - dmg)
        target.stun = 0.32 + Double(dmg) * 0.07
        target.invuln = 0.5
        if target.slinging {
            target.ammo += target.heldMass * 0.5
            target.slinging = false
            target.heldMass = 0
            target.pack = 0
        }
        let dir: CGFloat = s.fromPlayer ? 1 : -1
        target.x += dir * (16 + CGFloat(dmg) * 5)
        spawnBurst(x: s.x, y: s.y, count: 15)
        if target.isPlayer {
            setStatus(headHit ? "Хедшот по тебе (−\(dmg))" : "По тебе (−\(dmg))")
        } else {
            setStatus(headHit ? "В голову! −\(dmg)" : "Попадание −\(dmg)")
        }
        return true
    }

    private func shieldCenter(_ f: Fighter) -> CGPoint {
        CGPoint(x: f.x, y: groundY + (f.ducking ? 28 : 48))
    }

    private func shieldRadius(_ f: Fighter) -> CGFloat {
        f.ducking ? 36 : 48
    }

    private func circleHits(cx: CGFloat, cy: CGFloat, r: CGFloat, rect: NSRect) -> Bool {
        let nx = min(max(cx, rect.minX), rect.maxX)
        let ny = min(max(cy, rect.minY), rect.maxY)
        let dx = cx - nx
        let dy = cy - ny
        return dx * dx + dy * dy <= r * r
    }

    private func wallRect(_ w: SnowWall) -> NSRect {
        NSRect(x: w.x - 16, y: groundY, width: 32, height: 58)
    }

    // MARK: Snow

    private func spawnSnow(dt: CFTimeInterval) {
        snowAcc += dt
        let rate = 16.0
        while snowAcc > 1 / rate {
            snowAcc -= 1 / rate
            flakes.append(
                FallingFlake(
                    x: CGFloat.random(in: 0...max(1, bounds.width)),
                    y: bounds.height + 6,
                    vy: CGFloat.random(in: -95 ... -45),
                    r: CGFloat.random(in: 1.4...2.6)
                )
            )
        }
    }

    private func updateFlakes(dt: CFTimeInterval) {
        var next: [FallingFlake] = []
        for var f in flakes {
            f.y += f.vy * CGFloat(dt)
            f.x += sin((bounds.height - f.y) * 0.04) * 14 * CGFloat(dt)
            if f.y <= groundY {
                deposit(at: f.x, amount: 0.65)
            } else {
                next.append(f)
            }
        }
        flakes = next
        drifts.removeAll { $0.snow < 0.4 }
        if drifts.count > 12 {
            drifts.sort { $0.snow > $1.snow }
            drifts = Array(drifts.prefix(12))
        }
    }

    private func deposit(at x: CGFloat, amount: CGFloat) {
        if let i = nearestDrift(to: x, maxDist: 40) {
            drifts[i].snow = min(85, drifts[i].snow + amount)
            drifts[i].x = (drifts[i].x * 3 + x) / 4
        } else {
            drifts.append(SnowDrift(x: x, snow: amount))
        }
    }

    private func nearestDrift(to x: CGFloat, maxDist: CGFloat) -> Int? {
        var best: (Int, CGFloat)?
        for (i, d) in drifts.enumerated() {
            let dist = abs(d.x - x)
            if dist <= maxDist, best == nil || dist < best!.1 {
                best = (i, dist)
            }
        }
        return best?.0
    }

    private func spawnBurst(x: CGFloat, y: CGFloat, count: Int) {
        for _ in 0..<count {
            let a = CGFloat.random(in: 0...(2 * .pi))
            let sp = CGFloat.random(in: 50...170)
            bursts.append(
                Burst(
                    x: x, y: y,
                    vx: cos(a) * sp, vy: sin(a) * sp + 40,
                    r: CGFloat.random(in: 1.6...4.2),
                    life: Double.random(in: 0.2...0.5)
                )
            )
        }
    }

    // MARK: Storm + pickups

    private func updateStorm(dt: CFTimeInterval) {
        stormTimer -= dt
        switch stormPhase {
        case .idle:
            if stormTimer <= 0 {
                stormPhase = .warning
                stormTimer = 2.6
                setStatus("Осторожно! Скоро град снежков с неба!")
            }
        case .warning:
            if stormTimer <= 0 {
                stormPhase = .raining
                stormTimer = 4.2
                stormSpawnAcc = 0
                setStatus("СНЕГОПАД! Уворачивайся!")
            }
        case .raining:
            stormSpawnAcc += dt
            while stormSpawnAcc >= 0.28 {
                stormSpawnAcc -= 0.28
                spawnHazardBall()
            }
            if stormTimer <= 0 {
                stormPhase = .idle
                stormTimer = Double.random(in: 14...22)
                setStatus("Снегопад закончился")
            }
        }
    }

    private func spawnHazardBall() {
        let x = CGFloat.random(in: 40...(max(41, bounds.width - 40)))
        hazards.append(
            HazardBall(
                x: x,
                y: bounds.height + 20,
                vy: CGFloat.random(in: -380 ... -260),
                vx: CGFloat.random(in: -40...40),
                r: CGFloat.random(in: 11...16),
                damage: 1
            )
        )
    }

    private func updateHazards(dt: CFTimeInterval) {
        var next: [HazardBall] = []
        for var h in hazards {
            h.vy -= gravity * 0.35 * CGFloat(dt)
            h.x += h.vx * CGFloat(dt)
            h.y += h.vy * CGFloat(dt)

            if h.y - h.r <= groundY {
                spawnBurst(x: h.x, y: groundY + 8, count: 8)
                deposit(at: h.x, amount: 4)
                continue
            }

            var hitSomeone = false
            if player.invuln <= 0, player.hp > 0,
               hazardHits(h, fighter: player)
            {
                applyHazardHit(to: &player, at: h)
                hitSomeone = true
            }
            if !hitSomeone, enemy.invuln <= 0, enemy.hp > 0,
               hazardHits(h, fighter: enemy)
            {
                applyHazardHit(to: &enemy, at: h)
                hitSomeone = true
            }
            // Blocked by walls
            if !hitSomeone {
                for i in walls.indices where walls[i].hp > 0 {
                    if circleHits(cx: h.x, cy: h.y, r: h.r, rect: wallRect(walls[i])) {
                        walls[i].hp -= 1
                        spawnBurst(x: h.x, y: h.y, count: 8)
                        hitSomeone = true
                        break
                    }
                }
            }
            if !hitSomeone {
                next.append(h)
            }
        }
        hazards = next
    }

    private func hazardHits(_ h: HazardBall, fighter f: Fighter) -> Bool {
        if f.shieldTime > 0, f.shieldHP > 0 {
            let sc = shieldCenter(f)
            return hypot(h.x - sc.x, h.y - sc.y) < shieldRadius(f) + h.r
        }
        return circleHits(cx: h.x, cy: h.y, r: h.r, rect: bodyRect(f))
            || circleHits(cx: h.x, cy: h.y, r: h.r, rect: headRect(f))
    }

    private func applyHazardHit(to f: inout Fighter, at h: HazardBall) {
        if f.shieldTime > 0, f.shieldHP > 0 {
            f.shieldHP = 0
            f.shieldTime = 0
            spawnBurst(x: h.x, y: h.y, count: 14)
            if f.isPlayer { setStatus("Щит спас от града!") }
            return
        }
        f.hp = max(0, f.hp - h.damage)
        f.stun = 0.28
        f.invuln = 0.55
        if f.slinging {
            f.ammo += f.heldMass * 0.4
            f.slinging = false
            f.heldMass = 0
        }
        spawnBurst(x: h.x, y: h.y, count: 12)
        if f.isPlayer {
            setStatus("С неба (−\(h.damage))!")
        }
    }

    private func updatePickups(dt: CFTimeInterval) {
        pickupSpawnTimer -= dt
        if pickupSpawnTimer <= 0, pickups.count < 2, matchTime > 4 {
            spawnPickup()
            pickupSpawnTimer = Double.random(in: 10...18)
        }

        for i in pickups.indices {
            pickups[i].bob += dt
            pickups[i].life -= dt
        }
        pickups.removeAll { $0.life <= 0 }
    }

    private func spawnPickup() {
        let kinds: [PickupKind] = [.shield, .bomb, .mega, .heal, .ammo]
        let kind = kinds.randomElement()!
        let x = CGFloat.random(in: 80...(max(81, bounds.width - 80)))
        // Prefer mid-field so both can contest
        let midBias = bounds.width * 0.5 + CGFloat.random(in: -120...120)
        let px = min(max(80, midBias), bounds.width - 80)
        pickups.append(
            ArenaPickup(
                kind: kind,
                x: Bool.random() ? px : x,
                y: groundY + 22,
                bob: 0,
                life: 14
            )
        )
        setStatus("Бонус на поле: \(kind.title)")
    }

    private func collectPickups(for f: inout Fighter) {
        guard f.stun <= 0 else { return }
        pickups.removeAll { p in
            guard abs(p.x - f.x) < 34, abs(p.y - (groundY + 24)) < 40 else { return false }
            applyPickup(p.kind, to: &f)
            spawnBurst(x: p.x, y: p.y, count: 10)
            return true
        }
    }

    private func applyPickup(_ kind: PickupKind, to f: inout Fighter) {
        switch kind {
        case .shield:
            f.shieldTime = 1.0
            f.shieldHP = 1
            f.shieldCD = max(0, f.shieldCD - 0.5)
            if f.isPlayer { setStatus("Подобрал щит!") }
        case .bomb:
            f.nextBomb = true
            if f.isPlayer { setStatus("Бомба! Следующий бросок — взрывной") }
        case .mega:
            f.nextMega = true
            if f.isPlayer { setStatus("Мега-снежок на следующий бросок") }
        case .heal:
            f.hp = min(maxHP, f.hp + 1)
            if f.isPlayer { setStatus("Лечение +1 HP") }
        case .ammo:
            f.ammo = min(maxAmmo, f.ammo + 25)
            if f.isPlayer { setStatus("Запас снега +25") }
        }
    }

    // MARK: Bot

    private func updateBot(dt: CFTimeInterval) {
        bot.think -= dt
        bot.throwCD = max(0, bot.throwCD - dt)
        bot.wallCD = max(0, bot.wallCD - dt)

        let threats = balls.filter { $0.fromPlayer }
        var danger: CGFloat?
        for s in threats {
            let t: CGFloat = 0.28
            let px = s.x + s.vx * t
            let py = s.y + s.vy * t - 0.5 * gravity * t * t
            if abs(px - enemy.x) < 55, py < groundY + 100, py > groundY - 10 {
                danger = px
                break
            }
        }

        if let dx = danger {
            // Prefer shield over duck when a shot is incoming
            if enemy.shieldCD <= 0, enemy.shieldTime <= 0, abs(dx - enemy.x) < 70 {
                activateShield(for: &enemy)
            }
            enemy.ducking = enemy.shieldTime <= 0 && abs(dx - enemy.x) < 30 && enemy.stun <= 0
            enemy.move = enemy.ducking || enemy.shieldTime > 0 ? 0 : (dx > enemy.x ? -1 : 1)
            if enemy.slinging {
                enemy.ammo += enemy.heldMass * 0.5
                enemy.slinging = false
                enemy.heldMass = 0
                enemy.pack = 0
                enemy.windupRemaining = 0
            }
        } else {
            enemy.ducking = false
            // Seek nearest pickup if close enough / valuable
            if let target = pickups.min(by: { abs($0.x - enemy.x) < abs($1.x - enemy.x) }),
               abs(target.x - enemy.x) < 220,
               !enemy.slinging,
               (enemy.hp < maxHP || !enemy.nextBomb || target.kind == .shield)
            {
                let err = target.x - enemy.x
                enemy.move = abs(err) > 12 ? (err > 0 ? 1 : -1) : 0
            } else {
                let ideal = bounds.width * 0.78
                let err = ideal - enemy.x
                if abs(err) > 30, !enemy.slinging {
                    enemy.move = err > 0 ? 1 : -1
                } else if !enemy.slinging {
                    if bot.think <= 0 { bot.strafe = Bool.random() ? 1 : -1 }
                    enemy.move = bot.strafe
                } else {
                    enemy.move = 0
                }
            }
        }

        // During storm, prefer shield / duck / move from center hazards
        if stormPhase == .warning || stormPhase == .raining {
            if enemy.shieldCD <= 0, enemy.shieldTime <= 0 {
                activateShield(for: &enemy)
            }
            if stormPhase == .raining, !enemy.slinging {
                // Sidestep under gaps — bias toward nearer wall or edge
                if bot.think <= 0 {
                    bot.strafe = enemy.x > bounds.width * 0.5 ? 1 : -1
                }
            }
        }

        enemy.facing = player.x >= enemy.x ? 1 : -1

        // Keep ammo topped up; move toward a drift if empty
        if enemy.ammo < slingShotCost {
            refillAmmoIfNeeded(for: &enemy)
            if enemy.ammo < slingShotCost, let i = nearestDrift(to: enemy.x, maxDist: 400) {
                let err = drifts[i].x - enemy.x
                if abs(err) > 20 { enemy.move = err > 0 ? 1 : -1 }
            }
        }

        if (enemy.hp <= 4 || Bool.random() && bot.think <= 0),
           bot.wallCD <= 0,
           enemy.wallCD <= 0,
           enemy.ammo >= wallCost
        {
            tryPlantWall(for: &enemy)
            bot.wallCD = 4
        }

        if enemy.stun <= 0, danger == nil, bot.throwCD <= 0, !enemy.slinging, enemy.throwCD <= 0 {
            botStartWindup(for: &enemy)
            if enemy.slinging {
                bot.throwCD = Double.random(in: 1.1...1.7)
            }
        }
        if bot.think <= 0 { bot.think = Double.random(in: 0.35...0.75) }
    }

    private func setStatus(_ t: String) {
        status = t
        statusAge = 0
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let h = bounds.height

        drawSky(width: w, height: h)
        drawHills(width: w)
        drawGround(width: w, height: h)
        drawDrifts()
        drawWalls()
        drawPickups()

        for f in flakes {
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: f.x - f.r, y: f.y - f.r, width: f.r * 2, height: f.r * 2)).fill()
        }

        drawFighter(enemy)
        drawFighter(player)

        for s in balls { drawShot(s) }
        for h in hazards { drawHazard(h) }
        for b in bursts {
            let a = CGFloat(max(0, min(1, b.life * 2.2)))
            NSColor.white.withAlphaComponent(a).setFill()
            NSBezierPath(ovalIn: NSRect(x: b.x - b.r, y: b.y - b.r, width: b.r * 2, height: b.r * 2)).fill()
        }

        if player.slinging {
            drawSling(for: player)
        }
        if enemy.slinging {
            drawSling(for: enemy)
        }

        drawStormOverlay(width: w, height: h)
        if phase == .playing || phase == .roundOver || phase == .rematchWait {
            drawHUD(width: w, height: h)
        }
        if phase == .playing, introAge < 5 {
            drawControlsHint(width: w, height: h, alpha: introAge < 3.5 ? 1 : max(0, 1 - (introAge - 3.5) / 1.5))
        }
        switch phase {
        case .lobby:
            drawLobby(width: w, height: h)
        case .waitingOpponent, .rematchWait:
            drawWaitingOverlay(width: w, height: h)
        case .incomingChallenge:
            drawChallengeOverlay(width: w, height: h)
        case .roundOver:
            drawGameOver(width: w, height: h)
        case .playing:
            break
        }
    }

    private func drawStormOverlay(width w: CGFloat, height h: CGFloat) {
        switch stormPhase {
        case .idle:
            break
        case .warning:
            // Soft pulsing red — careful, not neon
            let pulse = 0.5 + 0.5 * sin(CGFloat(CACurrentMediaTime() * 4.5))
            let alpha = 0.06 + 0.07 * pulse
            NSColor(calibratedRed: 0.75, green: 0.18, blue: 0.18, alpha: alpha).setFill()
            bounds.fill()
            // Vignette edges
            NSColor(calibratedRed: 0.65, green: 0.1, blue: 0.1, alpha: 0.10 + 0.06 * pulse).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: h - 70, width: w, height: 70)).fill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: 50)).fill()

            let title = "⚠ Скоро снегопад"
            let tw = textWidth(title, size: 16, bold: true)
            drawText(
                title,
                at: CGPoint(x: (w - tw) / 2, y: h - 88),
                size: 16,
                bold: true,
                color: NSColor(calibratedRed: 0.65, green: 0.15, blue: 0.15, alpha: 0.75 + 0.2 * pulse)
            )
        case .raining:
            NSColor(calibratedRed: 0.55, green: 0.12, blue: 0.14, alpha: 0.10).setFill()
            bounds.fill()
            let title = "СНЕГОПАД"
            let tw = textWidth(title, size: 15, bold: true)
            drawText(
                title,
                at: CGPoint(x: (w - tw) / 2, y: h - 86),
                size: 15,
                bold: true,
                color: NSColor(calibratedRed: 0.7, green: 0.2, blue: 0.2, alpha: 0.85)
            )
        }
    }

    private func drawPickups() {
        for p in pickups {
            let bobY = sin(p.bob * 3.2) * 4
            let cy = p.y + bobY
            let r: CGFloat = 16
            // Soft glow
            p.kind.color.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - r - 4, y: cy - r - 4, width: (r + 4) * 2, height: (r + 4) * 2)).fill()
            NSColor.white.setFill()
            p.kind.color.setStroke()
            let ball = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: cy - r, width: r * 2, height: r * 2))
            ball.fill()
            ball.lineWidth = 2.2
            ball.stroke()

            let label = p.kind.short
            let lw = textWidth(label, size: 11, bold: true)
            drawText(label, at: CGPoint(x: p.x - lw / 2, y: cy - 6), size: 11, bold: true, color: p.kind.color)

            let nameW = textWidth(p.kind.title, size: 10, bold: false)
            drawText(
                p.kind.title,
                at: CGPoint(x: p.x - nameW / 2, y: cy + r + 4),
                size: 10,
                bold: false,
                color: NSColor(calibratedWhite: 0.3, alpha: 0.9)
            )
        }
    }

    private func drawHazard(_ h: HazardBall) {
        NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.28, alpha: 0.35).setStroke()
        NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
        let p = NSBezierPath(ovalIn: NSRect(x: h.x - h.r, y: h.y - h.r, width: h.r * 2, height: h.r * 2))
        p.fill()
        p.lineWidth = 2
        p.stroke()
        // Danger mark
        NSColor(calibratedRed: 0.8, green: 0.2, blue: 0.22, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: h.x - 3, y: h.y - 3, width: 6, height: 6)).fill()
    }

    private func drawSky(width w: CGFloat, height h: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            NSColor(calibratedRed: 0.70, green: 0.84, blue: 0.95, alpha: 1).setFill()
            bounds.fill()
            return
        }
        let colors = [
            NSColor(calibratedRed: 0.55, green: 0.74, blue: 0.92, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.82, green: 0.91, blue: 0.98, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.93, green: 0.96, blue: 0.99, alpha: 1).cgColor,
        ]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 0.55, 1]
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: h),
                end: CGPoint(x: 0, y: groundY),
                options: []
            )
        }
    }

    private func drawHills(width w: CGFloat) {
        // Soft distant snow hills
        NSColor(calibratedRed: 0.78, green: 0.88, blue: 0.95, alpha: 0.7).setFill()
        let back = NSBezierPath()
        back.move(to: CGPoint(x: 0, y: groundY + 40))
        back.curve(
            to: CGPoint(x: w * 0.35, y: groundY + 70),
            controlPoint1: CGPoint(x: w * 0.1, y: groundY + 30),
            controlPoint2: CGPoint(x: w * 0.22, y: groundY + 85)
        )
        back.curve(
            to: CGPoint(x: w * 0.7, y: groundY + 55),
            controlPoint1: CGPoint(x: w * 0.5, y: groundY + 50),
            controlPoint2: CGPoint(x: w * 0.58, y: groundY + 75)
        )
        back.curve(
            to: CGPoint(x: w, y: groundY + 48),
            controlPoint1: CGPoint(x: w * 0.85, y: groundY + 40),
            controlPoint2: CGPoint(x: w * 0.92, y: groundY + 60)
        )
        back.line(to: CGPoint(x: w, y: groundY))
        back.line(to: CGPoint(x: 0, y: groundY))
        back.close()
        back.fill()
    }

    private func drawGround(width w: CGFloat, height h: CGFloat) {
        // Snow floor
        NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: groundY + 2)).fill()

        // Soft bank edge
        NSColor(calibratedRed: 0.86, green: 0.91, blue: 0.96, alpha: 1).setFill()
        let edge = NSBezierPath()
        edge.move(to: CGPoint(x: 0, y: groundY + 2))
        var x: CGFloat = 0
        while x <= w {
            let bump = sin(x * 0.04) * 3 + sin(x * 0.11) * 2
            edge.line(to: CGPoint(x: x, y: groundY + 4 + bump))
            x += 8
        }
        edge.line(to: CGPoint(x: w, y: groundY))
        edge.line(to: CGPoint(x: 0, y: groundY))
        edge.close()
        edge.fill()

        // Shadow strip
        NSColor(calibratedWhite: 0.75, alpha: 0.18).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: groundY - 6, width: w, height: 6)).fill()
    }

    private func drawDrifts() {
        for d in drifts {
            let height = 10 + d.snow * 0.42
            let width = 36 + d.snow * 0.55
            let rect = NSRect(x: d.x - width / 2, y: groundY - 4, width: width, height: height)

            // Shadow
            NSColor(calibratedWhite: 0.7, alpha: 0.2).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 4, y: groundY - 6, width: width - 8, height: 10)).fill()

            NSColor.white.setFill()
            NSColor(calibratedRed: 0.72, green: 0.80, blue: 0.88, alpha: 0.9).setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.fill()
            path.lineWidth = 1.2
            path.stroke()

            // Highlight
            NSColor.white.withAlphaComponent(0.7).setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: d.x - width * 0.22,
                    y: groundY + height * 0.35,
                    width: width * 0.28,
                    height: height * 0.28
                )
            ).fill()
        }
    }

    private func drawWalls() {
        for wall in walls {
            let r = wallRect(wall)
            // Shadow
            NSColor(calibratedWhite: 0.6, alpha: 0.18).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX, y: groundY - 6, width: r.width, height: 10)).fill()

            NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
            NSColor(calibratedRed: 0.65, green: 0.74, blue: 0.84, alpha: 1).setStroke()
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            path.fill()
            path.lineWidth = 1.5
            path.stroke()

            for i in 0..<wall.hp {
                NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.85, alpha: 0.85).setFill()
                NSBezierPath(
                    ovalIn: NSRect(x: r.midX - 10 + CGFloat(i) * 10, y: r.maxY + 4, width: 6, height: 6)
                ).fill()
            }
        }
    }

    private func drawFighter(_ f: Fighter) {
        let accent = f.isPlayer
            ? NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.82, alpha: 1)
            : NSColor(calibratedRed: 0.82, green: 0.22, blue: 0.26, alpha: 1)

        let flash = f.invuln > 0 && Int(f.invuln * 18) % 2 == 0
        let fill = flash ? NSColor.white.withAlphaComponent(0.45) : NSColor.white
        let stroke = NSColor(calibratedRed: 0.55, green: 0.64, blue: 0.74, alpha: 1)

        // Lean back while winding up / forward on follow-through
        let lean: CGFloat
        if f.slinging {
            lean = -CGFloat(f.facing) * (6 + f.pack * 10)
        } else if f.armSwing > 0 {
            lean = CGFloat(f.facing) * 14 * f.armSwing
        } else {
            lean = 0
        }
        let cx = f.x + lean

        // Ground shadow
        NSColor(calibratedWhite: 0.55, alpha: 0.22).setFill()
        let shadowW: CGFloat = f.ducking ? 44 : 52
        NSBezierPath(
            ovalIn: NSRect(x: f.x - shadowW / 2, y: groundY - 8, width: shadowW, height: 12)
        ).fill()

        fill.setFill()
        stroke.setStroke()

        let shoulderY = groundY + 24 * 1.35 + 19
        let leftShoulder = CGPoint(x: cx - 17, y: shoulderY)
        let rightShoulder = CGPoint(x: cx + 17, y: shoulderY)

        if f.ducking {
            let body = bodyRect(f).offsetBy(dx: lean, dy: 0)
            let path = NSBezierPath(ovalIn: body)
            path.fill(); path.lineWidth = 1.6; path.stroke()
        } else {
            let baseR: CGFloat = 24
            let midR: CGFloat = 19
            let headR: CGFloat = 14
            let base = NSRect(x: cx - baseR, y: groundY, width: baseR * 2, height: baseR * 2)
            let mid = NSRect(x: cx - midR, y: groundY + baseR * 1.35, width: midR * 2, height: midR * 2)
            let head = NSRect(x: cx - headR, y: groundY + baseR * 1.35 + midR * 1.45, width: headR * 2, height: headR * 2)
            for rect in [base, mid, head] {
                let p = NSBezierPath(ovalIn: rect)
                p.fill(); p.lineWidth = 1.6; p.stroke()
            }

            accent.withAlphaComponent(0.75).setFill()
            for i in 0..<3 {
                let by = groundY + baseR * 1.35 + 8 + CGFloat(i) * 10
                NSBezierPath(ovalIn: NSRect(x: cx - 2.5, y: by, width: 5, height: 5)).fill()
            }

            let headC = CGPoint(x: head.midX, y: head.midY)
            let dir = CGFloat(f.facing)
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: headC.x - 5 + dir * 2, y: headC.y + 1, width: 3.5, height: 3.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: headC.x + 3 + dir * 2, y: headC.y + 1, width: 3.5, height: 3.5)).fill()

            accent.setFill()
            let nose = NSBezierPath()
            nose.move(to: CGPoint(x: headC.x + dir * 1, y: headC.y - 1))
            nose.line(to: CGPoint(x: headC.x + dir * 15, y: headC.y - 3))
            nose.line(to: CGPoint(x: headC.x + dir * 1, y: headC.y - 6))
            nose.close()
            nose.fill()
        }

        // Arms — wind-up / throw pose
        drawSnowmanArms(f, accent: accent, stroke: stroke, leftShoulder: leftShoulder, rightShoulder: rightShoulder, lean: lean)

        if f.ducking {
            let head = headRect(f).offsetBy(dx: lean, dy: 0)
            let p = NSBezierPath(ovalIn: head)
            fill.setFill(); stroke.setStroke()
            p.fill(); p.lineWidth = 1.6; p.stroke()
            let dir = CGFloat(f.facing)
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: head.midX - 5 + dir, y: head.midY + 1, width: 3, height: 3)).fill()
            NSBezierPath(ovalIn: NSRect(x: head.midX + 2 + dir, y: head.midY + 1, width: 3, height: 3)).fill()
        }

        // Telegraph: bot is winding up
        if f.slinging, f.windupRemaining > 0 {
            let bang = "!"
            let bw = textWidth(bang, size: 22, bold: true)
            let pulse = 0.7 + 0.3 * sin(CGFloat(CACurrentMediaTime() * 10))
            drawText(
                bang,
                at: CGPoint(x: cx + CGFloat(f.facing) * 28 - bw / 2, y: groundY + 100),
                size: 22,
                bold: true,
                color: accent.withAlphaComponent(pulse)
            )
        }

        // Shield bubble
        if f.shieldTime > 0, f.shieldHP > 0 {
            let sc = CGPoint(x: shieldCenter(f).x + lean, y: shieldCenter(f).y)
            let sr = shieldRadius(f)
            let pulse = 0.55 + 0.25 * sin(CGFloat(CACurrentMediaTime() * 8))
            accent.withAlphaComponent(0.14 + 0.08 * pulse).setFill()
            NSBezierPath(ovalIn: NSRect(x: sc.x - sr, y: sc.y - sr, width: sr * 2, height: sr * 2)).fill()
            accent.withAlphaComponent(0.55).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: sc.x - sr, y: sc.y - sr, width: sr * 2, height: sr * 2))
            ring.lineWidth = 2.5
            ring.stroke()
        }

        // Label above head
        let tag = f.isPlayer ? "Ты" : opponentName
        let tagY = groundY + (f.ducking ? 58 : 108)
        let tw = textWidth(tag, size: 12, bold: true)
        let pill = NSRect(x: cx - tw / 2 - 8, y: tagY, width: tw + 16, height: 20)
        accent.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        drawText(tag, at: CGPoint(x: cx - tw / 2, y: tagY + 3), size: 12, bold: true, color: .white)
    }

    private func drawSnowmanArms(
        _ f: Fighter,
        accent: NSColor,
        stroke: NSColor,
        leftShoulder: CGPoint,
        rightShoulder: CGPoint,
        lean: CGFloat
    ) {
        let dir = CGFloat(f.facing)
        // Throwing side = facing direction
        let throwShoulder = dir >= 0 ? rightShoulder : leftShoulder
        let otherShoulder = dir >= 0 ? leftShoulder : rightShoulder

        var throwHand: CGPoint
        var otherHand: CGPoint

        if f.slinging {
            // Pull hand back to snowball; front hand braces forward
            throwHand = f.slingPull
            otherHand = CGPoint(
                x: otherShoulder.x - dir * 10,
                y: otherShoulder.y + 8 + f.pack * 6
            )
        } else if f.armSwing > 0 {
            // Follow-through: arm snaps forward
            let swing = f.armSwing
            throwHand = CGPoint(
                x: throwShoulder.x + dir * (22 + 28 * swing),
                y: throwShoulder.y + 8 - 20 * swing
            )
            otherHand = CGPoint(
                x: otherShoulder.x - dir * 14,
                y: otherShoulder.y + 10
            )
            // Motion streaks
            accent.withAlphaComponent(0.25 * swing).setStroke()
            let streak = NSBezierPath()
            streak.move(to: CGPoint(x: throwHand.x - dir * 18, y: throwHand.y + 6))
            streak.line(to: throwHand)
            streak.lineWidth = 3
            streak.stroke()
        } else {
            throwHand = CGPoint(x: throwShoulder.x + dir * 20, y: throwShoulder.y + 12)
            otherHand = CGPoint(x: otherShoulder.x - dir * 20, y: otherShoulder.y + 12)
        }

        stroke.setStroke()
        let arms = NSBezierPath()
        arms.move(to: leftShoulder)
        arms.line(to: dir >= 0 ? otherHand : throwHand)
        arms.move(to: rightShoulder)
        arms.line(to: dir >= 0 ? throwHand : otherHand)
        arms.lineWidth = 2.6
        arms.lineCapStyle = .round
        arms.stroke()

        // Hand snowball while winding (extra clear telegraph)
        if f.slinging {
            let hr = 8 + f.pack * 7
            NSColor.white.setFill()
            accent.withAlphaComponent(0.8).setStroke()
            let ball = NSBezierPath(
                ovalIn: NSRect(x: f.slingPull.x - hr, y: f.slingPull.y - hr, width: hr * 2, height: hr * 2)
            )
            ball.fill()
            ball.lineWidth = 2
            ball.stroke()

            // Tiny shake when almost fully drawn
            if f.pack > 0.7 {
                let shake = sin(CGFloat(CACurrentMediaTime() * 28)) * 1.5
                _ = shake
                accent.withAlphaComponent(0.35).setFill()
                NSBezierPath(
                    ovalIn: NSRect(
                        x: f.slingPull.x - 3,
                        y: f.slingPull.y + hr + 4,
                        width: 6,
                        height: 6
                    )
                ).fill()
            }
        }

        _ = lean
    }

    private func drawShot(_ s: Shot) {
        let accent: NSColor
        if s.isBomb {
            accent = NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.1, alpha: 0.9)
        } else if s.fromPlayer {
            accent = NSColor(calibratedRed: 0.25, green: 0.5, blue: 0.95, alpha: 0.75)
        } else {
            accent = NSColor(calibratedRed: 0.9, green: 0.28, blue: 0.3, alpha: 0.75)
        }
        NSColor.white.setFill()
        accent.setStroke()
        let p = NSBezierPath(ovalIn: NSRect(x: s.x - s.r, y: s.y - s.r, width: s.r * 2, height: s.r * 2))
        p.fill(); p.lineWidth = s.isBomb ? 2.4 : 1.6; p.stroke()
    }

    private func drawSling(for f: Fighter) {
        let anchor = f.slingAnchor
        let pull = f.slingPull
        let power = f.pack
        let accent = f.isPlayer
            ? NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.82, alpha: 1)
            : NSColor(calibratedRed: 0.82, green: 0.22, blue: 0.26, alpha: 1)

        // Rubber bands from "hands" to snowball
        let left = CGPoint(x: f.x - 18, y: groundY + 58)
        let right = CGPoint(x: f.x + 18, y: groundY + 58)
        accent.withAlphaComponent(0.75).setStroke()
        let band = NSBezierPath()
        band.move(to: left)
        band.line(to: pull)
        band.move(to: right)
        band.line(to: pull)
        band.lineWidth = 2.4
        band.stroke()

        // Pull guide (max circle)
        NSColor.black.withAlphaComponent(0.08).setStroke()
        let guide = NSBezierPath(ovalIn: NSRect(
            x: anchor.x - maxSlingPull,
            y: anchor.y - maxSlingPull,
            width: maxSlingPull * 2,
            height: maxSlingPull * 2
        ))
        guide.lineWidth = 1
        guide.setLineDash([4, 4], count: 2, phase: 0)
        guide.stroke()

        // Snowball at pull point
        let hr = 9 + power * 8
        NSColor.white.setFill()
        accent.withAlphaComponent(0.7).setStroke()
        let ball = NSBezierPath(ovalIn: NSRect(x: pull.x - hr, y: pull.y - hr, width: hr * 2, height: hr * 2))
        ball.fill()
        ball.lineWidth = 2
        ball.stroke()

        // Trajectory preview (opposite to pull)
        let pdx = pull.x - anchor.x
        let pdy = pull.y - anchor.y
        let plen = hypot(pdx, pdy)
        guard plen > 12 else { return }
        let speed = minShotSpeed + (plen / maxSlingPull) * (maxShotSpeed - minShotSpeed)
        let vx = -pdx / plen * speed
        var vy = -pdy / plen * speed
        var x = anchor.x
        var y = anchor.y
        let step: CGFloat = 1 / 40
        let path = NSBezierPath()
        path.move(to: anchor)
        for _ in 0..<42 {
            vy -= gravity * step
            x += vx * step
            y += vy * step
            path.line(to: CGPoint(x: x, y: y))
            if y < groundY { break }
        }
        accent.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 2.2
        path.setLineDash([6, 5], count: 2, phase: 0)
        path.stroke()
    }

    private func drawHUD(width w: CGFloat, height h: CGFloat) {
        // Top panel
        let panel = NSRect(x: 16, y: h - 58, width: w - 32, height: 42)
        NSColor.white.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12).fill()
        NSColor(calibratedRed: 0.7, green: 0.8, blue: 0.9, alpha: 0.5).setStroke()
        let border = NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12)
        border.lineWidth = 1
        border.stroke()

        drawHP(label: "Ты", hp: player.hp, at: CGPoint(x: 28, y: h - 48), accent: NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.82, alpha: 1))
        let oppLabel = opponentName
        let botBlockW = textWidth(oppLabel, size: 13, bold: true) + CGFloat(maxHP) * 14 + 28
        drawHP(label: oppLabel, hp: enemy.hp, at: CGPoint(x: w - 16 - botBlockW, y: h - 48), accent: NSColor(calibratedRed: 0.82, green: 0.22, blue: 0.26, alpha: 1), labelAfter: true)

        let score = "\(myWins) : \(theirWins)"
        let scoreW = textWidth(score, size: 17, bold: true)
        drawText(score, at: CGPoint(x: (w - scoreW) / 2, y: h - 50), size: 17, bold: true, color: NSColor(calibratedWhite: 0.12, alpha: 1))

        let centerLabel: String
        if player.throwCD > 0 {
            centerLabel = String(format: "КД %.1f", player.throwCD)
        } else {
            centerLabel = String(format: "Снег %.0f", Double(player.ammo + player.heldMass))
        }
        let aw = textWidth(centerLabel, size: 11, bold: false)
        drawText(
            centerLabel,
            at: CGPoint(x: (w - aw) / 2, y: h - 68),
            size: 11,
            bold: false,
            color: player.throwCD > 0
                ? NSColor(calibratedRed: 0.75, green: 0.35, blue: 0.15, alpha: 1)
                : NSColor(calibratedWhite: 0.4, alpha: 1)
        )

        if player.slinging {
            let bw: CGFloat = 140
            let bx = (w - bw) / 2
            let by = h - 72
            NSColor.white.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: bw, height: 9), xRadius: 4, yRadius: 4).fill()
            NSColor(calibratedRed: 0.2, green: 0.48, blue: 0.9, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: bw * player.pack, height: 9), xRadius: 4, yRadius: 4).fill()
        }

        // Buff / shield strip
        var buffX: CGFloat = 28
        let buffY = h - 78
        if player.shieldTime > 0 || player.shieldCD > 0 {
            let label = player.shieldTime > 0 ? "Щит" : String(format: "Щит %.1f", player.shieldCD)
            drawText(
                label,
                at: CGPoint(x: buffX, y: buffY),
                size: 11,
                bold: true,
                color: player.shieldTime > 0
                    ? NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.82, alpha: 1)
                    : NSColor(calibratedWhite: 0.45, alpha: 1)
            )
            buffX += textWidth(label, size: 11, bold: true) + 12
        }
        if player.nextBomb {
            drawText("Бомба", at: CGPoint(x: buffX, y: buffY), size: 11, bold: true,
                     color: NSColor(calibratedRed: 0.9, green: 0.4, blue: 0.1, alpha: 1))
            buffX += textWidth("Бомба", size: 11, bold: true) + 12
        }
        if player.nextMega {
            drawText("Мега", at: CGPoint(x: buffX, y: buffY), size: 11, bold: true,
                     color: NSColor(calibratedRed: 0.45, green: 0.25, blue: 0.85, alpha: 1))
        }

        if statusAge < 3.5 {
            let a = CGFloat(statusAge < 2.6 ? 1 : max(0, 1 - (statusAge - 2.6) / 0.9))
            let sw = textWidth(status, size: 13, bold: false)
            drawText(
                status,
                at: CGPoint(x: (w - sw) / 2, y: 18),
                size: 13,
                bold: false,
                color: NSColor(calibratedWhite: 0.2, alpha: a)
            )
        }
    }

    private func drawHP(label: String, hp: Int, at point: CGPoint, accent: NSColor, labelAfter: Bool = false) {
        var x = point.x
        if !labelAfter {
            drawText(label, at: CGPoint(x: x, y: point.y), size: 13, bold: true, color: accent)
            x += textWidth(label, size: 13, bold: true) + 10
        }
        for i in 0..<maxHP {
            let on = i < hp
            let c = on ? accent : NSColor(calibratedWhite: 0.82, alpha: 1)
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + CGFloat(i) * 14, y: point.y + 2, width: 10, height: 10)).fill()
        }
        if labelAfter {
            x += CGFloat(maxHP) * 14 + 8
            drawText(label, at: CGPoint(x: x, y: point.y), size: 13, bold: true, color: accent)
        }
    }

    private func drawControlsHint(width w: CGFloat, height h: CGFloat, alpha: CGFloat) {
        guard alpha > 0.02 else { return }
        let lines = [
            "Тяни снежок как в Angry Birds · подбирай бонусы на поле",
            "Красное небо = скоро град · Space щит · W/↑ вал",
            "A / D — ходить · S — пригнуться",
        ]
        let boxH: CGFloat = 78
        let box = NSRect(x: w / 2 - 230, y: h / 2 - 30, width: 460, height: boxH)
        NSColor.black.withAlphaComponent(0.45 * alpha).setFill()
        NSBezierPath(roundedRect: box, xRadius: 14, yRadius: 14).fill()
        for (i, line) in lines.enumerated() {
            let tw = textWidth(line, size: 13, bold: false)
            drawText(
                line,
                at: CGPoint(x: box.midX - tw / 2, y: box.maxY - 24 - CGFloat(i) * 20),
                size: 13,
                bold: false,
                color: NSColor.white.withAlphaComponent(alpha)
            )
        }
    }

    private func drawGameOver(width w: CGFloat, height h: CGFloat) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        let layout = roundOverLayout()
        drawFrostCard(layout.card)
        drawMenuSnowflakes(around: layout.card)

        let title = won ? "Раунд за тобой!" : "Раунд проигран"
        let color = won
            ? NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.35, alpha: 1)
            : NSColor(calibratedRed: 0.78, green: 0.2, blue: 0.24, alpha: 1)
        let tw = textWidth(title, size: 24, bold: true)
        drawText(title, at: CGPoint(x: layout.card.midX - tw / 2, y: layout.titleY), size: 24, bold: true, color: color)

        drawScoreBadge(
            text: "\(myWins)  :  \(theirWins)",
            center: CGPoint(x: layout.card.midX, y: layout.scoreBadge.midY),
            width: layout.scoreBadge.width
        )

        // Participants row
        drawParticipantChip(
            name: "Ты",
            wins: myWins,
            accent: NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.85, alpha: 1),
            in: layout.youChip
        )
        let vsW = textWidth("vs", size: 12, bold: true)
        drawText(
            "vs",
            at: CGPoint(x: layout.card.midX - vsW / 2, y: layout.youChip.midY - 6),
            size: 12,
            bold: true,
            color: NSColor(calibratedWhite: 0.45, alpha: 1)
        )
        drawParticipantChip(
            name: opponentName,
            wins: theirWins,
            accent: NSColor(calibratedRed: 0.82, green: 0.28, blue: 0.3, alpha: 1),
            in: layout.oppChip
        )

        drawButton(layout.againButton, title: "Ещё раз", fill: NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.82, alpha: 1))
        drawButton(layout.menuButton, title: "В меню", fill: NSColor(calibratedWhite: 0.38, alpha: 1))
        drawButton(layout.resetButton, title: "Сброс счёта", fill: NSColor(calibratedWhite: 0.55, alpha: 1))
    }

    private struct RoundOverLayout {
        var card: NSRect
        var titleY: CGFloat
        var scoreBadge: NSRect
        var youChip: NSRect
        var oppChip: NSRect
        var againButton: NSRect
        var menuButton: NSRect
        var resetButton: NSRect
    }

    private func roundOverLayout() -> RoundOverLayout {
        let w = bounds.width
        let h = bounds.height
        let cardW: CGFloat = 400
        let btnW: CGFloat = 210
        let chipW: CGFloat = 148
        let chipH: CGFloat = 58
        let topPad: CGFloat = 30
        let bottomPad: CGFloat = 24
        let gapTitleToBadge: CGFloat = 18
        let gapBadgeToChips: CGFloat = 20
        let gapChipsToButtons: CGFloat = 24
        let gapButtons: CGFloat = 12
        let titleBlock: CGFloat = 28
        let badgeH: CGFloat = 34
        let againH: CGFloat = 42
        let menuH: CGFloat = 38
        let resetH: CGFloat = 36

        let contentH =
            topPad
            + titleBlock
            + gapTitleToBadge
            + badgeH
            + gapBadgeToChips
            + chipH
            + gapChipsToButtons
            + againH
            + gapButtons
            + menuH
            + gapButtons
            + resetH
            + bottomPad

        let cardH = contentH
        let card = NSRect(x: (w - cardW) / 2, y: (h - cardH) / 2, width: cardW, height: cardH)
        let btnX = card.midX - btnW / 2

        // Stack from top → bottom (y-up)
        var cursor = card.maxY - topPad

        let titleY = cursor - titleBlock + 6
        cursor -= titleBlock + gapTitleToBadge

        let scoreBadge = NSRect(x: card.midX - 72, y: cursor - badgeH, width: 144, height: badgeH)
        cursor = scoreBadge.minY - gapBadgeToChips

        let youChip = NSRect(x: card.minX + 32, y: cursor - chipH, width: chipW, height: chipH)
        let oppChip = NSRect(x: card.maxX - 32 - chipW, y: cursor - chipH, width: chipW, height: chipH)
        cursor = youChip.minY - gapChipsToButtons

        let againButton = NSRect(x: btnX, y: cursor - againH, width: btnW, height: againH)
        cursor = againButton.minY - gapButtons

        let menuButton = NSRect(x: btnX, y: cursor - menuH, width: btnW, height: menuH)
        cursor = menuButton.minY - gapButtons

        let resetButton = NSRect(x: btnX, y: cursor - resetH, width: btnW, height: resetH)

        return RoundOverLayout(
            card: card,
            titleY: titleY,
            scoreBadge: scoreBadge,
            youChip: youChip,
            oppChip: oppChip,
            againButton: againButton,
            menuButton: menuButton,
            resetButton: resetButton
        )
    }

    private func drawLobby(width w: CGFloat, height h: CGFloat) {
        drawSky(width: w, height: h)
        drawGround(width: w, height: h)
        drawHills(width: w)

        let layout = lobbyLayout()
        drawFrostCard(layout.card)
        drawMenuSnowflakes(around: layout.card)

        let title = "Снежный бой"
        let tw = textWidth(title, size: 28, bold: true)
        drawText(
            title,
            at: CGPoint(x: layout.card.midX - tw / 2, y: layout.titleY),
            size: 28,
            bold: true,
            color: NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.68, alpha: 1)
        )

        drawScoreBadge(
            text: "Серия  \(myWins) : \(theirWins)",
            center: CGPoint(x: layout.card.midX, y: layout.scoreBadge.midY),
            width: layout.scoreBadge.width
        )

        drawButton(layout.botButton, title: "Играть против бота", fill: NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.82, alpha: 1))

        // Friends list panel
        NSColor(calibratedRed: 0.93, green: 0.96, blue: 0.99, alpha: 1).setFill()
        NSColor(calibratedRed: 0.78, green: 0.86, blue: 0.94, alpha: 1).setStroke()
        let listPath = NSBezierPath(roundedRect: layout.listPanel, xRadius: 14, yRadius: 14)
        listPath.fill()
        listPath.lineWidth = 1
        listPath.stroke()

        let friendsTitle = lobbyPeers.isEmpty ? "Участники рядом" : "Участники рядом"
        let fw = textWidth(friendsTitle, size: 12, bold: true)
        drawText(
            friendsTitle,
            at: CGPoint(x: layout.listPanel.midX - fw / 2, y: layout.listPanel.maxY - 26),
            size: 12,
            bold: true,
            color: NSColor(calibratedRed: 0.35, green: 0.48, blue: 0.62, alpha: 1)
        )

        if lobbyPeers.isEmpty {
            let empty = "Никого нет · включи «Снежки по Wi‑Fi»"
            let ew = textWidth(empty, size: 12, bold: false)
            drawText(
                empty,
                at: CGPoint(x: layout.listPanel.midX - ew / 2, y: layout.listPanel.midY - 8),
                size: 12,
                bold: false,
                color: NSColor(calibratedWhite: 0.45, alpha: 1)
            )
        } else {
            for (i, peer) in lobbyPeers.prefix(4).enumerated() {
                let row = layout.peerButton(index: i)
                drawPeerRow(
                    name: OverlayController.shortPeerName(peer.name),
                    in: row,
                    index: i
                )
            }
        }

        drawButton(layout.resetButton, title: "Сброс счёта", fill: NSColor(calibratedWhite: 0.5, alpha: 1))
    }

    private struct LobbyLayout {
        var card: NSRect
        var titleY: CGFloat
        var scoreBadge: NSRect
        var botButton: NSRect
        var listPanel: NSRect
        var peerButtons: [NSRect]
        var resetButton: NSRect

        func peerButton(index: Int) -> NSRect {
            guard index >= 0, index < peerButtons.count else { return .zero }
            return peerButtons[index]
        }
    }

    private func lobbyLayout() -> LobbyLayout {
        let w = bounds.width
        let h = bounds.height
        let peerCount = min(4, lobbyPeers.count)
        let listRows = max(peerCount, 1)
        let listH: CGFloat = 36 + CGFloat(listRows) * 48 + 16
        let cardW: CGFloat = 420
        let cardH: CGFloat = 56 + 44 + 52 + 20 + listH + 20 + 44 + 28
        let card = NSRect(x: (w - cardW) / 2, y: (h - cardH) / 2, width: cardW, height: cardH)

        let contentW: CGFloat = 280
        let contentX = card.midX - contentW / 2
        let pad: CGFloat = 26

        var y = card.maxY - pad
        let titleY = y - 12
        y -= 48

        let scoreBadge = NSRect(x: card.midX - 78, y: y - 32, width: 156, height: 32)
        y = scoreBadge.minY - 20

        let botButton = NSRect(x: contentX, y: y - 44, width: contentW, height: 44)
        y = botButton.minY - 18

        let listPanel = NSRect(x: contentX - 8, y: y - listH, width: contentW + 16, height: listH)
        var peerButtons: [NSRect] = []
        var rowY = listPanel.maxY - 40
        if peerCount > 0 {
            for _ in 0..<peerCount {
                peerButtons.append(NSRect(x: listPanel.minX + 12, y: rowY - 40, width: listPanel.width - 24, height: 40))
                rowY -= 48
            }
        }

        y = listPanel.minY - 18
        let resetButton = NSRect(x: contentX, y: max(card.minY + 20, y - 40), width: contentW, height: 40)

        return LobbyLayout(
            card: card,
            titleY: titleY,
            scoreBadge: scoreBadge,
            botButton: botButton,
            listPanel: listPanel,
            peerButtons: peerButtons,
            resetButton: resetButton
        )
    }

    // MARK: Menu chrome

    private func drawFrostCard(_ card: NSRect) {
        // Soft shadow
        NSColor(calibratedWhite: 0.55, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: card.offsetBy(dx: 0, dy: -4), xRadius: 20, yRadius: 20).fill()

        NSColor(calibratedRed: 0.98, green: 0.99, blue: 1.0, alpha: 0.96).setFill()
        NSColor(calibratedRed: 0.72, green: 0.82, blue: 0.92, alpha: 0.85).setStroke()
        let path = NSBezierPath(roundedRect: card, xRadius: 20, yRadius: 20)
        path.fill()
        path.lineWidth = 1.5
        path.stroke()

        // Top frost highlight
        NSColor.white.withAlphaComponent(0.55).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: card.minX + 12, y: card.maxY - 18, width: card.width - 24, height: 10),
            xRadius: 5,
            yRadius: 5
        ).fill()
    }

    private func drawMenuSnowflakes(around card: NSRect) {
        let spots: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (card.minX - 18, card.maxY - 30, 7, 0.55),
            (card.maxX + 10, card.maxY - 50, 9, 0.45),
            (card.minX - 12, card.midY, 6, 0.4),
            (card.maxX + 16, card.midY - 20, 8, 0.5),
            (card.minX + 24, card.minY - 14, 7, 0.35),
            (card.maxX - 40, card.minY - 18, 10, 0.4),
            (card.midX - 60, card.maxY + 12, 6, 0.35),
            (card.midX + 50, card.maxY + 8, 8, 0.4),
        ]
        let t = CGFloat(CACurrentMediaTime())
        for (i, s) in spots.enumerated() {
            let spin = t * (0.4 + CGFloat(i) * 0.07) + CGFloat(i)
            drawSnowflake(
                at: CGPoint(x: s.0, y: s.1 + sin(t * 1.2 + CGFloat(i)) * 3),
                radius: s.2,
                alpha: s.3,
                rotation: spin
            )
        }
    }

    private func drawSnowflake(at center: CGPoint, radius: CGFloat, alpha: CGFloat, rotation: CGFloat) {
        NSColor.white.withAlphaComponent(alpha).setStroke()
        let path = NSBezierPath()
        for i in 0..<6 {
            let a = rotation + CGFloat(i) * .pi / 3
            path.move(to: center)
            path.line(to: CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
            let mid = CGPoint(x: center.x + cos(a) * radius * 0.55, y: center.y + sin(a) * radius * 0.55)
            let branch: CGFloat = radius * 0.28
            path.move(to: mid)
            path.line(to: CGPoint(x: mid.x + cos(a + 0.7) * branch, y: mid.y + sin(a + 0.7) * branch))
            path.move(to: mid)
            path.line(to: CGPoint(x: mid.x + cos(a - 0.7) * branch, y: mid.y + sin(a - 0.7) * branch))
        }
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.stroke()
    }

    private func drawScoreBadge(text: String, center: CGPoint, width: CGFloat) {
        let rect = NSRect(x: center.x - width / 2, y: center.y - 16, width: width, height: 32)
        NSColor(calibratedRed: 0.88, green: 0.93, blue: 0.98, alpha: 1).setFill()
        NSColor(calibratedRed: 0.65, green: 0.78, blue: 0.92, alpha: 1).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        path.fill()
        path.lineWidth = 1
        path.stroke()
        let tw = textWidth(text, size: 14, bold: true)
        drawText(
            text,
            at: CGPoint(x: center.x - tw / 2, y: center.y - 7),
            size: 14,
            bold: true,
            color: NSColor(calibratedRed: 0.2, green: 0.35, blue: 0.55, alpha: 1)
        )
    }

    private func drawParticipantChip(name: String, wins: Int, accent: NSColor, in rect: NSRect) {
        NSColor.white.setFill()
        accent.withAlphaComponent(0.35).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        path.fill()
        path.lineWidth = 1.5
        path.stroke()

        // Avatar circle
        let av = NSRect(x: rect.minX + 10, y: rect.midY - 14, width: 28, height: 28)
        accent.setFill()
        NSBezierPath(ovalIn: av).fill()
        let initial = String(name.prefix(1)).uppercased()
        let iw = textWidth(initial, size: 13, bold: true)
        drawText(initial, at: CGPoint(x: av.midX - iw / 2, y: av.midY - 7), size: 13, bold: true, color: .white)

        let clipped = name.count > 10 ? String(name.prefix(9)) + "…" : name
        drawText(clipped, at: CGPoint(x: av.maxX + 8, y: rect.midY + 2), size: 12, bold: true, color: .darkGray)
        drawText("\(wins) побед", at: CGPoint(x: av.maxX + 8, y: rect.midY - 14), size: 10, bold: false, color: NSColor(calibratedWhite: 0.45, alpha: 1))
    }

    private func drawPeerRow(name: String, in rect: NSRect, index: Int) {
        NSColor.white.setFill()
        NSColor(calibratedRed: 0.78, green: 0.86, blue: 0.94, alpha: 1).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        path.fill()
        path.lineWidth = 1
        path.stroke()

        let accents = [
            NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.9, alpha: 1),
            NSColor(calibratedRed: 0.85, green: 0.4, blue: 0.45, alpha: 1),
            NSColor(calibratedRed: 0.3, green: 0.7, blue: 0.55, alpha: 1),
            NSColor(calibratedRed: 0.7, green: 0.45, blue: 0.85, alpha: 1),
        ]
        let accent = accents[index % accents.count]
        let av = NSRect(x: rect.minX + 10, y: rect.midY - 13, width: 26, height: 26)
        accent.setFill()
        NSBezierPath(ovalIn: av).fill()
        let initial = String(name.prefix(1)).uppercased()
        let iw = textWidth(initial, size: 12, bold: true)
        drawText(initial, at: CGPoint(x: av.midX - iw / 2, y: av.midY - 6), size: 12, bold: true, color: .white)

        let clipped = name.count > 16 ? String(name.prefix(15)) + "…" : name
        drawText(clipped, at: CGPoint(x: av.maxX + 10, y: rect.midY - 7), size: 13, bold: true, color: .darkGray)

        // Challenge affordance
        let action = "Вызвать"
        let aw = textWidth(action, size: 11, bold: true)
        let pill = NSRect(x: rect.maxX - aw - 24, y: rect.midY - 12, width: aw + 16, height: 24)
        accent.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        drawText(action, at: CGPoint(x: pill.midX - aw / 2, y: pill.midY - 6), size: 11, bold: true, color: .white)
    }

    private func drawWaitingOverlay(width w: CGFloat, height h: CGFloat) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        let card = NSRect(x: w / 2 - 190, y: h / 2 - 85, width: 380, height: 170)
        drawFrostCard(card)
        drawMenuSnowflakes(around: card)

        let title = phase == .rematchWait ? "Ждём ещё один раунд…" : "Ждём оппонента…"
        let tw = textWidth(title, size: 18, bold: true)
        drawText(title, at: CGPoint(x: card.midX - tw / 2, y: card.maxY - 48), size: 18, bold: true, color: .darkGray)

        drawParticipantChip(
            name: opponentName,
            wins: theirWins,
            accent: NSColor(calibratedRed: 0.82, green: 0.28, blue: 0.3, alpha: 1),
            in: NSRect(x: card.midX - 80, y: card.midY - 10, width: 160, height: 48)
        )

        drawButton(menuButtonRect(), title: "Отмена", fill: NSColor(calibratedWhite: 0.42, alpha: 1))
    }

    private func drawChallengeOverlay(width w: CGFloat, height h: CGFloat) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        let card = NSRect(x: w / 2 - 190, y: h / 2 - 100, width: 380, height: 200)
        drawFrostCard(card)
        drawMenuSnowflakes(around: card)

        let title = "Вызов на бой"
        let tw = textWidth(title, size: 20, bold: true)
        drawText(title, at: CGPoint(x: card.midX - tw / 2, y: card.maxY - 42), size: 20, bold: true, color: .darkGray)

        drawParticipantChip(
            name: challengeFromName,
            wins: 0,
            accent: NSColor(calibratedRed: 0.82, green: 0.28, blue: 0.3, alpha: 1),
            in: NSRect(x: card.midX - 90, y: card.maxY - 110, width: 180, height: 52)
        )

        let score = "Серия сейчас  \(myWins) : \(theirWins)"
        let sw = textWidth(score, size: 12, bold: false)
        drawText(score, at: CGPoint(x: card.midX - sw / 2, y: card.minY + 70), size: 12, bold: false, color: NSColor(calibratedWhite: 0.4, alpha: 1))

        drawButton(acceptButtonRect(), title: "Принять", fill: NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.35, alpha: 1))
        drawButton(declineButtonRect(), title: "Отклонить", fill: NSColor(calibratedRed: 0.75, green: 0.25, blue: 0.28, alpha: 1))
    }

    private func drawButton(_ rect: NSRect, title: String, fill: NSColor) {
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()

        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let size = (title as NSString).size(withAttributes: [.font: font])
        drawText(
            title,
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 1),
            size: 13,
            bold: true,
            color: .white
        )
    }

    private func againRect() -> NSRect {
        roundOverLayout().againButton
    }

    private func menuButtonRect() -> NSRect {
        if phase == .waitingOpponent || phase == .rematchWait {
            return NSRect(x: (bounds.width - 150) / 2, y: bounds.height / 2 - 55, width: 150, height: 36)
        }
        return roundOverLayout().menuButton
    }

    private func resetScoreRect() -> NSRect {
        if phase == .lobby {
            return lobbyLayout().resetButton
        }
        return roundOverLayout().resetButton
    }

    private func acceptButtonRect() -> NSRect {
        NSRect(x: bounds.width / 2 - 155, y: bounds.height / 2 - 58, width: 140, height: 38)
    }

    private func declineButtonRect() -> NSRect {
        NSRect(x: bounds.width / 2 + 15, y: bounds.height / 2 - 58, width: 140, height: 38)
    }

    private func textWidth(_ text: String, size: CGFloat, bold: Bool) -> CGFloat {
        let font = bold
            ? NSFont.systemFont(ofSize: size, weight: .semibold)
            : NSFont.systemFont(ofSize: size, weight: .regular)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func drawText(_ text: String, at point: CGPoint, size: CGFloat, bold: Bool, color: NSColor) {
        let font = bold
            ? NSFont.systemFont(ofSize: size, weight: .semibold)
            : NSFont.systemFont(ofSize: size, weight: .regular)
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}

// MARK: - Models

private struct Fighter {
    var isPlayer: Bool
    var hp: Int = 6
    var x: CGFloat = 0
    var y: CGFloat = 0
    var move: CGFloat = 0
    var facing: Int = 1
    var ducking = false
    var slinging = false
    var slingAnchor = CGPoint.zero
    var slingPull = CGPoint.zero
    var pack: CGFloat = 0
    var heldMass: CGFloat = 0
    var ammo: CGFloat = 30
    var stun: CFTimeInterval = 0
    var invuln: CFTimeInterval = 0
    var shieldTime: CFTimeInterval = 0
    var shieldHP: Int = 0
    var shieldCD: CFTimeInterval = 0
    var throwCD: CFTimeInterval = 0
    var wallCD: CFTimeInterval = 0
    var nextBomb = false
    var nextMega = false
    /// Bot (or animated) wind-up before release.
    var windupRemaining: CFTimeInterval = 0
    var windupDuration: CFTimeInterval = 0.7
    var windupTarget = CGPoint.zero
    /// Throw follow-through (1 → 0).
    var armSwing: CGFloat = 0
}

private struct Shot {
    var x, y, vx, vy, r: CGFloat
    var damage: Int
    var fromPlayer: Bool
    var age: CFTimeInterval
    var isBomb: Bool = false
}

private enum PickupKind {
    case shield, bomb, mega, heal, ammo

    var title: String {
        switch self {
        case .shield: return "Щит"
        case .bomb: return "Бомба"
        case .mega: return "Мега"
        case .heal: return "Аптечка"
        case .ammo: return "Снег"
        }
    }

    var short: String {
        switch self {
        case .shield: return "🛡"
        case .bomb: return "💣"
        case .mega: return "❄"
        case .heal: return "+"
        case .ammo: return "○"
        }
    }

    var color: NSColor {
        switch self {
        case .shield: return NSColor(calibratedRed: 0.2, green: 0.45, blue: 0.9, alpha: 1)
        case .bomb: return NSColor(calibratedRed: 0.9, green: 0.4, blue: 0.1, alpha: 1)
        case .mega: return NSColor(calibratedRed: 0.45, green: 0.3, blue: 0.9, alpha: 1)
        case .heal: return NSColor(calibratedRed: 0.2, green: 0.7, blue: 0.4, alpha: 1)
        case .ammo: return NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.75, alpha: 1)
        }
    }
}

private struct ArenaPickup {
    var kind: PickupKind
    var x: CGFloat
    var y: CGFloat
    var bob: CFTimeInterval
    var life: CFTimeInterval
}

private struct HazardBall {
    var x, y, vy, vx, r: CGFloat
    var damage: Int
}

private struct SnowWall {
    var x: CGFloat
    var hp: Int
    var fromPlayer: Bool
    var life: CFTimeInterval
}

private struct SnowDrift {
    var x: CGFloat
    var snow: CGFloat
}

private struct FallingFlake {
    var x, y, vy, r: CGFloat
}

private struct Burst {
    var x, y, vx, vy, r: CGFloat
    var life: CFTimeInterval
}

private struct BotBrain {
    var think: CFTimeInterval = 0.3
    var throwCD: CFTimeInterval = 1.1
    var wallCD: CFTimeInterval = 0
    var strafe: CGFloat = -1
}
