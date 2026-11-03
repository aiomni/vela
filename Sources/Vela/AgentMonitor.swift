import VelaLocalization
import Foundation
import Darwin

enum AgentActivityMode: String, CaseIterable, Sendable {
    case working
    case presence

    var title: String {
        switch self {
        case .working: L("Working agents only")
        case .presence: L("Keep awake while present")
        }
    }
}

// Detection strategy adapted from Bulchimbeon (MIT):
// https://github.com/s3onghyun/bulchimbeon

struct AgentReport: Sendable {
    struct Entry: Sendable {
        let name: String
        let pid: Int32
        let reason: String
        let cpuPercent: Double?
        let busy: Bool
    }
    let entries: [Entry]
    var busyNames: String {
        Array(Set(entries.filter(\.busy).map(\.name))).sorted().joined(separator: ", ")
    }
    var diagnosticText: String {
        guard !entries.isEmpty else { return L("No local agents detected.") }
        return entries.map {
            let cpuLabel = $0.cpuPercent.map { "CPU \(String(format: "%.1f", $0))%" } ?? L("Sampling CPU")
            let state = $0.busy ? L("Active") : L("Idle")
            return "\($0.name) · PID \($0.pid) · \($0.reason) · \(cpuLabel) · \(state)"
        }.joined(separator: "\n")
    }
}

private struct AgentKind: Sendable {
    let name: String
    let binaries: Set<String>
    let pathMarkers: [String]
    let packageMarkers: [String]

    static let builtIn: [AgentKind] = [
        .init(name: "Claude Code", binaries: ["claude"], pathMarkers: ["/.local/share/claude/versions/"], packageMarkers: ["@anthropic-ai/claude-code"]),
        .init(name: "Codex", binaries: ["codex"], pathMarkers: [], packageMarkers: ["@openai/codex"]),
        .init(name: "Gemini CLI", binaries: ["gemini"], pathMarkers: [], packageMarkers: ["@google/gemini-cli"]),
        .init(name: "Cursor Agent", binaries: ["cursor-agent"], pathMarkers: [], packageMarkers: []),
        .init(name: "Copilot CLI", binaries: ["copilot"], pathMarkers: [], packageMarkers: ["@github/copilot"]),
        .init(name: "Aider", binaries: ["aider"], pathMarkers: [], packageMarkers: []),
        .init(name: "OpenCode", binaries: ["opencode"], pathMarkers: [], packageMarkers: ["opencode-ai"])
    ]

    static func all(custom: [String]) -> [AgentKind] {
        var seen = Set<String>()
        let names = custom.filter {
            $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"#, options: .regularExpression) != nil
                && seen.insert($0).inserted
        }.prefix(16)
        return builtIn + names.map { .init(name: $0, binaries: [$0], pathMarkers: [], packageMarkers: []) }
    }
}

private struct AgentProcess: Sendable {
    let pid: Int32
    let parent: Int32
    let startToken: UInt64?
    let executable: String
    let arguments: [String]
    let cpuNanoseconds: UInt64
    var basename: String { URL(fileURLWithPath: executable).lastPathComponent }
}

private enum AgentCatalog {
    static let runners: Set<String> = ["node", "bun", "deno"]
    static let inlineFlags: Set<String> = ["-e", "--eval", "-p", "--print"]

    static func match(_ process: AgentProcess, kinds: [AgentKind]) -> (AgentKind, String)? {
        let argv0 = process.arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent }
        for kind in kinds {
            if kind.binaries.contains(process.basename) { return (kind, L("Executable name")) }
            if let argv0, kind.binaries.contains(argv0) { return (kind, "argv[0]") }
            if kind.pathMarkers.contains(where: process.executable.contains) { return (kind, L("Installation path")) }
        }
        guard runners.contains(process.basename), process.arguments.count > 1,
              !inlineFlags.contains(process.arguments[1]),
              let script = process.arguments.dropFirst().first(where: { !$0.hasPrefix("-") })
        else { return nil }
        let scriptName = URL(fileURLWithPath: script).lastPathComponent
        for kind in kinds {
            if kind.binaries.contains(scriptName) || kind.packageMarkers.contains(where: script.contains) {
                return (kind, L("Script path"))
            }
        }
        return nil
    }
}

