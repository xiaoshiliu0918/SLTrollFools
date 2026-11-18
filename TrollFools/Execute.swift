//
//  Execute.swift
//  TrollFools
//
//  Created by Lessica on 2024/7/19.
//

import CocoaLumberjackSwift
import Foundation

enum Execute {
    @discardableResult
    static func rootSpawn(
        binary: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        ddlog: DDLog = .sharedInstance
    ) throws -> AuxiliaryExecute.TerminationReason {
        let receipt = AuxiliaryExecute.spawn(
            command: binary,
            args: arguments,
            environment: environment.merging([
                "DISABLE_TWEAKS": "1",
            ], uniquingKeysWith: { $1 }),
            personaOptions: .init(uid: 0, gid: 0),
            ddlog: ddlog
        )
        if !receipt.stdout.isEmpty {
            DDLogVerbose("Process \(receipt.pid) output: \(receipt.stdout)", ddlog: ddlog)
        }
        if !receipt.stderr.isEmpty {
            DDLogVerbose("Process \(receipt.pid) error: \(receipt.stderr)", ddlog: ddlog)
        }
        return receipt.terminationReason
    }

    static func rootSpawnWithOutputs(
        binary: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        ddlog: DDLog = .sharedInstance
    ) throws -> AuxiliaryExecute.ExecuteReceipt {
        let receipt = AuxiliaryExecute.spawn(
            command: binary,
            args: arguments,
            environment: environment.merging([
                "DISABLE_TWEAKS": "1",
            ], uniquingKeysWith: { $1 }),
            personaOptions: .init(uid: 0, gid: 0),
            ddlog: ddlog
        )
        if !receipt.stdout.isEmpty {
            DDLogVerbose("Process \(receipt.pid) output: \(receipt.stdout)", ddlog: ddlog)
        }
        if !receipt.stderr.isEmpty {
            DDLogVerbose("Process \(receipt.pid) error: \(receipt.stderr)", ddlog: ddlog)
        }
        return receipt
    }
}

// MARK: - Process Utilities

/// 基于 sysctl 的进程枚举。
///
/// 旧实现用 `kinfo_proc.p_comm` 比对进程名，而 `p_comm` 被内核截断到 15 字节
/// （`UnityFramework`、同名 demo、同一引擎产出的多个游戏都会撞车），
/// 会出现“杀错进程”或“永远等不到目标退出”。
/// 这里读取 `KERN_PROCARGS2` 的 argv[0]（完整可执行文件路径），按
/// `<Bundle>.app/<Executable>` 精确匹配。
///
/// 该文件同时被 App 与 trollfoolscli 两个 target 编译，因此两边共用同一套判定。
enum ProcessUtil {

    /// 进程的可执行文件路径（argv[0]）；无权限或进程已退出时返回 nil。
    static func executablePath(of pid: pid_t) -> String? {
        guard pid > 1 else { return nil }

        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argMax, &argMaxSize, nil, 0) == 0, argMax > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var bufferSize = buffer.count
        var mib2: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib2, 3, &buffer, &bufferSize, nil, 0) == 0,
              bufferSize > MemoryLayout<Int32>.size
        else { return nil }

        // 缓冲区开头是 int argc，紧跟 argv[0] 的 NUL 结尾字符串。
        let start = MemoryLayout<Int32>.size
        var end = start
        while end < bufferSize, buffer[end] != 0 { end += 1 }
        guard end > start else { return nil }
        return String(bytes: buffer[start..<end], encoding: .utf8)
    }

    /// 当前所有 pid（不含 kernel / launchd）。
    static func allPids() -> [pid_t] {
        allProcesses().map { $0.pid }
    }

    /// 进程表：pid + 内核里的 `p_comm`（截断到 15 字节）。
    ///
    /// `p_comm` 不够精确，但**足够做粗筛**：看门狗每秒轮询一次，
    /// 若对 500+ 个进程逐个读 `KERN_PROCARGS2`（每次一个 sysctl + 一块 ARG_MAX 缓冲），
    /// CPU 占用相当可观。先用 comm 命中 1~3 个候选，再走完整路径确认。
    static func allProcesses() -> [(pid: pid_t, comm: String)] {
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let capacity = size / MemoryLayout<kinfo_proc>.stride
        guard capacity > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [] }

        let actual = min(size / MemoryLayout<kinfo_proc>.stride, procs.count)
        var result: [(pid: pid_t, comm: String)] = []
        result.reserveCapacity(actual)
        for index in 0..<actual {
            let pid = procs[index].kp_proc.p_pid
            guard pid > 1 else { continue }
            let comm = withUnsafeBytes(of: procs[index].kp_proc.p_comm) { rawBuffer -> String in
                guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                    return ""
                }
                return String(cString: base)
            }
            result.append((pid, comm))
        }
        return result
    }

    static func executableName(of bundleURL: URL) -> String {
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        if let dict = NSDictionary(contentsOf: infoURL),
           let name = dict["CFBundleExecutable"] as? String,
           !name.isEmpty
        {
            return name
        }
        return bundleURL.deletingPathExtension().lastPathComponent
    }

    /// 指定 .app 当前在跑的所有 pid。
    static func pidsOfApp(at bundleURL: URL) -> [pid_t] {
        let bundlePath = bundleURL.resolvingSymlinksInPath().path
        let execName = executableName(of: bundleURL)
        let expected = bundlePath + "/" + execName
        // 兼容 /private/var 与 /var 两种前缀形态：再兜一层 "Xxx.app/Xxx" 后缀匹配。
        let suffix = "/" + bundleURL.lastPathComponent + "/" + execName
        // 先用内核 comm（截断到 15 字节）粗筛，避免对整张进程表读 PROCARGS2。
        // 注意 p_comm 是按**字节**截断的：非 ASCII 可执行名可能被切在半个字符上，
        // 粗筛会全部落空，这种情况下退回全表精确匹配（慢但不漏）。
        let isASCII = execName.utf8.allSatisfy { $0 < 0x80 }
        let commCandidate = String(execName.prefix(15))

        var result: [pid_t] = []
        for entry in allProcesses() {
            if isASCII, entry.comm != commCandidate { continue }
            guard let path = executablePath(of: entry.pid) else { continue }
            if path == expected || path.hasSuffix(suffix) {
                result.append(entry.pid)
            }
        }
        return result
    }

    /// 结束指定 .app 的所有进程，返回成功发送信号的进程数。
    @discardableResult
    static func killApp(at bundleURL: URL, signal: Int32 = SIGKILL) -> Int {
        let current = getpid()
        var killed = 0
        for pid in pidsOfApp(at: bundleURL) where pid != current {
            if kill(pid, signal) == 0 { killed += 1 }
        }
        return killed
    }
}
