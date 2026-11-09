import CryptoKit
import Foundation
import Network
import QuartzCore

/// Side of the local desktop where a snowball leaves / arrives.
enum SnowEdge: UInt8 {
    case left = 0
    case right = 1
}

enum PeerRelativeSide: String {
    case auto
    case left
    case right
}

struct PeerInfo: Equatable {
    let id: UInt64
    let name: String
    let side: PeerRelativeSide
    let isReachable: Bool
}

struct LanThrowRoute: Equatable {
    let leftName: String?
    let rightName: String?
}

struct OutboundSnowball {
    let edge: SnowEdge
    let normY: Float
    let vx: Float
    let vy: Float
    let mass: Float
}

struct InboundSnowball {
    let fromPeerID: UInt64
    let fromName: String
    let entryEdge: SnowEdge
    let normY: Float
    let vx: Float
    let vy: Float
    let mass: Float
}

/// LAN-only Bonjour + UDP snowball exchange.
///
/// Discovery and packets stay on Wi‑Fi / Ethernet / AWDL (interface-scoped),
/// so an active VPN default route should not carry snowballs — unless the VPN
/// itself blocks LAN traffic.
///
/// Security model (no accounts / registration):
/// - Advertise only on the local link via Bonjour (`_flake-snow._udp`)
/// - Accept UDP only from endpoints discovered for known peers
/// - Fixed-size binary packets with magic/version
/// - HMAC-SHA256 truncated tag keyed by both peers' Bonjour tokens
/// - Replay window + rate limits; ignore oversized / malformed input
/// - No remote code paths beyond spawning a capped snowball
final class PeerSnowNetwork {
    static let serviceType = "_flake-snow._udp"
    static let defaultsKeyEnabled = "flake.lanSnowballsEnabled"
    static let defaultsKeySides = "flake.lanPeerSides"

    private static let magic: UInt32 = 0x464C4B45 // FLKE
    private static let version: UInt8 = 1
    private static let packetSize = 48
    private static let typeHeartbeat: UInt8 = 1
    private static let typeSnowball: UInt8 = 2
    private static let typeGoodbye: UInt8 = 3
    private static let typeAck: UInt8 = 4
    private static let maxSnowballsPerSecond = 12
    private static let deliveryTimeout: CFTimeInterval = 1.8
    private static let maxAbsVelocity: Float = 2_400
    private static let minMass: Float = 8
    private static let maxMass: Float = 180

    private let localID: UInt64
    private let localToken: Data
    private let displayName: String
    private let queue = DispatchQueue(label: "com.flake.peer-snow", qos: .userInitiated)

    private var enabled = false
    private var listener: NWListener?
    /// NWBrowser omits TXT on current macOS; NetServiceBrowser resolves TXT reliably.
    private var bonjourBrowser: BonjourPeerBrowser?
    private var peers: [UInt64: PeerState] = [:]
    /// Names currently advertised on Bonjour (even if UDP heartbeat is quiet).
    private var bonjourLiveNames = Set<String>()
    private var sideOverrides: [String: String] = [:]
    private var inboundRate: [UInt64: (windowStart: CFTimeInterval, count: Int)] = [:]
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastEmittedPeers: [PeerInfo] = []
    private var pendingThrows: [UInt32: PendingThrow] = [:]
    /// Cached on main for menu: who receives a throw off each edge.
    private(set) var throwRouteMain = LanThrowRoute(leftName: nil, rightName: nil)

    var onPeersChanged: (([PeerInfo]) -> Void)?
    var onInboundSnowball: ((InboundSnowball) -> Void)?
    /// Peer confirmed the snowball landed on their screen.
    var onThrowDelivered: ((String) -> Void)?
    /// No ACK within timeout — likely blocked / offline mid-flight.
    var onThrowMissed: ((String) -> Void)?
    /// Mirrored on the main thread for UI / simulator toggles.
    private(set) var isEnabledMain = false