private enum ProcessProbe {
    static func scan() -> [AgentProcess] {
        let byteCount = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard byteCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.stride + 64)
        let filled = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
        }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride).compactMap(snapshot)
    }

    private static func snapshot(_ pid: pid_t) -> AgentProcess? {
        guard pid > 0 else { return nil }
        var pathBytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &pathBytes, UInt32(pathBytes.count)) > 0 else { return nil }
        let path = String(decoding: pathBytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let args = arguments(pid, limit: 16)
        var basic = proc_bsdinfo()
        let basicSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let hasBasic = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &basic, basicSize) == basicSize
        let parent: Int32 = hasBasic ? Int32(basic.pbi_ppid) : 0
        let startToken: UInt64? = hasBasic
            ? UInt64(basic.pbi_start_tvsec) * 1_000_000 + UInt64(basic.pbi_start_tvusec) : nil
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let cpu: UInt64 = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize
            ? (task.pti_total_user + task.pti_total_system) * timebase.0 / timebase.1 : 0
        return .init(pid: pid, parent: parent, startToken: startToken,
                     executable: path, arguments: args, cpuNanoseconds: cpu)
    }

    private static let timebase: (UInt64, UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(1, info.denom)))
    }()

    private static func arguments(_ pid: pid_t, limit: Int) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        defer { bytes.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return [] }
        var index = 4
        while index < size && bytes[index] != 0 { index += 1 }
        while index < size && bytes[index] == 0 { index += 1 }
        var result: [String] = []
        while index < size && result.count < min(argc, limit) {
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
}

private struct AgentActivityAnalyzer {
    private static let cpuWindowSeconds: TimeInterval = 60
    private static let cpuThreshold = 2.0
    private struct CpuSample {
        let startToken: UInt64
        let nanoseconds: UInt64
    }
    private var samples: [(at: TimeInterval, times: [Int32: CpuSample])] = []

    mutating func analyze(_ processes: [AgentProcess], at now: TimeInterval, customNames: [String],
                          mode: AgentActivityMode = .working) -> AgentReport {
        let current = Dictionary(uniqueKeysWithValues: processes.compactMap { process -> (Int32, CpuSample)? in
            guard let startToken = process.startToken else { return nil }
            return (process.pid, CpuSample(startToken: startToken,
                                           nanoseconds: process.cpuNanoseconds))
        })
        samples.removeAll { now - $0.at > 90 }
        let base = samples.last { now - $0.at >= Self.cpuWindowSeconds }
        samples.append((now, current))
        let elapsed = base.map { max(0, now - $0.at) } ?? 0
        var cpu: [Int32: Double] = [:]
        if let base {
            for (pid, sample) in current {
                if let previous = base.times[pid],
                   sample.startToken == previous.startToken,
                   sample.nanoseconds >= previous.nanoseconds {
                    cpu[pid] = Double(sample.nanoseconds - previous.nanoseconds) /
                        (elapsed * 1_000_000_000) * 100
                }
            }
        }
        var children: [Int32: [AgentProcess]] = [:]
        for process in processes { children[process.parent, default: []].append(process) }
        let kinds = AgentKind.all(custom: customNames)
        let entries: [AgentReport.Entry] = processes.compactMap { process in
            guard let (kind, reason) = AgentCatalog.match(process, kinds: kinds) else { return nil }
            // Headless Claude sessions without tools are often plugin helpers, not user work.
            if process.arguments.contains(where: { $0 == "--tools=" }) ||
                process.arguments.indices.contains(where: {
                    process.arguments[$0] == "--tools" &&
                    process.arguments.indices.contains($0 + 1) && process.arguments[$0 + 1].isEmpty
                }) {
                return nil
            }
            var caffeinateDescendant = false
            var total = cpu[process.pid] ?? 0
            var hasCpuSample = cpu[process.pid] != nil
            var queue = children[process.pid, default: []]
            var seen: Set<Int32> = [process.pid]
            while let child = queue.popLast(), seen.count < 512 {
                guard seen.insert(child.pid).inserted else { continue }
                if child.basename == "caffeinate" { caffeinateDescendant = true }
                if let childCpu = cpu[child.pid] {
                    total += childCpu
                    hasCpuSample = true
                }
                queue += children[child.pid, default: []]
            }
            let measuredCPU = base != nil && hasCpuSample ? total : nil
            let active = caffeinateDescendant || (measuredCPU ?? 0) >= Self.cpuThreshold
            let busy = mode == .presence || active
            let signal = caffeinateDescendant ? L("caffeinate child process") : active ? L("60-second CPU activity") : L("No work activity detected")
            return .init(name: kind.name, pid: process.pid,
                         reason: "\(reason) · \(signal)",
                         cpuPercent: measuredCPU, busy: busy)
        }
        return AgentReport(entries: entries.sorted { ($0.name, $0.pid) < ($1.name, $1.pid) })
    }
}

