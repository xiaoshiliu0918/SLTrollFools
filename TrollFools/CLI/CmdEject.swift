//
//  CmdEject.swift
//  TrollFools
//
//  Created by Rachel on 10/3/2025.
//

import ArgumentParser
import Foundation

struct CmdEject: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "eject",
        abstract: "Eject plugins from the specified application."
    )

    @Argument(help: "The bundle identifier of the application.")
    var bundleIdentifier: String

    @Option(name: [.customLong("path"), .customShort("p")], help: "The path of the plugin.")
    var pluginPath: String?

    @Flag(name: [.customLong("all")], help: "Eject all plugins.")
    var ejectAll: Bool = false

    func validate() throws {
        if ejectAll && pluginPath != nil {
            throw ArgumentParser.ValidationError(
                "The --all flag and --path option cannot be used at the same time."
            )
        }
        if !ejectAll && pluginPath == nil {
            throw ArgumentParser.ValidationError(
                "Either --all flag or --path option must be specified."
            )
        }
    }

    func run() throws {
        guard let app = LSApplicationProxy(forIdentifier: bundleIdentifier),
              let bundleURL = app.bundleURL()
        else {
            throw ArgumentParser.ValidationError("The specified application does not exist.")
        }
        if let pluginPath {
            // 不能用 URL(string:)：路径含空格/中文/百分号时会得到错误或 nil 的 URL。
            let pluginURL = URL(fileURLWithPath: pluginPath)
            if FileManager.default.fileExists(atPath: pluginPath) {
                try InjectorV3(bundleURL, loggerType: .os).eject([pluginURL], shouldDesist: true)
            } else {
                throw ArgumentParser.ValidationError("The specified plugin path is invalid.")
            }
        } else if ejectAll {
            try InjectorV3(bundleURL, loggerType: .os).ejectAll(shouldDesist: true)
        } else {
            throw ArgumentParser.ValidationError("No plugin to eject.")
        }
    }
}

