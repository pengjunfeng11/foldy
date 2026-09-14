import Foundation
import IOKit.hid
import QuartzCore

func bendAmount(angle: Double, clearAngle: Double) -> Double {
    guard angle.isFinite, clearAngle.isFinite, clearAngle > 0 else { return 0 }
    // Direct manipulation: easing belongs in shading, not between the hinge and the geometry.
    return min(1, max(0, (clearAngle - angle) / clearAngle))
}
func decodeAngle(_ bytes: [UInt8]) -> Double? {
    guard let id = bytes.first else { return nil }
    if id == 1, bytes.count >= 3 {
        let raw = Int(bytes[1]) | Int(bytes[2]) << 8
        return raw <= 360 ? Double(raw) : nil
    }
    if id == 7, (5...8).contains(bytes.count) {
        let raw = bytes.dropFirst().enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        return raw <= 36000 ? Double(raw) / 100 : nil
    }
    return nil
}
struct HingeSample {
    var angle = 120.0
    var timestamp = 0.0
    mutating func update(_ raw: Double, at time: Double) {
        // The sensor wraps around zero at a closed lid (359.52 means -0.48 degrees).
        angle = min(raw, 360 - raw)
        timestamp = time
    }
}
final class LidSensor {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private var device: IOHIDDevice?
    private let lock = NSLock()
    private var sample = HingeSample()
    private var pendingDelivery = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "app.local.bendy.hinge", qos: .userInteractive)
    var onAngle: ((Double) -> Void)?
    var status = "未找到铰链传感器"
    private var precise = false
    private var buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    var latest: HingeSample { lock.lock(); defer { lock.unlock() }; return sample }
    init() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x05ac, kIOHIDDeviceUsagePageKey: 0x20, kIOHIDDeviceUsageKey: 0x8a] as CFDictionary)
        IOHIDManagerOpen(manager, 0)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let found = devices.first else { return }
        guard IOHIDDeviceOpen(found, 0) == kIOReturnSuccess else { status = "传感器无法打开"; return }
        device = found
        if let fine = readReport(7) {
            precise = true
            sample.update(fine, at: CACurrentMediaTime())
            status = "高精度铰链 · 0.01° · 120 Hz 采样"
            // Report 7 is not emitted as an input event on this Mac; sample it off the UI thread.
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: 1.0 / 120, leeway: .microseconds(400))
            source.setEventHandler { [weak self] in
                guard let self, let angle = self.readReport(7) else { return }
                self.accept(angle)
            }
            timer = source
            source.resume()
        } else {
            status = "整数角度传感器 · 事件跟随"
            IOHIDDeviceRegisterInputReportCallback(found, buffer, 64, { context, result, _, _, reportID, report, length in
                guard result == kIOReturnSuccess, reportID == 1, let context else { return }
                let sensor = Unmanaged<LidSensor>.fromOpaque(context).takeUnretainedValue()
                if let angle = decodeAngle(Array(UnsafeBufferPointer(start: report, count: length))) { sensor.accept(angle) }
            }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDDeviceScheduleWithRunLoop(found, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
    }
    private func accept(_ angle: Double) {
        lock.lock()
        sample.update(angle, at: CACurrentMediaTime())
        let deliver = !pendingDelivery
        pendingDelivery = true
        lock.unlock()
        if deliver {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.pendingDelivery = false
                let angle = self.sample.angle
                self.lock.unlock()
                self.onAngle?(angle)
            }
        }
    }
    private func readReport(_ id: Int) -> Double? {
        guard let device else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8)
        var count = bytes.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, id, &bytes, &count) == kIOReturnSuccess else { return nil }
        return decodeAngle(Array(bytes.prefix(count)))
    }
    func readInitial() -> Double? {
        guard let raw = readReport(precise ? 7 : 1) else { return nil }
        lock.lock()
        sample.update(raw, at: CACurrentMediaTime())
        lock.unlock()
        return min(raw, 360 - raw)
    }
    deinit {
        timer?.cancel()
        if let device {
            if !precise { IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) }
            IOHIDDeviceClose(device, 0)
        }
        IOHIDManagerClose(manager, 0)
        buffer.deallocate()
    }
}
// Sensor readings are targets. Advance at display cadence, preserving motion between readings.
struct BendMotion {
    var value = 0.0
    var velocity = 0.0
    mutating func advance(target: Double, dt: Double, omega: Double = 34) {
        guard target.isFinite, dt.isFinite, dt > 0 else { return }
        let target = min(1, max(0, target))
        let t = min(dt, 0.1)
        let displacement = value - target, c = velocity + omega * displacement
        let decay = exp(-omega * t)
        value = target + (displacement + c * t) * decay
        velocity = (velocity - omega * c * t) * decay
        if abs(value - target) < 0.00005 && abs(velocity) < 0.001 { value = target; velocity = 0 }
    }
    mutating func follow(target: Double, dt: Double, smoothness: Double = 0) {
        guard target.isFinite else { return }
        let target = min(1, max(0, target)), previous = value
        // The difference sets the pursuit speed; keep one continuous motion, not a queue of tweens.
        let softness = smoothness.isFinite ? min(1, max(0, smoothness)) : 0.5
        // 0 preserves the old response; 1 spreads a step over roughly 260 ms to 95%.
        advance(target: target, dt: dt, omega: 90 / (1 + 4 * softness))
        if (target - previous) * (target - value) < 0 { value = target; velocity = 0 }
    }
    func settled(at target: Double) -> Bool { abs(value - target) < 0.00005 && abs(velocity) < 0.001 }
}
