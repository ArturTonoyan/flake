import AppKit
import Foundation
import simd

struct FlakeParticle {
    var x: Float
    var y: Float
    var vx: Float
    var vy: Float
    var size: Float
    var opacity: Float
    var wobble: Float
    var phase: Float
}

struct Snowball {
    var x: Float
    var y: Float
    var vx: Float
    var vy: Float
    var mass: Float
    var held: Bool
    /// Index of ball this one rests on; nil if free / on a ledge.
    var stackedOn: Int?
    /// Ledge id when resting on a window top.
    var restingLedge: UInt32?

    var radius: Float {
        // Slow packing: long roll reaches ~26pt, not a giant instantly.
        max(6, min(36, 4.2 + sqrtf(max(mass, 1)) * 1.65))
    }
}

/// Three stacked balls fused into a snowman.
struct Snowman {
    var x: Float
    var y: Float
    var vx: Float
    var vy: Float
    var baseMass: Float
    var midMass: Float
    var headMass: Float
    var held: Bool
    var restingLedge: UInt32?

    // Neat classic stack: base > mid > head.
    var baseR: Float { max(13, min(26, 6.5 + sqrtf(baseMass) * 1.35)) }
    var midR: Float { max(10, min(19, 5.2 + sqrtf(midMass) * 1.1)) }
    var headR: Float { max(7.5, min(13.5, 4.8 + sqrtf(headMass) * 0.95)) }

    // Soft sprites: nest so body disks visually touch (opaque core ≈ 0.72R).
    var midY: Float { y + (baseR + midR) * 0.68 }
    var headY: Float { midY + (midR + headR) * 0.68 }
    var topY: Float { headY + headR }
}

struct SettledSurface {
    var ledge: SnowLedge
    var heights: [Float]
    var cellWidth: Float

    mutating func resize(to ledge: SnowLedge, cellWidth: Float) {
        let count = max(4, Int(ceil(ledge.width / cellWidth)))
        if count == heights.count, abs(self.cellWidth - cellWidth) < 0.01 {
            self.ledge = ledge
            return
        }
        var next = [Float](repeating: 0, count: count)
        if !heights.isEmpty, ledge.width > 1 {
            for i in 0..<count {
                let t = Float(i) / Float(max(count - 1, 1))
                let src = t * Float(max(heights.count - 1, 0))
                let i0 = Int(src)
                let i1 = min(i0 + 1, heights.count - 1)
                let f = src - Float(i0)
                next[i] = heights[i0] * (1 - f) + heights[i1] * f
            }
        }
        self.heights = next
        self.cellWidth = cellWidth
        self.ledge = ledge
    }

    func height(atLocalX localX: Float) -> Float {
        guard !heights.isEmpty else { return 0 }
        let idx = localX / cellWidth
        let i0 = max(0, min(heights.count - 1, Int(floor(idx))))
        let i1 = min(heights.count - 1, i0 + 1)
        let f = idx - Float(i0)
        return heights[i0] * (1 - f) + heights[i1] * f
    }

    /// macOS window corner radius — snow must not stick past the rounded corner.
    /// Dock has no rounded chrome; use a tiny inset only.
    var cornerRadius: Float { ledge.isDock ? 2 : 12 }

    mutating func addSnow(atLocalX localX: Float, amount: Float) {
        guard !heights.isEmpty else { return }
        let corner = cornerRadius
        // No settling on the curved corners.
        if localX < corner || localX > ledge.width - corner { return }
        let deposit = min(amount, ledge.isDock ? 1.35 : 1.1)
        let center = Int((localX / cellWidth).rounded())
        let radius = ledge.isDock ? 3 : 2
        for d in -radius...radius {
            let i = center + d
            guard i >= 0, i < heights.count else { continue }
            let lx = Float(i) * cellWidth
            if lx < corner || lx > ledge.width - corner { continue }
            let w: Float = 1 - Float(abs(d)) / Float(radius + 1)
            let cap: Float = ledge.isDock ? 18 : 26
            heights[i] = min(heights[i] + deposit * w, cap)
        }
        relax(iterations: 1)
        taperEdges()
    }

    /// Follow rounded window corners — zero / fade snow in the corner zones.
    mutating func taperEdges() {
        guard heights.count > 4 else {
            for i in heights.indices { heights[i] = 0 }
            return
        }
        let r = cornerRadius
        guard r > 0.5 else { return }
        for i in heights.indices {
            let dist = min(Float(i) * cellWidth, max(0, ledge.width - Float(i) * cellWidth))
            if dist < r {
                // Quarter-circle falloff matching the window chrome.
                let t = dist / r
                let scale = t * t * (3 - 2 * t) // smoothstep
                heights[i] *= scale
                if dist < 2.5, !ledge.isDock { heights[i] = 0 }
            }
        }
        relax(iterations: 1)
    }

    mutating func relax(iterations: Int) {
        guard heights.count > 2 else { return }
        let maxSlope: Float = 1.1
        for _ in 0..<iterations {
            for i in 0..<(heights.count - 1) {
                let diff = heights[i] - heights[i + 1]
                if diff > maxSlope {
                    let move = (diff - maxSlope) * 0.5
                    heights[i] -= move
                    heights[i + 1] += move
                } else if diff < -maxSlope {
                    let move = (-diff - maxSlope) * 0.5
                    heights[i] += move
                    heights[i + 1] -= move
                }
            }
        }
    }

    mutating func push(atLocalX localX: Float, forceX: Float, forceY: Float) -> (left: Float, right: Float) {
        guard !heights.isEmpty else { return (0, 0) }
        let center = Int((localX / cellWidth).rounded())
        let radius = 5
        let strength = min(2.8, hypot(forceX, forceY) * 0.1)
        guard strength > 0.02 else { return (0, 0) }

        var spillLeft: Float = 0
        var spillRight: Float = 0
        let dir = forceX >= 0 ? 1 : -1

        for d in -radius...radius {
            let i = center + d
            guard i >= 0, i < heights.count else { continue }
            let falloff = 1 - Float(abs(d)) / Float(radius + 1)
            let take = min(heights[i], strength * falloff * 1.5)
            heights[i] -= take

            let dest = i + dir * max(1, Int(2 + abs(forceX) * 0.06))
            if dest < 0 {
                spillLeft += take
            } else if dest >= heights.count {
                spillRight += take
            } else {
                heights[dest] = min(28, heights[dest] + take * 0.85)
            }
        }
        _ = forceY
        taperEdges()
        return (spillLeft, spillRight)
    }

    mutating func scoop(atLocalX localX: Float, radius: Float) -> Float {
        guard !heights.isEmpty else { return 0 }
        let center = Int((localX / cellWidth).rounded())
        let cells = Int(ceil(radius / cellWidth))
        var taken: Float = 0
        for d in -cells...cells {
            let i = center + d
            guard i >= 0, i < heights.count else { continue }
            let falloff = 1 - Float(abs(d)) / Float(cells + 1)
            let amount = min(heights[i], 0.85 * falloff)
            heights[i] -= amount
            taken += amount
        }
        taperEdges()
        return taken
    }

    /// Rebuild a visible pile under a snowman (bypasses addSnow's tiny per-frame cap).
    mutating func restoreMound(atLocalX localX: Float, peak: Float = 11, radius: Float = 28) {
        guard !heights.isEmpty else { return }
        let corner = cornerRadius
        let clamped = max(corner + 1, min(ledge.width - corner - 1, localX))
        let center = Int((clamped / cellWidth).rounded())
        let cells = max(2, Int(ceil(radius / cellWidth)))
        for d in -cells...cells {
            let i = center + d
            guard i >= 0, i < heights.count else { continue }
            let lx = Float(i) * cellWidth
            if lx < corner || lx > ledge.width - corner { continue }
            let t = 1 - Float(abs(d)) / Float(cells + 1)
            let target = peak * t * t
            heights[i] = min(26, max(heights[i], target))
        }
        relax(iterations: 2)
        taperEdges()
    }
}

final class SnowSimulator {
    private(set) var particles: [FlakeParticle] = []
    private(set) var surfaces: [UInt32: SettledSurface] = [:]
    private(set) var balls: [Snowball] = []
    private(set) var snowmen: [Snowman] = []

    var intensity: Float = 0.7
    var mouseEnabled = true
    var mouseX: Float = -10_000
    var mouseY: Float = -10_000
    var mouseVX: Float = 0
    var mouseVY: Float = 0
    var mouseDown = false
    private var wasMouseDown = false

    private var worldMinX: Float = 0
    private var worldMinY: Float = 0
    private var worldMaxX: Float = 1920
    private var worldMaxY: Float = 1080
    /// Each screen rect in global Cocoa points — spawn evenly per display.
    private var screenRects: [(minX: Float, maxX: Float, minY: Float, maxY: Float, width: Float)] = []
    /// Screens covered by a maximized / fullscreen window — no snow at all there.
    private var snowBlockedScreens: [(minX: Float, maxX: Float, minY: Float, maxY: Float)] = []

    private var spawnAccumulator: Float = 0
    private let maxBalls = 24
    private let cellWidth: Float = 3.0
    private var wind: Float = 0
    private var windTarget: Float = 0
    private var windTimer: Float = 0
    private var rng = SystemRandomNumberGenerator()
    private var occluders: [SnowWindow] = []
    /// Non-dock, non-maximized windows — fast point-in-body tests (maximized → blocked screens).
    private var bodyOccluders: [SnowWindow] = []
    /// Front-to-back windows used when clipping drifts under overlapping chrome.
    private var coverOccluders: [SnowWindow] = []
    private var driftMeshDirty = true
    private var lastOccluderFingerprint: UInt64 = 0
    /// Previous frame poses for body windows — used to push snow when a window moves.
    private var prevWindowPose: [UInt32: (x: Float, y: Float, bottom: Float, right: Float)] = [:]
    private var heldBallIndex: Int?
    /// Ball currently being rolled from a drift under the cursor.
    private var rollingBallIndex: Int?
    private var rollCooldown: Float = 0
    /// Snow gathered while dragging before a ball actually appears.
    private var formingMass: Float = 0
    private let ballSpawnThreshold: Float = 11
    private let ballMaxMass: Float = 180

    private(set) var flakeUpload: [SIMD4<Float>] = []
    private(set) var ballUpload: [SIMD4<Float>] = []
    private(set) var decorUpload: [SIMD4<Float>] = []

    /// Snowballs that left the left/right desktop edge this frame (LAN handoff).
    private(set) var pendingEdgeExits: [OutboundSnowball] = []
    /// When false, edge exits melt locally instead of being offered to peers.
    var lanHandoffEnabled = false
    private(set) var driftVertices: [SIMD2<Float>] = []
    private(set) var driftColors: [SIMD4<Float>] = []
    private(set) var driftStripCounts: [Int] = []
    /// Filled mesh for snowmen (body + carrot + twigs), drawn with the drift pipeline.
    private(set) var propVertices: [SIMD2<Float>] = []
    private(set) var propColors: [SIMD4<Float>] = []
    private(set) var propTriCounts: [Int] = []
    private var heldSnowmanIndex: Int?
    /// Windows missing while switching Spaces — keep drifts until the Space returns.
    private var surfaceMissingSince: [UInt32: CFTimeInterval] = [:]
    /// Long enough to swipe away and come back without losing piles.
    private let surfaceGrace: CFTimeInterval = 90.0
    /// Currently on-screen windows only (missing Space windows stay cached but hidden).
    private var activeSurfaceIDs: Set<UInt32> = []
    /// After a Space switch / swipe, freeze dumps and ignore sliding frames.
    private var spaceSwitchUntil: CFTimeInterval = 0
    /// One-frame jump larger than this = Space animation, not a real drag.
    private let spaceJumpThreshold: Float = 36
    /// After a Space return, don't treat reattach as a drag-dump.
    private var restoreGuardUntil: [UInt32: CFTimeInterval] = [:]
    /// After dumping a dragged window, don't dump again every frame (shake spam).
    private var dumpCooldownUntil: [UInt32: CFTimeInterval] = [:]
    /// While a window is being dragged, flakes must not re-settle on it.
    private var noSettleUntil: [UInt32: CFTimeInterval] = [:]

