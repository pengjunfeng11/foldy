// Run: swiftc -DGUARDIAN_POLICY_CHECK Sources/TaskGuardian.swift Scripts/guardian-policy-check.swift -o /tmp/foldy-guardian-policy-check && /tmp/foldy-guardian-policy-check
import Foundation

@main
struct GuardianPolicyCheck {
    static func row(_ id: String = "task", _ turn: String = "turn1", _ status: String = "running") -> GuardianSnapshot.Row {
        GuardianSnapshot.Row(id: id, title: id, status: status, turn_id: turn)
    }
    static func snapshot(_ rows: [GuardianSnapshot.Row], trustworthy: Bool = true) -> GuardianSnapshot {
        GuardianSnapshot(ok: true, checked_at: 0, trustworthy: trustworthy,
                         running: rows.filter { $0.status == "running" }, tasks: rows)
    }
    static func main() {
        let running = snapshot([row()])
        var policy = GuardianPolicy()
        assert(!policy.update(running, now: 0, allowed: false, duration: 300).hold)
        assert(policy.update(running, now: 0, allowed: true, duration: 300).hold)
        assert(policy.deadline == 300)
        assert(policy.update(running, now: 100, allowed: true, duration: 7200).hold)
        assert(policy.deadline == 300) // Repeated observations cannot renew the absolute deadline.
        let completed = policy.update(snapshot([row("task", "turn1", "idle")]), now: 101, allowed: true, duration: 300)
        assert(!completed.hold && completed.reason == "finished" && policy.tracked.isEmpty)

        assert(policy.update(running, now: 200, allowed: true, duration: 300).hold)
        let waiting = policy.update(snapshot([row("task", "turn1", "attention")]), now: 201, allowed: true, duration: 300)
        assert(!waiting.hold && waiting.reason == "finished") // Waiting for a human is not a running job.

        assert(policy.update(running, now: 300, allowed: true, duration: 300).hold)
        assert(policy.update(nil, now: 305, allowed: true, duration: 300).reason == "uncertain")
        assert(policy.update(nil, now: 334.99, allowed: true, duration: 300).hold)
        let unknown = policy.update(nil, now: 335, allowed: true, duration: 300)
        assert(!unknown.hold && unknown.reason == "unknown")
        assert(!policy.update(running, now: 336, allowed: true, duration: 300).hold)
        assert(policy.deadline == nil) // Recovering the same turn cannot reset its budget after a prolonged gap.
        assert(!policy.update(snapshot([], trustworthy: false), now: 340, allowed: true, duration: 300).hold)
        assert(policy.update(snapshot([], trustworthy: false), now: 341, allowed: true, duration: 300).reason == "unknown")
        assert(policy.update(snapshot([]), now: 342, allowed: true, duration: 300).reason == "idle")
        assert(policy.update(snapshot([row("task", "turn2")]), now: 343, allowed: true, duration: 300).hold)

        policy = GuardianPolicy()
        assert(policy.update(running, now: 0, allowed: true, duration: 300).hold)
        assert(policy.update(running, now: 299.99, allowed: true, duration: 300).hold)
        assert(policy.update(running, now: 300, allowed: true, duration: 300).reason == "expired")
        assert(!policy.update(running, now: 301, allowed: true, duration: 300).hold)
        assert(policy.deadline == nil)
        assert(policy.update(snapshot([row("task", "turn2")]), now: 302, allowed: true, duration: 300).hold)
        assert(policy.deadline == 602)

        policy = GuardianPolicy()
        assert(policy.update(running, now: 0, allowed: true, duration: 300).hold)
        assert(policy.update(snapshot([row("task", "turn2")]), now: 300, allowed: true, duration: 300).hold)
        assert(policy.deadline == 600) // A new turn arriving exactly at expiry must not be expired itself.

        policy = GuardianPolicy()
        assert(policy.update(snapshot([row("a"), row("b")]), now: 0, allowed: true, duration: 300).hold)
        assert(policy.update(snapshot([row("a", "turn1", "unknown"), row("b")], trustworthy: false), now: 5, allowed: true, duration: 300).hold)
        assert(Set(policy.tracked.map(\.id)) == Set(["a", "b"]))
        let incomplete = snapshot([row("a", "turn1", "unknown"), row("b", "turn1", "idle")], trustworthy: false)
        assert(policy.update(incomplete, now: 10, allowed: true, duration: 300).reason == "uncertain")
        assert(policy.update(incomplete, now: 39.99, allowed: true, duration: 300).hold)
        assert(!policy.update(incomplete, now: 40, allowed: true, duration: 300).hold)

        policy = GuardianPolicy()
        assert(policy.update(running, now: 0, allowed: true, duration: 300).hold)
        assert(policy.update(snapshot([row("task", "turn1", "future-status")]), now: 290, allowed: true, duration: 300).reason == "uncertain")
        assert(policy.update(nil, now: 300, allowed: true, duration: 300).reason == "expired") // Grace cannot extend the deadline.
        policy = GuardianPolicy()
        assert(policy.update(running, now: 0, allowed: true, duration: 1).hold && policy.deadline == 300)
        policy = GuardianPolicy()
        assert(policy.update(running, now: 0, allowed: true, duration: 100000).hold && policy.deadline == 7200)
        assert(!policy.update(running, now: 1, allowed: false, duration: 300).hold && policy.deadline == nil)
        print("PASS: guardian running/finished/waiting, unknown grace, persistent tracking, missing metadata, absolute expiry, old/new turns, duration bounds")
    }
}
