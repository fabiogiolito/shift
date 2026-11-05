import Foundation

/// Memory used by processes Shift started, which macOS counts as Shift's own.
public struct MemoryUse: Equatable, Sendable {
    public var agent: UInt64 = 0
    public var server: UInt64 = 0
    public var total: UInt64 { agent + server }

    public init(agent: UInt64 = 0, server: UInt64 = 0) {
        self.agent = agent
        self.server = server
    }
}

enum ProcessMemory {
    /// One of Shift's own children (agent, dev server, setup command…), with everything it started.
    struct Child: Sendable {
        var pid: pid_t
        var directory: String?
        var footprint: UInt64
    }

    /// Shift's direct children: each leads the tree of one agent, server or command.
    static func ownChildren() -> [Child] {
        children(of: getpid()).map { Child(pid: $0, directory: ServerManager.cwd(of: $0), footprint: treeFootprint($0)) }
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 512)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return count > 0 ? pids.prefix(Int(count)).filter { $0 > 0 } : []
    }

    /// What Activity Monitor shows as Memory: the physical footprint. 0 if the process is gone.
    static func footprint(of pid: pid_t) -> UInt64 {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }

    /// The process and all of its descendants. Ones that re-parented themselves to launchd are lost.
    static func treeFootprint(_ pid: pid_t) -> UInt64 {
        var total: UInt64 = 0, stack = [pid], seen = Set<pid_t>()
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            total += footprint(of: next)
            stack += children(of: next)
        }
        return total
    }
}
