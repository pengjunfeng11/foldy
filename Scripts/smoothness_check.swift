// xcrun swiftc -O -assert-config Debug -swift-version 5 -target arm64-apple-macos14.0 Sources/Core.swift Sources/Renderer.swift Scripts/smoothness_check.swift -o /tmp/foldy-smoothness-check && /tmp/foldy-smoothness-check
import AppKit

@main struct SmoothnessCheck {
    static func main() {
        _ = NSApplication.shared
        var ripples = [Double]()
        for softness in [0.0, 0.5, 1.0] {
            var motion = BendMotion(), speeds = [Double]()
            for frame in 0..<360 {
                let previous = motion.value
                // Sparse, stepped 20 Hz input; animation continues at 120 Hz.
                motion.follow(target: Double(frame / 6) / 20 * 0.2, dt: 1 / 120.0, smoothness: softness)
                if frame > 120 { speeds.append((motion.value - previous) * 120) }
            }
            let mean = speeds.reduce(0, +) / Double(speeds.count)
            let ripple = sqrt(speeds.map { pow($0 - mean, 2) }.reduce(0, +) / Double(speeds.count)) / mean
            ripples.append(ripple)
            for target in [0.1, 0.8, 0.0] {
                for _ in 0..<120 {
                    motion.follow(target: target, dt: 1 / 120.0, smoothness: softness)
                    precondition((0...1).contains(motion.value), "Motion must remain bounded during reversal")
                }
                precondition(motion.settled(at: target), "Even maximum smoothing must settle within one second")
            }
            print("Smoothness", softness, "speed ripple", ripple)
        }
        precondition(ripples[1] < ripples[0] / 3 && ripples[2] < ripples[1], "The slider must actually reduce stop-go motion")

        // Exercise the renderer's real integration entry point without a window or screen permission.
        // Fast, irregularly timed callbacks must not alter a fixed presentation timeline.
        let renderer = DesktopRenderer()
        renderer.liveAmount = { _ in 0 }
        renderer.preferredFramesPerSecond = 120
        var expected = BendMotion()
        for frame in 0..<120 {
            let target = Double(frame) / 120 * 0.5
            let softness = frame < 60 ? 0.5 : 1.0
            renderer.smoothness = softness
            expected.follow(target: target, dt: 1 / 120.0, smoothness: softness)
            renderer.advanceMotion(to: target, at: 100 + Double(frame) / 120)
            precondition(abs(renderer.motion.value - expected.value) < 1e-9, "Animation must use presentation time, including when changing the slider mid-motion")
        }
        renderer.resetMotion()
        expected = BendMotion()
        expected.follow(target: 0.5, dt: 1 / 120.0, smoothness: 1)
        renderer.advanceMotion(to: 0.5, at: 1000)
        precondition(abs(renderer.motion.value - expected.value) < 1e-9, "Resume must reset the presentation clock, not jump across hidden time")
        print("PASS: smoothness range, retarget/settle, presentation clock and live adjustment")
    }
}
