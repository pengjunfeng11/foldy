import Foundation

struct GuardianSnapshot: Decodable {
    struct Row: Decodable {
        let id: String
        let title: String
        let status: String?
        let turn_id: String?
        var key: String { id + ":" + (turn_id ?? "") }
    }
    let ok: Bool
    let checked_at: Double
    let trustworthy: Bool
    let running: [Row]
    let tasks: [Row]
}

// A task's next turn may start a new session; an expired turn cannot renew itself forever.
struct GuardianPolicy {
    private(set) var deadline: Double?
    private(set) var tracked: [GuardianSnapshot.Row] = []
    private var uncertainSince: Double?
    private var expired = Set<String>()

    mutating func update(_ snapshot: GuardianSnapshot?, now: Double, allowed: Bool, duration: Double) -> (hold: Bool, reason: String) {
        guard allowed else { end(); return (false, "disabled") }
        var justExpired = false
        if let deadline, now >= deadline {
            expired.formUnion(tracked.map(\.key))
            end(); justExpired = true
        }
        let running = (snapshot?.running ?? []).filter { !expired.contains($0.key) }
        if !running.isEmpty {
            if deadline == nil { deadline = now + min(7200, max(300, duration)) }
            tracked = tracked.filter { old in
                !running.contains(where: { $0.id == old.id }) && !resolved(old, in: snapshot)
            } + running
            uncertainSince = nil
            return (true, "running")
        }
        if deadline != nil {
            let uncertain = snapshot == nil || tracked.contains { !resolved($0, in: snapshot) }
            if uncertain {
                if uncertainSince == nil { uncertainSince = now }
                if now - uncertainSince! < 30 { return (true, "uncertain") }
                expired.formUnion(tracked.map(\.key))
                end(); return (false, "unknown")
            }
            end(); return (false, "finished")
        }
        return (false, justExpired || !(snapshot?.running.isEmpty ?? true) ? "expired" :
                (snapshot?.trustworthy != true ? "unknown" : "idle"))
    }
    private func resolved(_ old: GuardianSnapshot.Row, in snapshot: GuardianSnapshot?) -> Bool {
        guard let row = snapshot?.tasks.first(where: { $0.id == old.id }) else { return false }
        return ["idle", "interrupted", "ended", "failed", "attention"].contains(row.status ?? "")
    }
    private mutating func end() { deadline = nil; tracked = []; uncertainSince = nil }
}

#if !GUARDIAN_POLICY_CHECK
import AppKit
import SwiftUI
import Security
import IOKit.ps

private struct GuardianReply: Decodable {
    let ok: Bool
    let active: Bool
    let original: Int?
    let current: Int?
    let error: String?
}

private final class GuardianReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
    func finish(_ result: Result<String, Error>) {
        lock.lock(); let saved = continuation; continuation = nil; lock.unlock()
        saved?.resume(with: result)
    }
}

