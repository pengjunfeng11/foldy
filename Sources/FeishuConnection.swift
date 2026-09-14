import AppKit
import SwiftUI
import CryptoKit

// Setup runs only from the connection button; the animation never waits for it.
@MainActor final class FeishuConnection: ObservableObject {
    @Published var busy = false
    @Published var connected = false
    @Published var status = "连接后，合盖摘要会发送给你自己的飞书账号。"
    @Published var accountName = ""
    @Published var verificationURL: URL?
    @Published var qrCode: NSImage?
    private var task: Task<Void, Never>?
    private let runner = SetupProcess()
    private var session = UUID()
    private var authorization = UUID()
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bendy Replica/Hooks")
    private static let cliVersion = "1.0.81"
    private static let cliSHA = "0693846b129044a8c1312999f04ff26343b9a2fdb41615343e33fe67cea9dea5"
    private var config: [String: Any] { Self.readJSON(Self.root.appendingPathComponent("config.json")) }

    func refreshStatus() {
        guard !busy else { return }
        let saved = config
        guard let path = saved["lark_path"] as? String, FileManager.default.isExecutableFile(atPath: path),
              let recipient = saved["recipient_open_id"] as? String, !recipient.isEmpty else {
            connected = false
            status = "尚未连接。点击下方按钮自动安装并打开飞书配置页面。"
            return
        }
        start { [weak self] token in
            guard let self else { return }
            self.status = "正在检查飞书连接…"
            let data = try await self.authStatus(path, directory: saved["lark_config_dir"] as? String)
            guard self.session == token else { return }
            let user = (data["identities"] as? [String: Any])?["user"] as? [String: Any] ?? [:]
            let bot = (data["identities"] as? [String: Any])?["bot"] as? [String: Any] ?? [:]
            guard bot["available"] as? Bool == true, bot["verified"] as? Bool == true else { throw SetupFailure("飞书应用连接已失效，请重新连接。") }
            if let expected = saved["account_open_id"] as? String {
                guard user["openId"] as? String == expected, data["appId"] as? String == saved["app_id"] as? String,
                      user["verified"] as? Bool == true else { throw SetupFailure("登录账号已变化或失效，已保留原收件人；请重新连接。") }
            }
            self.connected = true
            self.accountName = saved["account_name"] as? String ?? user["userName"] as? String ?? "已配置的飞书账号"
            self.status = "账号连接正常。可用“发送测试消息”验证提醒送达。"
        }
    }

