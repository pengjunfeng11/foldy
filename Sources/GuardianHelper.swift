import Foundation
import Security
import Darwin

enum GuardianFailure: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

// All access is serialized by the daemon queue. The journal is written before pmset.
final class GuardianLease {
    struct Journal: Codable { let original: Int; let startedAt: TimeInterval }
    let journalURL: URL
    let readPower: () throws -> Int
    let writePower: (Int) throws -> Void
    private(set) var journal: Journal?
    private(set) var owner: UUID?
    private(set) var expiresAt: TimeInterval = 0
    private var deadline: TimeInterval = 0
    private var sessionDeadline: TimeInterval = 0
    private(set) var lastError: String?

    init(journalURL: URL, readPower: @escaping () throws -> Int, writePower: @escaping (Int) throws -> Void) throws {
        self.journalURL = journalURL; self.readPower = readPower; self.writePower = writePower
        if FileManager.default.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            guard let original = journal?.original, (0...1).contains(original) else {
                throw GuardianFailure.message("恢复记录无效，未修改电源设置")
            }
        }
    }

    func renew(seconds: Int, owner client: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
               wallNow: TimeInterval = Date().timeIntervalSince1970) throws {
        guard (1...120).contains(seconds) else { throw GuardianFailure.message("防休眠续期必须在 1–120 秒内") }
        if journal != nil && owner != client { throw GuardianFailure.message("另一个连接仍在控制防休眠，或上次设置尚未恢复") }
        if journal == nil {
            let original = try readPower()
            guard (0...1).contains(original) else { throw GuardianFailure.message("无法确认原来的休眠设置") }
            let record = Journal(original: original, startedAt: wallNow)
            try JSONEncoder().encode(record).write(to: journalURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
            let journalFile = try FileHandle(forWritingTo: journalURL)
            defer { try? journalFile.close() }
            try journalFile.synchronize()
            journal = record; owner = client; sessionDeadline = now + 7200
        }
        guard now < sessionDeadline else {
            try restore()
            throw GuardianFailure.message("连续防休眠已达到两小时，请重新启用")
        }
        deadline = min(now + Double(seconds), sessionDeadline)
        expiresAt = wallNow + deadline - now
        do {
            if try readPower() != 1 { try writePower(1) }
            guard try readPower() == 1 else { throw GuardianFailure.message("系统未确认防休眠已开启") }
            lastError = nil
        } catch {
            // Keep the original journal even if pmset changed state before returning an error.
            owner = nil; deadline = 0; expiresAt = 0; lastError = error.localizedDescription
            throw error
        }
    }

    func restore() throws {
        guard let saved = journal else { return }
        do {
            if try readPower() != saved.original { try writePower(saved.original) }
            guard try readPower() == saved.original else { throw GuardianFailure.message("系统未确认原来的休眠设置已恢复") }
            try FileManager.default.removeItem(at: journalURL)
            journal = nil; owner = nil; deadline = 0; expiresAt = 0; sessionDeadline = 0; lastError = nil
        } catch { lastError = error.localizedDescription; throw error }
    }

    func disconnected(_ client: UUID) throws { if owner == client { owner = nil; try restore() } }
    func tick(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        if journal != nil && (owner == nil || now >= deadline) { try restore() }
    }
    func response(error: Error? = nil) -> String {
        var value: [String: Any] = ["ok": error == nil, "active": journal != nil && owner != nil,
                                    "expires_at": expiresAt, "original": journal?.original as Any? ?? NSNull()]
        do { value["current"] = try readPower() } catch { value["current"] = NSNull(); value["ok"] = false; value["error"] = error.localizedDescription }
        if let error { value["error"] = error.localizedDescription }
        else if let lastError { value["ok"] = false; value["error"] = lastError }
        return String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}"
    }
}

private func command(_ path: String, _ arguments: [String], timeout: Double = 10) throws -> (Int32, String) {
    let process = Process(), pipe = Pipe(), exited = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
    process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if exited.wait(timeout: .now() + 1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
        }
        throw GuardianFailure.message("系统电源命令超时；恢复记录已保留")
    }
    // These fixed system commands emit only a small settings/status response.
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (process.terminationStatus, output)
}

