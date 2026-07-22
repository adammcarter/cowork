import Darwin
import Foundation

/// Is the process that owns a dispatch still alive?
///
/// A bare `kill(pid, 0)` is not an answer. Pids are recycled, so a live pid may be
/// a *different* process that inherited the number — and reconciliation would then
/// leave an abandoned dispatch running forever because something else happens to
/// hold its pid. Identity is therefore (pid, start time): the kernel's own record
/// of when that pid began, which a recycled pid cannot reproduce.
public enum Liveness {
    /// The process start time the kernel reports for a pid, in whole seconds.
    /// `nil` means no such process — including a zombie, which is not one.
    public static func startTime(of pid: pid_t) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // A zeroed record means the pid is gone even when sysctl succeeds.
        guard info.kp_proc.p_pid == pid else { return nil }
        // A zombie is dead. It has exited and is only waiting to be reaped, but it
        // still occupies the process table with its original start time — so a
        // naive (pid, start) match reports it alive forever, and a dispatch whose
        // supervisor was killed would never reconcile. It cannot run code; it is
        // not an owner.
        guard info.kp_proc.p_stat != SZOMB else { return nil }
        return Int64(info.kp_proc.p_un.__p_starttime.tv_sec)
    }

    public static func current() -> (pid: pid_t, start: Int64) {
        let pid = getpid()
        return (pid, startTime(of: pid) ?? 0)
    }

    /// True only when the exact process is still running — same pid *and* same
    /// start time. Any other answer is "gone", which is the safe direction: a
    /// dispatch wrongly reconciled is visible and recoverable, while a dispatch
    /// wrongly believed alive is a leak that nothing will ever report.
    public static func isAlive(pid: pid_t, start: Int64) -> Bool {
        guard let actual = startTime(of: pid) else { return false }
        return actual == start
    }
}
