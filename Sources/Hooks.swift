import AppKit
import SwiftUI

// Raw hinge samples trigger actions; the visual spring must not delay them.
struct LidHookDetector {
    enum Event: Equatable { case prepare, close, open }
    private var armed = false
    private var prepared = false
    private var closed = false
    mutating func update(angle: Double, closeAngle: Double) -> [Event] {
        guard angle.isFinite, (0...180).contains(angle), closeAngle.isFinite else { return [] }
        let threshold = min(45, max(5, closeAngle))
        let reopen = max(60, threshold + 20)
        if angle >= reopen {
            let events: [Event] = closed ? [.open] : []
            armed = true; prepared = false; closed = false
            return events
        }
        guard armed, !closed else { return [] }
        var events: [Event] = []
        if !prepared && angle <= reopen - 5 { prepared = true; events.append(.prepare) }
        if angle <= threshold { closed = true; events.append(.close) }
        return events
    }
}

final class LidHooks: ObservableObject {
    let guardian = TaskGuardian()
    @Published var enabled = UserDefaults.standard.bool(forKey: "lidHooksEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "lidHooksEnabled"); guardian.setAllowed(enabled); resetDetector(); status = enabled ? "等待下一次合盖" : "合盖动作已暂停" }
    }
    @Published var feishu = UserDefaults.standard.object(forKey: "lidHooksFeishu") as? Bool ?? true {
        didSet { UserDefaults.standard.set(feishu, forKey: "lidHooksFeishu") }
    }
    @Published var closeAngle = min(45, max(5, UserDefaults.standard.object(forKey: "lidHooksAngle") as? Double ?? 20)) {
        didSet { UserDefaults.standard.set(closeAngle, forKey: "lidHooksAngle"); resetDetector() }
    }
    @Published var script = UserDefaults.standard.string(forKey: "lidHooksScript") ?? "" {
        didSet { UserDefaults.standard.set(script, forKey: "lidHooksScript") }
    }
    @Published var status = "等待下一次合盖"
    @Published var testing = false
    private var detector = LidHookDetector()
    private var lastAngle: Double?
    private var eventID = UUID().uuidString
    private let queue = DispatchQueue(label: "app.local.bendy.hooks", qos: .utility)
    private let scriptQueue = DispatchQueue(label: "app.local.bendy.custom-hook", qos: .utility)
    private let isTest = CommandLine.arguments.contains { $0.hasSuffix("-test") }
    private static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bendy Replica/Hooks")

    func update(angle: Double) {
        guard angle.isFinite, (0...180).contains(angle) else { return }
        lastAngle = angle
        guard enabled, !isTest else { return }
        for event in detector.update(angle: angle, closeAngle: closeAngle) {
            switch event {
            case .prepare:
                eventID = UUID().uuidString
                if feishu { runAdapter(["prepare", "--event-id", eventID], report: false) }
            case .close:
                if feishu { runAdapter(["close", "--event-id", eventID]) }
                if !script.isEmpty { runScript(angle: angle, id: eventID) }
            case .open:
                retryPending()
            }
        }
    }
    private func resetDetector() {
        detector = LidHookDetector()
        if let lastAngle { _ = detector.update(angle: lastAngle, closeAngle: closeAngle) }
    }
    func retryPending() {
        guard enabled, feishu, !isTest else { return }
        runAdapter(["wake"])
    }
    func testMessage() {
        guard !testing, !isTest else { return }
        testing = true
        runAdapter(["test"], isTestMessage: true)
    }
    func chooseScript() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择要在合盖时运行的可执行脚本。脚本需要执行权限和解释器声明。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { status = "这个脚本没有执行权限，请先设置后再选择。"; return }
        script = url.path
    }
    func openConfiguration() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.directory)
    }
    private func runAdapter(_ arguments: [String], report: Bool = true, isTestMessage: Bool = false) {
        let resources = Bundle.main.resourceURL?.appendingPathComponent("bendy_hooks.py")
        // Snapshot the switch before dispatch. Queued work rechecks it before starting.
        if report { status = isTestMessage ? "正在发送安装测试消息…" : "正在处理合盖提醒…" }
        queue.async { [weak self] in
            guard let self else { return }
            if !isTestMessage && (!UserDefaults.standard.bool(forKey: "lidHooksEnabled") || !(UserDefaults.standard.object(forKey: "lidHooksFeishu") as? Bool ?? true)) { return }
            let configURL = Self.directory.appendingPathComponent("config.json")
            let config = (try? Data(contentsOf: configURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let python = config?["python_path"] as? String ?? "/usr/bin/python3"
            let result: (Int32, String)
            if let resources {
                result = Self.execute(path: python, arguments: [resources.path] + arguments)
            } else { result = (-1, "提醒脚本未打包，请重新安装应用。") }
            let json = result.1.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let message = json?["message"] as? String ?? (result.0 == 0 ? "合盖提醒已处理" : "提醒执行失败，请检查飞书和 Codex 配置。")
            DispatchQueue.main.async {
                if report || result.0 != 0 { self.status = message }
                if isTestMessage { self.testing = false }
            }
        }
    }
    private func runScript(angle: Double, id: String) {
        let path = script
        scriptQueue.async { [weak self] in
            guard UserDefaults.standard.bool(forKey: "lidHooksEnabled") else { return }
            let result = Self.execute(path: path, arguments: ["close"], environment: ["BENDY_EVENT": "close", "BENDY_EVENT_ID": id, "BENDY_ANGLE": String(angle)])
            if result.0 != 0 { DispatchQueue.main.async { self?.status = "自定义合盖脚本执行失败（退出码 \(result.0)）。" } }
        }
    }
    // All process waits and file I/O stay on the utility queue, away from Metal and HID.
    static func execute(path: String, arguments: [String], environment: [String: String] = [:]) -> (Int32, String) {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("bendy-hook-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: output) else { return (-1, "无法创建提醒运行日志。") }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process(), finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return (-1, "无法启动提醒脚本：\(error.localizedDescription)") }
        if finished.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = finished.wait(timeout: .now() + 2) }
            return (-1, "提醒执行超时，未完成的消息将在开盖后重试。")
        }
        let data = (try? Data(contentsOf: output)) ?? Data()
        return (process.terminationStatus, String(data: data.suffix(8192), encoding: .utf8) ?? "")
    }
}

