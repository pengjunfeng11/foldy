import AppKit
import CoreImage
import ScreenCaptureKit
if CommandLine.arguments.contains("--self-test") {
    var lidHooks = LidHookDetector()
    assert(lidHooks.update(angle: 0, closeAngle: 20).isEmpty, "Starting closed must not send a message")
    assert(lidHooks.update(angle: 100, closeAngle: 20).isEmpty)
    assert(lidHooks.update(angle: 55, closeAngle: 20) == [.prepare])
    assert(lidHooks.update(angle: 20, closeAngle: 20) == [.close])
    for angle in [19.0, 20.2, 0.48, 25, 50] {
        assert(lidHooks.update(angle: angle, closeAngle: 20).isEmpty, "A closing cycle sends once despite jitter")
    }
    assert(lidHooks.update(angle: 60, closeAngle: 20) == [.open])
    assert(lidHooks.update(angle: 0, closeAngle: 20) == [.prepare, .close], "Fast closing must not skip events")
    assert(lidHooks.update(angle: .nan, closeAngle: 20).isEmpty)
    assert(lidHooks.update(angle: 500, closeAngle: 20).isEmpty)
    assert(lidHooks.update(angle: 100, closeAngle: 20) == [.open])
    assert(lidHooks.update(angle: 52, closeAngle: 20) == [.prepare])
    assert(lidHooks.update(angle: 90, closeAngle: 20).isEmpty, "Aborting a close must not emit a close event")
    assert(lidHooks.update(angle: 52, closeAngle: 20) == [.prepare])
    assert(LidHooks.execute(path: "/usr/bin/true", arguments: []).0 == 0)
    assert(LidHooks.execute(path: "/usr/bin/false", arguments: []).0 != 0)
    print("PASS: lid hook threshold, hysteresis, skipped angles, abort/reopen, and subprocess exit handling")
    assert(bendAmount(angle: 125, clearAngle: 115) == 0)
    assert(bendAmount(angle: 0, clearAngle: 115) == 1)
    assert(bendAmount(angle: 57.5, clearAngle: 115) == 0.5)
    assert(bendAmount(angle: .nan, clearAngle: 115) == 0)
    assert(bendAmount(angle: 20, clearAngle: 0) == 0)
    assert(decodeAngle([1, 126, 0]) == 126)
    assert(decodeAngle([1, 44, 1]) == 300)
    assert(decodeAngle([1, 255, 255]) == nil)
    assert(decodeAngle([2, 126, 0]) == nil)
    assert(decodeAngle([1]) == nil)
    assert(decodeAngle([7, 112, 140, 0, 0]) == 359.52)
    assert(decodeAngle([7, 255, 255, 255, 255]) == nil)
    var hinge = HingeSample()
    hinge.update(359.52, at: 1)
    assert(abs(hinge.angle - 0.48) < 0.000001, "Closed-lid wrap must not become a fully open lid")
    for fps in [60.0, 120.0] {
        for jump in [10.0, 30.0] {
            var motion = BendMotion()
            let target = jump / 125
            var previous = 0.0, largestStep = 0.0
            for _ in 0..<Int(fps * 0.15) {
                motion.follow(target: target, dt: 1 / fps)
                largestStep = max(largestStep, abs(motion.value - previous))
                assert(motion.value >= previous && motion.value <= target, "A sensor step must approach without bouncing")
                previous = motion.value
            }
            assert(largestStep < target * 0.8, "A sensor jump must span multiple displayed frames")
            assert(abs(motion.value - target) < target * 0.01, "The transition must finish promptly")
            for _ in 0..<Int(fps * 0.25) { motion.follow(target: 0, dt: 1 / fps) }
            assert(motion.settled(at: 0), "Opening must complete the transition and clear the overlay")
        }
        var motion = BendMotion(), maxLag = 0.0, maxStep = 0.0, previous = 0.0
        // A 20 Hz sensor feeds a 60/120 Hz display. Input values jump, output keeps moving.
        for frame in 0..<Int(fps) {
            let time = Double(frame) / fps
            let target = floor((time + 1e-8) * 20) / 20 * 0.5
            motion.follow(target: target, dt: 1 / fps)
            maxStep = max(maxStep, abs(motion.value - previous))
            if time > 0.2 { maxLag = max(maxLag, max(0, target - motion.value) / 0.5) }
            previous = motion.value
        }
        assert(maxStep < 0.025 * 0.8, "Do not pass the full 20 Hz staircase straight to the screen")
        assert(maxLag < 0.055, "Smoothing must not queue long transitions behind the latest target")
        print("Stepped sensor:", Int(fps), "display fps; max step degrees", maxStep * 125, "max target-following lag ms", maxLag * 1000)
        // A new target retargets the current motion; no old animation may run to completion first.
        for target in [0.8, 0.1, 0.9, 0.0] {
            for _ in 0..<Int(fps * 0.3) { motion.follow(target: target, dt: 1 / fps) }
            assert(motion.settled(at: target), "Reversal must reach the newest target without a tween backlog")
        }
    }
    var sixty = BendMotion(), oneTwenty = BendMotion()
    for _ in 0..<12 { sixty.advance(target: 0.8, dt: 1.0 / 60) }
    for _ in 0..<24 { oneTwenty.advance(target: 0.8, dt: 1.0 / 120) }
    assert(abs(sixty.value - oneTwenty.value) < 0.000001, "Motion must be refresh-rate independent")
    for _ in 0..<120 { oneTwenty.advance(target: 0, dt: 1.0 / 120) }
    assert(oneTwenty.settled(at: 0), "Opening must settle to an exact clear frame")
    print("PASS: angle bounds, HID validation, 60/120 Hz spring equivalence and settle")
} else if CommandLine.arguments.contains("--render-test") {
    _ = NSApplication.shared
    let renderer = autoreleasepool { DesktopRenderer() }
    let size = CGSize(width: 400, height: 240)
    let bounds = CGRect(origin: .zero, size: size)
    let source = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: 240), "inputColor0": CIColor(red: 0.8, green: 0.2, blue: 0.1), "inputColor1": CIColor(red: 0.1, green: 0.5, blue: 0.8)])!.outputImage!.cropped(to: bounds)
    func pixels(_ image: CIImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 400 * 240 * 4)
        renderer.context.render(image, toBitmap: &data, rowBytes: 400 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return data
    }
    renderer.amount = 0
    let original = pixels(source)
    let clear = pixels(renderer.processed(source, size: size))
    let maxDelta = zip(original, clear).map { abs(Int($0) - Int($1)) }.max()!
    print("Open-lid maximum channel delta:", maxDelta)
    assert(maxDelta <= 1, "Open lid must preserve pixels within 8-bit rounding")
    var results = [[UInt8]]()
    for style in ["Silk", "Shade", "Frost"] {
        renderer.style = style
        renderer.amount = 0.7
        let output = pixels(renderer.processed(source, size: size))
        assert(output != clear, "Fold must change the image")
        let top = 0
        assert(output[top] == 0 && output[top + 1] == 0 && output[top + 2] == 0, "Projected image must expose a black margin outside its source coverage")
        let bottom = (240 - 1) * 400 * 4 + 200 * 4
        assert(output[bottom] > 0 || output[bottom + 1] > 0 || output[bottom + 2] > 0, "The hinge edge must remain anchored and visible")
        results.append(output)
    }
    assert(results[0] != results[1] && results[1] != results[2] && results[0] != results[2], "Styles must produce distinct pixels")
    renderer.style = "Silk"
    renderer.blur = 0
    renderer.shadowStrength = 0
    let white = CIImage(color: .white).cropped(to: bounds)
    let feathered = pixels(renderer.processed(white, size: size, strength: 0.7))
    assert(feathered[200 * 4] >= 250, "The reference keeps the upper center bright; do not add a full-width black strip")
    // The reference blurs color and coverage together; a zero-blur edge only has pixel antialiasing.
    renderer.blur = 0.65
    let blurredEdge = pixels(renderer.processed(white, size: size, strength: 0.7))
    let edgeRow = (0..<100).map { blurredEdge[(80 * 400 + $0) * 4] }
    assert(edgeRow.filter { $0 > 16 && $0 < 239 }.count >= 3, "Blurred image coverage must spread smoothly into the black margin")
    print("PASS: Metal image rendering, identity at open lid, fold geometry, three distinct styles")
} else if CommandLine.arguments.contains("--capture-texture-test") {
    let capture = DesktopCapture(), width = 64, height = 32
    var pixelBuffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pixelBuffer) == kCVReturnSuccess)
    let buffer = pixelBuffer!
    CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
    CVPixelBufferLockBaseAddress(buffer, [])
    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height { for x in 0..<width {
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        bytes[offset] = UInt8(x * 4); bytes[offset + 1] = UInt8(y * 8)
        bytes[offset + 2] = UInt8((x + y) % 64 * 4); bytes[offset + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let copied = capture.outputQueue.sync { capture.makeCapturedTexture(buffer) }
    precondition(copied != nil, "An sRGB IOSurface frame must use the native copy path")
    precondition(copied!.storageMode == .private, "Live capture textures must use GPU-only storage to avoid blur stalls")
    let original = DesktopRenderer.makeTexture(CIImage(cvPixelBuffer: buffer))
    let completed = DesktopRenderer.queue.makeCommandBuffer()!
    completed.commit(); completed.waitUntilCompleted()
    func read(_ texture: MTLTexture) -> [UInt8] {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: width, height: height, mipmapped: false)
        desc.storageMode = .shared
        let staging = DesktopRenderer.gpu.makeTexture(descriptor: desc)!
        let command = DesktopRenderer.queue.makeCommandBuffer()!
        let blit = command.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: width, height: height, depth: 1), to: staging, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        command.commit(); command.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        staging.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }
    precondition(read(copied!) == read(original), "Native copy must preserve every sRGB pixel and its orientation")
    precondition(copied!.mipmapLevelCount == original.mipmapLevelCount, "Gradient blur needs the complete mip chain")
    print("PASS: native sRGB capture copy equals CI pixel-for-pixel, with the same orientation and mip levels")
} else if CommandLine.arguments.contains("--capture-demand-test") {
    // Feed the real capture callback without a desktop stream, window, or screen-recording permission.
    let capture = DesktopCapture()
    let source = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
    capture.stream = source
    capture.setNeedsFrames(false)
    var widths = [Int]()
    capture.onFrame = { widths.append($0.width) }
    func enqueueFrame(width: Int) {
        var pixelBuffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, 8, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer) == kCVReturnSuccess)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 255, CVPixelBufferGetBytesPerRow(buffer) * 8)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true)! as NSArray
        (attachments[0] as! NSMutableDictionary)[SCStreamFrameInfo.status] = SCFrameStatus.complete.rawValue
        let frame = sample!
        capture.outputQueue.async { capture.stream(source, didOutputSampleBuffer: frame, of: .screen) }
    }
    func drainMain(until done: () -> Bool, timeout: Double = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        precondition(done(), "Capture demand delivery timed out")
    }
    enqueueFrame(width: 8)
    enqueueFrame(width: 16)
    capture.outputQueue.sync {}
    precondition(capture.preparationCount == 0 && widths.isEmpty, "Hidden capture must not prepare textures")
    capture.setNeedsFrames(true)
    drainMain(until: { widths.count == 1 })
    precondition(widths == [16] && capture.readyForDemand, "Resuming must use the latest buffered frame without another capture callback")

    capture.setNeedsFrames(false)
    enqueueFrame(width: 24)
    capture.outputQueue.sync {}
    let beforeCancel = capture.preparationCount
    capture.setNeedsFrames(true)
    capture.outputQueue.sync {} // Queue the delivery, then cancel it before the main thread receives it.
    capture.setNeedsFrames(false)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(widths == [16] && !capture.readyForDemand, "Cancelled demand must not publish a late texture")
    capture.setNeedsFrames(true)
    capture.outputQueue.sync {}
    capture.setNeedsFrames(false)
    capture.setNeedsFrames(true) // Resume while the previous delivery is still queued on the main thread.
    drainMain(until: { widths.count == 2 })
    precondition(widths == [16, 24], "Demand resumed during a pending delivery must not lose the latest frame")

    capture.setNeedsFrames(false)
    enqueueFrame(width: 32)
    capture.outputQueue.sync {}
    capture.setNeedsFrames(true)
    capture.outputQueue.sync {}
    capture.stream = nil
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(widths == [16, 24] && !capture.readyForDemand, "Stopped streams must not publish a queued texture")
    print("PASS: hidden conversions 0; resume latest buffered frame; cancel/resume and stopped-stream delivery safe; conversions", capture.preparationCount, "before cancellation", beforeCancel)
} else if CommandLine.arguments.contains("--idle-render-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    func runApp(for seconds: Double) {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            app.stop(nil)
            app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
        }
        app.run()
        timer.invalidate()
    }
    let window = NSPanel(contentRect: NSRect(x: 40, y: 40, width: 400, height: 240), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.level = .floating
    let renderer = DesktopRenderer()
    renderer.frameImage = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 480))
    renderer.liveAmount = { _ in 0.2 }
    window.contentView = renderer
    var frames = 0
    renderer.onRendered = { _, _ in frames += 1 }
    window.orderFrontRegardless()
    runApp(for: 0.2) // Let AppKit publish the panel's visible occlusion state before waking it.
    renderer.resumePresentation()
    runApp(for: 0.3)
    let firstFrames = frames
    runApp(for: 0.3)
    let idleFrames = frames - firstFrames
    renderer.liveAmount = { time in 0.2 + 0.05 * sin(time * 12) }
    renderer.wake()
    let beforeMoving = frames
    runApp(for: 0.3)
    let movingFrames = frames - beforeMoving
    window.orderOut(nil)
    print("Initial frames:", firstFrames, "unchanged preview frames:", idleFrames, "moving preview frames:", movingFrames)
    fflush(stdout)
    assert(firstFrames > 0 && idleFrames == 0, "Unchanged preview must not repeatedly wait for a drawable")
    assert(movingFrames >= 10, "Skipping unchanged frames must preserve continuous angle animation")
    print("PASS: static preview stays idle; moving angle resumes drawing")
} else if CommandLine.arguments.contains("--overlay-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    func stopRun() {
        app.stop(nil)
        app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
    }
    func runApp(for seconds: Double) {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in stopRun() }
        app.run()
        timer.invalidate()
    }
    let liveCapture = CommandLine.arguments.contains("--live-capture")
    let builtInScreen = NSScreen.screens.first { screen in
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! UInt32
        return CGDisplayIsBuiltin(id) != 0
    }
    if liveCapture && builtInScreen == nil {
        fputs("FAIL: live capture requires an active built-in display\n", stderr)
        exit(1)
    }
    let screen = builtInScreen ?? NSScreen.main!
    let full = liveCapture || CommandLine.arguments.contains("--full-screen")
    let rect = full ? screen.frame : NSRect(x: screen.frame.midX - 200, y: screen.frame.midY - 130, width: 400, height: 260)
    let renderer = autoreleasepool { DesktopRenderer() }
    renderer.autoResizeDrawable = liveCapture
    renderer.liveAmount = { time in liveCapture ? 0.3 + 0.18 * sin(time * 3) : 0.08 }
    renderer.amount = liveCapture ? 0.3 : 0.08
    let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.ignoresMouseEvents = true
    panel.backgroundColor = liveCapture ? .clear : .black
    panel.isOpaque = !liveCapture
    if liveCapture { renderer.layer?.isOpaque = false }
    panel.hasShadow = false
    if !liveCapture && full && !CommandLine.arguments.contains("--opaque") { panel.alphaValue = 0.01 }
    panel.contentView = renderer
    panel.setFrame(rect, display: true)
    if liveCapture {
        let capture = DesktopCapture()
        var started = false, receivedFrame = false, failure: String?
        var presentationTimes = [Double]()
        capture.onFrame = { texture in
            renderer.inputTexture = texture
            if !receivedFrame {
                receivedFrame = true
                if started { stopRun() }
            }
        }
        capture.onError = { message in
            failure = message
            panel.orderOut(nil)
            renderer.resetMotion()
            stopRun()
        }
        renderer.onPresented = { _, time, _ in
            if time > 0 { DispatchQueue.main.async { presentationTimes.append(time) } }
        }
        // Make our transparent window enumerable so DesktopCapture can exclude its own application.
        panel.orderFrontRegardless()
        runApp(for: 0.1)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! UInt32
        let startTask = Task { @MainActor in
            do {
                try await capture.start(displayID: displayID)
                started = true
                if receivedFrame { stopRun() }
            } catch {
                failure = error.localizedDescription
                panel.orderOut(nil)
                stopRun()
            }
        }
        runApp(for: 5)
        if !started || !receivedFrame { failure = failure ?? "No live desktop frame arrived during capture startup" }
        var measuredFrom = 0.0
        if failure == nil {
            renderer.resumePresentation()
            runApp(for: 1)
            if failure == nil {
                measuredFrom = CACurrentMediaTime()
                runApp(for: 8)
            }
        }
        panel.orderOut(nil)
        renderer.resetMotion()
        var stopped = false
        Task { @MainActor in
            await startTask.value
            await capture.stop()
            stopped = true
            stopRun()
        }
        let stopDeadline = CACurrentMediaTime() + 5
        while !stopped && CACurrentMediaTime() < stopDeadline { runApp(for: 0.1) }
        if !stopped {
            fputs("FAIL: live desktop capture did not stop within five seconds\n", stderr)
            exit(1)
        }
        runApp(for: 0.1) // Drain presentation callbacks already submitted before the panel was hidden.
        if let failure {
            fputs("FAIL: live desktop capture: \(failure)\n", stderr)
            exit(1)
        }
        let times = Array(Set(presentationTimes.filter { $0 >= measuredFrom && $0 < measuredFrom + 8 })).sorted()
        guard times.count >= 2 else {
            fputs("FAIL: live overlay did not present desktop frames\n", stderr)
            exit(1)
        }
        let intervals = zip(times, times.dropFirst()).map { $1 - $0 }.sorted()
        let p50 = intervals[Int(Double(intervals.count - 1) * 0.5)]
        let p95 = intervals[Int(Double(intervals.count - 1) * 0.95)]
        let fps = Double(times.count) / 8
        let expectedFPS = Double(renderer.preferredFramesPerSecond)
        print("Live capture: frames", capture.frameCount, "presented", times.count, "FPS", fps, "requested FPS", expectedFPS, "interval ms p50/p95/max", p50 * 1000, p95 * 1000, intervals.last! * 1000)
        fflush(stdout)
        assert(fps >= expectedFPS * 0.9, "Live desktop overlay must sustain at least 90% of the requested frame rate")
        assert(p95 <= 1.5 / expectedFPS, "Live desktop overlay's p95 presentation interval must stay within 1.5 display frames")
        let longestGap = max(intervals.last!, max(times.first! - measuredFrom, measuredFrom + 8 - times.last!))
        assert(longestGap <= 3 / expectedFPS, "An isolated presentation stall must not hide behind average FPS or p95")
        print("PASS: live desktop capture and fullscreen presentation cadence")
    } else {
        let source = CIImage(color: CIColor(red: 0.9, green: 0.5, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: rect.width * 2, height: rect.height * 2))
        renderer.frameImage = source
        let inputTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in renderer.frameImage = source }
        defer { inputTimer.invalidate() }
        var rendered = 0, presented = 0
        renderer.onRendered = { _, _ in rendered += 1 }
        renderer.onPresented = { _, time, _ in if time > 0 { DispatchQueue.main.async { presented += 1 } } }
        for cycle in 1...2 {
            runApp(for: 0.25)
            let previous = presented
            panel.orderFrontRegardless()
            // Reproduce the live failure: MTKView reports a valid size while its paused layer remains 0x0.
            renderer.drawableSize = CGSize(width: rect.width * 2, height: rect.height * 2)
            (renderer.layer as! CAMetalLayer).drawableSize = .zero
            renderer.resumePresentation()
            let readySize = (renderer.layer as! CAMetalLayer).drawableSize
            if readySize != renderer.convertToBacking(renderer.bounds).size {
                panel.orderOut(nil)
                fputs("FAIL: overlay activation did not restore its actual backing-pixel drawable size\n", stderr)
                exit(1)
            }
            runApp(for: 0.75)
            panel.orderOut(nil)
            print("Overlay cycle", cycle, "bounds", renderer.bounds, "drawable", renderer.drawableSize, "layer", (renderer.layer as! CAMetalLayer).drawableSize, "rendered", rendered, "presented", presented - previous)
            fflush(stdout)
            assert(presented - previous >= 10, "Hidden nonactivating overlay must present image frames when shown")
        }
        print("PASS: hidden overlay startup and reappearance")
    }
} else if CommandLine.arguments.contains("--motion-test") || CommandLine.arguments.contains("--tracking-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let rect = CommandLine.arguments.contains("--full-screen") ? NSScreen.main!.frame : NSRect(x: 40, y: 40, width: 640, height: 400)
    let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
    let renderer = autoreleasepool { DesktopRenderer() }
    renderer.frameImage = CIImage(color: CIColor(red: 0.8, green: 0.5, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: rect.width * 2, height: rect.height * 2))
    window.contentView = renderer
    // Match the real floating overlay so another normal app cannot occlude this replay.
    window.level = .floating
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    app.activate(ignoringOtherApps: true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    var samples = [Double]()
    var renderTimes = [Double]()
    renderer.onRendered = { samples.append($0); renderTimes.append($1) }
    // Match the hardware's background sampling; keep sparse preview targets on the UI timer.
    let direct = CommandLine.arguments.contains("--tracking-test")
    if direct { renderer.smoothness = 0 } // Keep the original fast-end latency bound; the slider has a separate replay check.
    let startTime = CACurrentMediaTime()
    var hinge = HingeSample()
    hinge.update(130, at: startTime)
    let hingeLock = NSLock()
    var sensorTimer: DispatchSourceTimer?
    var previewTimer: Timer?
    var presented = [Double]()
    var presentationErrors = [Double]()
    var targetErrors = [Double]()
    var uiDeliveryTimes = [Double]()
    var followErrors = [Double]()
    if direct {
        renderer.onRendered = { value, cpuTime in
            samples.append(value); renderTimes.append(cpuTime)
            hingeLock.lock()
            let sample = hinge
            hingeLock.unlock()
            let elapsed = CACurrentMediaTime() - startTime
            if elapsed > 0.2 && elapsed < 0.95 {
                followErrors.append(abs(value - bendAmount(angle: sample.angle, clearAngle: 130)))
            }
        }
        renderer.liveAmount = { time in
            hingeLock.lock()
            let sample = hinge
            hingeLock.unlock()
            return bendAmount(angle: sample.angle, clearAngle: 130)
        }
        renderer.onPresented = { value, timestamp, target in
            DispatchQueue.main.async {
                guard timestamp > 0 else { return }
                presented.append(value)
                let elapsed = timestamp - startTime
                if elapsed > 0.2 && elapsed < 0.95 { presentationErrors.append(abs(value - elapsed * 0.8)); targetErrors.append(timestamp - target) }
            }
        }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.local.bendy.tracking-test", qos: .userInteractive))
        source.schedule(deadline: .now(), repeating: 1.0 / 120, leeway: .microseconds(400))
        source.setEventHandler {
            let now = CACurrentMediaTime()
            let value = min(0.8, (now - startTime) * 0.8)
            hingeLock.lock()
            hinge.update(130 * (1 - value), at: now)
            hingeLock.unlock()
            // The real sensor and capture both deliver through the main queue.
            DispatchQueue.main.async { uiDeliveryTimes.append(CACurrentMediaTime() - now) }
        }
        sensorTimer = source
        source.resume()
        renderer.resumePresentation()
    } else {
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            renderer.amount = min(0.8, (CACurrentMediaTime() - startTime) * 0.8)
            renderer.wake()
        }
    }
    _ = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { _ in
        app.stop(nil)
        app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
    }
    app.run()
    sensorTimer?.cancel()
    previewTimer?.invalidate()
    let largestStep = zip(samples, samples.dropFirst()).map { abs($0 - $1) }.max() ?? 1
    print("Requested FPS:", renderer.preferredFramesPerSecond, "mean submission ms:", renderTimes.reduce(0, +) / Double(max(1, renderTimes.count)) * 1000)
    print("Motion replay: frames=\(samples.count), largestStep=\(largestStep)")
    fflush(stdout)
    assert(samples.count >= 50, "Animation must run independently of sparse HID/capture updates")
    if !direct { assert(largestStep < 0.05, "Sparse preview targets must interpolate without visible jumps") }
    if direct {
        let error = presentationErrors.max() ?? 1
        let deliveries = uiDeliveryTimes.sorted()
        let p95Delivery = deliveries.isEmpty ? 1 : deliveries[Int(Double(deliveries.count - 1) * 0.95)]
        print("Presented frames:", presented.count, "worst tracking error ms:", error / 0.8 * 1000, "max presentation deadline deviation ms:", (targetErrors.max() ?? 0) * 1000)
        print("Main-queue deliveries:", deliveries.count, "p95 wait ms:", p95Delivery * 1000)
        print("Interpolation worst added tracking delay ms:", (followErrors.max() ?? 1) / 0.8 * 1000)
        fflush(stdout)
        assert(presented.count >= 50, "Verify actual drawable presentation, not submitted frames only")
        // Bound intentional interpolation separately from the system's presentation delay.
        assert((followErrors.max() ?? 1) / 0.8 < 0.04, "Interpolation must not add more than 40 ms of target-following delay")
        assert(largestStep < 0.05, "Raw sensor updates must remain continuous at display cadence")
        assert(deliveries.count >= 100 && p95Delivery < 0.05, "Rendering must not starve sensor and capture delivery on the main queue")
    }
    window.orderOut(nil)
    print("PASS: independent animation cadence and hinge tracking")
} else if CommandLine.arguments.contains("--sensor-test") {
    let sensor = LidSensor()
    print(sensor.status)
    print("Initial angle:", sensor.readInitial() as Any)
    var received = 0
    var timestamps = [Double]()
    sensor.onAngle = { _ in received += 1; timestamps.append(sensor.latest.timestamp) }
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    let intervals = zip(timestamps, timestamps.dropFirst()).map { $1 - $0 }.sorted()
    print("Samples delivered:", received, "median interval ms:", intervals.isEmpty ? 0 : intervals[intervals.count / 2] * 1000, "last angle:", sensor.latest.angle)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
