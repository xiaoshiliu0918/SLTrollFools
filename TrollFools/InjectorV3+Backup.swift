//
//  InjectorV3+Backup.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/10.
//

import CocoaLumberjackSwift
import Foundation

extension InjectorV3 {
    // MARK: - Constants

    static let alternateSuffix = "troll-fools.bak"

    static func alternateURL(for target: URL) -> URL {
        target.appendingPathExtension(Self.alternateSuffix)
    }

    // MARK: - Shared Methods

    func hasAlternate(_ target: URL) -> Bool {
        let alternateURL = Self.alternateURL(for: target)
        return FileManager.default.fileExists(atPath: alternateURL.path)
    }

    func makeAlternate(_ target: URL) throws {
        guard !hasAlternate(target) else {
            return
        }
        let alternateURL = Self.alternateURL(for: target)
        try cmdCopy(from: target, to: alternateURL)
    }

    func removeAlternate(_ target: URL) throws {
        guard hasAlternate(target) else {
            return
        }
        let alternateURL = Self.alternateURL(for: target)
        try cmdRemove(alternateURL)
    }

    func restoreAlternate(_ target: URL) throws {
        guard hasAlternate(target) else {
            return
        }
        let alternateURL = Self.alternateURL(for: target)
        try cmdMove(from: alternateURL, to: target, overwrite: true)
    }

    /// 把所有带备份的 Mach-O 直接回滚到注入前状态，返回回滚数量。
    ///
    /// 用于降级路径：插件文件已经不在磁盘上（系统清理/用户手删），
    /// 没有 load command 可摘，只能靠 `.bak` 整体还原，
    /// 否则目标 App 会带着指向不存在 dylib 的 LC 一直崩。
    @discardableResult
    func restoreAllAlternates() throws -> Int {
        var restored = 0
        let targets = try frameworkMachOsInBundle(bundleURL)
        for target in targets where hasAlternate(target) {
            try restoreAlternate(target)
            restored += 1
        }
        DDLogInfo("Restored \(restored) alternate(s) for \(bundleURL.lastPathComponent)", ddlog: logger)
        return restored
    }
}
