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

struct OutboundSnowball {
    let edge: SnowEdge
    let normY: Float
    let vx: Float
    let vy: Float
    let mass: Float
}

struct InboundSnowball {
    let fromPeerID: UInt64
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
    private static let maxSnowballsPerSecond = 12
    private static let maxAbsVelocity: Float = 2_400
    private static let minMass: Float = 8
    private static let maxMass: Float = 180

    private let localID: UInt64
    private let localToken: Data
    private let displayName: String
    private let queue = DispatchQueue(label: "com.flake.peer-snow", qos: .userInitiated)

    private var enabled = false
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [UInt64: PeerState] = [:]
    private var sideOverrides: [String: String] = [:]
    private var inboundRate: [UInt64: (windowStart: CFTimeInterval, count: Int)] = [:]
    private var heartbeatTimer: DispatchSourceTimer?

    var onPeersChanged: (([PeerInfo]) -> Void)?
    var onInboundSnowball: ((InboundSnowball) -> Void)?
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
        peers.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map {
                PeerInfo(
                    id: $0.id,
                    name: $0.name,
                    side: $0.side,
                    isReachable: $0.endpoint != nil && (CACurrentMediaTime() - $0.lastSeen) < 12
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
                    self.send(type: Self.typeGoodbye, to: peer, edge: .left, normY: 0, vx: 0, vy: 0, mass: 0)
                }
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
            self.sideOverrides[String(id)] = side.rawValue
            UserDefaults.standard.set(self.sideOverrides, forKey: Self.defaultsKeySides)
            if var peer = self.peers[id] {
                peer.side = side
                self.peers[id] = peer
                self.emitPeersChanged()
            }
        }
    }

    /// Throw a snowball that left the local desktop toward peers on that edge.
    func sendSnowball(_ ball: OutboundSnowball) {
        queue.async { [weak self] in
            guard let self, self.enabled else { return }
            let targets = self.targets(for: ball.edge)
            guard !targets.isEmpty else { return }
            for peer in targets {
                self.send(
                    type: Self.typeSnowball,
                    to: peer,
                    edge: ball.edge,
                    normY: ball.normY,
                    vx: ball.vx,
                    vy: ball.vy,
                    mass: ball.mass
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
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        for (_, peer) in peers {
            peer.connection?.cancel()
        }
        peers.removeAll()
        inboundRate.removeAll()
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
        // Browse only on Wi‑Fi / Ethernet / AWDL — not on VPN utun tunnels.
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: Self.localLinkBrowseParameters()
        )
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.queue.async {
                    self?.browser?.cancel()
                    self?.browser = nil
                    if self?.enabled == true {
                        self?.startBrowser()
                    }
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.queue.async {
                self?.applyBrowseResults(results)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
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
            if now - peer.lastSeen > 15 {
                stale.append(id)
                continue
            }
            send(type: Self.typeHeartbeat, to: peer, edge: .left, normY: 0, vx: 0, vy: 0, mass: 0)
        }
        if !stale.isEmpty {
            for id in stale {
                peers[id]?.connection?.cancel()
                peers.removeValue(forKey: id)
            }
            emitPeersChanged()
        }
    }

    // MARK: - Discovery

    private func applyBrowseResults(_ results: Set<NWBrowser.Result>) {
        var seenIDs = Set<UInt64>()
        for result in results {
            guard case let .service(name, type, domain, interface) = result.endpoint else { continue }
            guard type == Self.serviceType || type.hasPrefix("_flake-snow") else { continue }
            // Skip VPN / tunnel interfaces even if the system surfaces them.
            if let interface, !Self.isLocalLinkInterface(interface) { continue }
            let txt: NWTXTRecord? = {
                if case let .bonjour(metadata) = result.metadata {
                    return metadata
                }
                return nil
            }()
            guard let txt else { continue }
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
            else { continue }

            seenIDs.insert(peerID)
            let side = resolvedSide(for: peerID)
            // Pin the Bonjour endpoint to the discovered local interface so UDP
            // stays on Wi‑Fi even when a VPN owns the default route.
            let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: interface)

            if var existing = peers[peerID] {
                existing.name = name
                existing.token = token
                existing.endpoint = endpoint
                existing.side = side
                existing.lastSeen = CACurrentMediaTime()
                peers[peerID] = existing
                ensureConnection(for: peerID)
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
                ensureConnection(for: peerID)
            }
        }

        let removed = peers.keys.filter { !seenIDs.contains($0) && (CACurrentMediaTime() - (peers[$0]?.lastSeen ?? 0)) > 12 }
        for id in removed {
            peers[id]?.connection?.cancel()
            peers.removeValue(forKey: id)
        }
        emitPeersChanged()
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

    private func targets(for edge: SnowEdge) -> [PeerState] {
        let live = peers.values.filter {
            $0.endpoint != nil && (CACurrentMediaTime() - $0.lastSeen) < 12
        }
        if live.isEmpty { return [] }

        let explicit = live.filter {
            ($0.side == .left && edge == .left) || ($0.side == .right && edge == .right)
        }
        if !explicit.isEmpty { return Array(explicit) }

        let autos = live.filter { $0.side == PeerRelativeSide.auto }
        if autos.count == 1 { return autos }
        if autos.count > 1 {
            // Stable virtual desk: lower peer id sits on the left.
            let sorted = autos.sorted { $0.id < $1.id }
            if edge == .left {
                return sorted.first.map { [$0] } ?? []
            }
            return sorted.last.map { [$0] } ?? []
        }
        return []
    }

    private func send(
        type: UInt8,
        to peer: PeerState,
        edge: SnowEdge,
        normY: Float,
        vx: Float,
        vy: Float,
        mass: Float
    ) {
        guard let connection = peers[peer.id]?.connection ?? {
            ensureConnection(for: peer.id)
            return peers[peer.id]?.connection
        }() else { return }

        // Layout (48 bytes): magic/ver/type/flags/id/seq/time/edge/pad/normY16/vx/vy/mass/hmac8
        var packet = Data(count: Self.packetSize)
        packet.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            writeUInt32(Self.magic, to: base)
            base[4] = Self.version
            base[5] = type
            writeUInt16(0, to: base + 6)
            writeUInt64(localID, to: base + 8)
            let seq = UInt32.random(in: 1...UInt32.max)
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
        // Replay window: allow wrap but reject exact repeats recently.
        if seq == peer.lastSeq { return }
        peer.lastSeq = seq
        peer.lastSeen = CACurrentMediaTime()
        if peer.connection == nil {
            peer.connection = connection
        }
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
                entryEdge: entry,
                normY: normY,
                vx: vx,
                vy: vy,
                mass: mass
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
        DispatchQueue.main.async { [weak self] in
            self?.onPeersChanged?(snap)
        }
    }

    // MARK: - Local link (ignore VPN default route)

    /// UDP path constrained to Wi‑Fi / Ethernet / Apple peer-to-peer, not utun VPN.
    private static func localLinkUDPParameters() -> NWParameters {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        constrainToLocalLink(params)
        return params
    }

    private static func localLinkBrowseParameters() -> NWParameters {
        let params = NWParameters()
        params.includePeerToPeer = true
        constrainToLocalLink(params)
        return params
    }

    private static func constrainToLocalLink(_ params: NWParameters) {
        // Do not prohibit `.other`: AWDL (peer-to-peer Wi‑Fi) often reports as that.
        // VPN tunnels are filtered by interface name when browsing (see isLocalLinkInterface).
        params.prohibitedInterfaceTypes = [.loopback, .cellular]
    }

    private static func isLocalLinkInterface(_ interface: NWInterface) -> Bool {
        let name = interface.name.lowercased()
        // Explicit VPN / tunnel device names — never use these for snowballs.
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
            || name.hasPrefix("wg") || name.hasPrefix("tun") || name.hasPrefix("tap")
        {
            return false
        }
        switch interface.type {
        case .wifi, .wiredEthernet:
            return true
        case .other:
            // AWDL / LLW are fine; unknown virtual NICs are not.
            return name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("en")
        default:
            return false
        }
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
