import AppKit
import MetalKit
import CoreImage
import ScreenCaptureKit

final class DesktopRenderer: MTKView, MTKViewDelegate, CAMetalDisplayLinkDelegate {
    private struct RenderState: Equatable {
        let texture: ObjectIdentifier
        let parameters: SIMD4<Float>
        let style: String
        let size: CGSize
    }
    private var lastRender: RenderState?
    static let gpu = MTLCreateSystemDefaultDevice()!
    static let queue = gpu.makeCommandQueue()!
    static let ci = CIContext(mtlDevice: gpu, options: [.cacheIntermediates: false])
    static let pipeline: MTLRenderPipelineState = {
        let library = try! gpu.makeLibrary(source: shader, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        desc.fragmentFunction = library.makeFunction(name: "fold")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        return try! gpu.makeRenderPipelineState(descriptor: desc)
    }()
    let context = DesktopRenderer.ci
    var frameImage: CIImage? { didSet { if let frameImage { inputTexture = Self.makeTexture(frameImage) } } }
    var inputTexture: MTLTexture? { didSet { wake() } }
    var amount = 0.0 { didSet { if amount != oldValue { wake() } } }
    private(set) var motion = BendMotion()
    var liveAmount: ((Double) -> Double)?
    var presentationAllowed = true { didSet { if presentationAllowed != oldValue { wake() } } }
    private var displayLink: CAMetalDisplayLink!
    private var powerObserver: NSObjectProtocol?
    private var visibilityObserver: NSObjectProtocol?
    private var lastFrameTime: CFTimeInterval?
    var onSettled: (() -> Void)?
    var onRendered: ((Double, Double) -> Void)?
    var onPresented: ((Double, Double, Double) -> Void)?
    var smoothness = 0.5 { didSet { if smoothness != oldValue { wake() } } }
    var perspective = 1.0
    var blur = 0.65
    var shadowStrength = 0.4
    var style = "Silk"
    init() {
        super.init(frame: .zero, device: Self.gpu)
        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm_srgb
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
        _ = Self.pipeline
        displayLink = CAMetalDisplayLink(metalLayer: layer as! CAMetalLayer)
        displayLink.delegate = self
        displayLink.preferredFrameLatency = 1
        updateFrameRate()
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in self?.updateFrameRate() }
        visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, notification.object as? NSWindow === self.window else { return }
            self.wake()
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        displayLink?.invalidate()
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
    }
    private func updateFrameRate() {
        let maximum = window?.screen?.maximumFramesPerSecond ?? NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        let rate = ProcessInfo.processInfo.isLowPowerModeEnabled ? min(60, maximum) : maximum
        preferredFramesPerSecond = rate
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate), maximum: Float(rate), preferred: Float(rate))
    }
    func resetMotion() {
        motion = BendMotion()
        amount = 0
        lastFrameTime = nil
        lastRender = nil
        displayLink.isPaused = true
    }
    func resumePresentation() { lastRender = nil; wake() }
    func wake() {
        guard let window else {
            displayLink?.isPaused = true
            return
        }
        // The custom display clock bypasses MTKView's draw(), which normally prepares its drawable.
        // A hidden/paused view can report a valid drawableSize while the actual layer is still 0x0.
        let size = convertToBacking(bounds).size
        guard size.width >= 1, size.height >= 1, let metalLayer = layer as? CAMetalLayer else { return }
        metalLayer.contentsScale = window.backingScaleFactor
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        // AppKit publishes visibility after orderFront; prepare the first drawable before that.
        guard presentationAllowed, window.isVisible,
              window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else {
            displayLink?.isPaused = true
            return
        }
        if displayLink?.isPaused == true { lastFrameTime = nil; displayLink.isPaused = false }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if displayLink != nil { updateFrameRate() }; wake() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); if displayLink != nil { updateFrameRate() }; wake() }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { wake() }
    func draw(in view: MTKView) { wake() }
    static func makeTexture(_ source: CIImage) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(1, Int(source.extent.width)), height: max(1, Int(source.extent.height)), mipmapped: true)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget, .pixelFormatView]
        let texture = Self.gpu.makeTexture(descriptor: desc)!
        let command = Self.queue.makeCommandBuffer()!
        // Core Image uses bottom-left coordinates; drawable texture rows start at the top.
        let upright = source.oriented(.downMirrored)
        ci.render(upright, to: texture, commandBuffer: command, bounds: source.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        // CI writes encoded sRGB bytes; reinterpret them for hardware linear sampling/mipmaps.
        let sampled = texture.makeTextureView(pixelFormat: .bgra8Unorm_srgb)!
        let blit = command.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: sampled)
        blit.endEncoding()
        command.addCompletedHandler { [source] _ in withExtendedLifetime(source) {} }
        command.commit()
        return sampled
    }
    func encode(input: MTLTexture, output: MTLTexture, command: MTLCommandBuffer, strength: Double) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(Self.pipeline)
        encoder.setFragmentTexture(input, index: 0)
        var parameters: [Float] = [Float(strength), Float(perspective), Float(blur), Float(shadowStrength), style == "Shade" ? 1 : style == "Frost" ? 2 : 0, Float(output.width), Float(output.height), 0]
        encoder.setFragmentBytes(&parameters, length: 32, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
    func advanceMotion(to desired: Double, at presentationTime: CFTimeInterval) {
        // Callback arrival can jitter on the main queue; animate on the display's timeline.
        let dt = lastFrameTime.map { presentationTime - $0 } ?? 1 / Double(preferredFramesPerSecond)
        if liveAmount != nil {
            motion.follow(target: desired, dt: dt, smoothness: smoothness)
        } else {
            motion.advance(target: desired, dt: dt)
        }
        lastFrameTime = presentationTime
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard presentationAllowed, window?.isVisible == true,
              window?.occlusionState.contains(.visible) == true,
              !isHiddenOrHasHiddenAncestor, let input = inputTexture else { link.isPaused = true; return }
        let now = CACurrentMediaTime()
        let target = update.targetPresentationTimestamp
        let desired = liveAmount?(target) ?? amount
        advanceMotion(to: desired, at: target)
        let state = RenderState(texture: ObjectIdentifier(input), parameters: SIMD4(Float(motion.value), Float(perspective), Float(blur), Float(shadowStrength)), style: style, size: drawableSize)
        // Live content can be unchanged too; don't keep redrawing a stationary preview.
        guard state != lastRender else { return }
        // Metal's display link supplies a ready drawable; never wait for one on the UI thread.
        let drawable = update.drawable
        guard let command = Self.queue.makeCommandBuffer() else { return }
        encode(input: input, output: drawable.texture, command: command, strength: motion.value)
        if let callback = onPresented {
            let value = motion.value
            drawable.addPresentedHandler { drawable in callback(value, drawable.presentedTime, target) }
        }
        command.present(drawable)
        command.commit()
        lastRender = state
        onRendered?(motion.value, CACurrentMediaTime() - now)
        if motion.settled(at: desired) {
            // A live target may keep changing without a texture update; only fixed targets stop the clock.
            if liveAmount == nil { link.isPaused = true }
            onSettled?()
        }
    }
    // Exercises the same shader without a window for pixel and GPU regression checks.
    func processed(_ source: CIImage, size: CGSize, strength: Double? = nil) -> CIImage {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: Int(size.width), height: Int(size.height), mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        let output = Self.gpu.makeTexture(descriptor: desc)!
        let input = Self.makeTexture(source)
        let command = Self.queue.makeCommandBuffer()!
        encode(input: input, output: output, command: command, strength: strength ?? amount)
        command.commit()
        command.waitUntilCompleted()
        return CIImage(mtlTexture: output.makeTextureView(pixelFormat: .bgra8Unorm)!, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()])!.oriented(.downMirrored)
    }
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    vertex V fullscreenVertex(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        return {float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), uv};
    }
    struct P { float bend, perspective, blur, shadow, style, width, height, unused; };
    // Adapted from iphone-duo (MIT, jadon7); see Resources/THIRD_PARTY_NOTICES.txt.
    float coverage(float2 uv, float2 footprint) {
        float2 c = smoothstep(-footprint, footprint, uv)
                 * (1 - smoothstep(1 - footprint, 1 + footprint, uv));
        return c.x * c.y;
    }
    fragment float4 fold(V v [[stage_in]], texture2d<float> image [[texture(0)]], constant P &p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float bend = clamp(p.bend, 0.0f, 1.0f);
        // Forward fixed-eye projection, rotated onto the physical Mac's bottom hinge.
        // The real panel supplies the tilt; don't shrink a second digital panel inside it.
        float a = bend * p.perspective * 1.570796327f;
        float distance = 1 - v.uv.y;
        float depth = 1 / (1 - (7.89935f / 39.75052f) * distance * sin(a));
        float2 uv = float2((v.uv.x - 0.5f) * depth + 0.5f, 1 - distance * cos(a) * depth);
        float2 pixel = 1 / float2(image.get_width(), image.get_height());
        float2 aa = max(fwidth(uv), pixel * 0.5f);
        float baseLod = log2(max(1.0f, max(length(dfdx(uv) / pixel), length(dfdy(uv) / pixel))));
        float motion = smoothstep(0.0f, 1.0f, bend);
        float edge = clamp(1 - uv.y, 0.0f, 1.0f);
        // The reference's moving half spans 800 source pixels along the fold direction.
        float radius = 72 * float(image.get_height()) / 800 * p.blur / 0.65f
                     * (p.style == 2 ? 1.45f : 1.0f) * motion * pow(edge, 1.35f);
        float3 color = image.sample(s, clamp(uv, 0.0f, 1.0f), level(baseLod)).rgb;
        if (bend > 0) color *= coverage(uv, aa);
        if (radius > 0) {
            float lod = max(baseLod, log2(max(1.0f, radius)));
            float2 footprint = max(aa, pixel * radius * 0.75f);
            color = float3(0);
            for (int y = -2; y <= 2; y++) {
                for (int x = -2; x <= 2; x++) {
                    float wx = x == 0 ? 6.0f : (abs(x) == 1 ? 4.0f : 1.0f);
                    float wy = y == 0 ? 6.0f : (abs(y) == 1 ? 4.0f : 1.0f);
                    float2 sampleUV = uv + float2(x, y) * pixel * radius;
                    color += image.sample(s, clamp(sampleUV, 0.0f, 1.0f), level(lod)).rgb
                           * coverage(sampleUV, footprint) * wx * wy / 256;
                }
            }
        }
        float darken = motion * pow(clamp((edge - 0.2f) / 0.8f, 0.0f, 1.0f), 1.35f);
        color *= 1 - min(1.0f, 2 * darken * p.shadow * (p.style == 1 ? 1.65f : 1.0f));
        if (p.style == 2) color = mix(color, float3(dot(color, float3(0.2126f, 0.7152f, 0.0722f))), motion * 0.3f);
        return float4(color, 1);
    }
    """
}

final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    // The model and frame deliveries access these properties on the main thread.
    var stream: SCStream? {
        didSet {
            readyForDemand = false
            demandRevision += 1
            let source = stream, revision = demandRevision, needed = needsFrames
            outputQueue.async {
                self.outputStream = source
                self.latestFrame = nil
                self.frameRevision = 0
                self.preparedRevision = -1
                self.outputRevision = revision
                self.outputDemand = needed
            }
        }
    }
    var onFrame: ((MTLTexture) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var frameCount = 0
    private(set) var needsFrames = true
    private(set) var readyForDemand = false
    private var demandRevision = 0
    let outputQueue = DispatchQueue(label: "app.local.bendy.capture", qos: .userInteractive)
    // All buffer and preparation state stays on outputQueue, including demand changes.
    private var outputStream: SCStream?
    private var latestFrame: CVPixelBuffer?
    private var frameRevision = 0
    private var preparedRevision = -1
    private var outputRevision = 0
    private var outputDemand = true
    private var preparing = false
    private var conversions = 0
    private var textureCache: CVMetalTextureCache?
    var preparationCount: Int { outputQueue.sync { conversions } }
    func makeCapturedTexture(_ buffer: CVPixelBuffer) -> MTLTexture? {
        if textureCache == nil {
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, DesktopRenderer.gpu, nil, &textureCache) == kCVReturnSuccess else { return nil }
        }
        guard let textureCache else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm, width, height, 0, &wrapped) == kCVReturnSuccess,
              let wrapped, let source = CVMetalTextureGetTexture(wrapped) else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: true)
        // This copy is GPU-only; shared storage makes full-screen blur contend with capture.
        desc.storageMode = .private
        desc.usage = [.shaderRead]
        guard let texture = DesktopRenderer.gpu.makeTexture(descriptor: desc),
              let command = DesktopRenderer.queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1), to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        // ScreenCaptureKit owns these IOSurface bytes; keep them alive until the GPU copy finishes.
        command.addCompletedHandler { [buffer, wrapped] _ in withExtendedLifetime((buffer, wrapped)) {} }
        command.commit()
        return texture
    }
    func setNeedsFrames(_ needed: Bool) {
        guard needed != needsFrames else { return }
        needsFrames = needed
        readyForDemand = false
        demandRevision += 1
        let revision = demandRevision
        outputQueue.async {
            self.outputDemand = needed
            self.outputRevision = revision
            if needed {
                self.preparedRevision = -1
                self.prepareLatestFrame()
            }
        }
    }
    @MainActor func start(displayID: CGDirectDisplayID) async throws {
        frameCount = 0
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "BendyReplica", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到内建显示器"])
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        // The live system cursor remains above this click-through overlay; don't draw a delayed copy.
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = false
        let candidate = SCStream(filter: filter, configuration: config, delegate: self)
        try candidate.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        stream = candidate
        do { try await candidate.startCapture() }
        catch { stream = nil; throw error }
    }
    @MainActor func stop() async {
        let old = stream
        stream = nil
        try? await old?.stopCapture()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard self.stream === stream else { return }
            self.onError?(error.localizedDescription)
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        guard outputStream === stream else { return }
        // Keep only the latest raw frame while hidden; resume doesn't need another capture callback.
        latestFrame = buffer
        frameRevision += 1
        prepareLatestFrame()
    }
    private func prepareLatestFrame() {
        guard outputDemand, !preparing, frameRevision != preparedRevision,
              let source = outputStream, let buffer = latestFrame else { return }
        preparing = true
        conversions += 1
        let revision = outputRevision, frame = frameRevision
        let texture = makeCapturedTexture(buffer) ?? DesktopRenderer.makeTexture(CIImage(cvPixelBuffer: buffer))
        DispatchQueue.main.async {
            if self.stream === source, self.needsFrames, self.demandRevision == revision {
                self.frameCount += 1
                self.readyForDemand = true
                self.onFrame?(texture)
            }
            self.outputQueue.async {
                self.preparing = false
                if self.outputRevision == revision { self.preparedRevision = frame }
                // A newer frame or a resumed demand may have arrived during the pending delivery.
                self.prepareLatestFrame()
            }
        }
    }
}