    private struct PeerState {
        var id: UInt64
        var name: String
        var token: Data
        var endpoint: NWEndpoint?
        var connection: NWConnection?
        var lastSeen: CFTimeInterval
        var lastSeq: UInt32
        var side: PeerRelativeSide
    }

    private struct PendingThrow {
        let peerID: UInt64
        let peerName: String
        let sentAt: CFTimeInterval
    }

    init() {
        var idBytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, idBytes.count, &idBytes)
        localID = idBytes.withUnsafeBytes { $0.load(as: UInt64.self) }

        var token = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, token.count, &token)
        localToken = Data(token)

        displayName = Host.current().localizedName ?? "Mac"
        if let saved = UserDefaults.standard.dictionary(forKey: Self.defaultsKeySides) as? [String: String] {
            sideOverrides = saved
        }
    }

    var isEnabled: Bool { isEnabledMain }

    var peerSnapshot: [PeerInfo] {
        let now = CACurrentMediaTime()
        return peers.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map {
                let bonjourLive = bonjourLiveNames.contains($0.name)
                let recentlySeen = (now - $0.lastSeen) < 12
                return PeerInfo(
                    id: $0.id,
                    name: $0.name,
                    side: $0.side,
                    isReachable: $0.endpoint != nil && (bonjourLive || recentlySeen)
                )
            }
    }

    func setEnabled(_ on: Bool) {
        isEnabledMain = on
        UserDefaults.standard.set(on, forKey: Self.defaultsKeyEnabled)
        queue.async { [weak self] in
            guard let self else { return }
            if on == self.enabled { return }
            if !on {
                for peer in self.peers.values {
                    _ = self.send(type: Self.typeGoodbye, to: peer, edge: .left, normY: 0, vx: 0, vy: 0, mass: 0)
                }
                self.pendingThrows.removeAll()
            }
            self.enabled = on
            if on {
                self.startLocked()
            } else {
                self.stopLocked()
            }
            self.emitPeersChanged()
        }
    }

    func restoreFromDefaults() {
        let on = UserDefaults.standard.bool(forKey: Self.defaultsKeyEnabled)
        setEnabled(on)
    }

    func setSide(_ side: PeerRelativeSide, forPeerID id: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            // One peer per side: if A is already "справа", setting B to "справа"
            // moves A back to Авто — иначе непонятно, кому летит снежок.
            if side == .left || side == .right {
                for (otherID, other) in self.peers where otherID != id && other.side == side {
                    self.peers[otherID]?.side = .auto
                    self.sideOverrides[String(otherID)] = PeerRelativeSide.auto.rawValue
                }
            }
            self.sideOverrides[String(id)] = side.rawValue
            UserDefaults.standard.set(self.sideOverrides, forKey: Self.defaultsKeySides)
            if var peer = self.peers[id] {
                peer.side = side
                self.peers[id] = peer
            }
            self.emitPeersChanged()
        }
    }

    /// Throw a snowball that left the local desktop toward the peer on that edge.
    func sendSnowball(_ ball: OutboundSnowball) {
        queue.async { [weak self] in
            guard let self, self.enabled else { return }
            let targets = self.targets(for: ball.edge)
            guard let peer = targets.first else { return }
            let seq = self.send(
                type: Self.typeSnowball,
                to: peer,
                edge: ball.edge,
                normY: ball.normY,
                vx: ball.vx,
                vy: ball.vy,
                mass: ball.mass
            )
            if let seq {
                self.pendingThrows[seq] = PendingThrow(
                    peerID: peer.id,
                    peerName: peer.name,
                    sentAt: CACurrentMediaTime()
                )
            }
        }
    }

    func stop() {
        isEnabledMain = false
        queue.sync {
            enabled = false
            stopLocked()
        }
    }

    // MARK: - Lifecycle

    private func startLocked() {
        stopLocked()
        startListener()
        startBrowser()
        startHeartbeat()
    }

    private func stopLocked() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        DispatchQueue.main.async { [weak self] in
            self?.bonjourBrowser?.stop()
            self?.bonjourBrowser = nil
        }
        listener?.cancel()
        listener = nil
        for (_, peer) in peers {
            peer.connection?.cancel()
        }
        peers.removeAll()
        bonjourLiveNames.removeAll()
        inboundRate.removeAll()
        pendingThrows.removeAll()
        lastEmittedPeers = []
    }

    private func startListener() {
        do {
            let listener = try NWListener(using: Self.localLinkUDPParameters())
            let tokenHex = localToken.map { String(format: "%02x", $0) }.joined()
            listener.service = NWListener.Service(
                name: displayName,
                type: Self.serviceType,
                txtRecord: NWTXTRecord([
                    "id": String(localID),
                    "tok": tokenHex,
                    "ver": String(Self.version),
                ])
            )
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.queue.async {
                        self?.listener?.cancel()
                        self?.listener = nil
                        if self?.enabled == true {
                            self?.startListener()
                        }
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async {
                    self?.accept(connection)
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("Flake: LAN listener failed: \(error.localizedDescription)")
        }
    }

    private func startBrowser() {
        // Must start NetServiceBrowser on a run-loop thread (main).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bonjourBrowser?.stop()
            let browser = BonjourPeerBrowser(serviceType: Self.serviceType) { [weak self] event in
                self?.queue.async {
                    self?.handleBonjourEvent(event)
                }
            }
            self.bonjourBrowser = browser
            browser.start()
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 3)
        timer.setEventHandler { [weak self] in
            self?.heartbeatTick()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func heartbeatTick() {
        let now = CACurrentMediaTime()
        var stale: [UInt64] = []
        for (id, peer) in peers {
            let advertised = bonjourLiveNames.contains(peer.name)
            // Drop only when Bonjour forgot them AND UDP has been quiet.
            if !advertised && now - peer.lastSeen > 15 {
                stale.append(id)
                continue
            }
            if peer.connection == nil {
                ensureConnection(for: id)
            }
            _ = send(type: Self.typeHeartbeat, to: peer, edge: .left, normY: 0, vx: 0, vy: 0, mass: 0)
        }
        if !stale.isEmpty {
            for id in stale {
                peers[id]?.connection?.cancel()
                peers.removeValue(forKey: id)
            }
            emitPeersChanged()
        }
        expirePendingThrows(now: now)
    }

    private func expirePendingThrows(now: CFTimeInterval) {
        let timedOut = pendingThrows.filter { now - $0.value.sentAt >= Self.deliveryTimeout }
        guard !timedOut.isEmpty else { return }
        for (seq, pending) in timedOut {
            pendingThrows.removeValue(forKey: seq)
            let name = pending.peerName
            DispatchQueue.main.async { [weak self] in
                self?.onThrowMissed?(name)
            }
        }
    }

    // MARK: - Discovery

    private func handleBonjourEvent(_ event: BonjourPeerBrowser.Event) {
        guard enabled else { return }
        switch event {
        case let .resolved(name, txt, endpoint):
            bonjourLiveNames.insert(name)
            guard
                let idString = txt["id"],
                let peerID = UInt64(idString),
                peerID != localID,
                let tokHex = txt["tok"],
                let token = Data(hexString: tokHex),
                token.count == 16,
                let verString = txt["ver"],
                let ver = UInt8(verString),
                ver == Self.version
            else { return }

            let side = resolvedSide(for: peerID)
            if var existing = peers[peerID] {
                existing.name = name
                existing.token = token
                existing.endpoint = endpoint
                existing.side = side
                existing.lastSeen = CACurrentMediaTime()
                peers[peerID] = existing
            } else {
                peers[peerID] = PeerState(
                    id: peerID,
                    name: name,
                    token: token,
                    endpoint: endpoint,
                    connection: nil,
                    lastSeen: CACurrentMediaTime(),
                    lastSeq: 0,
                    side: side
                )
            }
            ensureConnection(for: peerID)
            emitPeersChanged()

        case let .removed(name):
            bonjourLiveNames.remove(name)
            let gone = peers.filter { $0.value.name == name }.map(\.key)
            guard !gone.isEmpty else { return }
            for id in gone {
                peers[id]?.connection?.cancel()
                peers.removeValue(forKey: id)
            }
            emitPeersChanged()
        }
    }

    private func resolvedSide(for id: UInt64) -> PeerRelativeSide {
        if let raw = sideOverrides[String(id)], let side = PeerRelativeSide(rawValue: raw) {
            return side
        }
        return .auto
    }

    private func ensureConnection(for id: UInt64) {
        guard var peer = peers[id], let endpoint = peer.endpoint else { return }
        if let connection = peer.connection {
            switch connection.state {
            case .ready, .preparing, .setup:
                return
            default:
                connection.cancel()
            }
        }
        let connection = NWConnection(to: endpoint, using: Self.localLinkUDPParameters())
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                if case .failed = state {
                    self?.peers[id]?.connection?.cancel()
                    self?.peers[id]?.connection = nil
                }
            }
        }
        connection.start(queue: queue)
        peer.connection = connection
        peers[id] = peer
        receiveLoop(on: connection, expectedPeerID: id)
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { _ in }
        connection.start(queue: queue)
        receiveLoop(on: connection, expectedPeerID: nil)
    }

    // MARK: - Send / receive

    /// Exactly one peer per throw edge.
    private func targets(for edge: SnowEdge) -> [PeerState] {
        if let peer = resolvedTarget(for: edge) {
            return [peer]
        }
        return []
    }

    private func livePeers() -> [PeerState] {
        let now = CACurrentMediaTime()
        return peers.values.filter { peer in
            peer.endpoint != nil
                && (bonjourLiveNames.contains(peer.name) || (now - peer.lastSeen) < 12)
        }
    }

    private func resolvedTarget(for edge: SnowEdge) -> PeerState? {
        let live = livePeers()
        guard !live.isEmpty else { return nil }

        let want: PeerRelativeSide = (edge == .left) ? .left : .right
        // Explicit seat wins (uniqueness enforced in setSide).
        if let seated = live.filter({ $0.side == want }).sorted(by: { $0.id < $1.id }).first {
            return seated
        }

        let leftTaken = live.contains { $0.side == .left }
        let rightTaken = live.contains { $0.side == .right }
        let autos = live.filter { $0.side == .auto }.sorted { $0.id < $1.id }
        guard !autos.isEmpty else { return nil }

        // Single auto peer with no seats claimed → both edges hit them.
        if autos.count == 1, !leftTaken, !rightTaken {
            return autos[0]
        }
        if edge == .left, !leftTaken {
            return autos.first
        }
        if edge == .right, !rightTaken {
            return autos.count >= 2 ? autos.last : autos.first
        }
        return nil
    }

    private func currentThrowRoute() -> LanThrowRoute {
        LanThrowRoute(
            leftName: resolvedTarget(for: .left)?.name,
            rightName: resolvedTarget(for: .right)?.name
        )
    }

    @discardableResult
    private func send(
        type: UInt8,
        to peer: PeerState,
        edge: SnowEdge,
        normY: Float,
        vx: Float,
        vy: Float,
        mass: Float,
        seqOverride: UInt32? = nil
    ) -> UInt32? {
        guard let connection = peers[peer.id]?.connection ?? {
            ensureConnection(for: peer.id)
            return peers[peer.id]?.connection
        }() else { return nil }

        let seq = seqOverride ?? UInt32.random(in: 1...UInt32.max)

        // Layout (48 bytes): magic/ver/type/flags/id/seq/time/edge/pad/normY16/vx/vy/mass/hmac8
        var packet = Data(count: Self.packetSize)
        packet.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            writeUInt32(Self.magic, to: base)
            base[4] = Self.version
            base[5] = type
            writeUInt16(0, to: base + 6)
            writeUInt64(localID, to: base + 8)
            writeUInt32(seq, to: base + 16)
            writeUInt32(UInt32(CACurrentMediaTime()), to: base + 20)
            base[24] = edge.rawValue
            base[25] = 0
            let normFixed = UInt16(min(1, max(0, normY)) * 10_000)
            writeUInt16(normFixed, to: base + 26)
            writeFloat(vx, to: base + 28)
            writeFloat(vy, to: base + 32)
            writeFloat(mass, to: base + 36)
        }

        let key = sharedKey(localToken: localToken, peerToken: peer.token)
        let body = packet.prefix(40)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        let tag = Data(mac).prefix(8)
        packet.replaceSubrange(40..<48, with: tag)

        connection.send(content: packet, completion: .contentProcessed { _ in })
        return seq
    }

    private func receiveLoop(on connection: NWConnection, expectedPeerID: UInt64?) {
        connection.receiveMessage { [weak self] content, _, _, error in
            self?.queue.async {
                defer {
                    if error == nil, self?.enabled == true {
                        self?.receiveLoop(on: connection, expectedPeerID: expectedPeerID)
                    }
                }
                guard let self, self.enabled, let content, content.count == Self.packetSize else { return }
                self.handlePacket(content, on: connection, expectedPeerID: expectedPeerID)
            }
        }
    }

    private func handlePacket(_ data: Data, on connection: NWConnection, expectedPeerID: UInt64?) {
        guard data.count == Self.packetSize else { return }
        let bytes = [UInt8](data)
        let magic = readUInt32(bytes, 0)
        guard magic == Self.magic, bytes[4] == Self.version else { return }
        let type = bytes[5]
        let senderID = readUInt64(bytes, 8)
        if let expectedPeerID, expectedPeerID != senderID { return }
        if senderID == localID { return }

        guard var peer = peers[senderID] else {
            // Unknown sender — ignore until Bonjour advertises them (no open relay).
            return
        }

        let body = data.prefix(40)
        let tag = data.suffix(8)
        let key = sharedKey(localToken: localToken, peerToken: peer.token)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: body, using: key)).prefix(8)
        guard tag == expected else { return }

        let seq = readUInt32(bytes, 16)
        peer.lastSeen = CACurrentMediaTime()
        if peer.connection == nil {
            peer.connection = connection
        }

        // ACK echoes our outbound snowball seq — don't mix it into their replay window.
        if type == Self.typeAck {
            peers[senderID] = peer
            if let pending = pendingThrows.removeValue(forKey: seq) {
                let name = pending.peerName
                DispatchQueue.main.async { [weak self] in
                    self?.onThrowDelivered?(name)
                }
            }
            return
        }

        // Replay window for peer-originated traffic.
        if seq == peer.lastSeq { return }
        peer.lastSeq = seq
        peers[senderID] = peer

        switch type {
        case Self.typeHeartbeat:
            emitPeersChanged()
        case Self.typeSnowball:
            guard allowInbound(from: senderID) else { return }
            let edgeRaw = bytes[24]
            guard let leaveEdge = SnowEdge(rawValue: edgeRaw) else { return }
            let normFixed = readUInt16(bytes, 26)
            let normY = min(1, max(0, Float(normFixed) / 10_000))
            var vx = readFloat(bytes, 28)
            var vy = readFloat(bytes, 32)
            var mass = readFloat(bytes, 36)
            vx = min(Self.maxAbsVelocity, max(-Self.maxAbsVelocity, vx))
            vy = min(Self.maxAbsVelocity, max(-Self.maxAbsVelocity, vy))
            mass = min(Self.maxMass, max(Self.minMass, mass))
            // Continuity across desks: left exit → enter from right, and vice versa.
            let entry: SnowEdge = (leaveEdge == .left) ? .right : .left
            let inbound = InboundSnowball(
                fromPeerID: senderID,
                fromName: peer.name,
                entryEdge: entry,
                normY: normY,
                vx: vx,
                vy: vy,
                mass: mass
            )
            // Confirm delivery so the thrower knows it landed.
            _ = send(
                type: Self.typeAck,
                to: peer,
                edge: leaveEdge,
                normY: 0,
                vx: 0,
                vy: 0,
                mass: 0,
                seqOverride: seq
            )
            DispatchQueue.main.async { [weak self] in
                self?.onInboundSnowball?(inbound)
            }
        case Self.typeGoodbye:
            peers[senderID]?.connection?.cancel()
            peers.removeValue(forKey: senderID)
            emitPeersChanged()
        default:
            break
        }
    }

    private func allowInbound(from id: UInt64) -> Bool {
        let now = CACurrentMediaTime()
        var bucket = inboundRate[id] ?? (windowStart: now, count: 0)
        if now - bucket.windowStart > 1 {
            bucket = (windowStart: now, count: 0)
        }
        bucket.count += 1
        inboundRate[id] = bucket
        return bucket.count <= Self.maxSnowballsPerSecond
    }

    private func sharedKey(localToken: Data, peerToken: Data) -> SymmetricKey {
        let a: Data
        let b: Data
        if localToken.lexicographicallyPrecedes(peerToken) {
            a = localToken
            b = peerToken
        } else {
            a = peerToken
            b = localToken
        }
        var material = Data("flake-lan-v1".utf8)
        material.append(a)
        material.append(b)
        let digest = SHA256.hash(data: material)
        return SymmetricKey(data: Data(digest))
    }

    private func emitPeersChanged() {
        let snap = peerSnapshot
        let route = currentThrowRoute()
        let peersChanged = snap != lastEmittedPeers
        lastEmittedPeers = snap
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.throwRouteMain = route
            if peersChanged {
                self.onPeersChanged?(snap)
            } else {
                // Still refresh menu when only throw routing changed.
                self.onPeersChanged?(snap)
            }
        }
    }

    // MARK: - Local link (ignore VPN default route)

    /// UDP path constrained away from cellular/loopback; LAN IPs keep Wi‑Fi route even with VPN.
    private static func localLinkUDPParameters() -> NWParameters {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        params.prohibitedInterfaceTypes = [.loopback, .cellular]
        return params
    }
}

