//
//  TempHome.swift
//  TrollFools
//
//  Minimal temp-injection launcher:
//  permanent plugin stash + one-tap game launch with auto inject & auto restore.
//

import SwiftUI
import UIKit
import CoreServices
import UniformTypeIdentifiers

// MARK: - Alert item (iOS 14 compatible)

struct TempAlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Game Targets

struct GameTarget {
    let buttonTitle: String
    let emoji: String
    /// keywords matched against plugin file names in the stash
    let pluginKeywords: [String]
    /// keywords matched against installed app display names
    let appNameKeywords: [String]
    /// optional hard-coded bundle identifier (checked first)
    let fixedBundleID: String?

    static let wzry = GameTarget(
        buttonTitle: "启动王者荣耀",
        emoji: "👑",
        pluginKeywords: ["王者", "王者荣耀", "wzry", "smoba"],
        appNameKeywords: ["王者", "smoba"],
        fixedBundleID: "com.tencent.smoba"
    )

    static let dnf = GameTarget(
        buttonTitle: "启动地下城与勇士",
        emoji: "⚔️",
        pluginKeywords: ["地下城", "dnf", "DNF"],
        appNameKeywords: ["地下城", "dnf", "DNF"],
        fixedBundleID: nil
    )
}

// MARK: - Stash

final class StashManager {
    static let shared = StashManager()

    static var stashRootURL: URL {
        // 必须解析符号链接：iOS 上 /var 是 /private/var 的软链，
        // 目录枚举器返回的是 /private/var/... 形态；若根仍是 /var/...，
        // "根前缀剔除"会错位，把绝对路径后缀（如 "ts/插件导入"、"s/Stash"）
        // 当成相对路径 → 双向同步产生嵌套污染。
        URL(fileURLWithPath: "/var/mobile/Library/TrollFools/Stash")
            .resolvingSymlinksInPath()
    }

    /// 导入结果：新导入 / 覆盖更新 / 同名同大小跳过。
    enum ImportOutcome {
        case imported
        case updated
        case skipped
    }

    // MARK: 双向镜像快照
    // 「插件导入」文件夹 ⇄ 暂存箱 双向同步的状态依据：
    /// iOS 文件 App 复制重名文件时会自动生成 "Name (2).ext" / "Name(2).ext"。
    /// 把这类名字折叠回 "Name.ext"，避免同一插件因重复复制产生多个副本。
    static func normalizedPluginName(_ rawName: String) -> String {
        let nsName = rawName as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        if let range = base.range(of: #"\s*\(\d+\)\s*$"#, options: .regularExpression) {
            let stripped = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty {
                return ext.isEmpty ? stripped : "\(stripped).\(ext)"
            }
        }
        return rawName
    }

    static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }

    func ensureStash() {
        try? FileManager.default.createDirectory(
            at: Self.stashRootURL, withIntermediateDirectories: true
        )
    }

    /// All plugin files currently in the stash (dylib / framework / bundle).
    func listPlugins() -> [URL] {
        ensureStash()
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: Self.stashRootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return urls
            .filter { $0.lastPathComponent != ".DS_Store" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Import one file into the stash (dedup version).
    /// - 同名且同大小的文件已在暂存箱 → .skipped（不覆盖、不重复导入）
    /// - 同名但内容不同 → 覆盖更新 → .updated
    /// - 新文件 → .imported
    /// - "Name(2).ext" 这类文件 App 复制副本名会被折叠回 "Name.ext"
    @discardableResult
    func importPluginDedup(from src: URL) throws -> (name: String, outcome: ImportOutcome) {
        ensureStash()
        let fm = FileManager.default
        let name = Self.normalizedPluginName(src.lastPathComponent)
        let dst = Self.stashRootURL.appendingPathComponent(name)

        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let srcSize = Self.fileSize(of: src)

        // 暂存箱已有同名且同大小的文件：跳过
        if fm.fileExists(atPath: dst.path), srcSize >= 0 {
            let dstSize = Self.fileSize(of: dst)
            if dstSize == srcSize {
                return (name, .skipped)
            }
        }

        let hadExisting = fm.fileExists(atPath: dst.path)
        if hadExisting {
            try? fm.removeItem(at: dst)
        }

        var reasons: [String] = []

        // Strategy 1: direct copy
        if !fm.fileExists(atPath: dst.path) {
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                reasons.append("copy:\(error.localizedDescription)")
            }
        }

        // Strategy 2: byte-level read then write
        if !fm.fileExists(atPath: dst.path) {
            do {
                let data = try Data(contentsOf: src)
                if data.isEmpty {
                    reasons.append("read:文件内容为空")
                } else {
                    try data.write(to: dst, options: .atomic)
                }
            } catch {
                reasons.append("read:\(error.localizedDescription)")
            }
        }

        // Verify
        guard fm.fileExists(atPath: dst.path) else {
            throw NSError(
                domain: "StashImport", code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "所有方式均失败（\(reasons.joined(separator: "；"))）。源路径：\(src.path)"]
            )
        }

        // 成功导入，保持镜像状态一致（无墓碑机制，删除由双向同步处理）
        return (name, hadExisting ? .updated : .imported)
    }

    /// Import one file into the stash. Returns the stored file name.
    /// (兼容旧调用点；内部走去重逻辑)
    @discardableResult
    func importPlugin(from src: URL) throws -> String {
        try importPluginDedup(from: src).name
    }

    /// 从暂存箱删除插件。
    /// 「插件导入」文件夹里的同名文件由双向同步负责删除。
    /// 从暂存箱删除插件。暂存箱是「插件导入」文件夹的单向镜像，
    /// 因此同时删除文件夹里的对应文件（同相对路径），否则下次同步又会被收回来。
    func removePlugin(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        let root = Self.stashRootURL.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(root) else { return }
        let rel = String(path.dropFirst(root.count))
        let mirror = ImportEngine.importFolderURL.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: mirror.path) {
            try? FileManager.default.removeItem(at: mirror)
        }
    }

    // MARK: 深度列举（支持子文件夹分类）

    /// 暂存箱/导入文件夹内的一项（文件或目录），relPath 相对根目录，
    /// 例如 "DNF.dylib"、"王者荣耀/DNF.dylib"。
    struct DeepItem {
        let relPath: String
        let url: URL
        let isDirectory: Bool
    }

    /// 递归列举目录下所有文件与子目录（跳过点文件），按相对路径排序。
    func listDeep(at root: URL? = nil) -> [DeepItem] {
        let rootURL = (root ?? Self.stashRootURL).resolvingSymlinksInPath()
        ensureStash()
        let fm = FileManager.default
        let rootPath = rootURL.path
        var result: [DeepItem] = []
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }
            var path = url.path
            if !path.hasPrefix(rootPath + "/") {
                path = url.resolvingSymlinksInPath().path
            }
            guard path.hasPrefix(rootPath + "/") else {
                enumerator.skipDescendants()
                continue
            }
            let rel = String(path.dropFirst(rootPath.count + 1))
            if rel.isEmpty { continue }
            let isDir = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
            result.append(DeepItem(relPath: rel, url: url, isDirectory: isDir))
        }
        result.sort { $0.relPath.localizedStandardCompare($1.relPath) == .orderedAscending }
        return result
    }

    /// 只列出「插件条目」：dylib/zip/deb 文件与 .framework/.bundle 目录。
    /// 插件 bundle（.framework/.bundle）内部的文件不单独列出；
    /// 分类子文件夹（非插件目录）本身也不是条目。
    func listPluginItems(at root: URL? = nil) -> [DeepItem] {
        listDeep(at: root).filter { item in
            if item.isDirectory {
                let ext = (item.url.lastPathComponent as NSString).pathExtension.lowercased()
                return Self.pluginBundleExtensions.contains(ext)
            }
            // 文件：扩展名须为插件类型，且不在插件 bundle 内部
            let ext = (item.url.lastPathComponent as NSString).pathExtension.lowercased()
            guard Self.pluginFileExtensions.contains(ext) else { return false }
            let ancestors = item.relPath.split(separator: "/").dropLast().map(String.init)
            return !ancestors.contains {
                Self.pluginBundleExtensions.contains((($0 as NSString).pathExtension.lowercased()))
            }
        }
    }

    /// 某插件文件所属的分类名（暂存箱根下的第一级子文件夹名；根目录文件 = 未分类）。
    static func category(ofPluginAt url: URL) -> String {
        let root = stashRootURL.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(root) else { return "未分类" }
        let rel = String(path.dropFirst(root.count))
        let parts = rel.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : "未分类"
    }

    // MARK: 插件类型判定
    // 只有这些类型会被当作插件：dylib / framework / bundle / zip / deb。
    // 分类子文件夹仅用于归类，其内部仍只收上述类型；
    // 其他任意文件（txt/png 等）不参与同步、不进暂存箱。

    static let pluginFileExtensions: Set<String> = ["dylib", "zip", "deb"]
    static let pluginBundleExtensions: Set<String> = ["framework", "bundle"]

    /// 判断一个相对路径是否为插件（或插件 bundle 内部的组成部分）。
    /// - 顶层/任意层级文件：扩展名为 dylib/zip/deb
    /// - .framework / .bundle 目录本身及其内部所有内容
    static func isPluginPath(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/").map(String.init)
        guard let last = parts.last else { return false }
        // 位于插件 bundle 内部 → 属于插件的一部分
        if parts.count > 1 {
            let ancestors = parts.dropLast()
            if ancestors.contains(where: {
                pluginBundleExtensions.contains((($0 as NSString).pathExtension.lowercased()))
            }) {
                return true
            }
        }
        let ext = (last as NSString).pathExtension.lowercased()
        return pluginFileExtensions.contains(ext) || pluginBundleExtensions.contains(ext)
    }

    /// Plugins whose file name (only the file itself, not its category
    /// folder path) contains any of the keywords.
    /// 分类文件夹仅用于视觉归类，不参与一键启动匹配；匹配只看插件文件名。
    func plugins(matching keywords: [String]) -> [URL] {
        listPluginItems().filter { item in
            let name = item.url.lastPathComponent.lowercased()
            return keywords.contains { name.contains($0.lowercased()) }
        }.map { $0.url }
    }
}

