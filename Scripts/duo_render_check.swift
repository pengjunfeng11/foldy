// Run from the repo: xcrun swiftc -O -assert-config Debug -swift-version 5 -target arm64-apple-macos14.0 Sources/Core.swift Sources/Renderer.swift Scripts/duo_render_check.swift -o /tmp/foldy-duo-render-check && /tmp/foldy-duo-render-check
import AppKit
import CoreImage

@main struct DuoRenderCheck {
    static func main() {
        _ = NSApplication.shared
        let renderer = DesktopRenderer()
        let width = 400, height = 240
        let size = CGSize(width: width, height: height)
        let bounds = CGRect(origin: .zero, size: size)
        let white = CIImage(color: .white).cropped(to: bounds)
        func pixels(_ source: CIImage, _ bend: Double) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            renderer.context.render(renderer.processed(source, size: size, strength: bend), toBitmap: &bytes,
                rowBytes: width * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return bytes
        }
        func red(_ bytes: [UInt8], _ x: Int, _ y: Int) -> Double { Double(bytes[(y * width + x) * 4]) }
        renderer.perspective = 0
        renderer.blur = 0
        renderer.shadowStrength = 1
        renderer.style = "Silk"
        var failures = [String]()
        func check(_ valid: Bool, _ message: String) { if !valid { failures.append(message) } }

        // Independent scalar oracle, from chuspeeism/iphone-duo main.js screenColor().
        // Rotate its horizontal hinge-distance gradient onto a Mac's bottom hinge.
        var maximumError = 0.0
        for bend in [0.15, 0.5, 0.8] {
            let result = pixels(white, bend)
            for y in [24, 72, 132, 204] {
                let edge = 1 - (Double(y) + 0.5) / Double(height)
                let motion = bend * bend * (3 - 2 * bend)
                let gradient = max(0, min(1, (edge - 0.2) / 0.8))
                let linear = 1 - min(1, 2 * motion * pow(gradient, 1.35))
                let expected = 255 * (linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055)
                maximumError = max(maximumError, abs(red(result, width / 2, y) - expected))
            }
        }
        print(String(format: "Reference darkness maximum byte error: %.3f", maximumError))
        check(maximumError <= 2, "Silk darkness must follow the reference's smoothstep, hinge gradient and black clamp")

        var previous = pixels(white, 0)
        for bend in stride(from: 0.05, through: 1.0, by: 0.05) {
            let current = pixels(white, bend)
            for y in [24, 72, 132, 204] {
                check(red(current, width / 2, y) <= red(previous, width / 2, y) + 1, "Closing must never brighten the same source point")
            }
            previous = current
        }

        renderer.shadowStrength = 0
        renderer.perspective = 1
        var gradient = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            gradient[i] = UInt8(x * 255 / (width - 1))
            gradient[i + 1] = UInt8(y * 255 / (height - 1))
        } }
        let coordinateImage = CIImage(bitmapData: Data(gradient), bytesPerRow: width * 4, size: size,
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let unbent = pixels(coordinateImage, 0)
        func sample(_ u: Double, _ v: Double, _ channel: Int) -> Double {
            let x = u * Double(width) - 0.5, y = v * Double(height) - 0.5
            let ix = Int(floor(x)), iy = Int(floor(y)), tx = x - floor(x), ty = y - floor(y)
            func p(_ dx: Int, _ dy: Int) -> Double { Double(unbent[((iy + dy) * width + ix + dx) * 4 + channel]) }
            return (p(0, 0) * (1 - tx) + p(1, 0) * tx) * (1 - ty)
                 + (p(0, 1) * (1 - tx) + p(1, 1) * tx) * ty
        }
        var projectionError = 0.0
        for bend in [0.25, 0.5, 0.75] {
            let result = pixels(coordinateImage, bend), angle = bend * .pi / 2
            for (x, y) in [(100, 48), (280, 96), (160, 180)] {
                // Reference front eye z=40; unfolded screen plane z=.24948; moving half=7.89935.
                // Rotate a physical point about the bottom hinge, then intersect eye→point with that plane.
                let hingeDistance = (1 - (Double(y) + 0.5) / Double(height)) * 7.89935
                let pointY = hingeDistance * cos(angle), pointZ = 0.24948 + hingeDistance * sin(angle)
                let ray = (0.24948 - 40) / (pointZ - 40)
                let u = 0.5 + ((Double(x) + 0.5) / Double(width) - 0.5) * ray
                let v = 1 - pointY * ray / 7.89935
                for channel in 0...1 {
                    projectionError = max(projectionError, abs(Double(result[(y * width + x) * 4 + channel]) - sample(u, v, channel)))
                }
            }
        }
        print(String(format: "Reference projection maximum byte error: %.3f", projectionError))
        check(projectionError <= 2, "Both source coordinates must match fixed-eye projection of the hinged physical plane")

        renderer.perspective = 0
        renderer.blur = 0.65
        var stripes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width where (x / 4) % 2 == 0 {
            let i = (y * width + x) * 4
            stripes[i] = 0; stripes[i + 1] = 0; stripes[i + 2] = 0
        } }
        let striped = CIImage(bitmapData: Data(stripes), bytesPerRow: width * 4, size: size,
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        func contrast(_ bytes: [UInt8], _ y: Int) -> Double {
            let values = (160..<240).map { red(bytes, $0, y) }, mean = values.reduce(0, +) / 80
            return values.map { abs($0 - mean) }.reduce(0, +) / 80
        }
        var lastContrast = Double.infinity
        for bend in [0.0, 0.2, 0.4, 0.6] {
            let result = pixels(striped, bend), far = contrast(result, 48), near = contrast(result, 216)
            check(far <= lastContrast + 1, "Far-edge detail must fade monotonically as folding increases")
            check(near + 1 >= far, "Blur must grow away from the bottom hinge")
            lastContrast = far
        }
        renderer.perspective = 1
        let coverage = pixels(white, 0.7)
        check((0..<height).allSatisfy { red(coverage, width / 2, $0) > 32 }, "Blur must not introduce a full-width black strip")
        let side = (0..<100).map { red(coverage, $0, 80) }
        check(Set(side.filter { $0 > 16 && $0 < 239 }).count >= 3, "Blurred side coverage must contain at least three distinct intermediate brightness levels")
        let before = pixels(striped, 0.4500), after = pixels(striped, 0.4501)
        let jump = zip(before, after).map { abs(Int($0) - Int($1)) }.max()!
        check(jump <= 2, "A tiny fold increment must not pop at a blur/coverage threshold")
        if !failures.isEmpty {
            failures.forEach { print("FAIL:", $0) }
            exit(1)
        }
        print("PASS: actual Metal reference darkness and projection, monotonic blur, continuous coverage")
    }
}