    func noteSpaceSwitch() {
        let now = CACurrentMediaTime()
        spaceSwitchUntil = now + 2.8
        // Hide non-Dock piles until sync sees stable windows again — never dump here.
        for (id, surface) in surfaces where !surface.ledge.isDock {
            if surfaceMissingSince[id] == nil {
                surfaceMissingSince[id] = now
            }
        }
        activeSurfaceIDs = Set(surfaces.compactMap { $0.value.ledge.isDock ? $0.key : nil })
        markDriftDirty()
        // Balls/snowmen on those windows stay parked with the surface — don't leave ghosts.
    }

    /// True when this resting ledge belongs to another Space (cached but not drawn).
    private func isParkedOnOtherSpace(restingLedge id: UInt32?) -> Bool {
        guard let id else { return false }
        if activeSurfaceIDs.contains(id) { return false }
        return surfaces[id] != nil
    }

    var worldWidth: Float { max(1, worldMaxX - worldMinX) }

    private var maxParticles: Int {
        // Scale with monitors + intensity so the main screen isn't starved.
        let screens = max(1, screenRects.count)
        return min(4500, Int(1200 * Float(screens) * max(1, intensity)))
    }

    func setWorldBounds(minX: Float, minY: Float, maxX: Float, maxY: Float) {
        worldMinX = minX
        worldMinY = minY
        worldMaxX = maxX
        worldMaxY = maxY
    }

    func setScreenFrames(_ frames: [NSRect]) {
        screenRects = frames.map {
            (
                minX: Float($0.minX),
                maxX: Float($0.maxX),
                minY: Float($0.minY),
                maxY: Float($0.maxY),
                width: Float(max(1, $0.width))
            )
        }
    }

    private func refreshSnowBlockedScreens() {
        // Only the display that actually hosts a maximized / fullscreen window.
        // Never blank a neighbor monitor when the other one is zoomed.
        var blocked: [(minX: Float, maxX: Float, minY: Float, maxY: Float)] = []
        for win in occluders where win.isMaximized && !win.isDock {
            guard let host = hostScreen(of: win) else { continue }
            let screenH = max(1, host.maxY - host.minY)
            let screenW = max(1, host.maxX - host.minX)
            let screenArea = screenW * screenH
            let overlapX = max(0, min(win.right, host.maxX) - max(win.x, host.minX))
            let overlapY = max(0, min(win.y, host.maxY) - max(win.bottom, host.minY))
            guard (overlapX * overlapY) / screenArea > 0.55 else { continue }
            if !blocked.contains(where: {
                abs($0.minX - host.minX) < 2 && abs($0.maxX - host.maxX) < 2
            }) {
                blocked.append(host)
            }
        }
        snowBlockedScreens = blocked
    }

    /// True when this display has a maximized / fullscreen app — overlay should stay dark.
    func isSnowBlocked(screenFrame: NSRect) -> Bool {
        let minX = Float(screenFrame.minX)
        let maxX = Float(screenFrame.maxX)
        let minY = Float(screenFrame.minY)
        let maxY = Float(screenFrame.maxY)
        return snowBlockedScreens.contains {
            abs($0.minX - minX) < 4
                && abs($0.maxX - maxX) < 4
                && abs($0.minY - minY) < 4
                && abs($0.maxY - maxY) < 4
        }
    }

    private func isOnBlockedScreen(x: Float, y: Float) -> Bool {
        // Tiny inset only — do not bleed into an adjacent monitor.
        let pad: Float = 2
        for s in snowBlockedScreens {
            if x >= s.minX - pad, x <= s.maxX + pad, y >= s.minY - pad, y <= s.maxY + pad {
                return true
            }
        }
        return false
    }

    func consumeEdgeExits() -> [OutboundSnowball] {
        let exits = pendingEdgeExits
        pendingEdgeExits.removeAll(keepingCapacity: true)
        return exits
    }

    /// Spawn a snowball arriving from a peer across the matching screen edge.
    @discardableResult
    func spawnInboundSnowball(
        entryEdge: SnowEdge,
        normY: Float,
        vx: Float,
        vy: Float,
        mass: Float
    ) -> Bool {
        guard balls.count < maxBalls else { return false }
        let clampedMass = min(ballMaxMass, max(8, mass))
        let r = max(6, min(36, 4.2 + sqrtf(clampedMass) * 1.65))
        let y = worldMinY + min(1, max(0, normY)) * max(1, worldMaxY - worldMinY)
        let x: Float
        var inboundVX = vx
        switch entryEdge {
        case .left:
            x = worldMinX + r + 2
            // Ensure it continues inward.
            if inboundVX < 40 { inboundVX = max(180, abs(vx)) }
        case .right:
            x = worldMaxX - r - 2
            if inboundVX > -40 { inboundVX = -max(180, abs(vx)) }
        }
        balls.append(
            Snowball(
                x: x,
                y: min(worldMaxY - r, max(worldMinY + r, y)),
                vx: inboundVX,
                vy: vy,
                mass: clampedMass,
                held: false,
                stackedOn: nil,
                restingLedge: nil
            )
        )
        return true
    }

    func clear() {
        particles.removeAll(keepingCapacity: true)
        surfaces.removeAll(keepingCapacity: true)
        markDriftDirty()
        prevWindowPose.removeAll(keepingCapacity: true)
        balls.removeAll(keepingCapacity: true)
        snowmen.removeAll(keepingCapacity: true)
        pendingEdgeExits.removeAll(keepingCapacity: true)
        heldBallIndex = nil
        rollingBallIndex = nil
        heldSnowmanIndex = nil
        formingMass = 0
        surfaceMissingSince.removeAll(keepingCapacity: true)
        restoreGuardUntil.removeAll(keepingCapacity: true)
        dumpCooldownUntil.removeAll(keepingCapacity: true)
        noSettleUntil.removeAll(keepingCapacity: true)
        flakeUpload.removeAll(keepingCapacity: true)
        ballUpload.removeAll(keepingCapacity: true)
        decorUpload.removeAll(keepingCapacity: true)
        driftVertices.removeAll(keepingCapacity: true)
        driftColors.removeAll(keepingCapacity: true)
        driftStripCounts.removeAll(keepingCapacity: true)
        propVertices.removeAll(keepingCapacity: true)
        propColors.removeAll(keepingCapacity: true)
        propTriCounts.removeAll(keepingCapacity: true)
    }

    func update(dt: Float, windows: [SnowWindow]) {
        let dtClamped = min(dt, 1.0 / 20.0)
        occluders = windows
        bodyOccluders = windows.filter { !$0.isDock && !$0.isMaximized }
        coverOccluders = windows.filter { !$0.isDock }
        let occluderFP = occluderFingerprint()
        if occluderFP != lastOccluderFingerprint {
            lastOccluderFingerprint = occluderFP
            markDriftDirty()
        }
        refreshSnowBlockedScreens()
        let ledges = windows.compactMap { $0.canAccumulate ? $0.ledge : nil }

        updateWind(dt: dtClamped)
        syncSurfaces(with: ledges)
        let liveLedges = activeLedges(from: ledges)
        applyMovingWindowForces(dt: dtClamped)
        spawn(dt: dtClamped)
        integrate(dt: dtClamped, ledges: liveLedges)
        if mouseEnabled {
            handleMouseButtons()
            applyMouse(dt: dtClamped)
        }
        updateBalls(dt: dtClamped, ledges: liveLedges)
        updateSnowmen(dt: dtClamped, ledges: liveLedges)
        wasMouseDown = mouseDown
        rememberWindowPoses()
        buildUploadBuffers()
    }

    private func rememberWindowPoses() {
        var next: [UInt32: (x: Float, y: Float, bottom: Float, right: Float)] = [:]
        next.reserveCapacity(bodyOccluders.count)
        for win in bodyOccluders {
            next[win.id] = (win.x, win.y, win.bottom, win.right)
        }
        prevWindowPose = next
    }

    /// Moving windows act as solid walls — shove flakes, balls, snowmen, and foreign drifts.
    private func applyMovingWindowForces(dt: Float) {
        let invDt = 1 / max(dt, 1 / 120)
        for win in bodyOccluders {
            guard let prev = prevWindowPose[win.id] else { continue }
            let dx = win.x - prev.x
            let dy = win.y - prev.y
            let move = hypot(dx, dy)
            guard move > 1.2 else { continue }
            let winVX = dx * invDt
            let winVY = dy * invDt

            // Flakes near / inside the moving chrome get pushed out.
            for i in particles.indices {
                var p = particles[i]
                let near = p.x >= min(prev.x, win.x) - 10
                    && p.x <= max(prev.right, win.right) + 10
                    && p.y >= min(prev.bottom, win.bottom) - 10
                    && p.y <= max(prev.y, win.y) + 10
                guard near else { continue }
                if bouncePointOffWindow(
                    win,
                    x: &p.x,
                    y: &p.y,
                    vx: &p.vx,
                    vy: &p.vy,
                    winVX: winVX,
                    winVY: winVY,
                    restitution: 0.35,
                    friction: 0.2
                ) || win.occludes(x: p.x, y: p.y) {
                    p.vx += winVX * 0.45
                    p.vy += winVY * 0.45
                    _ = bouncePointOffWindow(
                        win,
                        x: &p.x,
                        y: &p.y,
                        vx: &p.vx,
                        vy: &p.vy,
                        winVX: winVX,
                        winVY: winVY,
                        restitution: 0.4,
                        friction: 0.15
                    )
                } else {
                    // Sweep: flakes ahead of the motion get a nudge.
                    let ahead = dx * (p.x - win.x - win.width * 0.5)
                        + dy * (p.y - (win.bottom + win.height * 0.5))
                    if ahead > 0 {
                        p.vx += winVX * 0.12
                        p.vy += winVY * 0.12
                    }
                }
                particles[i] = p
            }

            for i in balls.indices where !balls[i].held {
                var x = balls[i].x
                var y = balls[i].y
                var vx = balls[i].vx
                var vy = balls[i].vy
                if bounceCircleOffWindow(
                    win,
                    x: &x,
                    y: &y,
                    vx: &vx,
                    vy: &vy,
                    radius: balls[i].radius,
                    winVX: winVX,
                    winVY: winVY,
                    restitution: 0.55,
                    friction: 0.2
                ) {
                    balls[i].x = x
                    balls[i].y = y
                    balls[i].vx = vx + winVX * 0.25
                    balls[i].vy = vy + winVY * 0.25
                    balls[i].restingLedge = nil
                }
            }

            for i in snowmen.indices where !snowmen[i].held {
                var x = snowmen[i].x
                var y = snowmen[i].y
                var vx = snowmen[i].vx
                var vy = snowmen[i].vy
                if bounceCircleOffWindow(
                    win,
                    x: &x,
                    y: &y,
                    vx: &vx,
                    vy: &vy,
                    radius: snowmen[i].baseR,
                    winVX: winVX,
                    winVY: winVY,
                    restitution: 0.4,
                    friction: 0.25
                ) {
                    snowmen[i].x = x
                    snowmen[i].y = y
                    snowmen[i].vx = vx + winVX * 0.2
                    snowmen[i].vy = vy + winVY * 0.2
                    snowmen[i].restingLedge = nil
                }
            }

            // Shove snow piled on OTHER windows that this chrome sweeps through.
            for (id, var surface) in surfaces where id != win.id && activeSurfaceIDs.contains(id) {
                let ledge = surface.ledge
                let bandTop = ledge.y + 26
                let bandBot = ledge.y - 2
                guard win.bottom < bandTop, win.y > bandBot else { continue }
                let overlapL = max(win.x, ledge.x)
                let overlapR = min(win.right, ledge.x + ledge.width)
                guard overlapR > overlapL + 2 else { continue }
                let local = (overlapL + overlapR) * 0.5 - ledge.x
                let spill = surface.push(
                    atLocalX: local,
                    forceX: winVX * 0.55,
                    forceY: winVY * 0.2
                )
                if spill.left > 0.02 || spill.right > 0.02 {
                    markDriftDirty()
                    spillOffEdge(surface: surface, amount: spill.left, side: -1, outwardSpeed: abs(winVX))
                    spillOffEdge(surface: surface, amount: spill.right, side: 1, outwardSpeed: abs(winVX))
                }
                // Scoop a bit of the overlapped pile into falling flakes.
                let scraped = surface.scoop(atLocalX: local, radius: min(22, (overlapR - overlapL) * 0.5))
                if scraped > 0.08 {
                    markDriftDirty()
                    spillOffEdge(
                        surface: surface,
                        amount: scraped * 0.65,
                        side: winVX >= 0 ? 1 : -1,
                        outwardSpeed: max(50, abs(winVX))
                    )
                }
                surfaces[id] = surface
            }
        }
    }