// MARK: - Import Engine (multi-channel, always visible on screen)

final class ImportEngine: ObservableObject {

    static let shared = ImportEngine()

    /// On-screen log lines, newest last. Rendered in the UI so results are
    /// always visible even if system alerts fail to present.
    @Published var logs: [String] = []
    @Published var notice: TempAlertItem?

    private func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    func log(_ line: String) {
        DispatchQueue.main.async {
            self.logs.append("[\(self.stamp())] \(line)")
            if self.logs.count > 40 {
                self.logs.removeFirst(self.logs.count - 40)
            }
        }
    }

    /// Import a batch of files. Safe to call from anywhere.
    func importURLs(_ urls: [URL], source: String, showAlert: Bool = true) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var ok: [String] = []
            var skipped: [String] = []
            var failures: [String] = []
            let fm = FileManager.default
            for url in urls {
                do {
                    // 一切以「插件导入」文件夹为准：外部导入（共享接收等）
                    // 先落进导入文件夹，再由单向同步收进暂存箱
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let name = StashManager.normalizedPluginName(url.lastPathComponent)
                    let dst = Self.importFolderURL.appendingPathComponent(name)
                    if fm.fileExists(atPath: dst.path) {
                        let oldSize = StashManager.fileSize(of: dst)
                        let newSize = StashManager.fileSize(of: url)
                        if oldSize >= 0, oldSize == newSize {
                            skipped.append(name)
                            continue
                        }
                        try? fm.removeItem(at: dst)
                    }
                    try fm.copyItem(at: url, to: dst)
                    ok.append(name)
                } catch {
                    failures.append("\(url.lastPathComponent)\n\(error.localizedDescription)")
                }
            }
            if !ok.isEmpty || !skipped.isEmpty {
                self.syncImportFolder()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                for name in ok {
                    self.log("✅ \(source)：已导入 \(name)")
                }
                for name in skipped {
                    self.log("♻️ \(source)：\(name) 已在暂存箱，跳过")
                }
                for failure in failures {
                    self.log("❌ \(source)：\(failure)")
                }
                if showAlert {
                    if !failures.isEmpty {
                        self.notice = TempAlertItem(title: "导入失败", message: failures.joined(separator: "\n\n"))
                    } else if !ok.isEmpty {
                        var msg = ok.joined(separator: ", ")
                        if !skipped.isEmpty {
                            msg += "\n\n已存在跳过：\(skipped.joined(separator: ", "))"
                        }
                        self.notice = TempAlertItem(title: "已添加插件", message: msg)
                    } else if !skipped.isEmpty {
                        self.notice = TempAlertItem(title: "插件已存在", message: skipped.joined(separator: ", "))
                    }
                }
            }
        }
    }

    /// The user-visible import folder inside our own Documents, exposed via
    /// UIFileSharingEnabled so it shows up in the Files app
    /// (固定路径：/var/mobile/Documents/插件导入).
    static var importFolderURL: URL {
        // 用户明确要求：导入文件夹固定为 /var/mobile/Documents/插件导入。
        // TrollStore 环境下 app 以 mobile 身份运行，可直接读写该全局目录；
        // 用户在文件 App / Filza 里往这里放插件、建分类文件夹，app 据此双向同步。
        // 若该位置不可写（非 TrollStore 安装），退回应用沙盒 Documents/插件导入。
        let fm = FileManager.default
        let preferred = URL(fileURLWithPath: "/var/mobile/Documents/插件导入", isDirectory: true)
            .resolvingSymlinksInPath()
        try? fm.createDirectory(at: preferred, withIntermediateDirectories: true)
        if fm.isWritableFile(atPath: preferred.path) {
            return preferred
        }
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("插件导入", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    static func ensureImportFolder() {
        try? FileManager.default.createDirectory(
            at: importFolderURL, withIntermediateDirectories: true
        )
    }

    /// 「插件导入」文件夹 → 暂存箱 **单向**镜像同步（递归，支持子文件夹分类）。
    /// ★ 一切以 /var/mobile/Documents/插件导入 为准：
    ///   - 文件夹里有 → 暂存箱必须有（内容不同以文件夹覆盖）
    ///   - 文件夹里没有 → 暂存箱删除（app 内的内容绝不回灌进文件夹）
    ///   - 文件夹里的分类目录 → 暂存箱同步创建（空分类也建）
    /// - 只同步插件类型（dylib/zip/deb 文件与 .framework/.bundle 目录）
    /// - 文件 App 复制副本 "DNF(2).dylib" 自动并入正本 "DNF.dylib"（按目录内处理）
    /// - force = true（手动按钮）：忽略大小比对，全部重新复制一遍
    func syncImportFolder(force: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            Self.ensureImportFolder()
            StashManager.shared.ensureStash()

            let folderURL = Self.importFolderURL
            let stashURL = StashManager.stashRootURL

            // 递归扫描一侧：返回 relPath → URL 的文件表 + 目录集合。
            // 双保险：枚举器返回的路径若与根前缀对不上（符号链接解析差异），
            // 先尝试标准化对齐；仍对不上则连同子树整体跳过，绝不生成碎片相对路径。
            func scan(_ root: URL, otherRoot: URL) -> (files: [String: URL], dirs: Set<String>) {
                var files: [String: URL] = [:]
                var dirs = Set<String>()
                let rootPath = root.resolvingSymlinksInPath().path
                let otherPath = otherRoot.resolvingSymlinksInPath().path
                guard let enumerator = fm.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey]
                ) else { return (files, dirs) }
                for case let url as URL in enumerator {
                    let name = url.lastPathComponent
                    if name.hasPrefix(".") {
                        enumerator.skipDescendants()
                        continue
                    }
                    var path = url.path
                    if !path.hasPrefix(rootPath + "/") {
                        path = url.resolvingSymlinksInPath().path
                    }
                    guard path.hasPrefix(rootPath + "/") else {
                        enumerator.skipDescendants() // 路径形态对不上：整棵子树跳过
                        continue
                    }
                    if path.hasPrefix(otherPath + "/") {
                        enumerator.skipDescendants() // 对端根嵌套在本端内：整体跳过，防止互拷
                        continue
                    }
                    let rel = String(path.dropFirst(rootPath.count + 1))
                    if rel.isEmpty { continue }
                    let isDir = ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) ?? false
                    if isDir { dirs.insert(rel) } else { files[rel] = url }
                }
                return (files, dirs)
            }

            var folderScan = scan(folderURL, otherRoot: stashURL)
            var stashScan = scan(stashURL, otherRoot: folderURL)

            // ── Step A-：清理历史版本遗留的"相对路径碎片"污染 ──
            // 症状：目录里出现 "ts/插件导入/…"、"s/Stash/…" 这类嵌套
            // （绝对路径后缀被当成相对路径复制）。凡相对路径里含系统目录名
            // 组件（插件导入/Documents/Library/TrollFools/Stash/…）即视为污染，
            // 两侧一并删除；随后清空同步快照并重新扫描（快照为空只做补齐，不误删）。
            let pollutionNames: Set<String> = [
                "插件导入", "Documents", "Library", "TrollFools",
                "Stash", "private", "var", "mobile",
            ]
            func isPolluted(_ rel: String) -> Bool {
                rel.split(separator: "/").contains { pollutionNames.contains(String($0)) }
            }
            var cleanedCount = 0
            for (rootURL, scanResult) in [(folderURL, folderScan), (stashURL, stashScan)] {
                var removedPrefixes: [String] = []
                for rel in Set(scanResult.files.keys).union(scanResult.dirs).sorted() {
                    guard isPolluted(rel),
                          !removedPrefixes.contains(where: { rel.hasPrefix($0 + "/") }) else { continue }
                    try? fm.removeItem(at: rootURL.appendingPathComponent(rel))
                    removedPrefixes.append(rel)
                    cleanedCount += 1
                }
            }
            if cleanedCount > 0 {
                self.log("🧹 已清理路径污染残留 \(cleanedCount) 项（历史版本相对路径错位导致）")
                // 重新扫描，保证后续步骤基于干净状态
                folderScan = scan(folderURL, otherRoot: stashURL)
                stashScan = scan(stashURL, otherRoot: folderURL)
            }

            var folderFiles = folderScan.files
            let folderDirs = folderScan.dirs
            var stashFiles = stashScan.files
            let stashDirs = stashScan.dirs

            // ── Step A0：类型过滤——只有插件类型（dylib/zip/deb 文件与
            // .framework/.bundle 目录及其内部）参与同步。
            // 用户放在导入文件夹里的其他文件（笔记/图片等）保持原样，不进暂存箱。
            folderFiles = folderFiles.filter { StashManager.isPluginPath($0.key) }
            stashFiles = stashFiles.filter { StashManager.isPluginPath($0.key) }

            // 暂存箱里不应该有非插件文件（可能是历史版本同步进去的残留），清掉
            for (rel, url) in stashScan.files where !StashManager.isPluginPath(rel) {
                try? fm.removeItem(at: url)
                self.log("🧹 已清理暂存箱内的非插件文件 \(rel)")
            }

            // ── Step A：每个目录内做文件 App 复制副本规范化（DNF(2).dylib → DNF.dylib）──
            let folderByParent = Dictionary(grouping: folderFiles.keys) {
                ($0 as NSString).deletingLastPathComponent
            }
            for (parent, paths) in folderByParent {
                for path in paths.sorted() {
                    let raw = (path as NSString).lastPathComponent
                    let norm = StashManager.normalizedPluginName(raw)
                    guard norm != raw else { continue }
                    let normRel = parent.isEmpty ? norm : parent + "/" + norm
                    if let twinURL = folderFiles[normRel] {
                        // 正本存在：大小相同 → 副本是重复复制产生的，删除
                        let s1 = StashManager.fileSize(of: folderFiles[path]!)
                        let s2 = StashManager.fileSize(of: twinURL)
                        if s1 >= 0, s1 == s2 {
                            try? fm.removeItem(at: folderFiles[path]!)
                            folderFiles.removeValue(forKey: path)
                            self.log("♻️ 已合并重复副本 \(path) → \(normRel)")
                        }
                        // 大小不同 → 视为不同版本，保留原名当独立插件
                    } else {
                        // 没有正本：直接改名为正本名
                        let dstURL = folderURL.appendingPathComponent(normRel)
                        try? fm.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if (try? fm.moveItem(at: folderFiles[path]!, to: dstURL)) != nil {
                            folderFiles.removeValue(forKey: path)
                            folderFiles[normRel] = dstURL
                        }
                    }
                }
            }

            // ── Step B：单向镜像——一切以「插件导入」文件夹为准 ──
            var imported: [String] = []
            var updated: [String] = []
            var removed: [String] = []

            for rel in folderFiles.keys.sorted() {
                let src = folderFiles[rel]!
                let dst = stashURL.appendingPathComponent(rel)
                let existing = stashFiles[rel]
                let needCopy: Bool
                if let s = existing {
                    let fs = StashManager.fileSize(of: src)
                    let ss = StashManager.fileSize(of: s)
                    needCopy = force || fs < 0 || fs != ss
                } else {
                    needCopy = true
                }
                guard needCopy else { continue }
                do {
                    try? fm.createDirectory(
                        at: dst.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                    try fm.copyItem(at: src, to: dst)
                    if existing == nil { imported.append(rel) } else { updated.append(rel) }
                } catch {
                    self.log("❌ 同步：\(rel) \(error.localizedDescription)")
                }
            }

            // 暂存箱里多出来的文件 = 文件夹里已不存在 → 删除（以文件夹为准，不回灌）
            for rel in stashFiles.keys where folderFiles[rel] == nil {
                try? fm.removeItem(at: stashURL.appendingPathComponent(rel))
                removed.append(rel)
            }

            // 目录对齐：文件夹里的目录 → 暂存箱同步创建（空分类也建）；
            // 暂存箱多出来的目录（含残留空分类）→ 删除
            for rel in folderDirs.sorted() {
                let dst = stashURL.appendingPathComponent(rel, isDirectory: true)
                if !fm.fileExists(atPath: dst.path) {
                    try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
                }
            }
            for rel in stashDirs.sorted() where !folderDirs.contains(rel) {
                // 其内容已在上一步按文件级清空，这里移除目录本身
                try? fm.removeItem(at: stashURL.appendingPathComponent(rel, isDirectory: true))
            }

            if !imported.isEmpty || !updated.isEmpty || !removed.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if !imported.isEmpty {
                        self.log("✅ 同步：已导入 \(imported.joined(separator: ", "))")
                    }
                    if !updated.isEmpty {
                        self.log("🔄 同步：已更新 \(updated.joined(separator: ", "))")
                    }
                    if !removed.isEmpty {
                        self.log("🗑 同步：已移除 \(removed.joined(separator: ", "))")
                    }
                    if !imported.isEmpty || !updated.isEmpty {
                        let names = (imported + updated).joined(separator: ", ")
                        self.notice = TempAlertItem(title: "同步完成", message: names)
                    }
                }
            }
        }
    }
}

