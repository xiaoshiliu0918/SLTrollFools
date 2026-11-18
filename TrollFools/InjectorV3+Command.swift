//
//  InjectorV3+Command.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/9.
//

import Foundation
import MachOKit

extension InjectorV3 {
    // MARK: - chown

    fileprivate static func chownBinaryURL() throws -> URL { try findExecutable("chown") }

    func cmdChangeOwner(_ target: URL, owner: uid_t, groupOwner: uid_t? = nil, recursively: Bool = false) throws {
        if isPrivileged {
            try rootChangeOwner(target, owner: owner, groupOwner: groupOwner, recursively: recursively)
            return
        }
        var args = [String]()
        if recursively {
            args.append("-R")
        }
        if let groupOwner {
            args.append(String(format: "%d:%d", owner, groupOwner))
        } else {
            args.append(String(format: "%d", owner))
        }
        args.append(target.path)
        let retCode = try Execute.rootSpawn(binary: try Self.chownBinaryURL().path, arguments: args, ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("chown", reason: retCode)
        }
    }

    func cmdChangeOwnerToInstalld(_ target: URL, recursively: Bool = false) throws {
        try cmdChangeOwner(target, owner: 33, groupOwner: 33, recursively: recursively)
    }

    private func rootChangeOwner(_ target: URL, owner: uid_t, groupOwner: uid_t? = nil, recursively: Bool = false) throws {
        let attrs: [FileAttributeKey: Any] = [
            .ownerAccountID: NSNumber(value: owner),
            .groupOwnerAccountID: NSNumber(value: groupOwner ?? owner),
        ]
        if !recursively {
            try FileManager.default.setAttributes(attrs, ofItemAtPath: target.path)
            return
        }
        if let enumerator = FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                try FileManager.default.setAttributes(attrs, ofItemAtPath: fileURL.path)
            }
        }
    }

    // MARK: - cp

    fileprivate static func cpBinaryURL() throws -> URL {
        if #available(iOS 16, *) {
            return try findExecutable("cp")
        } else {
            return try findExecutable("cp-15")
        }
    }

    func cmdCopy(from srcURL: URL, to destURL: URL, clone: Bool = false, overwrite: Bool = false) throws {
        if isPrivileged {
            try rootCopy(from: srcURL, to: destURL, overwrite: overwrite)
            return
        }
        if overwrite {
            try? cmdRemove(destURL, recursively: true)
        }
        var args = [String]()
        if clone {
            args.append("--reflink=auto")
        }
        args += ["-rfp", srcURL.path, destURL.path]
        let retCode = try Execute.rootSpawn(binary: try Self.cpBinaryURL().path, arguments: args, ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("cp", reason: retCode)
        }
    }

    private func rootCopy(from srcURL: URL, to destURL: URL, overwrite: Bool = false) throws {
        if overwrite {
            try? rootRemove(destURL, recursively: true)
        }
        try FileManager.default.copyItem(at: srcURL, to: destURL)
    }

    // MARK: - ldid

    fileprivate static func ldidBinaryURL() throws -> URL { try findExecutable("ldid") }

    func cmdPseudoSign(_ target: URL, force: Bool = false) throws {
        var hasCodeSign = false
        var preservesEntitlements = false

        let targetFile = try MachOKit.loadFromFile(url: target)
        switch targetFile {
        case let .machO(machOFile):
            preservesEntitlements = machOFile.header.fileType == .execute
            for command in machOFile.loadCommands {
                switch command {
                case .codeSignature:
                    hasCodeSign = true
                    break
                default:
                    continue
                }
            }
        case let .fat(fatFile):
            let machOFiles = try fatFile.machOFiles()
            for machOFile in machOFiles {
                preservesEntitlements = machOFile.header.fileType == .execute
                for command in machOFile.loadCommands {
                    switch command {
                    case .codeSignature:
                        hasCodeSign = true
                        break
                    default:
                        continue
                    }
                }
            }
        }

        guard force || !hasCodeSign else {
            return
        }

        if preservesEntitlements {
            var receipt: AuxiliaryExecute.ExecuteReceipt

            receipt = try Execute.rootSpawnWithOutputs(binary: try Self.ldidBinaryURL().path, arguments: [
                "-e", target.path,
            ], ddlog: logger)

            guard case let .exit(code) = receipt.terminationReason, code == EXIT_SUCCESS else {
                try throwCommandFailure("ldid", reason: receipt.terminationReason)
            }

            let xmlContent = receipt.stdout
            let xmlURL = temporaryDirectoryURL
                .appendingPathComponent("\(UUID().uuidString)_\(target.lastPathComponent)")
                .appendingPathExtension("xml")

            try xmlContent.write(to: xmlURL, atomically: true, encoding: .utf8)

            receipt = try Execute.rootSpawnWithOutputs(binary: try Self.ldidBinaryURL().path, arguments: [
                "-S\(xmlURL.path)", target.path,
            ], ddlog: logger)

            guard case let .exit(code) = receipt.terminationReason, code == EXIT_SUCCESS else {
                try throwCommandFailure("ldid", reason: receipt.terminationReason)
            }
        } else {
            let retCode = try Execute.rootSpawn(binary: try Self.ldidBinaryURL().path, arguments: [
                "-S", target.path,
            ], ddlog: logger)

            guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
                try throwCommandFailure("ldid", reason: retCode)
            }
        }
    }

    // MARK: - mkdir

    fileprivate static func mkdirBinaryURL() throws -> URL { try findExecutable("mkdir") }

    func cmdMakeDirectory(at target: URL, withIntermediateDirectories: Bool = false) throws {
        if isPrivileged {
            try rootMakeDirectory(at: target, withIntermediateDirectories: withIntermediateDirectories)
            return
        }
        var args = [String]()
        if withIntermediateDirectories {
            args.append("-p")
        }
        args.append(target.path)
        let retCode = try Execute.rootSpawn(binary: try Self.mkdirBinaryURL().path, arguments: args, ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("mkdir", reason: retCode)
        }
    }

    private func rootMakeDirectory(at target: URL, withIntermediateDirectories: Bool = false) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: withIntermediateDirectories)
    }

    // MARK: - mv

    fileprivate static func mvBinaryURL() throws -> URL {
        if #available(iOS 16, *) {
            return try findExecutable("mv")
        } else {
            return try findExecutable("mv-15")
        }
    }

    func cmdMove(from srcURL: URL, to destURL: URL, overwrite: Bool = false) throws {
        if isPrivileged {
            try rootMove(from: srcURL, to: destURL, overwrite: overwrite)
            return
        }
        if overwrite {
            try? cmdRemove(destURL, recursively: true)
        }
        var args = [String]()
        if overwrite {
            args.append("-f")
        }
        args += [srcURL.path, destURL.path]
        let retCode = try Execute.rootSpawn(binary: try Self.mvBinaryURL().path, arguments: args, ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("mv", reason: retCode)
        }
    }

    private func rootMove(from srcURL: URL, to destURL: URL, overwrite: Bool = false) throws {
        if overwrite {
            try? rootRemove(destURL, recursively: true)
        }
        try FileManager.default.moveItem(at: srcURL, to: destURL)
    }

    // MARK: - rm

    fileprivate static func rmBinaryURL() throws -> URL { try findExecutable("rm") }

    func cmdRemove(_ target: URL, recursively: Bool = false) throws {
        if isPrivileged {
            try rootRemove(target, recursively: recursively)
            return
        }
        let retCode = try Execute.rootSpawn(binary: try Self.rmBinaryURL().path, arguments: [
            recursively ? "-rf" : "-f", target.path,
        ], ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("rm", reason: retCode)
        }
    }

    private func rootRemove(_ target: URL, recursively: Bool = false) throws {
        if !recursively {
            let retCode = target.withUnsafeFileSystemRepresentation { unlink($0) }
            guard retCode == 0 else {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EPERM)
            }
            return
        }
        try FileManager.default.removeItem(at: target)
    }

    // MARK: - ct_bypass

    fileprivate static func ctBypassBinaryURL() throws -> URL { try findExecutable("ct_bypass") }

    func cmdCoreTrustBypass(_ target: URL, teamID: String) throws {
        try cmdPseudoSign(target)
        let retCode = try Execute.rootSpawn(binary: try Self.ctBypassBinaryURL().path, arguments: [
            "-r", "-i", target.path, "-t", teamID,
        ], ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("ct_bypass", reason: retCode)
        }
    }

    // MARK: - insert_dylib

    fileprivate static func insertDylibBinaryURL() throws -> URL { try findExecutable("insert_dylib") }

    func cmdInsertLoadCommandDylib(_ target: URL, name: String, weak: Bool = false) throws {
        let dylibs = try loadedDylibsOfMachO(target)
        if dylibs.contains(name) {
            return
        }
        var args = [
            name, target.path,
            "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes",
        ]
        if weak {
            args.append("--weak")
        }
        let retCode = try Execute.rootSpawn(binary: try Self.insertDylibBinaryURL().path, arguments: args, ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("insert_dylib", reason: retCode)
        }
    }

    // MARK: - install_name_tool

    fileprivate static func installNameToolBinaryURL() throws -> URL { try findExecutable("install_name_tool") }

    func cmdInsertLoadCommandRuntimePath(_ target: URL, name: String) throws {
        let rpaths = try runtimePathsOfMachO(target)
        if rpaths.contains(name) {
            return
        }
        try cmdPseudoSign(target, force: true)
        let retCode = try Execute.rootSpawn(binary: try Self.installNameToolBinaryURL().path, arguments: [
            "-add_rpath", name, target.path,
        ], ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("install_name_tool", reason: retCode)
        }
    }

    func cmdChangeLoadCommandDylib(_ target: URL, from srcName: String, to destName: String) throws {
        try cmdPseudoSign(target, force: true)
        let retCode = try Execute.rootSpawn(binary: try Self.installNameToolBinaryURL().path, arguments: [
            "-change", srcName, destName, target.path,
        ], ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("install-name-tool", reason: retCode)
        }
    }

    // MARK: - optool

    fileprivate static func optoolBinaryURL() throws -> URL { try findExecutable("optool") }

    func cmdRemoveLoadCommandDylib(_ target: URL, name: String) throws {
        let dylibs = try loadedDylibsOfMachO(target)
        guard dylibs.contains(name) else {
            return
        }
        let retCode = try Execute.rootSpawn(binary: try Self.optoolBinaryURL().path, arguments: [
            "uninstall", "-p", name, "-t", target.path,
        ], ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("optool", reason: retCode)
        }
    }

    // MARK: - Error Handling

    fileprivate func throwCommandFailure(_ command: String, reason: AuxiliaryExecute.TerminationReason) throws -> Never {
        switch reason {
        case let .exit(code):
            throw Error.generic(String(format: NSLocalizedString("%@ exited with code %d", comment: ""), command, code))
        case let .uncaughtSignal(signal):
            throw Error.generic(String(format: NSLocalizedString("%@ terminated with signal %d", comment: ""), command, signal))
        }
    }

    // MARK: - Path Finder

    fileprivate static func findExecutable(_ name: String) throws -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return url
        }
        if let firstArg = ProcessInfo.processInfo.arguments.first {
            let execURL = URL(fileURLWithPath: firstArg)
                .deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: execURL.path) {
                return execURL
            }
        }
        if let tfProxy = LSApplicationProxy(forIdentifier: Constants.gAppIdentifier),
           let tfBundleURL = tfProxy.bundleURL()
        {
            let execURL = tfBundleURL.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: execURL.path) {
                return execURL
            }
        }
        throw Error.generic(String(format: NSLocalizedString("Missing bundled component: %@", comment: ""), name))
    }
}