    func connect() {
        guard !busy else { return }
        start { [weak self] token in
            guard let self else { return }
            try Self.ensureDirectory(Self.root)
            let directory = Self.root.appendingPathComponent("Feishu").path
            try Self.ensureDirectory(URL(fileURLWithPath: directory))
            let cli = try await self.prepareCLI()
            let python = try await self.preparePython()
            self.status = "正在检查飞书应用…"
            let initial = try? await self.authStatus(cli, directory: directory)
            try Task.checkCancellation()
            if initial?["appId"] as? String == nil {
                self.status = "请在飞书页面确认创建应用，完成后会自动继续。"
                _ = try await self.command(cli, ["config", "init", "--new", "--brand", "feishu", "--lang", "zh_cn"], directory: directory, timeout: 620, token: token, watchURLs: true)
                self.clearAuthorization()
            }
            let current = try await self.authStatus(cli, directory: directory)
            let user = (current["identities"] as? [String: Any])?["user"] as? [String: Any] ?? [:]
            if user["verified"] as? Bool != true || user["available"] as? Bool != true {
                self.status = "请确认飞书登录，以便将摘要发送给你本人。"
                let response = try await self.command(cli, ["auth", "login", "--scope", "contact:user.base:readonly", "--no-wait", "--json"], directory: directory, timeout: 30)
                let auth = try Self.parseJSON(response)
                guard let rawURL = auth["verification_url"] as? String, let code = auth["device_code"] as? String else {
                    throw SetupFailure("飞书没有返回有效的登录页面，请重试。")
                }
                try await self.showAuthorization(rawURL, cli: cli, directory: directory, token: token, phase: self.authorization)
                _ = try await self.command(cli, ["auth", "login", "--device-code", code, "--json"], directory: directory, timeout: 620)
            }
            self.clearAuthorization()
            self.status = "正在绑定当前账号并接入 Codex 任务状态…"
            guard let script = Bundle.main.url(forResource: "foldy_setup", withExtension: "py") else { throw SetupFailure("安装包缺少连接组件，请重新安装 Foldy。") }
            var args = [script.path, "finish", "--lark", cli, "--lark-config-dir", directory, "--python", python]
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
                let executable = app.appendingPathComponent("Contents/Resources/codex").path
                if FileManager.default.isExecutableFile(atPath: executable) { args += ["--codex", executable] }
            }
            let result = try Self.parseJSON(try await self.command(python, args, timeout: 60))
            guard result["ok"] as? Bool == true else { throw SetupFailure(result["message"] as? String ?? "连接未完成，请重试。") }
            guard self.session == token else { return }
            self.connected = true
            self.accountName = result["account_name"] as? String ?? "当前飞书账号"
            self.status = "已连接。开启合盖动作后，摘要会发送给本人；可先发送测试消息。"
        }
    }

    func cancel() {
        guard busy else { return }
        session = UUID()
        task?.cancel(); task = nil
        runner.cancel()
        busy = false; clearAuthorization()
        status = "已取消连接，可以稍后重试。"
    }

    private func start(_ operation: @escaping (UUID) async throws -> Void) {
        let token = UUID(); session = token; busy = true
        task = Task { [weak self] in
            do { try await operation(token) }
            catch {
                guard let self, self.session == token else { return }
                self.connected = false
                self.status = (error as? SetupFailure)?.message ?? (error is CancellationError ? "已取消连接。" : "连接未完成，请检查网络后重试。")
            }
            guard let self, self.session == token else { return }
            self.busy = false; self.clearAuthorization(); self.task = nil
        }
    }

    private func prepareCLI() async throws -> String {
        let destination = Self.root.appendingPathComponent("Tools/lark-cli")
        if FileManager.default.isExecutableFile(atPath: destination.path),
           let version = try? await command(destination.path, ["--version"], timeout: 10), version.contains(Self.cliVersion) { return destination.path }
        status = "正在安装飞书连接组件，无需 Homebrew 或管理员密码…"
        let url = URL(string: "https://github.com/larksuite/cli/releases/download/v\(Self.cliVersion)/lark-cli-\(Self.cliVersion)-darwin-arm64.tar.gz")!
        try await installArchive(url: url, sha: Self.cliSHA, member: "lark-cli", destination: destination)
        return destination.path
    }

    private func preparePython() async throws -> String {
        // /usr/bin/python3 is an installer stub on a clean Mac. Avoid launching it.
        let developerTools = (try? await command("/usr/bin/xcode-select", ["-p"], timeout: 5)) != nil
        let candidates = [config["python_path"] as? String, "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].compactMap { $0 }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if URL(fileURLWithPath: path).resolvingSymlinksInPath().path == "/usr/bin/python3" && !developerTools { continue }
            if (try? await command(path, ["-c", "import sys;sys.exit(0 if sys.version_info >= (3,9) else 1)"], timeout: 8)) != nil { return path }
        }
        status = "正在准备摘要运行组件，仅安装到 Foldy 的目录…"
        let uv = Self.root.appendingPathComponent("Tools/uv")
        if !FileManager.default.isExecutableFile(atPath: uv.path) {
            try await installArchive(url: URL(string: "https://releases.astral.sh/github/uv/releases/download/0.11.7/uv-aarch64-apple-darwin.tar.gz")!,
                sha: "66e37d91f839e12481d7b932a1eccbfe732560f42c1cfb89faddfa2454534ba8", member: "uv-aarch64-apple-darwin/uv", destination: uv)
        }
        let runtime = Self.root.appendingPathComponent("Python")
        _ = try await command(uv.path, ["--no-config", "--no-cache", "python", "install", "3.12.13", "--install-dir", runtime.path, "--no-bin", "--no-progress"], timeout: 300)
        let path = try await command(uv.path, ["--no-config", "--no-cache", "python", "find", "3.12.13", "--managed-python", "--no-project", "--system", "--offline", "--resolve-links"],
            timeout: 15, extraEnvironment: ["UV_PYTHON_INSTALL_DIR": runtime.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(runtime.resolvingSymlinksInPath().path + "/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw SetupFailure("摘要运行组件安装未完成，请重试。")
        }
        return path
    }

    private func authStatus(_ cli: String, directory: String?) async throws -> [String: Any] {
        try Self.parseJSON(try await command(cli, ["auth", "status", "--json", "--verify"], directory: directory, timeout: 20))
    }

    private func clearAuthorization() {
        authorization = UUID(); verificationURL = nil; qrCode = nil
    }

    private func showAuthorization(_ raw: String, cli: String, directory: String?, token: UUID, phase: UUID) async throws {
        guard session == token, authorization == phase else { return }
        guard let url = Self.authorizationURL(raw) else { throw SetupFailure("飞书返回了无法识别的授权地址，已停止连接。") }
        verificationURL = url
        let imageName = "authorization-\(UUID().uuidString).png"
        let imageURL = Self.root.appendingPathComponent(imageName)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        _ = try? await command(cli, ["auth", "qrcode", raw, "--output", imageName], directory: directory, timeout: 10)
        guard session == token, authorization == phase, verificationURL == url else { return }
        qrCode = NSImage(contentsOf: imageURL)
        NSWorkspace.shared.open(url)
    }

    private func command(_ executable: String, _ arguments: [String], directory: String? = nil, timeout: Double,
                         token: UUID? = nil, watchURLs: Bool = false, extraEnvironment: [String: String] = [:]) async throws -> String {
        try Task.checkCancellation()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        environment["LARKSUITE_CLI_NO_UPDATE_NOTIFIER"] = "1"
        environment["LARKSUITE_CLI_NO_SKILLS_NOTIFIER"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        // A managed install uses the pinned download catalog, never ambient mirror overrides.
        for key in environment.keys.filter({ $0.hasPrefix("UV_") }) { environment.removeValue(forKey: key) }
        environment.merge(extraEnvironment) { _, new in new }
        if let directory { environment["LARKSUITE_CLI_CONFIG_DIR"] = directory }
        let phase = authorization
        let result = try await runner.run(executable, arguments, environment: environment, cwd: Self.root, timeout: timeout) { [weak self] line in
            guard watchURLs, let token, Self.authorizationURL(line) != nil else { return }
            Task { @MainActor in
                guard let self, self.session == token, self.authorization == phase, self.verificationURL?.absoluteString != line else { return }
                try? await self.showAuthorization(line, cli: executable, directory: directory, token: token, phase: phase)
            }
        }
        try Task.checkCancellation()
        guard result.code == 0 else {
            let json = (try? Self.parseJSON(result.output)) ?? (try? Self.parseJSON(result.error))
            if (json?["error"] as? [String: Any])?["type"] as? String == "network" {
                throw SetupFailure("飞书连接暂时中断，已有账号配置已保留，请稍后重试。")
            }
            throw SetupFailure(json?["message"] as? String ?? "飞书连接步骤未完成。请确认授权页面已完成；若企业限制应用创建，请联系管理员。")
        }
        return result.output
    }

    func installArchive(url: URL, sha: String, member: String, destination: URL) async throws {
        let (download, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SetupFailure("连接组件下载失败，请检查网络后重试。") }
        let digest = SHA256.hash(data: try Data(contentsOf: download)).map { String(format: "%02x", $0) }.joined()
        guard digest == sha else { throw SetupFailure("下载文件校验未通过，已停止安装，请重试。") }
        try Task.checkCancellation()
        let staging = Self.root.appendingPathComponent("install-\(UUID().uuidString)")
        try Self.ensureDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let listing = try await command("/usr/bin/tar", ["-tzf", download.path], timeout: 15)
        guard listing.split(separator: "\n").contains(Substring(member)), !member.hasPrefix("/"), !member.split(separator: "/").contains("..") else {
            throw SetupFailure("连接组件安装包内容无效。")
        }
        _ = try await command("/usr/bin/tar", ["-xzf", download.path, "-C", staging.path, member], timeout: 15)
        let source = staging.appendingPathComponent(member)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SetupFailure("连接组件不是有效程序。") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        try Self.ensureDirectory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: source) }
        else { try FileManager.default.moveItem(at: source, to: destination) }
    }

    nonisolated static func authorizationURL(_ raw: String) -> URL? {
        guard raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host, host == "feishu.cn" || host.hasSuffix(".feishu.cn") || host == "larksuite.com" || host.hasSuffix(".larksuite.com") else { return nil }
        return url
    }
    static func readJSON(_ url: URL) -> [String: Any] { (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
    static func parseJSON(_ text: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw SetupFailure("连接组件返回了无法识别的结果。") }
        return value
    }
    static func ensureDirectory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
}

struct SetupFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Native subprocesses keep login credentials in the CLI's Keychain, not in app logs.
final class SetupProcess: @unchecked Sendable {
    struct Result { let code: Int32; let output: String; let error: String }
    // Cancellation is protected by lock; only the worker accesses the Process.
    private final class Job: @unchecked Sendable { let process = Process(); var cancelled = false }
    private let lock = NSLock()
    private var jobs: [UUID: Job] = [:]
    private let queue: DispatchQueue
    init(queue: DispatchQueue = .global(qos: .utility)) { self.queue = queue }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        for job in jobs.values { job.cancelled = true }
    }

    func run(_ executable: String, _ arguments: [String], environment: [String: String], cwd: URL, timeout: Double,
             line: @escaping @Sendable (String) -> Void) async throws -> Result {
        let id = UUID(), job = Job()
        register(job, id: id)
        defer { remove(id) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try self.execute(job, executable, arguments, environment: environment, cwd: cwd, timeout: timeout, line: line)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.markCancelled(job) }
    }

    private func register(_ job: Job, id: UUID) { lock.lock(); jobs[id] = job; lock.unlock() }
    private func remove(_ id: UUID) { lock.lock(); jobs.removeValue(forKey: id); lock.unlock() }
    private func markCancelled(_ job: Job) { lock.lock(); job.cancelled = true; lock.unlock() }
    private func isCancelled(_ job: Job) -> Bool { lock.lock(); defer { lock.unlock() }; return job.cancelled }

    private func execute(_ job: Job, _ executable: String, _ arguments: [String], environment: [String: String], cwd: URL,
                         timeout: Double, line: @escaping @Sendable (String) -> Void) throws -> Result {
        // Regular files cannot block on an inherited pipe held open by a child process.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foldy-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("stdout"), stderr = directory.appendingPathComponent("stderr")
        for url in [stdout, stderr] {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw SetupFailure("无法创建连接组件的临时输出文件。")
            }
        }
        let outWriter = try FileHandle(forWritingTo: stdout), errWriter = try FileHandle(forWritingTo: stderr)
        defer { try? outWriter.close(); try? errWriter.close() }
        let outReader = try FileHandle(forReadingFrom: stdout), errReader = try FileHandle(forReadingFrom: stderr)
        defer { try? outReader.close(); try? errReader.close() }
        let process = job.process
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = environment; process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outWriter; process.standardError = errWriter
        // Registration precedes queueing; starting and cancellation use the same lock.
        lock.lock()
        do {
            guard !job.cancelled else { throw CancellationError() }
            try process.run()
            lock.unlock()
        } catch { lock.unlock(); throw error }
        let pid = process.processIdentifier
        // Darwin Process creates a separate group. Verify ownership before signaling children.
        let group = getpgid(pid)
        let target = group == pid || (group == -1 && kill(-pid, 0) == 0) ? -pid : pid
        func alive() -> Bool { kill(target, 0) == 0 || errno == EPERM }
        defer { if process.isRunning || (target < 0 && alive()) { kill(target, SIGKILL) } }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var stopTime: Double?, failure: Error?, killed = false
        var output = Data(), error = Data(), outPending = Data(), errPending = Data()
        let limit = 2 * 1024 * 1024
        func read(_ handle: FileHandle, into bytes: inout Data, pending: inout Data) throws -> Bool {
            while let chunk = try handle.read(upToCount: min(65536, limit - bytes.count + 1)), !chunk.isEmpty {
                guard bytes.count + chunk.count <= limit else { return false }
                bytes.append(chunk); pending.append(chunk)
                while let end = pending.firstIndex(of: 10) {
                    line(String(decoding: pending[..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                    pending.removeSubrange(...end)
                }
            }
            return true
        }
        while true {
            let withinLimit = try read(outReader, into: &output, pending: &outPending)
            let errorWithinLimit = try read(errReader, into: &error, pending: &errPending)
            let now = ProcessInfo.processInfo.systemUptime
            if stopTime == nil {
                if isCancelled(job) { failure = CancellationError(); stopTime = now }
                else if now >= deadline { failure = SetupFailure("连接步骤已超时，请重试。"); stopTime = now }
                else if !withinLimit || !errorWithinLimit { failure = SetupFailure("连接组件输出过多，已停止运行。"); stopTime = now }
                else if !process.isRunning && target < 0 && alive() { stopTime = now }
                if stopTime != nil { kill(target, SIGTERM) }
            }
            if let stopTime {
                if now - stopTime >= 0.5 && !killed { kill(target, SIGKILL); killed = true }
                if !process.isRunning && !alive() { break }
                if now - stopTime >= 2 { throw failure ?? SetupFailure("连接组件未能退出，请重新打开 Foldy。") }
            } else if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if let failure { throw failure }
        guard try read(outReader, into: &output, pending: &outPending),
              try read(errReader, into: &error, pending: &errPending) else { throw SetupFailure("连接组件输出过多，已停止运行。") }
        for pending in [outPending, errPending] where !pending.isEmpty {
            line(String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Result(code: process.terminationStatus, output: String(decoding: output, as: UTF8.self), error: String(decoding: error, as: UTF8.self))
    }
}