// MARK: - Process kill helper

private func killRunningApp(bid: String) {
    guard let proxy = LSApplicationProxy(forIdentifier: bid),
          let bundleURL = proxy.bundleURL()
    else { return }
    guard let info = CFBundleCopyInfoDictionaryForURL(bundleURL as CFURL) as? [String: Any],
          let execName = info["CFBundleExecutable"] as? String
    else { return }
    // p_comm is truncated to 15 chars
    let comm = String(execName.prefix(15))
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return }
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return }
    let count = size / MemoryLayout<kinfo_proc>.stride
    for index in 0..<count {
        let name = withUnsafeBytes(of: procs[index].kp_proc.p_comm) { rawBuffer -> String in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return ""
            }
            return String(cString: base)
        }
        if name == comm {
            kill(procs[index].kp_proc.p_pid, SIGKILL)
        }
    }
}

// MARK: - Injector orchestration

final class GameInjector: ObservableObject {

    static let shared = GameInjector()

    @Published var isWorking = false
    @Published var statusText: String = ""

    /// Resolve target app: fixed bid first, then display-name match.
    private func resolveApp(_ target: GameTarget) -> (bid: String, url: URL)? {
        if let bid = target.fixedBundleID,
           let proxy = LSApplicationProxy(forIdentifier: bid),
           let url = proxy.bundleURL() {
            return (bid, url)
        }
        let installed = LSApplicationWorkspace.default().allApplications() ?? []
        for kw in target.appNameKeywords {
            if let hit = installed.first(where: { proxy in
                (proxy.localizedName() ?? "").contains(kw) && proxy.bundleURL() != nil
            }) {
                guard let bid = hit.applicationIdentifier(), let url = hit.bundleURL() else { continue }
                return (bid, url)
            }
        }
        return nil
    }