    private func windowVelocity(for id: UInt32, current: SnowWindow, dt: Float) -> (Float, Float) {
        guard let prev = prevWindowPose[id] else { return (0, 0) }
        let invDt = 1 / max(dt, 1 / 120)
        return ((current.x - prev.x) * invDt, (current.y - prev.y) * invDt)
    }

    /// Reflect velocity about an outward unit normal (relative to a moving window).
    private func reflectVelocity(
        vx: inout Float,
        vy: inout Float,
        normalX: Float,
        normalY: Float,
        winVX: Float,
        winVY: Float,
        restitution: Float,
        friction: Float
    ) {
        var rvx = vx - winVX
        var rvy = vy - winVY
        let vn = rvx * normalX + rvy * normalY
        if vn >= 0 {
            vx = rvx + winVX
            vy = rvy + winVY
            return
        }
        rvx -= (1 + restitution) * vn * normalX
        rvy -= (1 + restitution) * vn * normalY
        let tx = -normalY
        let ty = normalX
        let vt = rvx * tx + rvy * ty
        rvx -= vt * friction * tx
        rvy -= vt * friction * ty
        vx = rvx + winVX
        vy = rvy + winVY
    }

    /// Point vs window body — eject to nearest edge and bounce.
    /// Top face is NOT a trampoline: snow must settle into the drift there.
    @discardableResult
    private func bouncePointOffWindow(
        _ win: SnowWindow,
        x: inout Float,
        y: inout Float,
        vx: inout Float,
        vy: inout Float,
        winVX: Float,
        winVY: Float,
        restitution: Float,
        friction: Float
    ) -> Bool {
        guard win.occludes(x: x, y: y) else { return false }
        let top = win.y - 1
        let dl = x - win.x
        let dr = win.right - x
        let dt = top - y
        let db = y - win.bottom
        // Prefer side / bottom walls. If the top is clearly nearest, leave the flake
        // for ledge settling instead of bouncing it into a hovering cloud.
        if dt <= dl, dt <= dr, dt <= db {
            return false
        }
        var nx: Float = 0
        var ny: Float = 0
        if dl <= dr, dl <= db {
            x = win.x - 1.2
            nx = -1
        } else if dr <= db {
            x = win.right + 1.2
            nx = 1
        } else {
            y = win.bottom - 1.2
            ny = -1
        }
        reflectVelocity(
            vx: &vx, vy: &vy,
            normalX: nx, normalY: ny,
            winVX: winVX, winVY: winVY,
            restitution: restitution, friction: friction
        )
        return true
    }

    /// Circle vs window sides / bottom. Top is a snow ledge — no bounce from above.
    @discardableResult
    private func bounceCircleOffWindow(
        _ win: SnowWindow,
        x: inout Float,
        y: inout Float,
        vx: inout Float,
        vy: inout Float,
        radius: Float,
        winVX: Float,
        winVY: Float,
        restitution: Float,
        friction: Float
    ) -> Bool {
        let bodyTop = win.y - 1

        // Entirely above the chrome — ledge landing handles this, not a wall bounce.
        if y >= bodyTop {
            return false
        }

        // Closest point on the solid rectangle (top face excluded for external hits).
        let cx = min(max(x, win.x), win.right)
        let cy = min(max(y, win.bottom), bodyTop)
        let dx = x - cx
        let dy = y - cy
        let d2 = dx * dx + dy * dy

        if d2 < 0.0001 {
            // Center is inside — eject via side / bottom (never trampoline off the top).
            let dl = x - win.x
            let dr = win.right - x
            let db = y - win.bottom
            let dt = bodyTop - y
            var nx: Float = 0
            var ny: Float = 0
            if dt < dl, dt < dr, dt < db {
                // Near the top from inside → park just above so snow/ball can settle.
                y = bodyTop + max(2, radius * 0.35)
                vy = min(vy, -20)
                vx *= 0.85
                return true
            }
            if dl <= dr, dl <= db {
                x = win.x - radius
                nx = -1
            } else if dr <= db {
                x = win.right + radius
                nx = 1
            } else {
                y = win.bottom - radius
                ny = -1
            }
            reflectVelocity(
                vx: &vx, vy: &vy,
                normalX: nx, normalY: ny,
                winVX: winVX, winVY: winVY,
                restitution: restitution, friction: friction
            )
            return true
        }

        // Ignore collisions whose contact normal points mostly upward (top face).
        let d = sqrtf(d2)
        guard d < radius else { return false }
        let nx = dx / d
        let ny = dy / d
        if ny > 0.55 { return false }
        let overlap = radius - d
        x += nx * (overlap + 0.5)
        y += ny * (overlap + 0.5)
        reflectVelocity(
            vx: &vx, vy: &vy,
            normalX: nx, normalY: ny,
            winVX: winVX, winVY: winVY,
            restitution: restitution, friction: friction
        )
        return true
    }

    private func markDriftDirty() {
        driftMeshDirty = true
    }

    private func occluderFingerprint() -> UInt64 {
        var h = UInt64(coverOccluders.count) &+ 2166136261
        for w in coverOccluders {
            h ^= UInt64(w.id)
            h &*= 16777619
            h ^= UInt64(w.x.bitPattern)
            h &*= 16777619
            h ^= UInt64(w.y.bitPattern)
            h &*= 16777619
            h ^= UInt64(w.width.bitPattern)
            h &*= 16777619
            h ^= UInt64(w.height.bitPattern)
            h &*= 16777619
            h ^= UInt64(truncatingIfNeeded: w.z)
            h &*= 16777619
        }
        for id in activeSurfaceIDs {
            h ^= UInt64(id)
            h &*= 16777619
        }
        return h
    }

    private func updateWind(dt: Float) {
        windTimer -= dt
        if windTimer <= 0 {
            windTarget = Float.random(in: -18...18, using: &rng)
            windTimer = Float.random(in: 2.5...6.0, using: &rng)
        }
        wind += (windTarget - wind) * min(1, dt * 0.4)
    }

    private func syncSurfaces(with ledges: [SnowLedge]) {
        var seen = Set<UInt32>()
        seen.reserveCapacity(ledges.count)
        let now = CACurrentMediaTime()

        // Three-finger Space swipe moves several windows at once before the notification fires.
        var jumpCount = 0
        var slideCount = 0
        for ledge in ledges {
            guard let prev = surfaces[ledge.id]?.ledge, !prev.isDock else { continue }
            let dist = hypot(ledge.x - prev.x, ledge.y - prev.y)
            if dist >= spaceJumpThreshold { jumpCount += 1 }
            // Coherent horizontal slide = Space animation (even in small per-frame steps).
            if dist > 6, abs(ledge.x - prev.x) > abs(ledge.y - prev.y) * 1.2 {
                slideCount += 1
            }
        }
        if jumpCount >= 2 || slideCount >= 2 {
            spaceSwitchUntil = max(spaceSwitchUntil, now + 1.6)
        }

        let inSpaceCooldown = now < spaceSwitchUntil
        var drawIDs = Set<UInt32>()

        for ledge in ledges {
            seen.insert(ledge.id)
            let returnedFromSpace = surfaceMissingSince.removeValue(forKey: ledge.id) != nil
            if returnedFromSpace {
                restoreGuardUntil[ledge.id] = now + 2.0
            }
            let guarded = (restoreGuardUntil[ledge.id] ?? 0) > now

            if var existing = surfaces[ledge.id] {
                let dx = abs(existing.ledge.x - ledge.x)
                let dy = abs(existing.ledge.y - ledge.y)
                let dw = abs(existing.ledge.width - ledge.width)
                let jump = hypot(dx, dy) >= spaceJumpThreshold || dw > 40
                let nudged = dx > 2.5 || dy > 2.5 || dw > 4.0
                let stable = dx < 3 && dy < 3 && dw < 4

                // During Space swipe windows slide across the display. Following those
                // intermediate frames makes drifts "swim" the wrong way. Freeze until
                // the window is stable again, then snap the saved pile onto it.
                if inSpaceCooldown && !ledge.isDock {
                    if returnedFromSpace || guarded || stable {
                        existing.resize(to: ledge, cellWidth: cellWidth)
                        existing.taperEdges()
                        surfaces[ledge.id] = existing
                        drawIDs.insert(ledge.id)
                    }
                    // else: keep cached ledge+heights, do not draw, do not follow the slide
                    continue
                }

                if jump && (returnedFromSpace || guarded) {
                    // Back on this Space: snap the saved pile onto the live frame.
                    existing.resize(to: ledge, cellWidth: cellWidth)
                    existing.taperEdges()
                    surfaces[ledge.id] = existing
                    drawIDs.insert(ledge.id)
                    markDriftDirty()
                } else if jump {
                    // Lone teleport (rare): reattach without dumping so we don't lock out.
                    existing.resize(to: ledge, cellWidth: cellWidth)
                    existing.taperEdges()
                    surfaces[ledge.id] = existing
                    drawIDs.insert(ledge.id)
                    markDriftDirty()
                } else if nudged && !guarded && !ledge.isDock {
                    // Dragging: dump snow once, knock balls/snowmen loose so they fall
                    // like flakes (do not ride the window), then follow the empty ledge.
                    noSettleUntil[ledge.id] = now + 0.55
                    detachPropsFromMovingLedge(ledge.id)
                    let canDump = now >= (dumpCooldownUntil[ledge.id] ?? 0)
                    if canDump {
                        releaseSurface(existing)
                        dumpCooldownUntil[ledge.id] = now + 0.55
                        var fresh = SettledSurface(ledge: ledge, heights: [], cellWidth: cellWidth)
                        fresh.resize(to: ledge, cellWidth: cellWidth)
                        surfaces[ledge.id] = fresh
                    } else {
                        existing.resize(to: ledge, cellWidth: cellWidth)
                        existing.taperEdges()
                        // Clear any pile that re-formed during the shake.
                        for i in existing.heights.indices { existing.heights[i] = 0 }
                        surfaces[ledge.id] = existing
                    }
                    drawIDs.insert(ledge.id)
                    markDriftDirty()
                } else {
                    if nudged || dw > 0.5 {
                        markDriftDirty()
                    }
                    existing.resize(to: ledge, cellWidth: cellWidth)
                    existing.taperEdges()
                    surfaces[ledge.id] = existing
                    drawIDs.insert(ledge.id)
                }
            } else {
                // Always create a surface for any live ledge (incl. after Space / new window id).
                var fresh = SettledSurface(ledge: ledge, heights: [], cellWidth: cellWidth)
                fresh.resize(to: ledge, cellWidth: cellWidth)
                surfaces[ledge.id] = fresh
                // Don't draw brand-new piles while Spaces are still sliding.
                if !inSpaceCooldown || ledge.isDock {
                    drawIDs.insert(ledge.id)
                }
            }
        }

        if activeSurfaceIDs != drawIDs {
            markDriftDirty()
        }
        activeSurfaceIDs = drawIDs

        // Off-Space windows: keep snow cached; only drop after a long absence.
        let gone = surfaces.keys.filter { !seen.contains($0) }
        for id in gone {
            if surfaces[id]?.ledge.isDock == true { continue }
            let since = surfaceMissingSince[id] ?? now
            surfaceMissingSince[id] = since
            if now - since >= surfaceGrace {
                if let surface = surfaces.removeValue(forKey: id) {
                    releaseSurface(surface)
                }
                surfaceMissingSince.removeValue(forKey: id)
                restoreGuardUntil.removeValue(forKey: id)
                dumpCooldownUntil.removeValue(forKey: id)
                noSettleUntil.removeValue(forKey: id)
            }
        }
    }