func guardianPowerValue(_ output: String) throws -> Int {
    var hasSleepSetting = false
    for line in output.split(separator: "\n") {
        let columns = line.split(whereSeparator: \.isWhitespace)
        if columns.first == "SleepDisabled" {
            guard columns.count == 2, let value = Int(columns[1]), (0...1).contains(value) else { throw GuardianFailure.message("SleepDisabled 返回值无效") }
            return value
        }
        if columns.count >= 2 && columns[0] == "sleep", Int(columns[1]) != nil { hasSleepSetting = true }
    }
    // pmset omits the global key on Macs where it has never been explicitly set.
    guard output.contains("Currently in use:"), hasSleepSetting else { throw GuardianFailure.message("无法确认系统休眠设置，未修改电源设置") }
    return 0
}

private func readPower() throws -> Int {
    let result = try command("/usr/bin/pmset", ["-g"])
    guard result.0 == 0 else { throw GuardianFailure.message("无法读取系统休眠设置") }
    return try guardianPowerValue(result.1)
}

private func writePower(_ value: Int) throws {
    guard (0...1).contains(value), geteuid() == 0 else { throw GuardianFailure.message("电源设置需要管理员权限") }
    let result = try command("/usr/bin/pmset", ["-a", "disablesleep", String(value)])
    guard result.0 == 0 else { throw GuardianFailure.message("pmset 修改失败，恢复记录已保留") }
}

private struct GuardianClient: Codable { let uid: UInt32; let requirement: String }
private var journalLock: Int32 = -1

private func unlockJournal() {
    if journalLock >= 0 { close(journalLock); journalLock = -1 }
}

private func secureDirectory() throws {
    let directory = GuardianPaths.directory.path
    var metadata = stat()
    if lstat(directory, &metadata) == 0 {
        guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == 0 else { throw GuardianFailure.message("防休眠服务目录权限异常") }
    } else {
        guard errno == ENOENT else { throw GuardianFailure.message("无法读取防休眠服务目录") }
        try FileManager.default.createDirectory(at: GuardianPaths.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    guard chmod(directory, 0o700) == 0 else { throw GuardianFailure.message("无法保护防休眠服务目录") }
    for filename in ["client.json", "lease.json"] {
        var file = stat()
        let path = GuardianPaths.directory.appendingPathComponent(filename).path
        if lstat(path, &file) == 0 {
            guard file.st_mode & S_IFMT == S_IFREG, file.st_uid == 0, file.st_mode & 0o077 == 0 else {
                throw GuardianFailure.message("防休眠恢复文件权限异常")
            }
        } else if errno != ENOENT { throw GuardianFailure.message("无法读取防休眠恢复文件") }
    }
}

private func makeLease() throws -> GuardianLease {
    try secureDirectory()
    let descriptor = open(GuardianPaths.directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw GuardianFailure.message("无法锁定防休眠恢复记录") }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_mode & 0o077 == 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        close(descriptor); throw GuardianFailure.message("旧防休眠服务仍在退出，请稍后重试")
    }
    journalLock = descriptor
    return try GuardianLease(journalURL: GuardianPaths.directory.appendingPathComponent("lease.json"), readPower: readPower, writePower: writePower)
}

private func clientIdentity(appPath: String, uid: UInt32) throws -> GuardianClient {
    guard uid > 0, getpwuid(uid) != nil else { throw GuardianFailure.message("无效的 Foldy 用户") }
    let url = URL(fileURLWithPath: appPath).resolvingSymlinksInPath()
    guard Bundle(url: url)?.bundleIdentifier == "app.local.bendy-replica" else { throw GuardianFailure.message("请选择有效的 Foldy 应用") }
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess else {
        throw GuardianFailure.message("Foldy 签名验证失败，未安装防休眠授权")
    }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else {
        throw GuardianFailure.message("无法确认 Foldy 代码身份")
    }
    let requirement = "cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\""
    var compiled: SecRequirement?
    guard SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &compiled) == errSecSuccess else { throw GuardianFailure.message("Foldy 签名要求无效") }
    return GuardianClient(uid: uid, requirement: requirement)
}

private final class GuardianEndpoint: NSObject, GuardianServiceProtocol {
    let id = UUID(), daemon: GuardianDaemon
    var closed = false // Accessed only on the daemon queue, including disconnect callbacks.
    init(_ daemon: GuardianDaemon) { self.daemon = daemon }
    func renew(_ seconds: Int, reply: @escaping (String) -> Void) {
        daemon.perform(reply) {
            guard !self.closed else { throw GuardianFailure.message("Foldy 连接已断开") }
            try self.daemon.lease.renew(seconds: seconds, owner: self.id)
        }
    }
    func restore(reply: @escaping (String) -> Void) {
        daemon.perform(reply) {
            guard self.daemon.lease.owner == nil || self.daemon.lease.owner == self.id else { throw GuardianFailure.message("防休眠由另一个连接管理") }
            try self.daemon.lease.restore()
        }
    }
    func status(reply: @escaping (String) -> Void) { daemon.perform(reply) {} }
}

