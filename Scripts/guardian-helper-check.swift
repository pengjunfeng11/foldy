import Foundation
import Security

private final class LoopbackGuardian: NSObject, NSXPCListenerDelegate, GuardianServiceProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: GuardianServiceProtocol.self)
        connection.exportedObject = self; connection.resume(); return true
    }
    func renew(_ seconds: Int, reply: @escaping (String) -> Void) { reply("unused") }
    func restore(reply: @escaping (String) -> Void) { reply("unused") }
    func status(reply: @escaping (String) -> Void) { reply("signed-loopback") }
}

@main enum GuardianHelperCheck {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foldy-guardian-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let explicit = try guardianPowerValue("System-wide power settings:\n SleepDisabled\t1\nCurrently in use:\n sleep 1")
        let implicit = try guardianPowerValue("Currently in use:\n sleep 1 (sleep prevented by powerd)")
        precondition(explicit == 1 && implicit == 0)
        for invalid in ["", "Currently in use:", "SleepDisabled 2\nCurrently in use:\n sleep 1"] {
            do { _ = try guardianPowerValue(invalid); preconditionFailure("invalid power response accepted") } catch {}
        }
        let id = UUID()
        for initial in [0, 1] {
            var value = initial, writes: [Int] = []
            let path = directory.appendingPathComponent("initial-\(initial).json")
            let lease = try GuardianLease(journalURL: path, readPower: { value }, writePower: { value = $0; writes.append($0) })
            for invalid in [0, -1, 121, Int.max] {
                do { try lease.renew(seconds: invalid, owner: id); preconditionFailure("invalid lease accepted") } catch {}
            }
            precondition(writes.isEmpty && !FileManager.default.fileExists(atPath: path.path))
            let idle = try JSONSerialization.jsonObject(with: Data(lease.response().utf8)) as! [String: Any]
            precondition(idle["original"] is NSNull && idle["current"] as? Int == initial)
            try lease.renew(seconds: 120, owner: id, now: 100, wallNow: 1000)
            precondition(value == 1 && lease.journal?.original == initial)
            let active = try JSONSerialization.jsonObject(with: Data(lease.response().utf8)) as! [String: Any]
            precondition(active["active"] as? Bool == true && active["original"] as? Int == initial)
            do { try lease.renew(seconds: 20, owner: UUID(), now: 101); preconditionFailure("other owner accepted") } catch {}
            try lease.tick(now: 219); precondition(lease.journal != nil)
            try lease.tick(now: 220); precondition(value == initial && lease.journal == nil)
            try lease.renew(seconds: 120, owner: id, now: 300)
            try lease.disconnected(id); precondition(value == initial && lease.journal == nil)
            try lease.renew(seconds: 120, owner: id, now: 500)
            // Simulates SIGKILL/reboot by dropping in-memory ownership and reading the durable journal.
            let restarted = try GuardianLease(journalURL: path, readPower: { value }, writePower: { value = $0 })
            try restarted.tick(now: 0); precondition(value == initial && restarted.journal == nil)
        }
        var value = 0, fail = true
        let path = directory.appendingPathComponent("failure.json")
        let lease = try GuardianLease(journalURL: path, readPower: { value }, writePower: {
            value = $0
            if fail { throw GuardianFailure.message("injected pmset failure after write") }
        })
        do { try lease.renew(seconds: 120, owner: id, now: 100); preconditionFailure("failed write accepted") } catch {}
        precondition(value == 1 && lease.journal?.original == 0 && FileManager.default.fileExists(atPath: path.path))
        // A restore that returns an error must retain the journal even when it changed the setting.
        do { try lease.restore(); preconditionFailure("failed restore accepted") } catch {}
        precondition(FileManager.default.fileExists(atPath: path.path))
        fail = false; try lease.tick(now: 101)
        precondition(value == 0 && lease.journal == nil && !FileManager.default.fileExists(atPath: path.path))
        try lease.renew(seconds: 120, owner: id, now: 1000)
        do { try lease.renew(seconds: 120, owner: id, now: 8200); preconditionFailure("two-hour cap ignored") } catch {}
        precondition(value == 0 && lease.journal == nil)
        try checkSignedIPC()
        print("guardian helper check passed: original 0/1, expiry, disconnect, crash recovery, failed writes, ownership, cap, JSON")
    }

    static func checkSignedIPC() throws {
        var code: SecCode?, staticCode: SecStaticCode?, signing: CFDictionary?
        precondition(SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess)
        precondition(SecCodeCopyStaticCode(code!, SecCSFlags(), &staticCode) == errSecSuccess)
        precondition(SecCodeCopySigningInformation(staticCode!, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess)
        let hash = (signing as! [String: Any])[kSecCodeInfoUnique as String] as! Data
        let requirement = "cdhash H\"\(hash.map { String(format: "%02x", $0) }.joined())\""
        let server = LoopbackGuardian(), listener = NSXPCListener.anonymous()
        listener.delegate = server; listener.setConnectionCodeSigningRequirement(requirement); listener.resume()
        defer { listener.invalidate() }
        for allowed in [true, false] {
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: GuardianServiceProtocol.self)
            connection.setCodeSigningRequirement(allowed ? requirement : "cdhash H\"0000000000000000000000000000000000000000\"")
            let completed = DispatchSemaphore(value: 0)
            var result = ""
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in result = "rejected"; completed.signal() } as! GuardianServiceProtocol
            proxy.status { result = $0; completed.signal() }
            precondition(completed.wait(timeout: .now() + 5) == .success, "XPC response timed out")
            connection.invalidate()
            precondition(result == (allowed ? "signed-loopback" : "rejected"), "XPC signature check was not enforced")
        }
        withExtendedLifetime(server) {}
        print("anonymous XPC check passed: exact signed peer accepted, mismatched cdhash rejected; no launchd registration")
    }
}