    private func activeLedges(from ledges: [SnowLedge]) -> [SnowLedge] {
        ledges.filter { activeSurfaceIDs.contains($0.id) }
    }

    /// Window is being dragged — balls / snowmen leave the ledge and freefall (like flakes).
    private func detachPropsFromMovingLedge(_ id: UInt32) {
        for i in balls.indices where !balls[i].held && balls[i].restingLedge == id {
            balls[i].restingLedge = nil
            balls[i].vy = min(balls[i].vy, -40)
            balls[i].vx *= 0.25
        }
        for i in snowmen.indices where !snowmen[i].held && snowmen[i].restingLedge == id {
            snowmen[i].restingLedge = nil
            snowmen[i].vy = min(snowmen[i].vy, -50)
            snowmen[i].vx *= 0.25
        }
    }

    private func releaseSurface(_ surface: SettledSurface) {
        let ledge = surface.ledge
        // Sparse dump — enough to look like falling snow, not a particle storm.
        for (i, h) in surface.heights.enumerated() where h > 0.5 {
            let count = min(3, Int(h / 4.0) + 1)
            let lx = Float(i) * surface.cellWidth
            // Skip most cells so a fast drag doesn't flood the sim.
            if i % 2 != 0 { continue }
            for _ in 0..<count {
                guard particles.count < maxParticles else { return }
                particles.append(
                    FlakeParticle(
                        x: ledge.x + lx + Float.random(in: -1.5...1.5, using: &rng),
                        y: ledge.y + h * Float.random(in: 0.2...1.0, using: &rng),
                        vx: Float.random(in: -40...40, using: &rng),
                        vy: Float.random(in: -55...(-10), using: &rng),
                        size: Float.random(in: 1.6...3.4, using: &rng),
                        opacity: Float.random(in: 0.55...0.95, using: &rng),
                        wobble: Float.random(in: 0.6...1.6, using: &rng),
                        phase: Float.random(in: 0...(2 * .pi), using: &rng)
                    )
                )
            }
        }
    }

    private func spawn(dt: Float) {
        let screens = screenRects.isEmpty
            ? [(minX: worldMinX, maxX: worldMaxX, minY: worldMinY, maxY: worldMaxY, width: worldWidth)]
            : screenRects

        // Independent quota per monitor — main display must never be starved.
        let perPoint: Float = 0.07 * intensity
        for screen in screens {
            // No snow on monitors covered by a fullscreen / maximized window.
            if snowBlockedScreens.contains(where: {
                abs($0.minX - screen.minX) < 2 && abs($0.maxX - screen.maxX) < 2
            }) {
                continue
            }
            var acc = max(22, perPoint * screen.width) * dt
            // Reuse global accumulator sliced per screen via local loop.
            while acc >= 1, particles.count < maxParticles {
                acc -= 1
                let x = Float.random(in: screen.minX...screen.maxX, using: &rng)
                let y = screen.maxY + Float.random(in: 4...48, using: &rng)
                particles.append(
                    FlakeParticle(
                        x: x,
                        y: y,
                        vx: wind * 0.15 + Float.random(in: -12...12, using: &rng),
                        vy: Float.random(in: -110...(-50), using: &rng) * (0.75 + 0.35 * intensity),
                        size: Float.random(in: 1.6...4.4, using: &rng),
                        opacity: Float.random(in: 0.55...1.0, using: &rng),
                        wobble: Float.random(in: 0.5...1.8, using: &rng),
                        phase: Float.random(in: 0...(2 * .pi), using: &rng)
                    )
                )
            }
        }
    }

    private func integrate(dt: Float, ledges: [SnowLedge]) {
        let sorted = ledges.sorted { $0.y > $1.y }
        // Particles far above every ledge never need the settle scan.
        let ledgeTop = sorted.first.map { $0.y + 30 } ?? worldMinY
        let ledgeBottom = sorted.last.map { $0.y - 4 } ?? worldMaxY
        let now = CACurrentMediaTime()
        var write = 0

        for i in particles.indices {
            var p = particles[i]
            p.phase += dt * 2.2
            p.vx += (wind - p.vx) * dt * 0.15
            p.x += (p.vx + sinf(p.phase) * 14 * p.wobble) * dt
            p.y += p.vy * dt
            p.vy -= 18 * dt

            // Cheap rejects before window tests.
            if isOnBlockedScreen(x: p.x, y: p.y) { continue }
            if p.y < worldMinY - 40 || p.x < worldMinX - 80 || p.x > worldMaxX + 80 {
                continue
            }

            var settled = false
            if p.y <= ledgeTop, p.y >= ledgeBottom {
                for ledge in sorted {
                    if now < (noSettleUntil[ledge.id] ?? 0) { continue }
                    // Far above this ledge — skip (sorted top→bottom, lower ones are farther).
                    if p.y > ledge.y + 36 { continue }
                    guard p.x >= ledge.x, p.x <= ledge.x + ledge.width else { continue }
                    guard var surface = surfaces[ledge.id] else { continue }
                    let localX = p.x - ledge.x
                    let pile = surface.height(atLocalX: localX)
                    let ground = ledge.y + pile
                    // Wide absorb band — flakes that grazed the top must become drift,
                    // not hover as a particle cloud (vy may be briefly upward after a wall hit).
                    let band = max(3.5, 2.0 + pile * 0.08)
                    if p.y <= ground + band, p.y >= ledge.y - 2.5 {
                        guard isTopmost(ledge: ledge, x: p.x, among: sorted) else { continue }
                        surface.addSnow(atLocalX: localX, amount: 0.55 + p.size * 0.22)
                        surfaces[ledge.id] = surface
                        markDriftDirty()
                        settled = true
                        break
                    }
                }
            }

            if settled { continue }

            // Windows are solid walls on the sides / bottom — never bounce off the top.
            for win in bodyOccluders {
                let (wvx, wvy) = windowVelocity(for: win.id, current: win, dt: dt)
                if bouncePointOffWindow(
                    win,
                    x: &p.x,
                    y: &p.y,
                    vx: &p.vx,
                    vy: &p.vy,
                    winVX: wvx,
                    winVY: wvy,
                    restitution: 0.45,
                    friction: 0.18
                ) {
                    if p.vy > 20 { p.vy *= 0.7 }
                    break
                }
            }

            // Inside the window near its top (bounce skipped) — absorb into that ledge.
            if isOccluded(x: p.x, y: p.y) {
                var absorbed = false
                for ledge in sorted {
                    guard p.x >= ledge.x, p.x <= ledge.x + ledge.width else { continue }
                    guard abs(p.y - ledge.y) < 18, var surface = surfaces[ledge.id] else { continue }
                    guard isTopmost(ledge: ledge, x: p.x, among: sorted) else { continue }
                    surface.addSnow(atLocalX: p.x - ledge.x, amount: 0.55 + p.size * 0.22)
                    surfaces[ledge.id] = surface
                    markDriftDirty()
                    absorbed = true
                    break
                }
                if !absorbed { continue }
                continue
            }

            particles[write] = p
            write += 1
        }
        particles.removeSubrange(write..<particles.count)
    }

    private func isTopmost(ledge: SnowLedge, x: Float, among ledges: [SnowLedge]) -> Bool {
        for other in ledges where other.id != ledge.id {
            if other.z < ledge.z,
               x >= other.x, x <= other.x + other.width,
               other.y >= ledge.y - 1
            {
                return false
            }
        }
        return true
    }

    /// True when a front-er window covers this point (CGWindowList: smaller z = closer to front).
    private func isCoveredByFrontWindow(
        x: Float,
        y: Float,
        behindZ: Int,
        ignoring ignoredID: UInt32
    ) -> Bool {
        for win in coverOccluders where win.id != ignoredID {
            guard win.z < behindZ else { continue }
            if x >= win.x - 0.5, x <= win.right + 0.5, y <= win.y + 1.5, y >= win.bottom {
                return true
            }
        }
        return false
    }

    private func isOccluded(x: Float, y: Float) -> Bool {
        // Maximized / fullscreen displays are already in snowBlockedScreens.
        if isOnBlockedScreen(x: x, y: y) { return true }
        for win in bodyOccluders {
            if win.occludes(x: x, y: y) { return true }
        }
        return false
    }

    /// Fullscreen / maximized app content — balls must never linger here.
    private func isInsideMaximized(x: Float, y: Float) -> Bool {
        isOnBlockedScreen(x: x, y: y)
    }

    /// Screen where most of the window's area actually sits (not merely `.first` hit).
    private func hostScreen(
        of win: SnowWindow
    ) -> (minX: Float, maxX: Float, minY: Float, maxY: Float)? {
        var best: (minX: Float, maxX: Float, minY: Float, maxY: Float)?
        var bestArea: Float = 0
        for s in screenRects {
            let overlapX = max(0, min(win.right, s.maxX) - max(win.x, s.minX))
            let overlapY = max(0, min(win.y, s.maxY) - max(win.bottom, s.minY))
            let area = overlapX * overlapY
            if area > bestArea {
                bestArea = area
                best = (minX: s.minX, maxX: s.maxX, minY: s.minY, maxY: s.maxY)
            }
        }
        let winArea = max(1, win.width * win.height)
        // Reject ambiguous / tiny spill onto a neighbor display.
        guard let best, bestArea / winArea > 0.55 else { return nil }
        return best
    }

    private func point(
        _ screen: (minX: Float, maxX: Float, minY: Float, maxY: Float),
        containsX x: Float,
        y: Float
    ) -> Bool {
        x >= screen.minX && x <= screen.maxX && y >= screen.minY && y <= screen.maxY
    }

    private func handleMouseButtons() {
        let pressed = mouseDown && !wasMouseDown
        let released = !mouseDown && wasMouseDown

        if pressed {
            if let sIdx = nearestSnowman(atX: mouseX, y: mouseY, maxDist: 40) {
                snowmen[sIdx].held = true
                snowmen[sIdx].restingLedge = nil
                snowmen[sIdx].vx = 0
                snowmen[sIdx].vy = 0
                heldSnowmanIndex = sIdx
                heldBallIndex = nil
                rollingBallIndex = nil
            } else if let idx = nearestBall(atX: mouseX, y: mouseY, maxDist: 36) {
                detachBall(idx)
                balls[idx].held = true
                balls[idx].vx = 0
                balls[idx].vy = 0
                heldBallIndex = idx
                rollingBallIndex = idx
                heldSnowmanIndex = nil
            }
        }

        if released {
            releaseGrabbedBall()
        }
    }

    private func nearestSnowman(atX x: Float, y: Float, maxDist: Float) -> Int? {
        var best: Int?
        var bestD = maxDist
        for i in snowmen.indices {
            let mid = hypot(snowmen[i].x - x, snowmen[i].midY - y)
            let head = hypot(snowmen[i].x - x, snowmen[i].headY - y)
            let base = hypot(snowmen[i].x - x, snowmen[i].y - y)
            let d = min(mid, min(head, base)) - snowmen[i].midR * 0.3
            if d < bestD {
                bestD = d
                best = i
            }
        }
        return best
    }

