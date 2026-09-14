import Foundation

@objc(GuardianServiceProtocol) protocol GuardianServiceProtocol {
    func renew(_ seconds: Int, reply: @escaping (String) -> Void)
    func restore(reply: @escaping (String) -> Void)
    func status(reply: @escaping (String) -> Void)
}

enum GuardianPaths {
    static let label = "app.local.foldy.guardian"
    static let helper = "/Library/PrivilegedHelperTools/\(label)"
    static let plist = "/Library/LaunchDaemons/\(label).plist"
    static let directory = URL(fileURLWithPath: "/var/db/\(label)")
}