    /// 通用临时注入：对任意 App 注入指定插件列表，然后跳转。
    /// - Parameters:
    ///   - appName: 用于日志与提示的显示名。
    ///   - bid: 目标 App 的 bundle identifier。
    ///   - bundleURL: 目标 App 的 bundle URL。
    ///   - plugins: 要注入的插件文件列表。
    func injectAndLaunch(appName: String, bid: String, bundleURL: URL, plugins: [URL]) {
        guard !isWorking else { return }
        isWorking = true
        statusText = "正在处理…"
        let engine = ImportEngine.shared
        engine.log("🚀 \(appName)：开始处理")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let names = plugins.map { $0.lastPathComponent }.joined(separator: ", ")
            engine.log("🩺 目标 App：\(bid)")
            engine.log("💉 注入 \(plugins.count) 个插件：\(names)…")

            DispatchQueue.main.async { self.statusText = "正在加载 \(plugins.count) 个插件…" }

            // 1. kill the app if running (inject requires it not running)
            killRunningApp(bid: bid)
            Thread.sleep(forTimeInterval: 0.5)

            // 2. inject (non-persistent)
            do {
                let injector = try InjectorV3(bundleURL, loggerType: .os)
                try injector.inject(plugins, shouldPersist: false)
                engine.log("✅ 注入完成")

                // 3. record session + spawn detached watchdog
                let manager = TempInjectManager.shared
                try manager.writeState(bid: bid, assetURLs: plugins)
                try manager.spawnWatchdog(bid: bid)
                engine.log("🐕 看门狗已启动（退出后自动还原）")

                // 4. jump to the app
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let launched = manager.launchApp(bid: bid)
                    engine.log(launched ? "📲 跳转指令已发送" : "⚠️ 跳转指令发送失败，请手动打开")
                    if !launched {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let retry = manager.launchApp(bid: bid)
                            engine.log(retry ? "📲 重试跳转成功" : "❌ 重试跳转仍失败，请手动打开")
                        }
                    }
                }
                self.finish(success: "插件已加载，正在打开 \(appName)。退出后插件自动移除。")
            } catch {
                engine.log("❌ 注入失败：\(error.localizedDescription)")
                self.finish(alertOnly: "加载失败：\(error.localizedDescription)")
            }
        }
    }

    func injectAndLaunch(_ target: GameTarget, stash: StashManager = .shared) {
        guard !isWorking else { return }
        isWorking = true
        statusText = "正在处理…"
        let engine = ImportEngine.shared
        engine.log("🚀 \(target.buttonTitle)：开始处理")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. resolve app
            guard let targetApp = self.resolveApp(target) else {
                engine.log("❌ 未找到已安装的目标 App")
                self.finish(alertOnly: "未找到「\(target.buttonTitle.replacingOccurrences(of: "启动", with: ""))」对应的已安装 App，请确认游戏已安装。")
                return
            }
            let bid = targetApp.bid
            let bundleURL = targetApp.url
            engine.log("🩺 目标 App：\(bid)")

            // 2. resolve plugins
            let plugins = stash.plugins(matching: target.pluginKeywords)
            guard !plugins.isEmpty else {
                engine.log("❌ 暂存箱无匹配插件（关键词：\(target.pluginKeywords.joined(separator: "/"))）")
                self.finish(alertOnly: "暂存箱中没有匹配「\(target.buttonTitle.replacingOccurrences(of: "启动", with: ""))」的插件。\n请先把对应的 dylib 放入暂存箱（文件名需包含“\(target.appNameKeywords.first ?? "")”）再试。")
                return
            }
            let names = plugins.map { $0.lastPathComponent }.joined(separator: ", ")
            engine.log("💉 匹配到 \(plugins.count) 个插件：\(names)，开始注入…")

            DispatchQueue.main.async { self.statusText = "正在加载 \(plugins.count) 个插件…" }

            // 3. kill the game if running (inject requires it not running)
            killRunningApp(bid: bid)
            Thread.sleep(forTimeInterval: 0.5)

            // 4. inject (non-persistent)
            do {
                let injector = try InjectorV3(bundleURL, loggerType: .os)
                try injector.inject(plugins, shouldPersist: false)
                engine.log("✅ 注入完成")

                // 5. record session + spawn detached watchdog
                let manager = TempInjectManager.shared
                try manager.writeState(bid: bid, assetURLs: plugins)
                try manager.spawnWatchdog(bid: bid)
                engine.log("🐕 看门狗已启动（退出游戏后自动还原）")

                // 6. jump to the game
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let launched = manager.launchApp(bid: bid)
                    engine.log(launched ? "📲 跳转指令已发送" : "⚠️ 跳转指令发送失败，请手动打开游戏")
                    if !launched {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let retry = manager.launchApp(bid: bid)
                            engine.log(retry ? "📲 重试跳转成功" : "❌ 重试跳转仍失败，请手动打开游戏")
                        }
                    }
                }
                self.finish(success: "插件已加载，正在打开游戏。退出游戏后插件自动移除。")
            } catch {
                engine.log("❌ 注入失败：\(error.localizedDescription)")
                self.finish(alertOnly: "加载失败：\(error.localizedDescription)")
            }
        }
    }

    private func finish(alertOnly message: String) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusText = ""
            ImportEngine.shared.notice = TempAlertItem(title: "提示", message: message)
        }
    }

    private func finish(success message: String) {
        DispatchQueue.main.async {
            self.isWorking = false
            self.statusText = ""
            ImportEngine.shared.notice = TempAlertItem(title: "完成", message: message)
        }
    }
}