    private func releaseGrabbedBall() {
        if let sIdx = heldSnowmanIndex, snowmen.indices.contains(sIdx) {
            snowmen[sIdx].held = false
            snowmen[sIdx].restingLedge = nil
            snowmen[sIdx].vx = mouseVX * 0.55
            snowmen[sIdx].vy = mouseVY * 0.45
        }
        heldSnowmanIndex = nil

        let idx = heldBallIndex ?? rollingBallIndex
        if let idx, balls.indices.contains(idx) {
            balls[idx].held = false
            balls[idx].stackedOn = nil
            balls[idx].restingLedge = nil
            // Fling with cursor velocity — allow upward throws.
            let throwVX = mouseVX * 0.7
            let throwVY = mouseVY * 0.65
            let speed = hypot(throwVX, throwVY)
            balls[idx].vx = throwVX
            balls[idx].vy = throwVY
            // Boost weak flicks so a quick swipe always launches.
            if speed > 80, speed < 220 {
                let boost = 220 / max(speed, 1)
                balls[idx].vx *= boost
                balls[idx].vy *= boost
            } else if speed <= 80 {
                // Slow drop: try stacking / settling instead of a toss.
                balls[idx].vx = throwVX
                balls[idx].vy = min(0, throwVY)
                let snowmenBefore = snowmen.count
                tryStack(ballIndex: idx)
                if snowmen.count == snowmenBefore, balls.indices.contains(idx), balls[idx].stackedOn == nil {
                    settleBallOnLedgeIfNeeded(idx)
                }
            }
            // Fast throw: leave airborne — no immediate settle.
        }
        heldBallIndex = nil
        rollingBallIndex = nil
        formingMass = 0
    }

    /// Soft point sprites fade before the full radius — nest into the pile so the
    /// opaque disc sits on the snow instead of hovering above it.
    private func ballGroundY(ledgeY: Float, pile: Float, radius: Float) -> Float {
        ledgeY + pile + radius * 0.72
    }

    /// True when a ball is close enough to a window/Dock top to land instead of melt.
    private func isNearAnyLedgeTop(
        x: Float,
        y: Float,
        radius: Float,
        ledges: [SnowLedge]
    ) -> Bool {
        let now = CACurrentMediaTime()
        for ledge in ledges {
            if now < (noSettleUntil[ledge.id] ?? 0) { continue }
            guard x >= ledge.x - radius, x <= ledge.x + ledge.width + radius else { continue }
            let localX = max(0, min(ledge.width, x - ledge.x))
            let pile = surfaces[ledge.id]?.height(atLocalX: localX) ?? 0
            let ground = ballGroundY(ledgeY: ledge.y, pile: pile, radius: radius)
            if y <= ground + max(14, radius * 1.3), y >= ledge.y - max(12, radius) {
                return true
            }
        }
        return false
    }

    /// Flying snowball knocks another ball off its ledge / stack.
    @discardableResult
    private func knockBallsIfHit(byBall ballIndex: Int) -> Bool {
        guard balls.indices.contains(ballIndex) else { return false }
        let speed = hypot(balls[ballIndex].vx, balls[ballIndex].vy)
        guard speed > 80 else { return false }
        var hit = false
        let b = balls[ballIndex]
        for j in balls.indices where j != ballIndex && !balls[j].held {
            if isParkedOnOtherSpace(restingLedge: balls[j].restingLedge) { continue }
            let dx = balls[j].x - b.x
            let dy = balls[j].y - b.y
            let dist = hypot(dx, dy)
            let minDist = b.radius + balls[j].radius
            guard dist > 0.1, dist < minDist * 1.05 else { continue }

            let nx = dx / dist
            let ny = dy / dist
            // Separate so they don't stick together.
            let overlap = minDist - dist
            balls[ballIndex].x -= nx * overlap * 0.55
            balls[ballIndex].y -= ny * overlap * 0.55
            balls[j].x += nx * overlap * 0.55
            balls[j].y += ny * overlap * 0.55

            // Transfer momentum — knock target free.
            let push = speed * 0.75
            balls[j].vx += nx * push + balls[ballIndex].vx * 0.25
            balls[j].vy += ny * push + max(40, balls[ballIndex].vy * 0.35)
            balls[j].restingLedge = nil
            detachBall(j)

            balls[ballIndex].vx *= 0.55
            balls[ballIndex].vy *= 0.55
            balls[ballIndex].restingLedge = nil
            hit = true
        }
        return hit
    }

    /// Hit a snowman with a flying snowball → smash into three free balls.
    @discardableResult
    private func smashSnowmanIfHit(byBall ballIndex: Int) -> Bool {
        guard balls.indices.contains(ballIndex), balls.count < maxBalls - 2 else { return false }
        let b = balls[ballIndex]
        let speed = hypot(b.vx, b.vy)
        guard speed > 120 else { return false }

        var hit: Int?
        var hitD = b.radius + 40
        for sIdx in snowmen.indices {
            if snowmen[sIdx].held { continue }
            if isParkedOnOtherSpace(restingLedge: snowmen[sIdx].restingLedge) { continue }
            let s = snowmen[sIdx]
            let dBase = hypot(b.x - s.x, b.y - s.y) - (b.radius + s.baseR)
            let dMid = hypot(b.x - s.x, b.y - s.midY) - (b.radius + s.midR)
            let dHead = hypot(b.x - s.x, b.y - s.headY) - (b.radius + s.headR)
            let d = min(dBase, min(dMid, dHead))
            if d < hitD {
                hitD = d
                hit = sIdx
            }
        }
        guard let sIdx = hit, hitD < 6 else { return false }
        let s = snowmen[sIdx]
        let nx = b.vx / speed
        let ny = b.vy / speed

        // Scatter three body parts.
        let parts: [(Float, Float, Float, Float)] = [
            (s.x, s.y, s.baseMass, 0),
            (s.x, s.midY, s.midMass, 0.4),
            (s.x, s.headY, s.headMass, 0.8),
        ]
        for (px, py, mass, kick) in parts where balls.count < maxBalls {
            let side = Float.random(in: -1...1, using: &rng)
            balls.append(
                Snowball(
                    x: px + side * 4,
                    y: py + 4,
                    vx: nx * (120 + kick * 80) + side * 90,
                    vy: ny * (80 + kick * 60) + Float.random(in: 40...140, using: &rng),
                    mass: mass,
                    held: false,
                    stackedOn: nil,
                    restingLedge: nil
                )
            )
        }

        // Projectile bounces off / loses energy.
        balls[ballIndex].vx = -nx * speed * 0.35 + Float.random(in: -40...40, using: &rng)
        balls[ballIndex].vy = abs(ny) * speed * 0.25 + 60
        balls[ballIndex].restingLedge = nil
        balls[ballIndex].mass = max(4, balls[ballIndex].mass * 0.7)

        snowmen.remove(at: sIdx)
        if let h = heldSnowmanIndex {
            if h == sIdx { heldSnowmanIndex = nil }
            else if h > sIdx { heldSnowmanIndex = h - 1 }
        }
        return true
    }

    private func settleBallOnLedgeIfNeeded(_ index: Int) {
        guard balls.indices.contains(index) else { return }
        let ledges = occluders.compactMap { win -> SnowLedge? in
            guard win.canAccumulate, activeSurfaceIDs.contains(win.id) else { return nil }
            return win.ledge
        }
        for ledge in ledges.sorted(by: { $0.y > $1.y }) {
            guard balls[index].x >= ledge.x, balls[index].x <= ledge.x + ledge.width else { continue }
            let pile = surfaces[ledge.id]?.height(atLocalX: balls[index].x - ledge.x) ?? 0
            let ground = ballGroundY(ledgeY: ledge.y, pile: pile, radius: balls[index].radius)
            // Must be near the ledge — never teleport up/down onto a distant window.
            guard abs(balls[index].y - ground) <= balls[index].radius * 2.5 else { continue }
            balls[index].y = ground
            balls[index].vy = 0
            balls[index].vx *= 0.5
            balls[index].restingLedge = ledge.id
            return
        }
    }

    private func nearestBall(atX x: Float, y: Float, maxDist: Float) -> Int? {
        var best: Int?
        var bestD = maxDist
        for i in balls.indices {
            let d = hypot(balls[i].x - x, balls[i].y - y) - balls[i].radius * 0.35
            if d < bestD {
                bestD = d
                best = i
            }
        }
        return best
    }

    private func detachBall(_ index: Int) {
        guard balls.indices.contains(index) else { return }
        let id = index
        // Anyone stacked on this ball falls free.
        for i in balls.indices where balls[i].stackedOn == id {
            balls[i].stackedOn = nil
            balls[i].restingLedge = nil
        }
        balls[index].stackedOn = nil
        balls[index].restingLedge = nil
    }

    private func tryStack(ballIndex: Int) {
        guard balls.indices.contains(ballIndex) else { return }
        let a = balls[ballIndex]
        var best: Int?
        var bestScore: Float = .greatestFiniteMagnitude

        for j in balls.indices where j != ballIndex {
            let b = balls[j]
            guard !b.held else { continue }
            // Prefer smaller/similar on larger; allow a bit of slack for playability.
            guard a.radius <= b.radius * 1.35 else { continue }
            // Must be above the other ball's center.
            guard a.y > b.y + b.radius * 0.15 else { continue }
            let dx = abs(a.x - b.x)
            let targetY = stackedBallY(baseY: b.y, baseR: b.radius, topR: a.radius)
            let dy = abs(a.y - targetY)
            let maxDx = max(14, b.radius * 1.15)
            let maxDy = max(22, a.radius * 2.8)
            guard dx < maxDx, dy < maxDy else { continue }
            // Prefer the highest ball under the drop (stack on top of an existing stack).
            let score = dx + dy * 0.55 - b.y * 0.02
            if score < bestScore {
                bestScore = score
                best = j
            }
        }

        if let base = best {
            // Avoid cycles.
            var cursor: Int? = base
            var hops = 0
            while let c = cursor, hops < 8 {
                if c == ballIndex { return }
                cursor = balls[c].stackedOn
                hops += 1
            }
            balls[ballIndex].stackedOn = base
            balls[ballIndex].restingLedge = nil
            balls[ballIndex].vx = 0
            balls[ballIndex].vy = 0
            let b = balls[base]
            balls[ballIndex].x = b.x
            balls[ballIndex].y = stackedBallY(
                baseY: b.y,
                baseR: b.radius,
                topR: balls[ballIndex].radius
            )
            // Keep the whole stack planted on the window.
            pinStackRootToLedge(base)
            promoteSnowmanIfReady(topIndex: ballIndex)
        }
    }

    /// Soft ball sprites fade before the math radius — nest so stacked balls touch.
    private func stackedBallY(baseY: Float, baseR: Float, topR: Float) -> Float {
        baseY + (baseR + topR) * 0.68
    }

    /// Walk down to the free root of a stack and glue it onto its ledge.
    private func pinStackRootToLedge(_ index: Int) {
        var root = index
        var hops = 0
        while let under = balls[root].stackedOn, balls.indices.contains(under), hops < 8 {
            root = under
            hops += 1
        }
        guard balls.indices.contains(root) else { return }
        balls[root].vx = 0
        balls[root].vy = 0
        settleBallOnLedgeIfNeeded(root)
        // If still no ledge, try a generous snap under the stack.
        if balls[root].restingLedge == nil {
            settleBallOnLedgeGenerous(root)
        }
    }

    private func settleBallOnLedgeGenerous(_ index: Int) {
        guard balls.indices.contains(index) else { return }
        let ledges = occluders.compactMap { win -> SnowLedge? in
            guard win.canAccumulate, activeSurfaceIDs.contains(win.id) else { return nil }
            return win.ledge
        }
        for ledge in ledges.sorted(by: { $0.y > $1.y }) {
            guard balls[index].x >= ledge.x - 6, balls[index].x <= ledge.x + ledge.width + 6 else { continue }
            let pile = surfaces[ledge.id]?.height(atLocalX: balls[index].x - ledge.x) ?? 0
            let ground = ballGroundY(ledgeY: ledge.y, pile: pile, radius: balls[index].radius)
            guard abs(balls[index].y - ground) <= balls[index].radius * 3.5 else { continue }
            balls[index].y = ground
            balls[index].vy = 0
            balls[index].vx = 0
            balls[index].restingLedge = ledge.id
            return
        }
    }

    private func ballSupportsStack(_ index: Int) -> Bool {
        balls.contains { $0.stackedOn == index }
    }

