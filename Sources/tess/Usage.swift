import AppKit

/// What apps cost: memory with their helper processes (a browser's tabs, an Electron app's
/// renderers), as physical footprint like Activity Monitor's Memory column. About a millisecond
/// for every app at once.
enum Usage {
    static func memory(_ apps: Set<pid_t>) -> [pid_t: UInt64] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [:] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [:] }
        var children: [pid_t: [pid_t]] = [:]
        for p in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) { children[p.kp_eproc.e_ppid, default: []].append(p.kp_proc.p_pid) }
        func footprint(_ pid: pid_t) -> UInt64 {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            return ok == 0 ? info.ri_phys_footprint : 0
        }
        var out: [pid_t: UInt64] = [:]
        for app in apps {
            var total: UInt64 = 0, stack = [app]
            while let p = stack.popLast() {
                total += footprint(p)
                stack += children[p] ?? []
            }
            out[app] = total
        }
        return out
    }
}