// MARK: - Target Selection (跨 Tab 共享已选目标应用)

/// 跨 Tab 共享的「当前已选目标应用」状态。
final class TargetSelection: ObservableObject {
    static let shared = TargetSelection()

    @Published var selectedApp: App?

    private init() {}
}

// MARK: - 收藏置顶 (收藏的 App 自动排最前)

/// 收藏的 App（bundle id）集合，用 UserDefaults 持久化。
/// 收藏的应用在「应用」列表中自动置顶，方便快速找到常用目标。
final class FavoriteApps: ObservableObject {

    static let shared = FavoriteApps()

    private static let defaultsKey = "shiliu.favoriteApps"

    @Published private(set) var bundleIDs: Set<String>

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        bundleIDs = Set(stored)
    }

    func isFavorite(_ bid: String) -> Bool {
        bundleIDs.contains(bid)
    }

    func toggle(_ bid: String) {
        if bundleIDs.contains(bid) {
            bundleIDs.remove(bid)
        } else {
            bundleIDs.insert(bid)
        }
        UserDefaults.standard.set(Array(bundleIDs), forKey: Self.defaultsKey)
    }
}

// MARK: - 切页刷新信号

/// 三个页面都常驻（用 opacity 保活），onAppear 不会再次触发。
/// 切页时 bump 一次，让注入页 / 暂存箱重新读盘，避免列表过期。
final class TabRefreshSignal: ObservableObject {
    static let shared = TabRefreshSignal()

    @Published private(set) var tick: Int = 0

    private init() {}

    func bump() { tick += 1 }
}


// MARK: - Home View (顶部胶囊分页：应用 / 注入 / 暂存箱)

struct TempHomeView: View {

    @ObservedObject private var engine = ImportEngine.shared
    @ObservedObject private var refreshSignal = TabRefreshSignal.shared
    @State private var selectedTab = 0
    @State private var visitedTabs: Set<Int> = [0]
    @State private var refreshing = false

    private let titles = ["应用", "注入", "暂存箱"]

    var body: some View {
        ZStack {
            KFBackground()

            VStack(spacing: 0) {

                // 顶栏：绿菱 + 标题 + 刷新
                KFNavBar("石榴注入", subtitle: "TrollFools · Injector") {
                    KFIconButton(systemName: "arrow.clockwise", active: refreshing) {
                        refreshAll()
                    }
                }
                .padding(.horizontal, 16)
                .kfTitleIn()

                // 白色药丸分页（P2 招牌件）
                KFSegmented(selection: $selectedTab, titles: titles)
                    .padding(.horizontal, 16)
                    .padding(.top, 3)
                    .padding(.bottom, 11)
                    .kfRise(1)

                // 三个页面常驻，靠 opacity + 横向位移做 page-in / page-out
                ZStack(alignment: .top) {

                    if visitedTabs.contains(0) {
                        AppTabView()
                            .opacity(selectedTab == 0 ? 1 : 0)
                            .offset(x: pageOffset(0))
                            .allowsHitTesting(selectedTab == 0)
                            .zIndex(selectedTab == 0 ? 1 : 0)
                    }

                    if visitedTabs.contains(1) {
                        InjectTabView()
                            .opacity(selectedTab == 1 ? 1 : 0)
                            .offset(x: pageOffset(1))
                            .allowsHitTesting(selectedTab == 1)
                            .zIndex(selectedTab == 1 ? 1 : 0)
                    }

                    if visitedTabs.contains(2) {
                        StashView()
                            .opacity(selectedTab == 2 ? 1 : 0)
                            .offset(x: pageOffset(2))
                            .allowsHitTesting(selectedTab == 2)
                            .zIndex(selectedTab == 2 ? 1 : 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(KFMotion.page, value: selectedTab)
            }
        }
        .onChange(of: selectedTab) { tab in
            if !visitedTabs.contains(tab) {
                visitedTabs.insert(tab)
            }
            // 页面常驻，onAppear 不会再次触发；切页给一次刷新信号重新读盘
            refreshSignal.bump()
        }
        .onAppear {
            // cleanupOrphans 可能同步跑整条 CLI 恢复流程，扔到后台
            DispatchQueue.global(qos: .utility).async {
                TempInjectManager.shared.cleanupOrphans()
            }
            ImportEngine.shared.syncImportFolder()
        }
        .onOpenURL { url in
            // 接收「用其他应用打开」共享进来的文件
            ImportEngine.shared.log("📩 收到共享文件：\(url.lastPathComponent)")
            ImportEngine.shared.importURLs([url], source: "共享")
        }
        .alert(item: $engine.notice) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("好")))
        }
    }

    /// 切页方向：当前页归位，已离开的页往左退，未进入的页从右待命
    private func pageOffset(_ index: Int) -> CGFloat {
        if selectedTab == index { return 0 }
        return index < selectedTab ? -18 : 18
    }