    /// bottom → mid → top stack of 3 becomes a snowman.
    private func promoteSnowmanIfReady(topIndex: Int) {
        guard balls.indices.contains(topIndex), let mid = balls[topIndex].stackedOn, balls.indices.contains(mid) else { return }
        guard let base = balls[mid].stackedOn, balls.indices.contains(base) else { return }
        // Exactly 3 high: base has nothing under it.
        guard balls[base].stackedOn == nil else { return }
        // Nobody else stacked on top of the head.
        guard !balls.contains(where: { $0.stackedOn == topIndex }) else { return }

        // Keep visual size order: heaviest = base, lightest = head.
        let ordered = [balls[base], balls[mid], balls[topIndex]].sorted { $0.mass > $1.mass }
        // Free body — optional soft rest on the same ledge the stack was on, no pin.
        var snowman = Snowman(
            x: balls[base].x,
            y: balls[base].y,
            vx: 0,
            vy: 0,
            baseMass: ordered[0].mass,
            midMass: ordered[1].mass,
            headMass: ordered[2].mass,
            held: false,
            restingLedge: nil
        )
        if let lid = balls[base].restingLedge,
           let surface = surfaces[lid],
           activeSurfaceIDs.contains(lid)
        {
            let ledge = surface.ledge
            let local = max(0, min(ledge.width, snowman.x - ledge.x))
            let pile = surface.height(atLocalX: local)
            let ground = ballGroundY(ledgeY: ledge.y, pile: pile, radius: snowman.baseR)
            if abs(snowman.y - ground) <= snowman.baseR * 1.8 {
                snowman.y = ground
                snowman.restingLedge = lid
            }
        }

        snowmen.append(snowman)

        let remove = Set([base, mid, topIndex])
        if let h = heldBallIndex, remove.contains(h) { heldBallIndex = nil }
        if let r = rollingBallIndex, remove.contains(r) { rollingBallIndex = nil }

        var next: [Snowball] = []
        var map = [Int?](repeating: nil, count: balls.count)
        for i in balls.indices where !remove.contains(i) {
            map[i] = next.count
            next.append(balls[i])
        }
        for i in next.indices {
            if let s = next[i].stackedOn {
                next[i].stackedOn = (s < map.count) ? map[s] : nil
            }
        }
        balls = next
    }

    private func applyMouse(dt: Float) {
        let flakeRadius: Float = 36
        let flakeRadius2 = flakeRadius * flakeRadius
        let speed = hypot(mouseVX, mouseVY)
        rollCooldown = max(0, rollCooldown - dt)

        for i in particles.indices {
            guard !isOccluded(x: particles[i].x, y: particles[i].y) else { continue }
            let dx = particles[i].x - mouseX
            let dy = particles[i].y - mouseY
            let d2 = dx * dx + dy * dy
            guard d2 < flakeRadius2, d2 > 0.01 else { continue }
            let d = sqrtf(d2)
            let nx = dx / d
            let ny = dy / d
            let push = (1 - d / flakeRadius) * (38 + min(120, speed * 0.35))
            particles[i].vx += nx * push * 0.08
            particles[i].vy += ny * push * 0.08
            if speed > 40 {
                particles[i].vy += 12 * (1 - d / flakeRadius)
            }
        }

        if mouseDown, let sIdx = heldSnowmanIndex, snowmen.indices.contains(sIdx) {
            snowmen[sIdx].held = true
            snowmen[sIdx].restingLedge = nil
            snowmen[sIdx].x = mouseX
            snowmen[sIdx].y = mouseY - snowmen[sIdx].baseR
            snowmen[sIdx].vx = 0
            snowmen[sIdx].vy = 0
            return
        }

        // While button is held, ball sticks to the cursor — never "slips off".
        if mouseDown, let idx = activeGrabIndex() {
            pinBallToMouse(idx)
            // Pack only while actually rolling across a drift — slow growth.
            if speed > 3 {
                growHeldBallFromDrifts(
                    ballIndex: idx,
                    reach: 20 + balls[idx].radius * 0.7,
                    dt: dt
                )
            }
            return
        }

        if !mouseDown {
            formingMass = 0
        }

        let rolling = mouseDown && speed > 6
        var brushedDrift = false
        // Cursor near the pile top — hover alone should shove snow (no click needed).
        let driftReach: Float = 28

        for (id, var surface) in surfaces {
            guard activeSurfaceIDs.contains(id) else { continue }
            let ledge = surface.ledge
            guard mouseX >= ledge.x - 10, mouseX <= ledge.x + ledge.width + 10 else { continue }
            let localX = mouseX - ledge.x
            let clampedLocal = max(0, min(ledge.width, localX))
            let pile = surface.height(atLocalX: clampedLocal)
            let ground = ledge.y + pile
            let dy = mouseY - ground
            guard dy > -10, dy < driftReach, pile > 0.35 else {
                surfaces[id] = surface
                continue
            }

            brushedDrift = true

            if mouseDown {
                // Held button: pack snow into a ball — do not sweep the drift away.
                if rolling, pile > 1.0 {
                    let scoopRadius = min(7, 3.5 + pile * 0.12)
                    let scooped = surface.scoop(atLocalX: clampedLocal, radius: scoopRadius)
                    let gained = scooped * 0.18
                    if gained > 0.04 {
                        markDriftDirty()
                        growOrSpawnBall(
                            mass: gained,
                            x: mouseX,
                            y: max(mouseY, ground + 8),
                            vx: mouseVX * 0.2,
                            vy: mouseVY * 0.1
                        )
                    }
                }
            } else if speed > 6 {
                // Free cursor: sweep the pile sideways (and off the window edges).
                let spill = surface.push(
                    atLocalX: clampedLocal,
                    forceX: mouseVX,
                    forceY: mouseVY
                )
                if spill.left > 0.01 || spill.right > 0.01 {
                    markDriftDirty()
                }
                spillOffEdge(
                    surface: surface,
                    amount: spill.left,
                    side: -1,
                    outwardSpeed: abs(mouseVX)
                )
                spillOffEdge(
                    surface: surface,
                    amount: spill.right,
                    side: 1,
                    outwardSpeed: abs(mouseVX)
                )

                let edgeZone: Float = 26
                if speed > 10, localX < edgeZone || localX > ledge.width - edgeZone {
                    let side: Float = localX < edgeZone ? -1 : 1
                    let edgeLocal = side < 0 ? 0 : ledge.width
                    let scraped = surface.scoop(atLocalX: edgeLocal, radius: 18)
                    if scraped > 0.01 { markDriftDirty() }
                    spillOffEdge(
                        surface: surface,
                        amount: scraped,
                        side: side,
                        outwardSpeed: max(40, abs(mouseVX))
                    )
                }
            }

            surfaces[id] = surface
        }

        if mouseDown, !brushedDrift, rollingBallIndex == nil, heldBallIndex == nil {
            formingMass = max(0, formingMass - dt * 4)
        }
    }

    private func activeGrabIndex() -> Int? {
        if let idx = heldBallIndex, balls.indices.contains(idx) { return idx }
        if let idx = rollingBallIndex, balls.indices.contains(idx) { return idx }
        return nil
    }

    private func pinBallToMouse(_ index: Int) {
        guard balls.indices.contains(index) else { return }
        balls[index].held = true
        balls[index].x = mouseX
        balls[index].y = mouseY
        balls[index].vx = 0
        balls[index].vy = 0
        balls[index].stackedOn = nil
        balls[index].restingLedge = nil
        heldBallIndex = index
        rollingBallIndex = index
    }

    /// Pack drift snow into a held ball. Needs a long roll to get meaningfully bigger.
    private func growHeldBallFromDrifts(ballIndex: Int, reach: Float, dt: Float) {
        guard balls.indices.contains(ballIndex) else { return }
        var gainedTotal: Float = 0
        let r = balls[ballIndex].radius
        let speed = hypot(mouseVX, mouseVY)
        let travel = min(18, speed * max(dt, 1.0 / 120.0))

        for (id, var surface) in surfaces {
            guard activeSurfaceIDs.contains(id) else { continue }
            let ledge = surface.ledge
            guard mouseX >= ledge.x - r - 8, mouseX <= ledge.x + ledge.width + r + 8 else { continue }
            let localX = max(0, min(ledge.width, mouseX - ledge.x))
            let pile = surface.height(atLocalX: localX)
            guard pile > 0.6 else { continue }
            let ground = ledge.y + pile
            guard mouseY >= ground - r * 0.4, mouseY <= ground + max(reach, r * 0.85) else { continue }

            // Modest scoop — size comes from distance traveled, not one swipe.
            let scoopRadius = min(9, 3.5 + r * 0.18)
            let scooped = surface.scoop(atLocalX: localX, radius: scoopRadius)
            gainedTotal += scooped * 0.22
            if travel > 0.8, scooped > 0.04 {
                gainedTotal += travel * 0.08
            }
            surfaces[id] = surface
        }

        guard gainedTotal > 0.03 else { return }
        markDriftDirty()
        balls[ballIndex].mass = min(ballMaxMass, balls[ballIndex].mass + gainedTotal)
    }

    private func growOrSpawnBall(mass: Float, x: Float, y: Float, vx: Float, vy: Float) {
        guard mouseDown else { return }

        if let idx = activeGrabIndex() {
            balls[idx].mass = min(ballMaxMass, balls[idx].mass + mass)
            pinBallToMouse(idx)
            return
        }

        formingMass += mass
        guard formingMass >= ballSpawnThreshold else { return }

        if let near = nearestBall(atX: x, y: y, maxDist: 28), !balls[near].held {
            balls[near].mass = min(ballMaxMass, balls[near].mass + formingMass * 0.4)
            detachBall(near)
            pinBallToMouse(near)
            formingMass = 0
            return
        }

        guard balls.count < maxBalls, rollCooldown <= 0 else { return }
        let initial = min(ballMaxMass, max(8, formingMass * 0.45))
        balls.append(
            Snowball(
                x: x,
                y: y,
                vx: 0,
                vy: 0,
                mass: initial,
                held: true,
                stackedOn: nil,
                restingLedge: nil
            )
        )
        let idx = balls.count - 1
        pinBallToMouse(idx)
        formingMass = 0
        rollCooldown = 0.2
    }