// MARK: - Bonjour browse (NetService — TXT works; NWBrowser metadata is empty on macOS)

private final class BonjourPeerBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    enum Event {
        case resolved(name: String, txt: [String: String], endpoint: NWEndpoint)
        case removed(name: String)
    }

    private let serviceType: String
    private let onEvent: (Event) -> Void
    private let browser = NetServiceBrowser()
    private var resolving: [String: NetService] = [:]
    private var liveNames = Set<String>()

    init(serviceType: String, onEvent: @escaping (Event) -> Void) {
        self.serviceType = serviceType.hasSuffix(".") ? serviceType : serviceType + "."
        self.onEvent = onEvent
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = true
    }

    func start() {
        browser.searchForServices(ofType: serviceType, inDomain: "local.")
    }

    func stop() {
        browser.stop()
        for service in resolving.values {
            service.stop()
            service.delegate = nil
        }
        resolving.removeAll()
        liveNames.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let key = service.name
        liveNames.insert(key)
        service.delegate = self
        resolving[key] = service
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let key = service.name
        liveNames.remove(key)
        resolving[key]?.stop()
        resolving[key]?.delegate = nil
        resolving.removeValue(forKey: key)
        onEvent(.removed(name: key))
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        NSLog("Flake: Bonjour browse failed: \(errorDict)")
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let key = sender.name
        defer {
            sender.stop()
            sender.delegate = nil
            resolving.removeValue(forKey: key)
        }
        guard liveNames.contains(key) else { return }
        guard let txtData = sender.txtRecordData() else { return }
        let raw = NetService.dictionary(fromTXTRecord: txtData)
        var txt: [String: String] = [:]
        for (k, v) in raw {
            if let s = String(data: v, encoding: .utf8) { txt[k] = s }
        }
        guard !txt.isEmpty else { return }
        guard let endpoint = Self.endpoint(for: sender) else { return }
        onEvent(.resolved(name: sender.name, txt: txt, endpoint: endpoint))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeValue(forKey: sender.name)
        sender.delegate = nil
        NSLog("Flake: Bonjour resolve failed for \(sender.name): \(errorDict)")
    }

    /// Prefer a LAN unicast address so UDP stays off the VPN tunnel.
    private static func endpoint(for service: NetService) -> NWEndpoint? {
        if let lan = firstLANHost(from: service.addresses),
           let port = NWEndpoint.Port(rawValue: UInt16(service.port))
        {
            return NWEndpoint.hostPort(host: lan, port: port)
        }
        // Fallback: Bonjour service name (Network.framework re-resolves).
        var type = service.type
        if type.hasSuffix(".") { type.removeLast() }
        var domain = service.domain
        if domain.hasSuffix(".") { domain.removeLast() }
        return NWEndpoint.service(name: service.name, type: type, domain: domain, interface: nil)
    }

    private static func firstLANHost(from addresses: [Data]?) -> NWEndpoint.Host? {
        guard let addresses else { return nil }
        var fallback: NWEndpoint.Host?
        for data in addresses {
            guard let ip = numericHost(fromSockaddr: data) else { continue }
            if ip.contains(":") {
                // IPv6 — keep as fallback only.
                if fallback == nil { fallback = NWEndpoint.Host(ip) }
                continue
            }
            let parts = ip.split(separator: ".").compactMap { UInt8($0) }
            guard parts.count == 4 else { continue }
            let o0 = parts[0], o1 = parts[1]
            if o0 == 198 && (o1 == 18 || o1 == 19) { continue } // VPN fake-ip
            if o0 == 127 { continue }
            let isPrivate =
                o0 == 10
                || (o0 == 192 && o1 == 168)
                || (o0 == 172 && o1 >= 16 && o1 <= 31)
                || (o0 == 169 && o1 == 254)
            let host = NWEndpoint.Host(ip)
            if isPrivate { return host }
            if fallback == nil { fallback = host }
        }
        return fallback
    }

    private static func numericHost(fromSockaddr data: Data) -> String? {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = data.withUnsafeBytes { raw -> Int32 in
            guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return -1 }
            return getnameinfo(
                sa,
                socklen_t(data.count),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
        }
        guard rc == 0 else { return nil }
        return String(cString: hostname)
    }
}

