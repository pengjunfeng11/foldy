// xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 Sources/FeishuConnection.swift Scripts/setup_process_check.swift -o /tmp/foldy-setup-process-check && /tmp/foldy-setup-process-check
import Foundation
import Darwin

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func contains(_ value: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values.contains(value) }
}

@main struct SetupProcessCheck {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("foldy-process-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let runner = SetupProcess(), lines = Lines()
        let result = try await runner.run("/bin/sh", ["-c", "printf '{\"ok\":true}\\n'; printf 'warning\\nhttps://open.feishu.cn/test\\n' >&2"], environment: environment, cwd: root, timeout: 2) { lines.append($0) }
        precondition(result.code == 0 && result.output == "{\"ok\":true}\n")
        precondition(result.error == "warning\nhttps://open.feishu.cn/test\n")
        precondition(lines.contains("https://open.feishu.cn/test"), "Authorization URLs on stderr must still be observed")
        _ = try JSONSerialization.jsonObject(with: Data(result.output.utf8))

        // Both the direct child and its descendant ignore TERM, requiring group KILL.
        let stubborn = "trap '' TERM; printf '%s' \"$$\" > \"$1\"; /bin/sh -c 'trap \"\" TERM; while :; do /bin/sleep 10; done' & wait"
        func pid(_ name: String) -> pid_t? { (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)).flatMap(Int32.init) }
        func assertGone(_ name: String) {
            guard let processID = pid(name) else { preconditionFailure("Fixture did not start: \(name)") }
            precondition(kill(processID, 0) == -1 && errno == ESRCH, "Direct process survived: \(name)")
            precondition(kill(-processID, 0) == -1 && errno == ESRCH, "Descendant survived: \(name)")
        }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await runner.run("/bin/sh", ["-c", stubborn, "check", root.appendingPathComponent("timeout").path], environment: environment, cwd: root, timeout: 0.2) { _ in }
            preconditionFailure("A timeout must fail")
        } catch { precondition(!(error is CancellationError)) }
        precondition(ProcessInfo.processInfo.systemUptime - start < 3, "Timeout must be bounded")
        assertGone("timeout")

        let first = Task { try await runner.run("/bin/sh", ["-c", stubborn, "check", root.appendingPathComponent("first").path], environment: environment, cwd: root, timeout: 10) { _ in } }
        let second = Task { try await runner.run("/bin/sh", ["-c", stubborn, "check", root.appendingPathComponent("second").path], environment: environment, cwd: root, timeout: 10) { _ in } }
        for _ in 0..<100 {
            if pid("first") != nil && pid("second") != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(pid("first") != nil && pid("second") != nil)
        runner.cancel()
        for task in [first, second] {
            do { _ = try await task.value; preconditionFailure("Cancelled work must fail") }
            catch { precondition(error is CancellationError) }
        }
        assertGone("first"); assertGone("second")

        let cancelledTask = Task { try await runner.run("/bin/sh", ["-c", stubborn, "check", root.appendingPathComponent("task-cancel").path], environment: environment, cwd: root, timeout: 10) { _ in } }
        for _ in 0..<100 {
            if pid("task-cancel") != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(pid("task-cancel") != nil)
        cancelledTask.cancel()
        do { _ = try await cancelledTask.value; preconditionFailure("Task cancellation must stop its process") }
        catch { precondition(error is CancellationError) }
        assertGone("task-cancel")

        let queue = DispatchQueue(label: "foldy.setup-check.held")
        queue.suspend()
        let held = SetupProcess(queue: queue)
        let queued = Task { try await held.run("/usr/bin/touch", [root.appendingPathComponent("must-not-start").path], environment: environment, cwd: root, timeout: 2) { _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        held.cancel()
        queue.resume()
        do { _ = try await queued.value; preconditionFailure("Cancelled queued work must not launch") }
        catch { precondition(error is CancellationError) }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-start").path))

        print("PASS: separate stdout/stderr, URL observation, bounded TERM-resistant timeout, concurrent/task/queued cancellation and no surviving process groups")
    }
}
