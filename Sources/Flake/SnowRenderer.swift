import AppKit
import Metal
import MetalKit
import simd

struct FrameUniforms {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    /// .x = backing scale; remaining components pad to 16-byte alignment.
    var scalePad: SIMD4<Float>
}

/// Renders the shared global-coordinate simulation into one screen's MTKView.
final class SnowRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let flakePipeline: MTLRenderPipelineState
    private let ballPipeline: MTLRenderPipelineState
    private let softBallPipeline: MTLRenderPipelineState
    private let driftPipeline: MTLRenderPipelineState

    // Dedicated buffers — never reuse the same storage for two encoded draws
    // in one frame (GPU reads happen after encode; overwrite = black snowman / streaks).
    private var flakeBuffer: MTLBuffer?
    private var ballBuffer: MTLBuffer?
    private var decorBuffer: MTLBuffer?
    private var lanBuffer: MTLBuffer?
    private var lanFlakeBuffer: MTLBuffer?
    private var softBallPosBuffer: MTLBuffer?
    private var softBallLocalBuffer: MTLBuffer?
    private var lanSoftBallPosBuffer: MTLBuffer?
    private var lanSoftBallLocalBuffer: MTLBuffer?
    private var driftPosBuffer: MTLBuffer?
    private var driftColBuffer: MTLBuffer?
    private var propPosBuffer: MTLBuffer?
    private var propColBuffer: MTLBuffer?
    private var uniformsBuffer: MTLBuffer

    private let simulator: SnowSimulator
    let screenFrame: NSRect
    /// Reused scratch so multi-monitor draws don't re-upload off-screen points.
    private var pointScratch: [SIMD4<Float>] = []
    private var driftPosScratch: [SIMD2<Float>] = []
    private var driftColScratch: [SIMD4<Float>] = []
    private var driftCountScratch: [Int] = []

    init?(view: MTKView, simulator: SnowSimulator, screenFrame: NSRect) {
        guard
            let device = view.device ?? MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue()
        else { return nil }

        self.device = device
        self.queue = queue
        self.simulator = simulator
        self.screenFrame = screenFrame

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        view.sampleCount = 1
        view.framebufferOnly = true

        guard
            let library = try? device.makeLibrary(source: MetalShaders.source, options: nil),
            let flakeV = library.makeFunction(name: "flake_vertex"),
            let flakeF = library.makeFunction(name: "flake_fragment"),
            let ballV = library.makeFunction(name: "ball_vertex"),
            let ballF = library.makeFunction(name: "ball_fragment"),
            let softBallV = library.makeFunction(name: "softball_vertex"),
            let softBallF = library.makeFunction(name: "softball_fragment"),
            let driftV = library.makeFunction(name: "drift_vertex"),
            let driftF = library.makeFunction(name: "drift_fragment")
        else { return nil }

        let flakeDesc = MTLRenderPipelineDescriptor()
        flakeDesc.vertexFunction = flakeV
        flakeDesc.fragmentFunction = flakeF
        flakeDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        Self.enableBlending(flakeDesc.colorAttachments[0])

        let ballDesc = MTLRenderPipelineDescriptor()
        ballDesc.vertexFunction = ballV
        ballDesc.fragmentFunction = ballF
        ballDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        Self.enableBlending(ballDesc.colorAttachments[0])

        let softBallDesc = MTLRenderPipelineDescriptor()
        softBallDesc.vertexFunction = softBallV
        softBallDesc.fragmentFunction = softBallF
        softBallDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        Self.enableBlending(softBallDesc.colorAttachments[0])

        let softBallVertex = MTLVertexDescriptor()
        softBallVertex.attributes[0].format = .float2
        softBallVertex.attributes[0].offset = 0
        softBallVertex.attributes[0].bufferIndex = 0
        softBallVertex.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        softBallVertex.attributes[1].format = .float4
        softBallVertex.attributes[1].offset = 0
        softBallVertex.attributes[1].bufferIndex = 2
        softBallVertex.layouts[2].stride = MemoryLayout<SIMD4<Float>>.stride
        softBallDesc.vertexDescriptor = softBallVertex

        let driftDesc = MTLRenderPipelineDescriptor()
        driftDesc.vertexFunction = driftV
        driftDesc.fragmentFunction = driftF
        driftDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        Self.enableBlending(driftDesc.colorAttachments[0])

        let driftVertex = MTLVertexDescriptor()
        driftVertex.attributes[0].format = .float2
        driftVertex.attributes[0].offset = 0
        driftVertex.attributes[0].bufferIndex = 0
        driftVertex.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride
        driftVertex.attributes[1].format = .float4
        driftVertex.attributes[1].offset = 0
        driftVertex.attributes[1].bufferIndex = 2
        driftVertex.layouts[2].stride = MemoryLayout<SIMD4<Float>>.stride
        driftDesc.vertexDescriptor = driftVertex

        do {
            flakePipeline = try device.makeRenderPipelineState(descriptor: flakeDesc)
            ballPipeline = try device.makeRenderPipelineState(descriptor: ballDesc)
            softBallPipeline = try device.makeRenderPipelineState(descriptor: softBallDesc)
            driftPipeline = try device.makeRenderPipelineState(descriptor: driftDesc)
        } catch {
            return nil
        }

        guard let uniforms = device.makeBuffer(
            length: MemoryLayout<FrameUniforms>.stride,
            options: .storageModeShared
        ) else { return nil }
        uniformsBuffer = uniforms

        super.init()
        view.delegate = self
    }

    private static func enableBlending(_ att: MTLRenderPipelineColorAttachmentDescriptor?) {
        guard let att else { return }
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .sourceAlpha
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.sourceAlphaBlendFactor = .one
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        render(into: view)
    }

    func render(into view: MTKView, lanOnly: Bool = false) {
        guard
            let drawable = view.currentDrawable,
            let rpd = view.currentRenderPassDescriptor,
            let cmd = queue.makeCommandBuffer(),
            let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        let scale = Float(view.window?.backingScaleFactor
            ?? view.layer?.contentsScale
            ?? NSScreen.main?.backingScaleFactor
            ?? 2)
        var frame = FrameUniforms(
            origin: SIMD2<Float>(Float(screenFrame.minX), Float(screenFrame.minY)),
            size: SIMD2<Float>(Float(screenFrame.width), Float(screenFrame.height)),
            scalePad: SIMD4<Float>(max(1, scale), 0, 0, 0)
        )
        memcpy(uniformsBuffer.contents(), &frame, MemoryLayout<FrameUniforms>.stride)

        // Wide pad so giant LAN snowballs / large rolled balls near edges still upload.
        let minX = Float(screenFrame.minX) - 220
        let maxX = Float(screenFrame.maxX) + 220
        let minY = Float(screenFrame.minY) - 220
        let maxY = Float(screenFrame.maxY) + 220

        if !lanOnly {
            // Drifts only — dedicated buffers, never shared with props.
            cullDriftStrips(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
            if !driftPosScratch.isEmpty, !driftCountScratch.isEmpty {
                uploadMesh(
                    positions: driftPosScratch,
                    colors: driftColScratch,
                    posBuffer: &driftPosBuffer,
                    colBuffer: &driftColBuffer
                )
                enc.setRenderPipelineState(driftPipeline)
                enc.setVertexBuffer(driftPosBuffer, offset: 0, index: 0)
                enc.setVertexBuffer(driftColBuffer, offset: 0, index: 2)
                enc.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)
                var start = 0
                for n in driftCountScratch {
                    if n >= 3 {
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: start, vertexCount: n)
                    }
                    start += n
                }
            }

            drawPointBatch(
                simulator.flakeUpload,
                pipeline: flakePipeline,
                buffer: &flakeBuffer,
                encoder: enc,
                minX: minX, maxX: maxX, minY: minY, maxY: maxY
            )
            // Snowballs + snowman bodies (white).
            drawPointBatch(
                simulator.ballUpload,
                pipeline: ballPipeline,
                buffer: &ballBuffer,
                encoder: enc,
                minX: minX, maxX: maxX, minY: minY, maxY: maxY
            )
            drawSoftBallMesh(
                positions: simulator.softBallPositions,
                localOp: simulator.softBallLocalOp,
                posBuffer: &softBallPosBuffer,
                localBuffer: &softBallLocalBuffer,
                encoder: enc,
                minX: minX, maxX: maxX, minY: minY, maxY: maxY
            )

            // Carrot / twigs / bucket — dedicated buffers (never share with drifts).
            if !simulator.propVertices.isEmpty {
                // Props are few; only draw if any vertex lands on this display.
                let onScreen = simulator.propVertices.contains {
                    $0.x >= minX && $0.x <= maxX && $0.y >= minY && $0.y <= maxY
                }
                if onScreen {
                    uploadMesh(
                        positions: simulator.propVertices,
                        colors: simulator.propColors,
                        posBuffer: &propPosBuffer,
                        colBuffer: &propColBuffer
                    )
                    enc.setRenderPipelineState(driftPipeline)
                    enc.setVertexBuffer(propPosBuffer, offset: 0, index: 0)
                    enc.setVertexBuffer(propColBuffer, offset: 0, index: 2)
                    enc.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: simulator.propVertices.count)
                }
            }

            // Coal eyes / smile / buttons on top.
            drawPointBatch(
                simulator.decorUpload,
                pipeline: ballPipeline,
                buffer: &decorBuffer,
                encoder: enc,
                minX: minX, maxX: maxX, minY: minY, maxY: maxY
            )
        }

        // Peer hits / stains — always on top of window content & fullscreen apps.
        drawSoftBallMesh(
            positions: simulator.lanSoftBallPositions,
            localOp: simulator.lanSoftBallLocalOp,
            posBuffer: &lanSoftBallPosBuffer,
            localBuffer: &lanSoftBallLocalBuffer,
            encoder: enc,
            minX: minX, maxX: maxX, minY: minY, maxY: maxY
        )
        drawPointBatch(
            simulator.lanOverlayUpload,
            pipeline: ballPipeline,
            buffer: &lanBuffer,
            encoder: enc,
            minX: minX, maxX: maxX, minY: minY, maxY: maxY
        )
        // Shatter crystals — same snowflake look as falling snow.
        drawPointBatch(
            simulator.lanFlakeUpload,
            pipeline: flakePipeline,
            buffer: &lanFlakeBuffer,
            encoder: enc,
            minX: minX, maxX: maxX, minY: minY, maxY: maxY
        )

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func drawSoftBallMesh(
        positions: [SIMD2<Float>],
        localOp: [SIMD4<Float>],
        posBuffer: inout MTLBuffer?,
        localBuffer: inout MTLBuffer?,
        encoder: MTLRenderCommandEncoder,
        minX: Float,
        maxX: Float,
        minY: Float,
        maxY: Float
    ) {
        guard !positions.isEmpty, positions.count == localOp.count else { return }
        let onScreen = positions.contains {
            $0.x >= minX && $0.x <= maxX && $0.y >= minY && $0.y <= maxY
        }
        guard onScreen else { return }
        uploadMesh(
            positions: positions,
            colors: localOp,
            posBuffer: &posBuffer,
            colBuffer: &localBuffer
        )
        encoder.setRenderPipelineState(softBallPipeline)
        encoder.setVertexBuffer(posBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(localBuffer, offset: 0, index: 2)
        encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: positions.count)
    }

    private func uploadMesh(
        positions: [SIMD2<Float>],
        colors: [SIMD4<Float>],
        posBuffer: inout MTLBuffer?,
        colBuffer: inout MTLBuffer?
    ) {
        let posBytes = positions.count * MemoryLayout<SIMD2<Float>>.stride
        let colBytes = colors.count * MemoryLayout<SIMD4<Float>>.stride
        if posBuffer == nil || posBuffer!.length < posBytes {
            posBuffer = device.makeBuffer(length: max(posBytes, 4096), options: .storageModeShared)
        }
        if colBuffer == nil || colBuffer!.length < colBytes {
            colBuffer = device.makeBuffer(length: max(colBytes, 4096), options: .storageModeShared)
        }
        positions.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(posBuffer!.contents(), base, posBytes) }
        }
        colors.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(colBuffer!.contents(), base, colBytes) }
        }
    }

    private func drawPointBatch(
        _ data: [SIMD4<Float>],
        pipeline: MTLRenderPipelineState,
        buffer: inout MTLBuffer?,
        encoder: MTLRenderCommandEncoder,
        minX: Float,
        maxX: Float,
        minY: Float,
        maxY: Float
    ) {
        guard !data.isEmpty else { return }
        pointScratch.removeAll(keepingCapacity: true)
        pointScratch.reserveCapacity(min(data.count, data.count / max(1, NSScreen.screens.count) + 64))
        for p in data where p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY {
            pointScratch.append(p)
        }
        guard !pointScratch.isEmpty else { return }
        let bytes = pointScratch.count * MemoryLayout<SIMD4<Float>>.stride
        if buffer == nil || buffer!.length < bytes {
            buffer = device.makeBuffer(length: max(bytes, 1024), options: .storageModeShared)
        }
        pointScratch.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(buffer!.contents(), base, bytes)
            }
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointScratch.count)
    }

    private func cullDriftStrips(minX: Float, maxX: Float, minY: Float, maxY: Float) {
        driftPosScratch.removeAll(keepingCapacity: true)
        driftColScratch.removeAll(keepingCapacity: true)
        driftCountScratch.removeAll(keepingCapacity: true)
        let srcPos = simulator.driftVertices
        let srcCol = simulator.driftColors
        var start = 0
        for n in simulator.driftStripCounts {
            defer { start += n }
            guard n >= 3, start + n <= srcPos.count, start + n <= srcCol.count else { continue }
            var any = false
            for i in 0..<n {
                let p = srcPos[start + i]
                if p.x >= minX, p.x <= maxX, p.y >= minY, p.y <= maxY {
                    any = true
                    break
                }
            }
            guard any else { continue }
            let base = driftPosScratch.count
            for i in 0..<n {
                driftPosScratch.append(srcPos[start + i])
                driftColScratch.append(srcCol[start + i])
            }
            driftCountScratch.append(driftPosScratch.count - base)
        }
    }
}