    private func refreshAll() {
        withAnimation(KFMotion.soft) { refreshing = true }
        ImportEngine.shared.syncImportFolder(force: true)
        refreshSignal.bump()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(KFMotion.soft) { refreshing = false }
        }
    }

    // MARK: 首项 · 应用

    struct AppTabView: View {

        @StateObject private var appList = AppListModel()
        @StateObject private var targetSelection = TargetSelection.shared
        @StateObject private var favorites = FavoriteApps.shared
        @ObservedObject private var refreshSignal = TabRefreshSignal.shared
        @State private var searchText = ""
        @State private var showFavoritesOnly = false

        private var allApps: [App] {
            appList.activeScopeApps.values.flatMap { $0 }
        }

        private var filteredApps: [App] {
            let filtered = searchText.isEmpty
                ? allApps
                : allApps.filter {
                    $0.name.localizedCaseInsensitiveContains(searchText)
                        || $0.bid.localizedCaseInsensitiveContains(searchText)
                }
            let onlyFavorites = showFavoritesOnly
                ? filtered.filter { favorites.isFavorite($0.bid) }
                : filtered
            // 收藏置顶，其余按名称稳定排序
            return onlyFavorites.sorted { a, b in
                let aFav = favorites.isFavorite(a.bid)
                let bFav = favorites.isFavorite(b.bid)
                if aFav != bFav { return aFav }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        var body: some View {
            ScrollView {
                VStack(spacing: 11) {

                    KFSearchField(text: $searchText, placeholder: "搜索 App 名称或 Bundle ID")
                        .kfRise(0)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            KFFilterPill(
                                title: showFavoritesOnly ? "★ 收藏" : "☆ 收藏",
                                isOn: showFavoritesOnly
                            ) {
                                withAnimation(KFMotion.spring) {
                                    showFavoritesOnly.toggle()
                                }
                            }

                            ForEach(Scope.allCases, id: \.self) { scope in
                                KFFilterPill(
                                    title: scope.localizedShortName,
                                    isOn: appList.activeScope == scope
                                ) {
                                    withAnimation(KFMotion.spring) {
                                        appList.activeScope = scope
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .kfRise(1)

                    if filteredApps.isEmpty {
                        KFEmptyState(
                            icon: searchText.isEmpty ? "square.grid.2x2" : "magnifyingglass",
                            title: searchText.isEmpty
                                ? (showFavoritesOnly ? "还没有收藏的应用" : "没有可注入的 App")
                                : "没有找到「\(searchText)」",
                            message: searchText.isEmpty
                                ? (showFavoritesOnly
                                    ? "点应用右侧的星标即可收藏，收藏的会置顶显示。"
                                    : "请确认 App 已安装，且为可注入类型（App Store / 巨魔商店应用）。")
                                : "换个关键词试试，或点搜索框右侧 ✕ 清空搜索。"
                        )
                        .kfRise(2)
                    } else {
                        appListCard
                            .kfRise(2)
                    }

                    if appList.unsupportedCount > 0 && !showFavoritesOnly {
                        Text("另有 \(appList.unsupportedCount) 个不支持注入的用户应用未显示")
                            .font(.system(size: 11))
                            .foregroundColor(KFColor.faint)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 2)
                    }

                    Text("石榴动态注入 v1.0 · 基于 TrollFools")
                        .font(.system(size: 10.5))
                        .foregroundColor(KFColor.faint)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                }
                .padding(.horizontal, 16)
                .padding(.top, 3)
                .padding(.bottom, 24)
            }
            .onChange(of: refreshSignal.tick) { _ in
                appList.reload()
            }
        }

        private var appListCard: some View {
            VStack(spacing: 0) {
                ForEach(Array(filteredApps.enumerated()), id: \.element.bid) { pair in
                    appRow(pair.element)
                    if pair.offset < filteredApps.count - 1 {
                        KFDivider(inset: 62)
                    }
                }
            }
            .kfCard(radius: 18)
        }

        @ViewBuilder
        private func appRow(_ app: App) -> some View {
            let isSelected = targetSelection.selectedApp?.bid == app.bid
            let isFav = favorites.isFavorite(app.bid)

            HStack(spacing: 8) {

                Button {
                    withAnimation(KFMotion.spring) {
                        targetSelection.selectedApp = app
                    }
                } label: {
                    HStack(spacing: 11) {
                        Image(uiImage: app.icon ?? UIImage())
                            .resizable()
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(KFColor.line, lineWidth: 0.8)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(app.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(KFColor.text)
                                    .lineLimit(1)

                                if app.isInjected || app.hasPersistedAssets {
                                    Image(systemName: app.isInjected
                                            ? "bandage.fill"
                                            : "exclamationmark.triangle.fill")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(KFColor.green)
                                }
                            }

                            Text(app.bid)
                                .font(.system(size: 10.5))
                                .foregroundColor(KFColor.weak)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 6)

                        KFCheckCircle(isOn: isSelected)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(KFButtonStyle(scale: 0.99))

                Button {
                    withAnimation(KFMotion.spring) {
                        favorites.toggle(app.bid)
                    }
                } label: {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(isFav ? KFColor.green : KFColor.faint)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(KFButtonStyle(scale: 0.86))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(isSelected ? KFColor.green.opacity(0.055) : Color.clear)
        }
    }

    // MARK: 中间项 · 注入

    struct InjectTabView: View {

        @StateObject private var injector = GameInjector.shared
        @StateObject private var targetSelection = TargetSelection.shared
        @ObservedObject private var engine = ImportEngine.shared
        @ObservedObject private var refreshSignal = TabRefreshSignal.shared
        @State private var plugins: [URL] = []
        @State private var groups: [(category: String, items: [StashManager.DeepItem])] = []
        @State private var collapsed: Set<String> = []
        @State private var selected: Set<String> = []

        var body: some View {
            ZStack(alignment: .bottom) {

                ScrollView {
                    VStack(spacing: 11) {

                        targetCard
                            .kfRise(0)

                        KFSectionHeader("选择插件") {
                            if !plugins.isEmpty {
                                KFPill(
                                    title: selected.count == plugins.count ? "清空" : "全选",
                                    icon: selected.count == plugins.count ? "xmark" : "checkmark"
                                ) {
                                    withAnimation(KFMotion.spring) {
                                        if selected.count == plugins.count {
                                            selected.removeAll()
                                        } else {
                                            selected = Set(plugins.map { $0.absoluteString })
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 3)
                        .kfRise(1)

                        pluginsCard
                            .kfRise(2)

                        KFSectionHeader("SYSTEM OUTPUT") {
                            HStack(spacing: 6) {
                                KFPill(title: "清空", icon: "trash") {
                                    withAnimation(KFMotion.soft) {
                                        engine.logs.removeAll()
                                    }
                                }
                                KFPill(title: "复制", icon: "doc.on.doc") {
                                    UIPasteboard.general.string = engine.logs.joined(separator: "\n")
                                }
                            }
                        }
                        .padding(.top, 3)
                        .kfRise(3)

                        KFTerminal(
                            lines: engine.logs,
                            maxLines: 8,
                            emptyText: "等待注入指令…"
                        )
                        .kfRise(4)

                        Text("石榴动态注入 v1.0 · 基于 TrollFools")
                            .font(.system(size: 10.5))
                            .foregroundColor(KFColor.faint)
                            .padding(.top, 10)
                            .padding(.bottom, 6)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 3)
                    .padding(.bottom, 108)
                }

                // 底部常驻主按钮（对应「初始化内核」）
                VStack(spacing: 0) {
                    LinearGradient(
                        gradient: Gradient(colors: [
                            KFColor.bg.opacity(0),
                            KFColor.bg.opacity(0.94),
                            KFColor.bg
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 26)

                    KFPrimaryButton(
                        title: injectButtonTitle,
                        icon: injector.isWorking ? nil : "bolt.fill",
                        enabled: canInject,
                        loading: injector.isWorking
                    ) {
                        startInjection()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .background(KFColor.bg)
                }
            }
            .onAppear {
                reloadPlugins()
            }
            .onChange(of: refreshSignal.tick) { _ in
                reloadPlugins()
            }
            .onChange(of: engine.logs.count) { _ in
                reloadPlugins()
            }
        }

        // MARK: 目标卡

        @ViewBuilder
        private var targetCard: some View {
            if let app = targetSelection.selectedApp {
                KFStatusCard(
                    caption: "目标应用",
                    bigText: app.name,
                    statusText: "已锁定",
                    detailText: app.bid,
                    isActive: true
                ) {
                    Image(uiImage: app.icon ?? UIImage())
                        .resizable()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(KFColor.green.opacity(0.35), lineWidth: 1)
                        )
                }
            } else {
                KFStatusCard(
                    caption: "目标应用",
                    bigText: "未选择",
                    statusText: "待选择",
                    detailText: "请到「应用」页点选要注入的 App",
                    isActive: false
                ) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(KFColor.faint)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(KFColor.card2)
                        )
                }
            }
        }

        // MARK: 插件列表

        @ViewBuilder
        private var pluginsCard: some View {
            if plugins.isEmpty {
                KFEmptyState(
                    icon: "shippingbox",
                    title: "暂存箱暂无插件",
                    message: "请先到「暂存箱」页导入 dylib / framework / zip / deb，支持按分类文件夹自动归类。"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.category) { groupPair in

                        groupHeader(groupPair.element.category, count: groupPair.element.items.count)

                        if !collapsed.contains(groupPair.element.category) {
                            ForEach(Array(groupPair.element.items.enumerated()), id: \.element.relPath) { itemPair in
                                pluginRow(itemPair.element)
                                if itemPair.offset < groupPair.element.items.count - 1 {
                                    KFDivider(inset: 44)
                                }
                            }
                        }

                        if groupPair.offset < groups.count - 1 {
                            KFDivider(inset: 0)
                        }
                    }
                }
                .kfCard(radius: 18)
            }
        }

        private func groupHeader(_ category: String, count: Int) -> some View {
            Button {
                toggleCollapsed(category)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: collapsed.contains(category) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(KFColor.faint)
                        .frame(width: 11)

                    Text(category)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(KFColor.text)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(KFColor.faint)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(KFButtonStyle(scale: 0.995))
        }

        private func pluginRow(_ item: StashManager.DeepItem) -> some View {
            let url = item.url
            let isSelected = selected.contains(url.absoluteString)

            return Button {
                withAnimation(KFMotion.spring) {
                    if isSelected {
                        selected.remove(url.absoluteString)
                    } else {
                        selected.insert(url.absoluteString)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    KFCheckCircle(isOn: isSelected)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(KFColor.text)
                            .lineLimit(1)

                        Text(url.pathExtension.uppercased())
                            .font(.system(size: 9.5, weight: .semibold))
                            .kerning(0.5)
                            .foregroundColor(KFColor.faint)
                    }

                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(isSelected ? KFColor.green.opacity(0.055) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(KFButtonStyle(scale: 0.995))
        }

        // MARK: - 插件分组

        private static let collapsedKey = "shiliu.injectCollapsed"

        private func loadCollapsed() {
            let arr = UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []
            collapsed = Set(arr)
        }

        private func toggleCollapsed(_ category: String) {
            withAnimation(KFMotion.spring) {
                if collapsed.contains(category) {
                    collapsed.remove(category)
                } else {
                    collapsed.insert(category)
                }
            }
            UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
        }

        /// 刷新插件列表：按分类分组（与暂存箱一致），同时维护全选用的扁平数组。
        private func reloadPlugins() {
            loadCollapsed()
            let items = StashManager.shared.listPluginItems()
            plugins = items.map { $0.url }

            var byCategory: [String: [StashManager.DeepItem]] = [:]
            for item in items {
                let category = StashManager.category(ofPluginAt: item.url)
                byCategory[category, default: []].append(item)
            }
            groups = byCategory
                .sorted { lhs, rhs in
                    if (lhs.key == "未分类") != (rhs.key == "未分类") {
                        return rhs.key == "未分类" // 未分类永远排最后
                    }
                    return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                }
                .map { (category: $0.key, items: $0.value) }
        }

        private var canInject: Bool {
            targetSelection.selectedApp != nil && !selected.isEmpty && !injector.isWorking
        }

        /// 注入按钮标题：根据当前状态动态变化。
        private var injectButtonTitle: String {
            if injector.isWorking {
                return injector.statusText.isEmpty ? "正在处理…" : injector.statusText
            }
            if targetSelection.selectedApp == nil {
                return "请先选择目标应用"
            }
            if selected.isEmpty {
                return "请选择要注入的插件"
            }
            return selected.count == 1 ? "注入并启动（1 个插件）" : "注入并启动（\(selected.count) 个插件）"
        }

        private func startInjection() {
            guard let app = targetSelection.selectedApp else { return }
            let urls = plugins.filter { selected.contains($0.absoluteString) }
            guard !urls.isEmpty else { return }
            let engine = ImportEngine.shared
            engine.log("⚡️ 临时注入：\(app.name) ← \(urls.count) 个插件")
            engine.log("   - \(urls.map { $0.lastPathComponent }.joined(separator: "\n   - "))")
            injector.injectAndLaunch(
                appName: app.name,
                bid: app.bid,
                bundleURL: app.url,
                plugins: urls
            )
        }
    }
}



// MARK: - Stash Page (permanent storage)

struct StashView: View {

    @ObservedObject private var engine = ImportEngine.shared
    @ObservedObject private var refreshSignal = TabRefreshSignal.shared
    @State private var groups: [(category: String, items: [StashManager.DeepItem])] = []
    @State private var collapsed: Set<String> = []
    @State private var isCreateCategoryPresented = false
    @State private var newCategoryName = ""
    @State private var pendingDeleteURL: URL?
    @State private var pendingDeleteName: String = ""
    @State private var isDeleteConfirmPresented = false

    private let stash = StashManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 11) {

                // 说明行卡
                HStack(alignment: .top, spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(KFColor.card2)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundColor(KFColor.green)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("「插件导入」文件夹的实时镜像")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(KFColor.text)

                        Text("同步目录：/var/mobile/Documents/插件导入。文件夹里有什么这里就显示什么，删除也会同步；只有 dylib / framework / bundle / zip / deb 会被当作插件，重复副本自动合并。")
                            .font(.system(size: 11))
                            .foregroundColor(KFColor.weak)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(13)
                .kfCard(radius: 18)
                .kfRise(0)

                HStack(spacing: 9) {
                    KFSecondaryButton(title: "立即同步", icon: "arrow.triangle.2.circlepath") {
                        ImportEngine.shared.syncImportFolder(force: true)
                        reload()
                    }

                    KFSecondaryButton(title: "新建分类", icon: "folder.badge.plus") {
                        isCreateCategoryPresented = true
                    }
                }
                .kfRise(1)

                // 统计行
                HStack(spacing: 6) {
                    Circle()
                        .fill(KFColor.green)
                        .frame(width: 5, height: 5)
                        .shadow(color: KFColor.green.opacity(0.9), radius: 3)

                    Text("\(groups.reduce(0) { $0 + $1.items.count }) 个插件")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(KFColor.sub)

                    Text("·")
                        .font(.system(size: 11))
                        .foregroundColor(KFColor.faint)

                    Text("\(groups.count) 个分类")
                        .font(.system(size: 11))
                        .foregroundColor(KFColor.weak)

                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 3)
                .padding(.top, 2)
                .kfRise(2)

                if groups.isEmpty {
                    KFEmptyState(
                        icon: "shippingbox",
                        title: "暂无插件",
                        message: "把 dylib / framework / zip / deb 放进「插件导入」文件夹，会自动同步到这里。"
                    )
                    .kfRise(3)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.category) { groupPair in

                            stashGroupHeader(groupPair.element.category, count: groupPair.element.items.count)

                            if !collapsed.contains(groupPair.element.category) {
                                if groupPair.element.items.isEmpty {
                                    Text("空分类文件夹")
                                        .font(.system(size: 11))
                                        .foregroundColor(KFColor.faint)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 11)
                                } else {
                                    ForEach(Array(groupPair.element.items.enumerated()), id: \.element.relPath) { itemPair in
                                        stashRow(itemPair.element)
                                        if itemPair.offset < groupPair.element.items.count - 1 {
                                            KFDivider(inset: 44)
                                        }
                                    }
                                }
                            }

                            if groupPair.offset < groups.count - 1 {
                                KFDivider(inset: 0)
                            }
                        }
                    }
                    .kfCard(radius: 18)
                    .kfRise(3)
                }

                if !engine.logs.isEmpty {
                    KFSectionHeader("导入日志")
                        .padding(.top, 3)
                        .kfRise(4)

                    KFTerminal(lines: engine.logs, maxLines: 10, emptyText: "暂无导入记录")
                        .kfRise(5)
                }

                Text("石榴动态注入 v1.0 · 基于 TrollFools")
                    .font(.system(size: 10.5))
                    .foregroundColor(KFColor.faint)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 3)
            .padding(.bottom, 24)
        }
        .onAppear {
            loadCollapsed()
            reload()
            ImportEngine.shared.syncImportFolder()
        }
        .onChange(of: engine.logs.count) { _ in
            reload()
        }
        .onChange(of: refreshSignal.tick) { _ in
            reload()
        }
        .alert(isPresented: $isDeleteConfirmPresented) {
            Alert(
                title: Text("删除插件？"),
                message: Text(pendingDeleteName + "\n会同时删除「插件导入」文件夹中的对应文件。"),
                primaryButton: .destructive(Text("删除")) {
                    if let url = pendingDeleteURL {
                        ImportEngine.shared.log("🗑 已删除插件：\(url.lastPathComponent)")
                        stash.removePlugin(url)
                        reload()
                    }
                    pendingDeleteURL = nil
                },
                secondaryButton: .cancel(Text("取消")) {
                    pendingDeleteURL = nil
                }
            )
        }
        .sheet(isPresented: $isCreateCategoryPresented) {
            createCategorySheet
        }
    }

    // MARK: 行 / 分组

    private func stashGroupHeader(_ category: String, count: Int) -> some View {
        Button {
            withAnimation(KFMotion.spring) {
                toggleCollapsed(category)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsed.contains(category) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(KFColor.faint)
                    .frame(width: 11)

                Text(category)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(KFColor.text)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(KFColor.faint)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(KFButtonStyle(scale: 0.995))
    }

    private func stashRow(_ item: StashManager.DeepItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isDirectory ? "shippingbox.fill" : "doc.fill")
                .font(.system(size: 11))
                .foregroundColor(KFColor.green)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(KFColor.text)
                    .lineLimit(1)

                Text(item.relPath)
                    .font(.system(size: 10))
                    .foregroundColor(KFColor.faint)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                pendingDeleteURL = item.url
                pendingDeleteName = item.url.lastPathComponent
                isDeleteConfirmPresented = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(KFColor.red.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(KFButtonStyle(scale: 0.86))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    // MARK: 新建分类

    private var createCategorySheet: some View {
        ZStack {
            KFBackground()

            VStack(alignment: .leading, spacing: 15) {

                HStack(spacing: 10) {
                    Text("新建分类")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(KFColor.text)

                    Spacer(minLength: 8)

                    KFIconButton(systemName: "xmark") {
                        newCategoryName = ""
                        isCreateCategoryPresented = false
                    }
                }
                .kfTitleIn()

                Text("会在 /var/mobile/Documents/插件导入 下创建同名文件夹，之后把对应插件拖进该文件夹即可自动归类。")
                    .font(.system(size: 11.5))
                    .foregroundColor(KFColor.weak)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .kfRise(0)

                HStack(spacing: 9) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(KFColor.weak)

                    TextField("分类名称（如：王者荣耀）", text: $newCategoryName)
                        .font(.system(size: 14))
                        .foregroundColor(KFColor.text)
                        .accentColor(KFColor.green)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                .padding(.horizontal, 13)
                .frame(height: 46)
                .kfCard(radius: 13)
                .kfRise(1)

                KFPrimaryButton(
                    title: "创建分类",
                    icon: "checkmark",
                    enabled: !trimmedCategoryName.isEmpty
                ) {
                    createCategory()
                }
                .kfRise(2)

                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private var trimmedCategoryName: String {
        newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createCategory() {
        let name = trimmedCategoryName
        if !name.isEmpty, name != ".", name != "..", !name.contains("/") {
            let folderURL = ImportEngine.importFolderURL
                .appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: folderURL, withIntermediateDirectories: true
            )
            ImportEngine.shared.log("📁 已创建分类：\(name)")
            ImportEngine.shared.syncImportFolder()
            reload()
        }
        newCategoryName = ""
        isCreateCategoryPresented = false
    }

    // MARK: - Reload

    private static let collapsedKey = "shiliu.stashCollapsed"

    private func loadCollapsed() {
        let arr = UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []
        collapsed = Set(arr)
    }

    private func toggleCollapsed(_ category: String) {
        if collapsed.contains(category) {
            collapsed.remove(category)
        } else {
            collapsed.insert(category)
        }
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey)
    }

    private func reload() {
        // 按分类分组：子文件夹名 = 分类名；根目录插件 = 未分类；空分类也显示。
        // 只把插件类型（dylib/zip/deb 文件与 .framework/.bundle 目录）当条目，
        // 插件 bundle 内部的文件不单独成行。
        let deep = stash.listDeep()
        var byCategory: [String: [StashManager.DeepItem]] = [:]
        var topLevelDirs = Set<String>()
        for item in deep {
            let ext = (item.url.lastPathComponent as NSString).pathExtension.lowercased()
            if item.isDirectory {
                if StashManager.pluginBundleExtensions.contains(ext) {
                    // .framework / .bundle 目录本身就是插件
                    let category = StashManager.category(ofPluginAt: item.url)
                    byCategory[category, default: []].append(item)
                } else if !item.relPath.contains("/") {
                    topLevelDirs.insert(item.relPath) // 顶层分类文件夹（可能为空）
                }
                continue
            }
            // 文件：仅插件扩展名，且不在插件 bundle 内部
            guard StashManager.pluginFileExtensions.contains(ext) else { continue }
            let ancestors = item.relPath.split(separator: "/").dropLast().map(String.init)
            guard !ancestors.contains(where: {
                StashManager.pluginBundleExtensions.contains((($0 as NSString).pathExtension.lowercased()))
            }) else { continue }
            let category = StashManager.category(ofPluginAt: item.url)
            byCategory[category, default: []].append(item)
        }
        for dir in topLevelDirs where byCategory[dir] == nil {
            byCategory[dir] = [] // 空分类也展示
        }
        groups = byCategory
            .sorted { lhs, rhs in
                if (lhs.key == "未分类") != (rhs.key == "未分类") {
                    return rhs.key == "未分类" // 未分类永远排最后
                }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .map { (category: $0.key, items: $0.value) }
    }
}
