// xcrun swiftc -O -assert-config Debug -swift-version 5 -target arm64-apple-macos14.0 Sources/FeishuConnection.swift Scripts/feishu_install_check.swift -o /tmp/foldy-feishu-install-check && /tmp/foldy-feishu-install-check
import AppKit
import CryptoKit

@main struct FeishuInstallCheck {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("foldy-feishu-install-check-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let config = FeishuConnection.root.appendingPathComponent("config.json")
        let originalConfig = try? Data(contentsOf: config)

        let sampleURL = "https://open.feishu.cn/page/cli?user_code=foldy-test"
        for value in [sampleURL, "https://accounts.feishu.cn/oauth/authorize?a=1&b=2", "https://open.larksuite.com/page/cli?user_code=foldy-test"] {
            precondition(FeishuConnection.authorizationURL(value)?.absoluteString == value, "Allowed authorization URL must remain unchanged")
        }
        for value in ["http://open.feishu.cn/page/cli", "https://open.feishu.cn.evil.example/", "https://evilfeishu.cn/",
                      "https://open.larksuite.com.evil.example/", "https://larksuite.com@evil.example/", "https://evil.example@open.feishu.cn/",
                      "https://user:password@open.feishu.cn/", "javascript:alert(1)", "file:///tmp/feishu.cn", " https://open.feishu.cn/", "https://open.feishu.cn/\n"] {
            precondition(FeishuConnection.authorizationURL(value) == nil, "Untrusted authorization URL was accepted: \(value)")
        }

        let archive = URL(string: "https://github.com/larksuite/cli/releases/download/v1.0.81/lark-cli-1.0.81-darwin-arm64.tar.gz")!
        let cli = temporary.appendingPathComponent("lark-cli")
        let connection = FeishuConnection()
        try await connection.installArchive(url: archive, sha: "0693846b129044a8c1312999f04ff26343b9a2fdb41615343e33fe67cea9dea5", member: "lark-cli", destination: cli)
        precondition(fm.isExecutableFile(atPath: cli.path), "Verified archive must produce an executable")
        let installedDigest = SHA256.hash(data: try Data(contentsOf: cli))
        let version = try run(cli, ["--version"], cwd: temporary)
        precondition(version.trimmingCharacters(in: .whitespacesAndNewlines) == "lark-cli version 1.0.81", "Installed CLI version differs from pinned version")
        _ = try run(cli, ["auth", "qrcode", sampleURL, "--output", "authorization.png"], cwd: temporary)
        let png = try Data(contentsOf: temporary.appendingPathComponent("authorization.png"))
        precondition(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "CLI must generate a PNG without login")
        precondition(NSImage(data: png) != nil, "Generated authorization QR must decode in AppKit")

        let rejected = temporary.appendingPathComponent("rejected-cli")
        do {
            try await connection.installArchive(url: archive, sha: String(repeating: "0", count: 64), member: "lark-cli", destination: rejected)
            preconditionFailure("An incorrect checksum must reject installation")
        } catch {
            precondition(String(describing: error).contains("校验未通过"), "Expected checksum rejection, not a network or unrelated failure: \(error)")
        }
        precondition(!fm.fileExists(atPath: rejected.path), "Failed checksum must not leave an executable")
        let preservedDigest = SHA256.hash(data: try Data(contentsOf: cli))
        precondition(preservedDigest == installedDigest, "Failed install must preserve the working executable")
        precondition((try? Data(contentsOf: config)) == originalConfig, "Installation check must not change the user's hook configuration")
        print("PASS: real archive download and SHA256, executable 1.0.81, login-free QR PNG, checksum rejection, authorization URL allowlist")
    }

    private static func run(_ executable: URL, _ arguments: [String], cwd: URL) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("LARKSUITE_CLI_") && $0.key != "OPENCLAW_HOME" && $0.key != "HERMES_HOME" }
        environment["LARKSUITE_CLI_CONFIG_DIR"] = cwd.appendingPathComponent("cli-config").path
        environment["LARKSUITE_CLI_LOG_DIR"] = cwd.appendingPathComponent("cli-logs").path
        environment["LARKSUITE_CLI_NO_UPDATE_NOTIFIER"] = "1"
        environment["LARKSUITE_CLI_NO_SKILLS_NOTIFIER"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "CLI check failed: \(String(decoding: output, as: UTF8.self))")
        return String(decoding: output, as: UTF8.self)
    }
}