struct CmdWatch: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Watch the target app and restore it (eject temporary plugins) after it exits."
    )

    @Argument(help: "The bundle identifier of the application.")
    var bundleIdentifier: String

    @Option(name: .customLong("timeout"), help: "Seconds to wait for the app to be launched.")
    var launchTimeout: Int = 600

    @Flag(name: [.customLong("all")], help: "Eject all plugins instead of the temporary set.")
    var ejectAll: Bool = false

    private struct TempEntry: Codable {
        let name: String
        let kind: String
    }

    func run() throws {
        let stateDirURL = Constants.tempInjectRootURL.appendingPathComponent(bundleIdentifier, isDirectory: true)
        let pidFileURL = stateDirURL.appendingPathComponent("watchdog.pid")

        guard let app = LSApplicationProxy(forIdentifier: bundleIdentifier),
              let bundleURL = app.bundleURL(),
              FileManager.default.fileExists(atPath: bundleURL.path)
        else {
            // App 已卸载 / bundle 路径失效：没有可还原的目标了。
            // 必须清掉会话目录并正常退出，否则 cleanupOrphans 每次启动都会
            // 重试一个永远失败的还原（还要占住 300 秒超时）。
            if ejectAll {
                throw ArgumentParser.ValidationError("The specified application does not exist.")
            }
            FileHandle.standardError.write(
                "watch: \(bundleIdentifier) is not installed; session state cleared.\n"
                    .data(using: .utf8)!
            )
            try? FileManager.default.removeItem(at: stateDirURL)
            return
        }

        // Kill any previous watchdog of the same target to avoid duplicates.
        // 先用 pid 文件，再用可执行路径确认；pid 可能已被系统复用。
        if let previousPID = Self.readPID(from: pidFileURL), previousPID > 1,
           previousPID != ProcessInfo.processInfo.processIdentifier,
           let path = ProcessUtil.executablePath(of: previousPID), path.hasSuffix("/trollfoolscli")
        {
            kill(previousPID, SIGKILL)
        }

        try FileManager.default.createDirectory(at: stateDirURL, withIntermediateDirectories: true)
        try String(ProcessInfo.processInfo.processIdentifier)
            .write(to: pidFileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: pidFileURL) }

        // 目标进程判定改为按完整可执行文件路径匹配，
        // 不再使用被内核截断到 15 字节的 p_comm（Unity 系游戏会撞名）。
        // Phase 1: wait for the target app to be launched.
        var hasSeenLaunched = false
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, launchTimeout)))
        while Date() < deadline {
            if !ProcessUtil.pidsOfApp(at: bundleURL).isEmpty {
                hasSeenLaunched = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }

        // Phase 2: wait for the target app to exit.
        if hasSeenLaunched {
            while !ProcessUtil.pidsOfApp(at: bundleURL).isEmpty {
                Thread.sleep(forTimeInterval: 2)
            }
            Thread.sleep(forTimeInterval: 2) // grace period, let the system release the binary
        }

        // Phase 3: restore the app by ejecting what the temporary session injected.
        let injector = try InjectorV3(bundleURL, loggerType: .os)
        if injector.appID.isEmpty {
            injector.appID = bundleIdentifier
        }
        if injector.teamID.isEmpty {
            injector.teamID = app.teamID() ?? "0000000000"
        }

        let stateFileURL = stateDirURL.appendingPathComponent("state.json")
        let stateFileExists = FileManager.default.fileExists(atPath: stateFileURL.path)
        let entries = Self.readTempEntries(bundleIdentifier)
        if ejectAll {
            // Only an explicit --all may eject everything (including
            // user-persisted plugins). Never fall back to it implicitly.
            try injector.ejectAll(shouldDesist: true)
        } else if entries.isEmpty {
            if stateFileExists {
                // 状态文件在、但解析不出内容：绝不能顺手删掉会话目录。
                // 目录里的 `<binary>.troll-fools.bak` 是唯一能救回目标 App 的备份，
                // 清掉就再没有重试机会了。用非零退出码把“失败”告诉调用方。
                FileHandle.standardError.write(
                    "watch: state.json is unreadable for \(bundleIdentifier); refusing to clean up.\n"
                        .data(using: .utf8)!
                )
                throw ArgumentParser.ValidationError("state.json is unreadable")
            }
            // No session state to restore: this happens when a previous
            // restore already completed, or when the state file was lost.
            // Doing nothing here protects persistent plugins from being
            // accidentally ejected.
            FileHandle.standardError.write(
                "watch: no temporary session state for \(bundleIdentifier); nothing to restore.\n"
                    .data(using: .utf8)!
            )
            try? FileManager.default.removeItem(at: stateDirURL)
            return
        } else {
            var assetURLs = [URL]()
            for entry in entries {
                switch entry.kind {
                case "bundle":
                    assetURLs.append(bundleURL.appendingPathComponent(entry.name))
                case "framework":
                    // Frameworks are copied into Frameworks/, not the app root.
                    assetURLs.append(injector.frameworksDirectoryURL.appendingPathComponent(entry.name))
                default:
                    assetURLs.append(injector.frameworksDirectoryURL.appendingPathComponent(entry.name))
                }
            }
            // 插件文件可能已被系统清理或用户手动删掉。此时没有 LC 可摘，
            // eject 会因“找不到可修改的 Mach-O”抛错 → 会话永远还原不掉。
            // 这种降级情况下直接按备份回滚二进制。
            //
            // 注意只有 dylib/framework 才有 load command；.bundle 只是资源目录，
            // 缺了它不需要回滚（否则会把同一二进制上的其它注入一并抹掉）。
            let fileManager = FileManager.default
            let linkedURLs = entries
                .filter { $0.kind != "bundle" }
                .map { injector.frameworksDirectoryURL.appendingPathComponent($0.name) }
            let existingLinked = linkedURLs.filter { fileManager.fileExists(atPath: $0.path) }
            let existingAssets = assetURLs.filter { fileManager.fileExists(atPath: $0.path) }

            if existingLinked.isEmpty {
                if !linkedURLs.isEmpty {
                    try injector.restoreAllAlternates()
                }
            } else {
                try injector.eject(existingAssets, shouldDesist: true)
                if existingLinked.count != linkedURLs.count {
                    // 仍缺失的条目对应的 LC 还在二进制里，靠备份整体回滚
                    try injector.restoreAllAlternates()
                }
            }
        }

        try? FileManager.default.removeItem(at: stateDirURL)
    }

    // 进程枚举/应用匹配已统一到 ProcessUtil（Execute.swift），
    // 这里不再保留按 p_comm 比较的重复实现。

    private static func readPID(from url: URL) -> pid_t? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(trimmed)
    }

    private static func readTempEntries(_ bid: String) -> [TempEntry] {
        let stateFileURL = Constants.tempInjectRootURL
            .appendingPathComponent(bid, isDirectory: true)
            .appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateFileURL),
              let entries = try? JSONDecoder().decode([TempEntry].self, from: data)
        else {
            return []
        }
        return entries
    }
}
