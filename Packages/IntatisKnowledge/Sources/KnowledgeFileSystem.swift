import Foundation
import IntatisCore
import IntatisProtocol

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct KnowledgeFileSystemLimits: Equatable, Sendable {
    public var maximumFiles = 100_000
    public var maximumTotalBytes = 2 * 1_024 * 1_024 * 1_024
    public var maximumSingleFileBytes = 256 * 1_024 * 1_024
    public var maximumDepth = 64

    public init() {}
}

public struct KnowledgeFileIdentity: Equatable, Hashable, Sendable {
    public let deviceID: UInt64
    public let fileID: UInt64
    public let size: Int
    public let mode: UInt16
    public let linkCount: UInt64
}

public struct KnowledgeScannedFile: Equatable, Sendable {
    public let relativePath: String
    public let identity: KnowledgeFileIdentity
}

public struct KnowledgeSecureFileSystem: Sendable {
    public let limits: KnowledgeFileSystemLimits

    public init(limits: KnowledgeFileSystemLimits = KnowledgeFileSystemLimits()) {
        self.limits = limits
    }

    public func authorizeRoot(_ root: URL,
                              workspaceLease: WorkspaceLease) throws -> (
        canonical: URL,
        identity: WorkspaceRootIdentity
    ) {
        guard let leaseIdentity = workspaceLease.rootIdentity,
              leaseIdentity.matchesCurrentDirectory(rootPath: workspaceLease.rootPath),
              let identity = WorkspaceRootIdentity.capture(rootPath: root.path) else {
            throw KnowledgeDomainError(.accessDenied, "Knowledge store is outside the active workspace lease or its root identity changed.")
        }
        let workspace = URL(
            fileURLWithPath: leaseIdentity.canonicalPath,
            isDirectory: true)
        let canonical = URL(fileURLWithPath: identity.canonicalPath, isDirectory: true)
        guard PathConfinement.isWithin(canonical.path, root: workspace),
              Self.workspaceLeaseAllows(
                  canonical,
                  workspaceRoot: workspace,
                  lease: workspaceLease) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge store is outside the active workspace lease or its path policy.")
        }
        try validateDirectory(canonical)
        return (canonical, identity)
    }

    public func scan(root: URL,
                     expectedRootIdentity: WorkspaceRootIdentity? = nil) throws -> [KnowledgeScannedFile] {
        let rootIdentity = try expectedRootIdentity ?? capturedDirectoryIdentity(root)
        try validateDirectory(root)
        var pending = [root]
        var files: [KnowledgeScannedFile] = []
        var totalBytes = 0
        while let directory = pending.popLast() {
            guard try capturedDirectoryIdentity(root) == rootIdentity else {
                throw KnowledgeDomainError(.revisionChanged, retryable: true, "Knowledge snapshot root changed while it was being read.")
            }
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []) else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot directory cannot be read.")
            }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let relative = try relativePath(child, root: root)
                let depth = relative.split(separator: "/").count
                guard depth <= limits.maximumDepth else {
                    throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot exceeds the directory depth limit.")
                }
                var status = stat()
                guard lstat(child.path, &status) == 0 else {
                    throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot entry identity cannot be read.")
                }
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    try validateDirectory(child)
                    pending.append(child)
                case S_IFREG:
                    let identity = try validateRegularFileStatus(status)
                    guard identity.size <= limits.maximumSingleFileBytes else {
                        throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot file exceeds the size limit.")
                    }
                    totalBytes += identity.size
                    guard totalBytes <= limits.maximumTotalBytes,
                          files.count < limits.maximumFiles else {
                        throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot exceeds the total file or byte limit.")
                    }
                    files.append(KnowledgeScannedFile(relativePath: relative, identity: identity))
                default:
                    throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot contains a symlink or special file.")
                }
            }
        }
        guard try capturedDirectoryIdentity(root) == rootIdentity else {
            throw KnowledgeDomainError(.revisionChanged, retryable: true, "Knowledge snapshot root changed while it was being read.")
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    public func readFile(root: URL,
                         relativePath: String,
                         maximumBytes: Int? = nil,
                         expectedRootIdentity: WorkspaceRootIdentity? = nil) throws -> Data {
        try validateRelativePath(relativePath)
        let rootIdentity = try expectedRootIdentity ?? capturedDirectoryIdentity(root)
        let candidate = root.appendingPathComponent(relativePath)
        guard PathConfinement.isWithin(candidate.path, root: root) else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot path escapes its root.")
        }
        try validateParentChain(candidate.deletingLastPathComponent(), root: root)
        guard try capturedDirectoryIdentity(root) == rootIdentity else {
            throw KnowledgeDomainError(.revisionChanged, retryable: true, "Knowledge snapshot root changed before file open.")
        }

        let descriptor = open(candidate.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot leaf could not be opened safely.")
        }
        defer { _ = close(descriptor) }

        var initial = stat()
        guard fstat(descriptor, &initial) == 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot leaf identity could not be read.")
        }
        let identity = try validateRegularFileStatus(initial)
        let byteLimit = min(maximumBytes ?? limits.maximumSingleFileBytes, limits.maximumSingleFileBytes)
        guard identity.size <= byteLimit else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot leaf exceeds the bounded read limit.")
        }

        var data = Data()
        data.reserveCapacity(identity.size)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                #if canImport(Darwin)
                return Darwin.read(descriptor, base, raw.count)
                #elseif canImport(Glibc)
                return Glibc.read(descriptor, base, raw.count)
                #elseif canImport(Musl)
                return Musl.read(descriptor, base, raw.count)
                #else
                return -1
                #endif
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot leaf read failed.")
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= byteLimit else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot leaf exceeded the bounded read limit.")
            }
        }

        var final = stat()
        var installed = stat()
        guard fstat(descriptor, &final) == 0,
              lstat(candidate.path, &installed) == 0,
              initial.st_dev == final.st_dev,
              initial.st_ino == final.st_ino,
              initial.st_size == final.st_size,
              initial.st_dev == installed.st_dev,
              initial.st_ino == installed.st_ino,
              try capturedDirectoryIdentity(root) == rootIdentity else {
            throw KnowledgeDomainError(.revisionChanged, retryable: true, "Knowledge snapshot leaf changed while it was being read.")
        }
        return data
    }

    public func leafInventory(root: URL,
                              excluding excluded: Set<String> = [
                                IntatisHostApplication.identity
                                    .knowledgeBundleDirectoryName
                                    + "/checksums.json",
                            ]) throws -> [KnowledgeChecksumEntry] {
        let rootIdentity = try capturedDirectoryIdentity(root)
        return try scan(root: root, expectedRootIdentity: rootIdentity).compactMap { file in
            guard !excluded.contains(file.relativePath) else { return nil }
            let data = try readFile(
                root: root,
                relativePath: file.relativePath,
                maximumBytes: file.identity.size,
                expectedRootIdentity: rootIdentity)
            return KnowledgeChecksumEntry(
                path: file.relativePath,
                size: data.count,
                sha256: KnowledgeDigest.sha256(data),
                role: Self.role(for: file.relativePath))
        }
    }

    public static func canonicalBundleDigest(_ entries: [KnowledgeChecksumEntry]) throws -> String {
        let selected = entries.filter {
            !$0.path.hasPrefix(
                KnowledgeHostIdentity.bundleDirectory + "/")
        }.sorted { $0.path < $1.path }
        guard !selected.isEmpty else {
            throw KnowledgeDomainError(.okfInvalid, "Knowledge bundle contains no OKF knowledge files.")
        }
        struct Projection: Codable {
            let version: String
            let files: [KnowledgeChecksumEntry]
        }
        return try KnowledgeDigest.canonical(
            Projection(
                version: KnowledgeHostIdentity.schema(
                    "okf-bundle-digest/1"),
                files: selected))
    }

    /// Commits every leaf byte in one snapshot, including the checksum
    /// inventory itself. This host seal is separate from the Profile's
    /// self-excluding checksum list, so it closes validate/publish TOCTOU
    /// without introducing a self-referential bundle field.
    public func snapshotSealDigest(root: URL) throws -> String {
        struct Projection: Codable {
            let version: String
            let files: [KnowledgeChecksumEntry]
        }
        let files = try leafInventory(root: root, excluding: [])
            .sorted { $0.path < $1.path }
        return try KnowledgeDigest.canonical(Projection(
            version: KnowledgeHostIdentity.schema(
                "knowledge-snapshot-content-seal/1"),
            files: files))
    }

    public func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              path.utf8.count <= 2_048,
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                  $0.isEmpty || $0 == "." || $0 == ".."
              }) else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot relative path is invalid.")
        }
    }

    private func relativePath(_ candidate: URL, root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let path = candidate.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot entry escapes its root.")
        }
        let relative = String(path.dropFirst(rootPath.count + 1))
        try validateRelativePath(relative)
        return relative
    }

    private func validateParentChain(_ directory: URL, root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        var current = directory.standardizedFileURL
        while current.path != rootPath {
            guard current.path.hasPrefix(rootPath + "/") else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot parent escapes its root.")
            }
            try validateDirectory(current)
            current.deleteLastPathComponent()
        }
        try validateDirectory(root)
    }

    private func validateDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              (status.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot directory is not a safe owner-controlled directory.")
        }
    }

    private func capturedDirectoryIdentity(_ url: URL) throws -> WorkspaceRootIdentity {
        guard let identity = WorkspaceRootIdentity.capture(rootPath: url.path) else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot root identity cannot be captured.")
        }
        return identity
    }

    private func validateRegularFileStatus(_ status: stat) throws -> KnowledgeFileIdentity {
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              (status.st_mode & (S_IWGRP | S_IWOTH | S_IXUSR | S_IXGRP | S_IXOTH)) == 0,
              status.st_size >= 0,
              status.st_size <= off_t(limits.maximumSingleFileBytes) else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot file is not a safe single-link regular file.")
        }
        return KnowledgeFileIdentity(
            deviceID: UInt64(status.st_dev),
            fileID: UInt64(status.st_ino),
            size: Int(status.st_size),
            mode: UInt16(status.st_mode & 0o7777),
            linkCount: UInt64(status.st_nlink))
    }

    private static func role(for path: String) -> String {
        if path == KnowledgeHostIdentity.bundlePath("profile.json") {
            return "profile"
        }
        if path == KnowledgeHostIdentity.bundlePath("chunks.jsonl") {
            return "chunk_manifest"
        }
        if path.hasPrefix(KnowledgeHostIdentity.bundlePath("dense/")) {
            return "dense_index"
        }
        if path.hasPrefix(KnowledgeHostIdentity.bundlePath("lexical/")) {
            return "lexical_index"
        }
        if path.hasPrefix(KnowledgeHostIdentity.bundlePath("auxiliary/")) {
            return "auxiliary"
        }
        if OKFBundleLayout.isConcept(path) { return "concept" }
        if path.split(separator: "/").contains("references") {
            return "reference"
        }
        return "okf"
    }

    private static func workspaceLeaseAllows(
        _ url: URL,
        workspaceRoot: URL,
        lease: WorkspaceLease
    ) -> Bool {
        let relative = PathConfinement.relativePath(
            of: url,
            root: workspaceRoot)
        if lease.deniedPatterns.contains(where: {
            workspaceLeasePath(relative, matches: $0)
        }) {
            return false
        }
        return lease.allowedPathRules.contains { rule in
            rule.pattern == "."
                || workspaceLeasePath(relative, matches: rule.pattern)
        }
    }

    private static func workspaceLeasePath(
        _ path: String,
        matches pattern: String
    ) -> Bool {
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        let normalizedPattern = pattern.replacingOccurrences(of: "\\", with: "/")
        if !normalizedPattern.contains("/") {
            return normalizedPath.split(separator: "/").contains {
                workspaceLeaseGlob(String($0), matches: normalizedPattern)
            }
        }
        return workspaceLeaseGlob(normalizedPath, matches: normalizedPattern)
    }

    private static func workspaceLeaseGlob(
        _ value: String,
        matches pattern: String
    ) -> Bool {
        var expression = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterStars = pattern.index(after: next)
                    if afterStars < pattern.endIndex,
                       pattern[afterStars] == "/" {
                        expression += "(?:.*/)?"
                        index = pattern.index(after: afterStars)
                    } else {
                        expression += ".*"
                        index = afterStars
                    }
                    continue
                }
                expression += "[^/]*"
            } else if character == "?" {
                expression += "[^/]"
            } else {
                expression += NSRegularExpression.escapedPattern(
                    for: String(character))
            }
            index = pattern.index(after: index)
        }
        expression += "$"
        guard let regex = try? NSRegularExpression(pattern: expression) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }
}