// MARK: - Binary helpers

private func writeUInt16(_ value: UInt16, to ptr: UnsafeMutablePointer<UInt8>) {
    var v = value.bigEndian
    withUnsafeBytes(of: &v) { ptr.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: 2) }
}

private func writeUInt32(_ value: UInt32, to ptr: UnsafeMutablePointer<UInt8>) {
    var v = value.bigEndian
    withUnsafeBytes(of: &v) { ptr.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: 4) }
}

private func writeUInt64(_ value: UInt64, to ptr: UnsafeMutablePointer<UInt8>) {
    var v = value.bigEndian
    withUnsafeBytes(of: &v) { ptr.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: 8) }
}

private func writeFloat(_ value: Float, to ptr: UnsafeMutablePointer<UInt8>) {
    var v = value.bitPattern.bigEndian
    withUnsafeBytes(of: &v) { ptr.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: 4) }
}

private func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
}

private func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    var v: UInt32 = 0
    for i in 0..<4 { v = (v << 8) | UInt32(bytes[offset + i]) }
    return v
}

private func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v = (v << 8) | UInt64(bytes[offset + i]) }
    return v
}

private func readFloat(_ bytes: [UInt8], _ offset: Int) -> Float {
    let pattern = readUInt32(bytes, offset)
    return Float(bitPattern: pattern)
}

private extension Data {
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleaned.count % 2 == 0, cleaned.count == 32 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