struct LidHooksSettings: View {
    @ObservedObject var hooks: LidHooks
    @StateObject private var connection = FeishuConnection()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("启用合盖动作", isOn: $hooks.enabled).toggleStyle(.switch)
            Text("接近合上时触发一次，打开到 \(Int(max(60, hooks.closeAngle + 20)))° 以上后重新就绪。无需开启桌面效果或录屏权限。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("触发角度")
                Slider(value: $hooks.closeAngle, in: 5...45, step: 1).accessibilityLabel("合盖触发角度")
                Text("\(Int(hooks.closeAngle))°").monospacedDigit().frame(width: 38)
            }
            GuardianSettings(guardian: hooks.guardian)
            Toggle("飞书 · Codex 任务与额度摘要", isOn: $hooks.feishu)
            VStack(alignment: .leading, spacing: 10) {
                Text(connection.accountName.isEmpty ? "尚未连接飞书账号" : "飞书账号：\(connection.accountName)")
                    .font(.headline).accessibilityIdentifier("feishuAccount")
                Text(connection.status).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).accessibilityIdentifier("feishuConnectionStatus")
                HStack {
                    if connection.busy {
                        ProgressView().controlSize(.small).accessibilityLabel("正在连接飞书")
                        Button("取消") { connection.cancel() }
                            .accessibilityLabel("取消飞书连接").accessibilityIdentifier("cancelFeishuConnection")
                    } else {
                        Button(connection.connected ? "检查飞书连接" : "安装并连接飞书") {
                            if connection.connected { connection.refreshStatus() } else { connection.connect() }
                        }.accessibilityIdentifier("connectFeishu")
                    }
                }
                if let url = connection.verificationURL {
                    HStack(alignment: .top, spacing: 12) {
                        if let qrCode = connection.qrCode {
                            Image(nsImage: qrCode).interpolation(.none).resizable().scaledToFit()
                                .frame(width: 128, height: 128).accessibilityLabel("飞书授权二维码")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Link("打开飞书授权页面", destination: url).accessibilityIdentifier("feishuAuthorizationLink")
                            Text(url.absoluteString).font(.caption2).textSelection(.enabled)
                            Text("在飞书授权页面确认后，将自动继续配置。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("无需提前准备 Bot，首次连接会引导完成飞书应用配置。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            Text("发送到已配置的飞书收件人。快速合盖可能中断发送，重新开盖时会补发。任务记录缺失时会标明状态未知。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("发送测试消息") { hooks.testMessage() }.disabled(hooks.testing)
                if hooks.testing { ProgressView().controlSize(.small) }
                Button("打开提醒配置") { hooks.openConfiguration() }
            }
            Divider()
            Text("自定义合盖 Hook").font(.headline)
            Text(hooks.script.isEmpty ? "未设置" : hooks.script).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("选择可执行脚本…") { hooks.chooseScript() }
                if !hooks.script.isEmpty { Button("移除") { hooks.script = "" } }
            }
            Text("脚本会收到 close 参数，以及 BENDY_EVENT、BENDY_EVENT_ID、BENDY_ANGLE 环境变量。最长执行 30 秒。")
                .font(.caption).foregroundStyle(.secondary)
            Text(hooks.status).font(.callout).textSelection(.enabled)
        }.onAppear { connection.refreshStatus() }
            .onDisappear { connection.cancel() }
    }
}