private final class GuardianDaemon: NSObject, NSXPCListenerDelegate {
    let lease: GuardianLease, client: GuardianClient
    let queue = DispatchQueue(label: "app.local.foldy.guardian.power", qos: .utility)
    let listener = NSXPCListener(machServiceName: GuardianPaths.label)
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    init(lease: GuardianLease, client: GuardianClient) {
        self.lease = lease; self.client = client; super.init()
    }
    func perform(_ reply: @escaping (String) -> Void, operation: @escaping () throws -> Void) {
        queue.async {
            do { try operation(); reply(self.lease.response()) }
            catch { reply(self.lease.response(error: error)) }
        }
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == client.uid else { return false }
        let endpoint = GuardianEndpoint(self)
        connection.setCodeSigningRequirement(client.requirement)
        connection.exportedInterface = NSXPCInterface(with: GuardianServiceProtocol.self)
        connection.exportedObject = endpoint
        let disconnected: () -> Void = { [weak self] in
            self?.queue.async { endpoint.closed = true; try? self?.lease.disconnected(endpoint.id) }
        }
        connection.invalidationHandler = disconnected
        connection.interruptionHandler = disconnected
        connection.resume(); return true
    }
    func run() {
        // Recovery happens before accepting any new lease, including after a daemon crash/reboot.
        queue.sync { try? lease.restore() }
        listener.setConnectionCodeSigningRequirement(client.requirement)
        listener.delegate = self; listener.resume()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in try? self?.lease.tick() }; timer.resume(); self.timer = timer
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                do { try self?.lease.restore(); exit(0) } catch { exit(1) }
            }
            source.resume(); signals.append(source)
        }
        RunLoop.main.run()
    }
}

#if GUARDIAN_HELPER
@main enum GuardianHelperMain {
    static func main() {
        do {
            guard geteuid() == 0 else { throw GuardianFailure.message("防休眠助手必须通过系统安装器获得管理员授权") }
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--recover"] { let lease = try makeLease(); try lease.restore(); print(lease.response()); return }
            if (arguments.count == 3 || (arguments.count == 4 && arguments[3] == "--normal-sleep")),
               arguments[0] == "--install", let uid = UInt32(arguments[2]) {
                let client = try clientIdentity(appPath: arguments[1], uid: uid)
                let running = try command("/bin/launchctl", ["print", "system/\(GuardianPaths.label)"])
                if running.0 == 0 {
                    guard try command("/bin/launchctl", ["bootout", "system/\(GuardianPaths.label)"]).0 == 0 else { throw GuardianFailure.message("旧防休眠服务未停止") }
                }
                let lease = try makeLease(); try lease.restore()
                if arguments.count == 4 {
                    try writePower(0)
                    guard try readPower() == 0 else { throw GuardianFailure.message("未能恢复正常休眠，尚未接管电源设置") }
                }
                let receipt = GuardianPaths.directory.appendingPathComponent("client.json")
                try JSONEncoder().encode(client).write(to: receipt, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
                unlockJournal()
                guard try command("/bin/launchctl", ["bootstrap", "system", GuardianPaths.plist]).0 == 0 else { throw GuardianFailure.message("防休眠服务启动失败") }
                print("{\"ok\":true}"); return
            }
            guard arguments.isEmpty else { throw GuardianFailure.message("不支持的助手操作") }
            let lease = try makeLease()
            // A damaged/missing client receipt must not strand a previous power change.
            try? lease.restore()
            let client = try JSONDecoder().decode(GuardianClient.self, from: Data(contentsOf: GuardianPaths.directory.appendingPathComponent("client.json")))
            guard client.uid > 0, client.requirement.range(of: #"^cdhash H\"[a-f0-9]{40}\"$"#, options: .regularExpression) != nil else { throw GuardianFailure.message("防休眠授权记录无效") }
            let daemon = GuardianDaemon(lease: lease, client: client)
            withExtendedLifetime(daemon) { daemon.run() }
        } catch {
            let result: [String: Any] = ["ok": false, "error": error.localizedDescription]
            let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
            FileHandle.standardError.write(data); FileHandle.standardError.write(Data("\n".utf8)); exit(1)
        }
    }
}
#endif