    private func updateBalls(dt: Float, ledges: [SnowLedge]) {
        let sorted = ledges.sorted { $0.y > $1.y }
        let ledgeByID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })

        // Pass 1: free roots only (stacked children follow in pass 2).
        for i in balls.indices {
            if balls[i].held { continue }
            if balls[i].stackedOn != nil { continue }

            // Parked with a window on another Space — freeze, don't draw as a ghost.
            if isParkedOnOtherSpace(restingLedge: balls[i].restingLedge) {
                balls[i].vx = 0
                balls[i].vy = 0
                continue
            }
            // Ledge was destroyed — drop.
            if let lid = balls[i].restingLedge, surfaces[lid] == nil {
                balls[i].restingLedge = nil
            }

            let supportsStack = ballSupportsStack(i)
            let r = balls[i].radius

            let flightSpeed = hypot(balls[i].vx, balls[i].vy)
            let inFlight = flightSpeed > 90

            // Resting ball sticks to a still ledge — never ride a window being dragged.
            if let lid = balls[i].restingLedge, let ledge = ledgeByID[lid] {
                let ledgeMoving = CACurrentMediaTime() < (noSettleUntil[lid] ?? 0)
                if ledgeMoving {
                    balls[i].restingLedge = nil
                } else {
                    let onLedge = balls[i].x >= ledge.x - 2 && balls[i].x <= ledge.x + ledge.width + 2
                    if onLedge && !inFlight {
                        balls[i].x = max(ledge.x + 3, min(ledge.x + ledge.width - 3, balls[i].x + balls[i].vx * dt))
                        let local2 = max(0, min(ledge.width, balls[i].x - ledge.x))
                        let pile2 = surfaces[lid]?.height(atLocalX: local2) ?? 0
                        balls[i].y = ballGroundY(ledgeY: ledge.y, pile: pile2, radius: r)
                        balls[i].vy = 0
                        balls[i].vx *= supportsStack ? 0.5 : 0.88
                        if abs(balls[i].vx) < 6 || supportsStack { balls[i].vx = 0 }
                        continue
                    }
                    balls[i].restingLedge = nil
                }
            }

            // Never linger inside a fullscreen app — melt immediately.
            if isInsideMaximized(x: balls[i].x, y: balls[i].y) {
                balls[i].mass = 0
                continue
            }

            balls[i].vy -= 520 * dt
            balls[i].vx *= inFlight ? 0.995 : (supportsStack ? 0.92 : 0.985)
            let steps = 4
            let stepDt = dt / Float(steps)
            var rested = false
            for _ in 0..<steps {
                let yBefore = balls[i].y
                balls[i].x += balls[i].vx * stepDt
                balls[i].y += balls[i].vy * stepDt

                if isInsideMaximized(x: balls[i].x, y: balls[i].y) {
                    balls[i].mass = 0
                    rested = true
                    break
                }

                let stepSpeed = hypot(balls[i].vx, balls[i].vy)

                // Land on window tops first.
                for ledge in sorted {
                    if CACurrentMediaTime() < (noSettleUntil[ledge.id] ?? 0) { continue }
                    let pad = max(6, r * 0.45)
                    guard balls[i].x >= ledge.x - pad, balls[i].x <= ledge.x + ledge.width + pad else {
                        continue
                    }
                    let localX = max(0, min(ledge.width, balls[i].x - ledge.x))
                    let pile = surfaces[ledge.id]?.height(atLocalX: localX) ?? 0
                    let ground = ballGroundY(ledgeY: ledge.y, pile: pile, radius: r)
                    // Still rising hard past the seat — let it arc over.
                    if balls[i].vy > 50, balls[i].y > ground + r * 0.5 { continue }
                    // Tunnel-proof catch: any descent that crosses / overlaps the seat.
                    let catchPad = max(8, abs(balls[i].vy) * stepDt + r * 0.35)
                    let crossed = balls[i].vy <= 20
                        && yBefore >= ground - 2
                        && balls[i].y <= ground + catchPad
                    let overlapping = balls[i].vy <= 40
                        && balls[i].y <= ground + max(10, r * 1.1)
                        && balls[i].y >= ground - max(10, r * 0.95)
                    if crossed || overlapping {
                        balls[i].y = ground
                        balls[i].vy = 0
                        balls[i].vx *= supportsStack ? 0.5 : 0.82
                        if supportsStack || abs(balls[i].vx) < 12 { balls[i].vx = 0 }
                        balls[i].restingLedge = ledge.id
                        rested = true
                        break
                    }
                }
                if rested { break }

                // Sides / bottom / face of windows — bounce like a wall.
                var bounced = false
                for win in bodyOccluders {
                    let (wvx, wvy) = windowVelocity(for: win.id, current: win, dt: dt)
                    var x = balls[i].x
                    var y = balls[i].y
                    var vx = balls[i].vx
                    var vy = balls[i].vy
                    if bounceCircleOffWindow(
                        win,
                        x: &x,
                        y: &y,
                        vx: &vx,
                        vy: &vy,
                        radius: r,
                        winVX: wvx,
                        winVY: wvy,
                        restitution: 0.58,
                        friction: 0.22
                    ) {
                        balls[i].x = x
                        balls[i].y = y
                        balls[i].vx = vx
                        balls[i].vy = vy
                        balls[i].restingLedge = nil
                        bounced = true
                        break
                    }
                }
                if bounced { continue }

                // Smash a snowman if this snowball is flying fast enough.
                if stepSpeed > 100, smashSnowmanIfHit(byBall: i) {
                    rested = true
                    break
                }

                // Knock other snowballs when flying.
                if stepSpeed > 80, knockBallsIfHit(byBall: i) {
                    // keep flying after impact
                }
            }
            if balls[i].mass <= 1 { continue }
            if !rested { balls[i].restingLedge = nil }

            // Soft separate when both are slow (not a throw impact).
            if !supportsStack, !inFlight {
                for j in balls.indices where j != i && balls[j].stackedOn == nil && !balls[j].held {
                    if ballSupportsStack(j) { continue }
                    if isParkedOnOtherSpace(restingLedge: balls[j].restingLedge) { continue }
                    let dx = balls[j].x - balls[i].x
                    let dy = balls[j].y - balls[i].y
                    let dist = hypot(dx, dy)
                    let minDist = balls[i].radius + balls[j].radius
                    if dist > 0.1, dist < minDist {
                        let nx = dx / dist
                        let ny = dy / dist
                        let overlap = minDist - dist
                        balls[i].x -= nx * overlap * 0.5
                        balls[i].y -= ny * overlap * 0.5
                        balls[j].x += nx * overlap * 0.5
                        balls[j].y += ny * overlap * 0.5
                    }
                }
            }

            if balls[i].y < worldMinY - 80 {
                balls[i].mass = 0
                continue
            }

            // Fast horizontal exit → hand off to a LAN peer (or melt).
            if lanHandoffEnabled, !supportsStack, flightSpeed > 120 {
                let rExit = balls[i].radius
                if balls[i].x < worldMinX - rExit, balls[i].vx < -60 {
                    let h = max(1, worldMaxY - worldMinY)
                    let normY = min(1, max(0, (balls[i].y - worldMinY) / h))
                    pendingEdgeExits.append(
                        OutboundSnowball(
                            edge: .left,
                            normY: normY,
                            vx: balls[i].vx,
                            vy: balls[i].vy,
                            mass: balls[i].mass
                        )
                    )
                    balls[i].mass = 0
                    continue
                }
                if balls[i].x > worldMaxX + rExit, balls[i].vx > 60 {
                    let h = max(1, worldMaxY - worldMinY)
                    let normY = min(1, max(0, (balls[i].y - worldMinY) / h))
                    pendingEdgeExits.append(
                        OutboundSnowball(
                            edge: .right,
                            normY: normY,
                            vx: balls[i].vx,
                            vy: balls[i].vy,
                            mass: balls[i].mass
                        )
                    )
                    balls[i].mass = 0
                    continue
                }
            }
        }

        // Pass 2: stacked balls follow their base after roots have moved.
        for i in balls.indices {
            if balls[i].held { continue }
            guard let base = balls[i].stackedOn, balls.indices.contains(base) else { continue }
            let b = balls[base]
            balls[i].x = b.x
            balls[i].y = stackedBallY(baseY: b.y, baseR: b.radius, topR: balls[i].radius)
            balls[i].vx = 0
            balls[i].vy = 0
            balls[i].restingLedge = nil
        }

        // Compact destroyed balls; fix indices.
        var map = [Int?](repeating: nil, count: balls.count)
        var next: [Snowball] = []
        next.reserveCapacity(balls.count)
        for i in balls.indices where balls[i].mass > 1 {
            map[i] = next.count
            next.append(balls[i])
        }
        for i in next.indices {
            if let s = next[i].stackedOn {
                next[i].stackedOn = (s < map.count) ? map[s] : nil
            }
        }
        if let h = heldBallIndex {
            heldBallIndex = (h < map.count) ? map[h] : nil
        }
        if let r = rollingBallIndex {
            rollingBallIndex = (r < map.count) ? map[r] : nil
        }
        balls = next
    }

    private func updateSnowmen(dt: Float, ledges: [SnowLedge]) {
        let sorted = ledges.sorted { $0.y > $1.y }
        for i in snowmen.indices {
            if snowmen[i].held { continue }

            if isParkedOnOtherSpace(restingLedge: snowmen[i].restingLedge) {
                snowmen[i].vx = 0
                snowmen[i].vy = 0
                continue
            }
            if let lid = snowmen[i].restingLedge, surfaces[lid] == nil {
                snowmen[i].restingLedge = nil
            }
            if isInsideMaximized(x: snowmen[i].x, y: snowmen[i].y) {
                snowmen[i].baseMass = 0
                continue
            }

            // Free physics like balls — can be thrown off a ledge, no hard pin.
            snowmen[i].vy -= 620 * dt
            snowmen[i].vx *= 0.988
            let steps = 4
            let stepDt = dt / Float(steps)
            var rested = false
            for _ in 0..<steps {
                let yBefore = snowmen[i].y
                snowmen[i].x += snowmen[i].vx * stepDt
                snowmen[i].y += snowmen[i].vy * stepDt

                if isInsideMaximized(x: snowmen[i].x, y: snowmen[i].y) {
                    snowmen[i].baseMass = 0
                    rested = true
                    break
                }

                // Fast throw: skip soft sitting so he can leave the ledge.
                let fast = hypot(snowmen[i].vx, snowmen[i].vy) > 120

                for ledge in sorted {
                    if CACurrentMediaTime() < (noSettleUntil[ledge.id] ?? 0) { continue }
                    let pad = snowmen[i].baseR * 0.35
                    guard snowmen[i].x >= ledge.x - pad, snowmen[i].x <= ledge.x + ledge.width + pad else { continue }
                    let pile = surfaces[ledge.id]?.height(atLocalX: snowmen[i].x - ledge.x) ?? 0
                    let ground = ballGroundY(ledgeY: ledge.y, pile: pile, radius: snowmen[i].baseR)
                    let crossed = yBefore >= ground - 2 && snowmen[i].y <= ground + 3 && snowmen[i].vy <= 0
                    let sitting = !fast
                        && abs(snowmen[i].y - ground) <= max(4, snowmen[i].baseR * 0.5)
                        && snowmen[i].vy <= 50
                        && abs(snowmen[i].vx) < 80
                    let hoverFix = !fast
                        && snowmen[i].y > ground
                        && snowmen[i].y <= ground + snowmen[i].baseR * 1.1
                        && snowmen[i].vy <= 30
                    if crossed || sitting || hoverFix {
                        snowmen[i].y = ground
                        snowmen[i].vy = 0
                        snowmen[i].vx *= 0.82
                        snowmen[i].restingLedge = ledge.id
                        rested = true
                        break
                    }
                }
                if rested { break }

                for win in bodyOccluders {
                    let (wvx, wvy) = windowVelocity(for: win.id, current: win, dt: dt)
                    var x = snowmen[i].x
                    var y = snowmen[i].y
                    var vx = snowmen[i].vx
                    var vy = snowmen[i].vy
                    if bounceCircleOffWindow(
                        win,
                        x: &x,
                        y: &y,
                        vx: &vx,
                        vy: &vy,
                        radius: snowmen[i].baseR,
                        winVX: wvx,
                        winVY: wvy,
                        restitution: 0.42,
                        friction: 0.28
                    ) {
                        snowmen[i].x = x
                        snowmen[i].y = y
                        snowmen[i].vx = vx
                        snowmen[i].vy = vy
                        snowmen[i].restingLedge = nil
                        break
                    }
                }
            }
            if !rested { snowmen[i].restingLedge = nil }

            // Slide off the ends of a ledge while resting.
            if let lid = snowmen[i].restingLedge,
               let ledge = sorted.first(where: { $0.id == lid }),
               snowmen[i].x < ledge.x + 2 || snowmen[i].x > ledge.x + ledge.width - 2
            {
                snowmen[i].restingLedge = nil
            }

            if snowmen[i].y < worldMinY - 120 {
                snowmen[i].baseMass = 0
            }
        }

        var map = [Int?](repeating: nil, count: snowmen.count)
        var next: [Snowman] = []
        for i in snowmen.indices where snowmen[i].baseMass > 1 {
            map[i] = next.count
            next.append(snowmen[i])
        }
        if let h = heldSnowmanIndex {
            heldSnowmanIndex = (h < map.count) ? map[h] : nil
        }
        snowmen = next
    }

    private func spillOffEdge(surface: SettledSurface, amount: Float, side: Float, outwardSpeed: Float) {
        guard amount > 0.15 else { return }
        let ledge = surface.ledge
        let edgeX = side < 0 ? ledge.x - 2 : ledge.x + ledge.width + 2
        let n = min(14, Int(amount * 1.4) + 1)
        for _ in 0..<n where particles.count < maxParticles {
            let h = surface.height(atLocalX: side < 0 ? 0 : ledge.width)
            particles.append(
                FlakeParticle(
                    x: edgeX + Float.random(in: -3...3, using: &rng),
                    y: ledge.y + max(h, 2) + Float.random(in: 0...6, using: &rng),
                    vx: side * (35 + outwardSpeed * 0.15) + Float.random(in: -15...15, using: &rng),
                    vy: Float.random(in: -55...(-8), using: &rng),
                    size: Float.random(in: 1.4...3.3, using: &rng),
                    opacity: Float.random(in: 0.5...0.95, using: &rng),
                    wobble: Float.random(in: 0.6...1.5, using: &rng),
                    phase: Float.random(in: 0...(2 * .pi), using: &rng)
                )
            )
        }
    }

    private func buildUploadBuffers() {
        // Particles were already culled for occlusion / blocked screens in integrate;
        // mouse-spawned flakes are rare and live at most one frame over chrome.
        flakeUpload.removeAll(keepingCapacity: true)
        flakeUpload.reserveCapacity(particles.count)
        for p in particles {
            flakeUpload.append(SIMD4<Float>(p.x, p.y, p.size, p.opacity))
        }

        ballUpload.removeAll(keepingCapacity: true)
        decorUpload.removeAll(keepingCapacity: true)
        ballUpload.reserveCapacity(balls.count + snowmen.count * 3)
        for b in balls {
            if !b.held {
                if isParkedOnOtherSpace(restingLedge: b.restingLedge) { continue }
                if isOnBlockedScreen(x: b.x, y: b.y) { continue }
                // Never draw over fullscreen / window content.
                if isInsideMaximized(x: b.x, y: b.y) { continue }
                if isOccluded(x: b.x, y: b.y) { continue }
                if let lid = b.restingLedge, let surface = surfaces[lid],
                   isCoveredByFrontWindow(x: b.x, y: b.y, behindZ: surface.ledge.z, ignoring: lid)
                {
                    continue
                }
            }
            let alpha: Float = b.held ? 1.0 : 0.98
            // z = diameter in points (shader multiplies by backing scale).
            ballUpload.append(SIMD4<Float>(b.x, b.y, b.radius * 2.0, alpha))
        }

        propVertices.removeAll(keepingCapacity: true)
        propColors.removeAll(keepingCapacity: true)
        propTriCounts.removeAll(keepingCapacity: true)
        for s in snowmen {
            if !s.held {
                if isParkedOnOtherSpace(restingLedge: s.restingLedge) { continue }
                if isOnBlockedScreen(x: s.x, y: s.y) { continue }
                if isOccluded(x: s.x, y: s.y) { continue }
                if let lid = s.restingLedge, let surface = surfaces[lid],
                   isCoveredByFrontWindow(x: s.x, y: s.y, behindZ: surface.ledge.z, ignoring: lid)
                {
                    continue
                }
            }
            // Body MUST stay in ballUpload (white sprites). Details go to decorUpload.
            ballUpload.append(SIMD4<Float>(s.x, s.y, s.baseR * 2.0, 1.0))
            ballUpload.append(SIMD4<Float>(s.x, s.midY, s.midR * 2.0, 1.0))
            ballUpload.append(SIMD4<Float>(s.x, s.headY, s.headR * 2.0, 1.0))
            appendSnowmanDetails(s)
        }

        // Drift mesh is expensive — rebuild only when heightmaps actually changed.
        if driftMeshDirty {
            rebuildDriftMesh()
            driftMeshDirty = false
        }
    }

    private func rebuildDriftMesh() {
        driftVertices.removeAll(keepingCapacity: true)
        driftColors.removeAll(keepingCapacity: true)
        driftStripCounts.removeAll(keepingCapacity: true)

        for (id, surface) in surfaces {
            // Hidden Spaces must not draw drifts on the current desktop.
            guard activeSurfaceIDs.contains(id) else { continue }
            let ledge = surface.ledge
            // No drifts on a screen covered by a fullscreen window.
            if isOnBlockedScreen(x: ledge.x + ledge.width * 0.5, y: ledge.y) { continue }
            guard surface.heights.contains(where: { $0 > 0.25 }) else { continue }

            let corner = surface.cornerRadius
            // Split into visible runs so a front window can cut the drift (no snow over it).
            var run: [(x: Float, h: Float)] = []
            func flushRun() {
                guard run.count >= 2 else {
                    run.removeAll(keepingCapacity: true)
                    return
                }
                var points: [(x: Float, h: Float)] = []
                points.append((run.first!.x, 0))
                points.append(contentsOf: run)
                points.append((run.last!.x, 0))
                let startCount = driftVertices.count
                let botY = ledge.y - 1.0
                for p in points {
                    let top = botY + 1.0 + p.h
                    let alpha: Float = p.h < 0.15 ? 0 : min(0.98, 0.45 + p.h * 0.03)
                    driftVertices.append(SIMD2<Float>(p.x, botY))
                    driftColors.append(SIMD4<Float>(1, 1, 1, alpha * 0.7))
                    driftVertices.append(SIMD2<Float>(p.x, top))
                    driftColors.append(SIMD4<Float>(1, 1, 1, alpha))
                }
                driftStripCounts.append(driftVertices.count - startCount)
                run.removeAll(keepingCapacity: true)
            }

            for i in 0..<surface.heights.count {
                let x = ledge.x + Float(i) * surface.cellWidth
                let local = Float(i) * surface.cellWidth
                guard local >= corner - 0.5, local <= ledge.width - corner + 0.5 else { continue }
                var h = max(0, surface.heights[i])
                let dist = min(local, ledge.width - local)
                if dist < corner {
                    let t = dist / corner
                    h *= t * t * (3 - 2 * t)
                }
                // Mid-pile sample: hide wherever a front window overlaps this ledge.
                let sampleY = ledge.y + max(1, h * 0.5)
                if isCoveredByFrontWindow(x: x, y: sampleY, behindZ: ledge.z, ignoring: id)
                    || isCoveredByFrontWindow(x: x, y: ledge.y + 1, behindZ: ledge.z, ignoring: id)
                {
                    flushRun()
                    continue
                }
                if h > 0.2 {
                    run.append((x, h))
                } else {
                    flushRun()
                }
            }
            flushRun()
        }
    }

    /// Face coals as points; carrot / twigs / square bucket as filled triangles.
    private func appendSnowmanDetails(_ s: Snowman) {
        let coal: Float = 2
        // Small coal eyes — ~10% of head diameter.
        let eyeDiam = max(2.0, min(3.6, s.headR * 0.22))
        decorUpload.append(SIMD4(s.x - s.headR * 0.28, s.headY + s.headR * 0.12, eyeDiam, coal))
        decorUpload.append(SIMD4(s.x + s.headR * 0.28, s.headY + s.headR * 0.12, eyeDiam, coal))

        // Smile — 5 tiny coals.
        let smile = max(1.4, eyeDiam * 0.55)
        for i in -2...2 {
            let t = Float(i) / 2.0
            let sx = s.x + t * s.headR * 0.28
            let sy = s.headY - s.headR * 0.28 - (1 - abs(t)) * s.headR * 0.08
            decorUpload.append(SIMD4(sx, sy, smile, coal))
        }

        // Buttons on mid (+ one on base like the reference).
        let btn = max(2.0, min(3.2, s.midR * 0.16))
        decorUpload.append(SIMD4(s.x, s.midY + s.midR * 0.35, btn, coal))
        decorUpload.append(SIMD4(s.x, s.midY - s.midR * 0.05, btn, coal))
        decorUpload.append(SIMD4(s.x, s.midY - s.midR * 0.42, btn, coal))
        let baseBtn = max(2.0, min(3.4, s.baseR * 0.12))
        decorUpload.append(SIMD4(s.x, s.y + s.baseR * 0.25, baseBtn, coal))

        appendCarrotNose(s)
        appendBranchArm(s, left: true)
        appendBranchArm(s, left: false)
        appendBucketHat(s)
    }

    private func appendCarrotNose(_ s: Snowman) {
        let orange = SIMD4<Float>(1.0, 0.48, 0.08, 1)
        let baseX = s.x + s.headR * 0.08
        let y = s.headY - s.headR * 0.02
        let tipX = baseX + s.headR * 0.9
        let half = s.headR * 0.14
        appendTri(
            SIMD2(baseX, y + half),
            SIMD2(baseX, y - half),
            SIMD2(tipX, y),
            orange
        )
    }

    private func appendBranchArm(_ s: Snowman, left: Bool) {
        let brown = SIMD4<Float>(0.40, 0.24, 0.12, 1)
        let dir: Float = left ? -1 : 1
        let ox = s.x + dir * s.midR * 0.82
        let oy = s.midY + s.midR * 0.18
        let len = s.midR * 1.35
        let ex = ox + dir * len
        let ey = oy + len * 0.32
        appendStick(x0: ox, y0: oy, x1: ex, y1: ey, thickness: 1.35, color: brown)
        let mx = ox + dir * len * 0.58
        let my = oy + len * 0.18
        appendStick(x0: mx, y0: my, x1: mx + dir * len * 0.38, y1: my + len * 0.42, thickness: 1.05, color: brown)
        appendStick(x0: mx + dir * len * 0.12, y0: my + len * 0.06, x1: mx + dir * len * 0.4, y1: my - len * 0.18, thickness: 0.95, color: brown)
    }

    /// Solid square metal bucket on the head (not a cone / wireframe).
    private func appendBucketHat(_ s: Snowman) {
        let metal = SIMD4<Float>(0.55, 0.58, 0.62, 1)
        let metalDark = SIMD4<Float>(0.32, 0.35, 0.38, 1)
        let rim = SIMD4<Float>(0.68, 0.70, 0.74, 1)
        let cx = s.x
        let bottom = s.headY + s.headR * 0.45
        let side = s.headR * 1.05
        let height = s.headR * 1.05

        // Square body.
        appendQuad(
            x0: cx - side, y0: bottom,
            x1: cx + side, y1: bottom,
            x2: cx + side, y2: bottom + height,
            x3: cx - side, y3: bottom + height,
            color: metal
        )
        // Top rim lip (slightly wider).
        let lip = side * 1.12
        appendQuad(
            x0: cx - lip, y0: bottom + height - 1.5,
            x1: cx + lip, y1: bottom + height - 1.5,
            x2: cx + lip, y2: bottom + height + 2.2,
            x3: cx - lip, y3: bottom + height + 2.2,
            color: rim
        )
        // Dark band around the middle.
        let bandY = bottom + height * 0.45
        appendQuad(
            x0: cx - side, y0: bandY - 1.2,
            x1: cx + side, y1: bandY - 1.2,
            x2: cx + side, y2: bandY + 1.2,
            x3: cx - side, y3: bandY + 1.2,
            color: metalDark
        )
        // Square handle: two uprights + top bar.
        let hx = side * 0.62
        let hy0 = bottom + height * 0.55
        let hy1 = bottom + height + s.headR * 0.55
        appendStick(x0: cx - hx, y0: hy0, x1: cx - hx, y1: hy1, thickness: 1.3, color: metalDark)
        appendStick(x0: cx + hx, y0: hy0, x1: cx + hx, y1: hy1, thickness: 1.3, color: metalDark)
        appendStick(x0: cx - hx, y0: hy1, x1: cx + hx, y1: hy1, thickness: 1.3, color: metalDark)
    }

    private func appendTri(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ color: SIMD4<Float>) {
        propVertices.append(contentsOf: [a, b, c])
        propColors.append(contentsOf: [color, color, color])
    }

    private func appendQuad(
        x0: Float, y0: Float, x1: Float, y1: Float,
        x2: Float, y2: Float, x3: Float, y3: Float,
        color: SIMD4<Float>
    ) {
        appendTri(SIMD2(x0, y0), SIMD2(x1, y1), SIMD2(x2, y2), color)
        appendTri(SIMD2(x0, y0), SIMD2(x2, y2), SIMD2(x3, y3), color)
    }

    private func appendStick(x0: Float, y0: Float, x1: Float, y1: Float, thickness: Float, color: SIMD4<Float>) {
        let dx = x1 - x0
        let dy = y1 - y0
        let len = max(0.001, hypot(dx, dy))
        let nx = -dy / len * thickness * 0.5
        let ny = dx / len * thickness * 0.5
        appendQuad(
            x0: x0 + nx, y0: y0 + ny,
            x1: x0 - nx, y1: y0 - ny,
            x2: x1 - nx, y2: y1 - ny,
            x3: x1 + nx, y3: y1 + ny,
            color: color
        )
    }
}