actor AgentMonitor {
    private var analyzer = AgentActivityAnalyzer()
    private var customNames: [String] = []
    private var mode: AgentActivityMode = .working

    func setCustomNames(_ names: [String]) { customNames = names }
    func setMode(_ newMode: AgentActivityMode) { mode = newMode }

    func scan(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AgentReport {
        analyzer.analyze(ProcessProbe.scan(), at: now, customNames: customNames, mode: mode)
    }
}

func verifyAgentActivityAnalyzer() {
    let start: TimeInterval = 1_000
    func process(_ pid: Int32, _ parent: Int32, _ executable: String,
                 _ arguments: [String], _ nanoseconds: UInt64,
                 startToken: UInt64 = 1) -> AgentProcess {
        AgentProcess(pid: pid, parent: parent, startToken: startToken, executable: executable,
                     arguments: arguments, cpuNanoseconds: nanoseconds)
    }
    var analyzer = AgentActivityAnalyzer()
    let codex = process(100, 1, "/opt/codex", ["codex"], 0)
    let first = analyzer.analyze([codex], at: start, customNames: [])
    precondition(first.entries.count == 1 && !first.entries[0].busy && first.entries[0].cpuPercent == nil)
    let early = analyzer.analyze([process(100, 1, "/opt/codex", ["codex"], 200_000_000)],
                                 at: start + 5, customNames: [])
    precondition(!early.entries[0].busy && early.entries[0].cpuPercent == nil)
    let quiet = analyzer.analyze([process(100, 1, "/opt/codex", ["codex"], 200_000_000)],
                                 at: start + 60, customNames: [])
    precondition(!quiet.entries[0].busy && quiet.entries[0].cpuPercent! < 2)
    let active = analyzer.analyze([process(100, 1, "/opt/codex", ["codex"], 2_000_000_000)],
                                  at: start + 65, customNames: [])
    precondition(active.entries[0].busy && active.entries[0].cpuPercent! > 2)
    let idle = analyzer.analyze([process(100, 1, "/opt/codex", ["codex"], 2_000_000_000)],
                                at: start + 130, customNames: [])
    precondition(!idle.entries[0].busy && idle.entries[0].cpuPercent! < 2)
    precondition(analyzer.analyze([], at: start + 136, customNames: []).entries.isEmpty)

    analyzer = AgentActivityAnalyzer()
    _ = analyzer.analyze([codex], at: start, customNames: [])
    let reusedPID = analyzer.analyze([process(100, 1, "/opt/codex", ["codex"], 2_000_000_000,
                                             startToken: 2)], at: start + 65, customNames: [])
    precondition(reusedPID.entries.count == 1 && !reusedPID.entries[0].busy &&
                 reusedPID.entries[0].cpuPercent == nil)

    analyzer = AgentActivityAnalyzer()
    let waiting = process(101, 1, "/opt/claude", ["claude"], 0)
    let caffeinate = process(102, 101, "/usr/bin/caffeinate", ["caffeinate"], 0)
    let immediate = analyzer.analyze([waiting, caffeinate], at: start, customNames: [])
    precondition(immediate.entries.count == 1 && immediate.entries[0].busy)
    let shell = process(105, 101, "/bin/sh", ["sh"], 0)
    let nested = process(106, 105, "/usr/bin/caffeinate", ["caffeinate"], 0)
    let nestedReport = analyzer.analyze([waiting, shell, nested], at: start + 5, customNames: [])
    precondition(nestedReport.entries.count == 1 && nestedReport.entries[0].busy)

    analyzer = AgentActivityAnalyzer()
    let buildChild = process(108, 101, "/usr/bin/swift", ["swift"], 0)
    _ = analyzer.analyze([waiting, buildChild], at: start, customNames: [])
    let buildActive = analyzer.analyze([waiting, process(108, 101, "/usr/bin/swift", ["swift"], 1_200_000_000)],
                                       at: start + 60, customNames: [])
    precondition(buildActive.entries.count == 1 && buildActive.entries[0].busy &&
                 abs(buildActive.entries[0].cpuPercent! - 2) < 0.001)

    analyzer = AgentActivityAnalyzer()
    let script = process(103, 1, "/usr/local/bin/node", ["node", "/opt/@openai/codex/bin/codex.js"], 0)
    let unrelated = process(104, 1, "/usr/local/bin/node", ["node", "-e", "@openai/codex"], 0)
    let scripts = analyzer.analyze([script, unrelated], at: start, customNames: [])
    precondition(scripts.entries.count == 1 && scripts.entries[0].pid == 103)
    precondition(!scripts.entries[0].busy)
    let presence = analyzer.analyze([script], at: start + 5, customNames: [], mode: .presence)
    precondition(presence.entries.count == 1 && presence.entries[0].busy)

    analyzer = AgentActivityAnalyzer()
    let headless = process(107, 1, "/opt/claude", ["claude", "--tools="], 0)
    precondition(analyzer.analyze([headless], at: start, customNames: [], mode: .presence).entries.isEmpty)
    print("PASS: 60-second CPU activity, idle detection, presence option, PID reuse, caffeinate and headless filtering")
}