// All state is used on the main run loop. Process work runs on SetupProcess's utility queue.
final class TaskGuardian: ObservableObject {
    @Published var enabled = UserDefaults.standard.bool(forKey: "guardianEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "guardianEnabled")
            if enabled != oldValue { policy = GuardianPolicy() }
            schedule()
        }
    }
    @Published var onlyOnPower = UserDefaults.standard.bool(forKey: "guardianOnlyOnPower") {
        didSet { UserDefaults.standard.set(onlyOnPower, forKey: "guardianOnlyOnPower"); schedule() }
    }
    @Published var normalizeOnInstall = UserDefaults.standard.bool(forKey: "guardianNormalizeOnInstall") {
        didSet { UserDefaults.standard.set(normalizeOnInstall, forKey: "guardianNormalizeOnInstall") }
    }
    @Published var durationMinutes = min(120, max(5, UserDefaults.standard.object(forKey: "guardianDuration") as? Double ?? 30)) {
        didSet { UserDefaults.standard.set(durationMinutes, forKey: "guardianDuration") }
    }
    @Published private(set) var installing = false
    @Published private(set) var connected = false
    @Published private(set) var active = false
    @Published private(set) var runningNames: [String] = []
    @Published private(set) var status = "首次安装后，自动检测本机 Codex 任务。"
    private var allowed = UserDefaults.standard.bool(forKey: "lidHooksEnabled")
    private var shuttingDown = false
    private var policy = GuardianPolicy()
    private var connection: NSXPCConnection?
    private var work: Task<Void, Never>?
    private var pending = false
    private var timer: Timer?
    private let runner = SetupProcess()
    private let isTest = CommandLine.arguments.contains { $0.hasSuffix("-test") }
    private static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bendy Replica/Hooks")

    init() {
        guard !isTest else { return }
        DispatchQueue.main.async { [weak self] in self?.schedule() }
    }
    func setAllowed(_ value: Bool) { allowed = value; schedule() }
    func stop() { enabled = false }

    private func schedule() {
        guard !isTest, !installing, !shuttingDown else { return }
        if enabled && timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.schedule() }
            timer?.tolerance = 0.5
        } else if !enabled { timer?.invalidate(); timer = nil }
        pending = true
        guard work == nil else { return }
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.pending && !self.shuttingDown && !self.installing {
                self.pending = false
                await self.reconcile()
            }
            self.work = nil
        }
    }

    @MainActor private func reconcile() async {
        do {
            if connection == nil {
                guard FileManager.default.fileExists(atPath: GuardianPaths.helper) else {
                    status = "点击安装并授权后，才能执行系统防休眠命令。"; return
                }
                let reply = try await request("status")
                connected = true; active = reply.active
            }
            let eligible = enabled && allowed && (!onlyOnPower || Self.onACPower) && !shuttingDown
            var snapshot: GuardianSnapshot?
            if eligible { snapshot = try? await readTasks() }
            runningNames = snapshot?.running.map(\.title) ?? []
            // User switches may have changed while the metadata query was in flight.
            let stillEligible = eligible && enabled && allowed && (!onlyOnPower || Self.onACPower) && !shuttingDown
            let decision = policy.update(snapshot, now: ProcessInfo.processInfo.systemUptime, allowed: stillEligible, duration: durationMinutes * 60)
            if decision.hold {
                let reply = try await request("renew")
                active = reply.active; connected = true
                guard reply.active && reply.current == 1 else { throw SetupFailure("系统尚未确认防休眠。") }
                let remaining = Int(ceil(max(0, (policy.deadline ?? 0) - ProcessInfo.processInfo.systemUptime) / 60))
                status = decision.reason == "uncertain" ? "任务状态暂时不可读，最多保留 30 秒后恢复。" : "正在守护 \(runningNames.count) 个任务，合盖继续运行；最多剩余 \(remaining) 分钟。"
                if reply.original == 1 { status += "原设置已全局禁睡，结束后仍保留该设置。" }
            } else {
                if active {
                    let reply = try await request("restore")
                    active = reply.active
                    guard !active else { throw SetupFailure("系统尚未确认恢复。") }
                    status = reply.current == 1 ? "守护已结束；已恢复原来的全局禁睡设置。" : "守护已结束；已恢复正常休眠。"
                } else if !enabled { status = "任务守护已关闭。" }
                else if !allowed { status = "先开启上方的“启用合盖动作”。" }
                else if onlyOnPower && !Self.onACPower { status = "等待接通电源。" }
                else if decision.reason == "expired" { status = "本轮守护已停止。重新开关守护可继续这批任务。" }
                else if decision.reason == "unknown" { status = "暂时无法确认任务状态，未开启防休眠。" }
                else { status = "正在检测任务；有任务运行时自动防休眠。" }
            }
        } catch {
            disconnect()
            status = "任务守护未就绪：\(error.localizedDescription) 请重新安装并授权。"
        }
    }

    @MainActor private func readTasks() async throws -> GuardianSnapshot {
        guard let script = Bundle.main.url(forResource: "bendy_hooks", withExtension: "py") else { throw SetupFailure("缺少任务检测脚本。") }
        let data = try? Data(contentsOf: Self.root.appendingPathComponent("config.json"))
        let config = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let python = config?["python_path"] as? String ?? "/usr/bin/python3"
        let arguments = [script.path, "guardian-status"] + Set(policy.tracked.map(\.id)).sorted().flatMap { ["--task-id", $0] }
        let result = try await runner.run(python, arguments, environment: ProcessInfo.processInfo.environment, cwd: FileManager.default.homeDirectoryForCurrentUser, timeout: 5, line: { _ in })
        guard result.code == 0, let bytes = result.output.data(using: .utf8) else { throw SetupFailure("任务检测失败。") }
        let snapshot = try JSONDecoder().decode(GuardianSnapshot.self, from: bytes)
        guard snapshot.ok, abs(Date().timeIntervalSince1970 - snapshot.checked_at) < 15 else { throw SetupFailure("任务检测结果已过期。") }
        return snapshot
    }

    @MainActor private func request(_ operation: String) async throws -> GuardianReply {
        if connection == nil {
            guard let helper = Bundle.main.url(forResource: "FoldyGuardian", withExtension: nil) else { throw SetupFailure("缺少防休眠助手。") }
            var code: SecStaticCode?, info: CFDictionary?
            guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
                  SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else { throw SetupFailure("防休眠助手签名无效。") }
            let client = NSXPCConnection(machServiceName: GuardianPaths.label, options: .privileged)
            client.remoteObjectInterface = NSXPCInterface(with: GuardianServiceProtocol.self)
            client.setCodeSigningRequirement("cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\"")
            client.resume(); connection = client
        }
        let client = connection!
        let json: String = try await withCheckedThrowingContinuation { continuation in
            let once = GuardianReplyOnce(continuation)
            let proxy = client.remoteObjectProxyWithErrorHandler { once.finish(.failure($0)) } as? GuardianServiceProtocol
            guard let proxy else { once.finish(.failure(SetupFailure("无法连接系统助手。"))); return }
            let reply: (String) -> Void = { once.finish(.success($0)) }
            switch operation {
            case "renew": proxy.renew(60, reply: reply)
            case "restore": proxy.restore(reply: reply)
            default: proxy.status(reply: reply)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) { once.finish(.failure(SetupFailure("系统助手响应超时。"))) }
        }
        let reply = try JSONDecoder().decode(GuardianReply.self, from: Data(json.utf8))
        guard reply.ok else { throw SetupFailure(reply.error ?? "系统助手操作失败。") }
        return reply
    }

    func install() {
        guard !installing, !isTest else { return }
        installing = true; status = "即将显示 macOS 管理员验证窗口…"
        timer?.invalidate(); timer = nil
        Task { @MainActor in
            if let work { await work.value }
            if active { _ = try? await request("restore") }
            disconnect()
            do {
                guard let pkg = Bundle.main.url(forResource: "Guardian", withExtension: "pkg") else { throw SetupFailure("缺少任务守护安装包。") }
                var appCode: SecStaticCode?
                guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &appCode) == errSecSuccess, let appCode,
                      SecStaticCodeCheckValidity(appCode, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else { throw SetupFailure("Foldy 安装资源签名校验失败。") }
                // Validate an immutable root-owned copy against the digest embedded at build time.
                // Checking the user-writable source before an auth dialog leaves a replacement race.
                let command = [
                    "set -eu",
                    "guardian_stage=$(/usr/bin/mktemp -d /private/tmp/foldy-guardian.XXXXXX)",
                    "/bin/chmod 700 \"$guardian_stage\"",
                    "trap '/bin/rm -rf \"$guardian_stage\"' EXIT",
                    "/bin/cp " + Self.shellQuote(pkg.path) + " \"$guardian_stage/Guardian.pkg\"",
                    "guardian_digest=$(/usr/bin/shasum -a 256 \"$guardian_stage/Guardian.pkg\" | /usr/bin/cut -d ' ' -f 1)",
                    "[ \"$guardian_digest\" = " + Self.shellQuote(GuardianPackage.sha256) + " ] || { /bin/echo '安装包校验失败，未安装。' >&2; exit 1; }",
                    "/usr/sbin/installer -pkg \"$guardian_stage/Guardian.pkg\" -target /",
                    Self.shellQuote(GuardianPaths.helper) + " --install " + Self.shellQuote(Bundle.main.bundleURL.path) + " " + String(getuid()) + (normalizeOnInstall ? " --normal-sleep" : "")
                ].joined(separator: "; ")
                let script = "do shell script \"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
                let result = try await runner.run("/usr/bin/osascript", ["-e", script], environment: ProcessInfo.processInfo.environment, cwd: FileManager.default.temporaryDirectory, timeout: 180, line: { _ in })
                guard result.code == 0 else { throw SetupFailure(result.error.contains("-128") ? "已取消管理员验证。" : String(result.error.suffix(1200))) }
                guard !shuttingDown else { throw CancellationError() }
                _ = try await request("status")
                guard !shuttingDown else { throw CancellationError() }
                connected = true; enabled = true; policy = GuardianPolicy()
                status = "安装成功，正在检测任务…"
            } catch { disconnect(); status = "安装未完成：\(error.localizedDescription)" }
            installing = false
            if connected { schedule() }
        }
    }

    @MainActor func shutdown() async {
        shuttingDown = true; timer?.invalidate(); timer = nil
        runner.cancel()
        if let work { await work.value }
        if connection != nil { _ = try? await request("restore") }
        disconnect()
    }
    private func disconnect() { connection?.invalidate(); connection = nil; connected = false; active = false }
    private static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static var onACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let kind = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return kind as String == kIOPSACPowerValue
    }
}
#endif
