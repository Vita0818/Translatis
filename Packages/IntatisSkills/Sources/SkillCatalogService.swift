import Foundation
import IntatisCore
import IntatisPermission
import IntatisTools

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Process-shared loader. Each call produces a fresh immutable snapshot; the
/// actor serializes filesystem observation without turning live files into
/// mutable runtime state.
public actor SkillCatalogService {
    public static let shared = SkillCatalogService()

    public init() {}

    public func snapshot(
        configuration: SkillDiscoveryConfiguration,
        catalogBudget: SkillCatalogMetadataBudget? = nil
    ) async throws -> SkillSnapshot {
        try Task.checkCancellation()
        let workspace = try PathConfinement.canonicalExistingDirectory(
            configuration.workspaceRoot)
        let current = try PathConfinement.canonicalExistingDirectory(
            configuration.currentDirectory)
        guard Self.isWithin(current, root: workspace) else {
            throw IntatisError.permissionDenied(
                "Skill current directory escapes the workspace root")
        }

        var diagnostics = DiagnosticBuffer(
            limits: configuration.limits)
        let roots = Self.discoveryRoots(
            configuration: configuration,
            workspace: workspace,
            current: current,
            diagnostics: &diagnostics)
        var frozen: [FrozenSkill] = []
        var seenSkillFiles: Set<String> = []
        var remainingSnapshotBytes =
            configuration.limits.maxSnapshotResourceBytes

        for root in roots {
            try Task.checkCancellation()
            try Self.scan(
                root: root,
                limits: configuration.limits,
                seenSkillFiles: &seenSkillFiles,
                remainingSnapshotBytes: &remainingSnapshotBytes,
                frozen: &frozen,
                diagnostics: &diagnostics)
        }
        try Task.checkCancellation()

        return SkillSnapshot(
            frozenSkills: frozen,
            diagnostics: diagnostics.finalized(),
            catalogBudget:
                catalogBudget
                ?? .characters(
                    configuration.limits.catalogCharacterBudget),
            maxExplicitSkills:
                configuration.limits.maxExplicitSkills,
            maxExplicitActivationCharacters:
                configuration.limits
                    .maxExplicitActivationCharacters,
            maxToolDisclosureCharacters:
                configuration.limits
                    .maxToolDisclosureCharacters)
    }
}

private extension SkillCatalogService {
    struct DiscoveryRoot {
        var url: URL
        var scope: SkillScope
        var label: String
        var device: UInt64?
        var inode: UInt64?

        init(
            url: URL,
            scope: SkillScope,
            label: String,
            device: UInt64? = nil,
            inode: UInt64? = nil
        ) {
            self.url = url
            self.scope = scope
            self.label = label
            self.device = device
            self.inode = inode
        }
    }

    struct ValidatedDirectory {
        var url: URL
        var device: UInt64
        var inode: UInt64
    }

    struct PendingDirectory {
        var url: URL
        var depth: Int
    }

    struct ParsedFrontmatter {
        var name: String
        var description: String
    }

    struct DiagnosticBuffer {
        private var values: [SkillDiagnostic] = []
        private var omittedCount = 0
        private let limits: SkillDiscoveryLimits

        init(limits: SkillDiscoveryLimits) {
            self.limits = limits
        }

        mutating func append(_ diagnostic: SkillDiagnostic) {
            let bounded = SkillDiagnostic(
                sourceLocator: boundedText(
                    diagnostic.sourceLocator,
                    limit:
                        limits.maxDiagnosticLocatorCharacters,
                    secretReplacement: "skill-source"),
                message: boundedText(
                    diagnostic.message,
                    limit:
                        limits.maxDiagnosticMessageCharacters,
                    secretReplacement:
                        "Skill diagnostic details were redacted."))
            if values.count < limits.maxDiagnostics {
                values.append(bounded)
            } else {
                omittedCount += 1
            }
        }

        mutating func finalized() -> [SkillDiagnostic] {
            guard omittedCount > 0 else { return values }
            if values.count >= limits.maxDiagnostics,
               !values.isEmpty {
                values.removeLast()
                omittedCount += 1
            }
            values.append(SkillDiagnostic(
                sourceLocator: "skill-discovery",
                message:
                    "\(omittedCount) additional Skill diagnostics were omitted by the frozen diagnostic limit."))
            return values
        }

        private func boundedText(
            _ value: String,
            limit: Int,
            secretReplacement: String
        ) -> String {
            guard !SecretScanner.containsSecret(value) else {
                return secretReplacement
            }
            let singleLine = value
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .replacingOccurrences(of: "<", with: "‹")
                .replacingOccurrences(of: ">", with: "›")
            guard singleLine.count > limit else {
                return singleLine
            }
            return String(singleLine.prefix(max(0, limit - 1))) + "…"
        }
    }

    static func discoveryRoots(
        configuration: SkillDiscoveryConfiguration,
        workspace: URL,
        current: URL,
        diagnostics: inout DiagnosticBuffer
    ) -> [DiscoveryRoot] {
        var candidates: [DiscoveryRoot] = []

        for directory in directories(
            from: workspace,
            through: current)
        {
            candidates.append(DiscoveryRoot(
                url: directory
                    .appendingPathComponent(".agents", isDirectory: true)
                    .appendingPathComponent("skills", isDirectory: true),
                scope: .workspace,
                label: "workspace:\(relativePath(directory, root: workspace))/.agents/skills"))
        }

        if configuration.access == .workspaceAndGlobal {
            if let home = configuration.homeDirectory {
                candidates.append(DiscoveryRoot(
                    url: home
                        .appendingPathComponent(".agents", isDirectory: true)
                        .appendingPathComponent("skills", isDirectory: true),
                    scope: .user,
                    label: "user:.agents/skills"))
            }
            if let codexHome = configuration.codexHome {
                let legacy = codexHome.appendingPathComponent(
                    "skills",
                    isDirectory: true)
                candidates.append(DiscoveryRoot(
                    url: legacy,
                    scope: .user,
                    label: "user:codex-home/skills"))
                candidates.append(DiscoveryRoot(
                    url: legacy.appendingPathComponent(
                        ".system",
                        isDirectory: true),
                    scope: .system,
                    label: "system:codex-home/skills/.system"))
            }
            candidates.append(contentsOf:
                configuration.bundledRoots.enumerated().map {
                    DiscoveryRoot(
                        url: $0.element,
                        scope: .system,
                        label: "system:bundle-\($0.offset)")
                })
            candidates.append(contentsOf:
                configuration.adminRoots.enumerated().map {
                    DiscoveryRoot(
                        url: $0.element,
                        scope: .admin,
                        label: "admin:root-\($0.offset)")
                })
            candidates.append(contentsOf:
                configuration.additionalRoots.enumerated().map {
                    DiscoveryRoot(
                        url: $0.element,
                        scope: .additional,
                        label: "additional:root-\($0.offset)")
                })
        }

        var roots: [DiscoveryRoot] = []
        var seen: Set<String> = []
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: candidate.url.path,
                isDirectory: &isDirectory)
            else {
                continue
            }
            guard isDirectory.boolValue else {
                diagnostics.append(SkillDiagnostic(
                    sourceLocator: candidate.label,
                    message: "Skill root is not a directory."))
                continue
            }
            do {
                let validated = try validatedNoFollowDirectory(
                    candidate.url)
                let canonical = validated.url
                guard candidate.scope != .workspace
                        || isWithin(canonical, root: workspace) else {
                    diagnostics.append(SkillDiagnostic(
                        sourceLocator: candidate.label,
                        message:
                            "Workspace Skill root escaped the workspace and was ignored."))
                    continue
                }
                guard seen.insert(canonical.path).inserted else {
                    continue
                }
                var resolved = candidate
                resolved.url = canonical
                resolved.device = validated.device
                resolved.inode = validated.inode
                roots.append(resolved)
            } catch {
                diagnostics.append(SkillDiagnostic(
                    sourceLocator: candidate.label,
                    message:
                        "Skill root was rejected as unsafe or inaccessible."))
            }
        }
        return roots
    }

    static func scan(
        root: DiscoveryRoot,
        limits: SkillDiscoveryLimits,
        seenSkillFiles: inout Set<String>,
        remainingSnapshotBytes: inout Int,
        frozen: inout [FrozenSkill],
        diagnostics: inout DiagnosticBuffer
    ) throws {
        var queue = [PendingDirectory(url: root.url, depth: 0)]
        var cursor = 0
        var visitedDirectories: Set<String> = []
        var directoryCount = 0
        var entryCount = 0

        while cursor < queue.count {
            try Task.checkCancellation()
            let pending = queue[cursor]
            cursor += 1
            let canonicalDirectory: URL
            do {
                canonicalDirectory = try canonicalNoFollowDirectory(
                    pending.url)
            } catch {
                diagnostics.append(SkillDiagnostic(
                    sourceLocator: locator(for: pending.url, under: root),
                    message:
                        "A Skill directory symlink or unsafe directory was ignored."))
                continue
            }
            guard isWithin(canonicalDirectory, root: root.url),
                  visitedDirectories.insert(
                    canonicalDirectory.path).inserted else {
                continue
            }
            directoryCount += 1
            guard directoryCount <= limits.maxDirectoriesPerRoot else {
                diagnostics.append(SkillDiagnostic(
                    sourceLocator: root.label,
                    message:
                        "Skill root scan stopped at the \(limits.maxDirectoriesPerRoot)-directory limit."))
                break
            }

            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: canonicalDirectory,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                    ],
                    options: [])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                diagnostics.append(SkillDiagnostic(
                    sourceLocator:
                        locator(
                            for: canonicalDirectory,
                            under: root),
                    message:
                        "Skill directory could not be read."))
                continue
            }
            entryCount += children.count
            guard entryCount <= limits.maxEntriesPerRoot else {
                diagnostics.append(SkillDiagnostic(
                    sourceLocator: root.label,
                    message:
                        "Skill root scan stopped at the \(limits.maxEntriesPerRoot)-entry limit."))
                break
            }

            if let skillFile = children.first(where: {
                $0.lastPathComponent == "SKILL.md"
            }) {
                try loadSkill(
                    skillFile: skillFile,
                    root: root,
                    limits: limits,
                    seenSkillFiles: &seenSkillFiles,
                    remainingSnapshotBytes:
                        &remainingSnapshotBytes,
                    frozen: &frozen,
                    diagnostics: &diagnostics)
            }

            guard pending.depth < limits.maxScanDepth else {
                continue
            }
            for child in children {
                guard !child.lastPathComponent.hasPrefix(".") else {
                    continue
                }
                guard !isSymbolicLink(child) else {
                    diagnostics.append(SkillDiagnostic(
                        sourceLocator: locator(for: child, under: root),
                        message:
                            "A Skill discovery symlink was ignored."))
                    continue
                }
                let candidate = child.standardizedFileURL
                guard isWithin(candidate, root: root.url),
                      isDirectoryNoFollow(candidate) else {
                    continue
                }
                queue.append(PendingDirectory(
                    url: candidate,
                    depth: pending.depth + 1))
            }
        }
    }

    static func loadSkill(
        skillFile: URL,
        root: DiscoveryRoot,
        limits: SkillDiscoveryLimits,
        seenSkillFiles: inout Set<String>,
        remainingSnapshotBytes: inout Int,
        frozen: inout [FrozenSkill],
        diagnostics: inout DiagnosticBuffer
    ) throws {
        try Task.checkCancellation()
        let canonicalFile = skillFile.standardizedFileURL
        let skillDirectory = canonicalFile.deletingLastPathComponent()
        let source = locator(for: canonicalFile, under: root)
        guard !isSymbolicLink(canonicalFile) else {
            diagnostics.append(SkillDiagnostic(
                sourceLocator: source,
                message: "A SKILL.md symlink was ignored."))
            return
        }
        guard isWithin(canonicalFile, root: root.url),
              isRegularFileNoFollow(canonicalFile) else {
            diagnostics.append(SkillDiagnostic(
                sourceLocator: source,
                message:
                    "SKILL.md is not a regular file inside its discovery root."))
            return
        }
        guard seenSkillFiles.insert(canonicalFile.path).inserted else {
            return
        }

        let contents: String
        let byteCount: Int
        do {
            let loaded = try readUTF8(
                canonicalFile,
                rootedAt: root,
                maxBytes: limits.maxSkillFileBytes)
            contents = loaded.text
            byteCount = loaded.byteCount
        } catch {
            diagnostics.append(SkillDiagnostic(
                sourceLocator: source,
                message:
                    "SKILL.md could not be loaded: \(error.localizedDescription)"))
            return
        }
        guard !SecretScanner.containsSecret(contents) else {
            diagnostics.append(SkillDiagnostic(
                sourceLocator: source,
                message:
                    "SKILL.md was ignored because secret-bearing content is not allowed."))
            return
        }
        guard byteCount <= remainingSnapshotBytes else {
            diagnostics.append(SkillDiagnostic(
                sourceLocator: source,
                message:
                    "SKILL.md exceeds the remaining frozen snapshot budget."))
            return
        }

        let parsed: ParsedFrontmatter
        do {
            parsed = try parseFrontmatter(
                contents,
                defaultName: skillDirectory.lastPathComponent,
                limits: limits)
        } catch {
            diagnostics.append(SkillDiagnostic(
                sourceLocator: source,
                message:
                    "Invalid Skill frontmatter: \(error.localizedDescription)"))
            return
        }
        let dependencyMetadata =
            loadMCPDependencyMetadata(
                skillDirectory:
                    skillDirectory,
                root: root,
                sourceLocator: source,
                diagnostics: &diagnostics)

        remainingSnapshotBytes -= byteCount
        var perSkillBytes = 0
        var resources: [String: String] = [:]
        try freezeResources(
            skillDirectory: skillDirectory,
            root: root,
            limits: limits,
            remainingSnapshotBytes:
                &remainingSnapshotBytes,
            perSkillBytes: &perSkillBytes,
            resources: &resources,
            sourceLocator: source,
            diagnostics: &diagnostics)

        let identity = ToolRegistry.authorizationDigest(
            SkillSnapshot.framed([
                IntatisHostApplication.identity.temporaryPrefix(
                    "skill-id-v1"),
                root.scope.rawValue,
                canonicalFile.path,
            ]))
        let metadata = SkillMetadata(
            id: "skill_\(identity.prefix(24))",
            name: parsed.name,
            description: parsed.description,
            scope: root.scope,
            sourceLocator: source,
            resourcePaths: resources.keys.sorted(),
            mcpDependencyMetadataState:
                dependencyMetadata.state,
            mcpDependencies:
                dependencyMetadata.dependencies)
        frozen.append(FrozenSkill(
            metadata: metadata,
            instructions: contents,
            resources: resources))
    }

    static func freezeResources(
        skillDirectory: URL,
        root: DiscoveryRoot,
        limits: SkillDiscoveryLimits,
        remainingSnapshotBytes: inout Int,
        perSkillBytes: inout Int,
        resources: inout [String: String],
        sourceLocator: String,
        diagnostics: inout DiagnosticBuffer
    ) throws {
        var queue = [PendingDirectory(
            url: skillDirectory,
            depth: 0)]
        var cursor = 0
        var visitedDirectories: Set<String> = []
        var directoryCount = 0
        var entryCount = 0

        while cursor < queue.count,
              resources.count < limits.maxResourcesPerSkill,
              perSkillBytes < limits.maxResourceBytesPerSkill,
              remainingSnapshotBytes > 0
        {
            try Task.checkCancellation()
            let pending = queue[cursor]
            cursor += 1
            let directory: URL
            do {
                directory = try canonicalNoFollowDirectory(pending.url)
            } catch {
                diagnostics.append(SkillDiagnostic(
                    sourceLocator: sourceLocator,
                    message:
                        "A Skill resource directory symlink or unsafe directory was ignored."))
                continue
            }
            guard isWithin(directory, root: skillDirectory),
                  visitedDirectories.insert(directory.path).inserted else {
                continue
            }
            directoryCount += 1
            guard directoryCount <= limits.maxDirectoriesPerRoot else {
                diagnostics.append(SkillDiagnostic(
                    sourceLocator: sourceLocator,
                    message:
                        "Skill resource scan stopped at the directory limit."))
                break
            }

            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                    ],
                    options: [])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                diagnostics.append(SkillDiagnostic(
                    sourceLocator: sourceLocator,
                    message:
                        "A Skill resource directory could not be read."))
                continue
            }
            entryCount += children.count
            guard entryCount <= limits.maxEntriesPerRoot else {
                diagnostics.append(SkillDiagnostic(
                    sourceLocator: sourceLocator,
                    message:
                        "Skill resource scan stopped at the \(limits.maxEntriesPerRoot)-entry limit."))
                break
            }

            for child in children {
                if child.lastPathComponent == "SKILL.md",
                   directory.path == skillDirectory.path {
                    continue
                }
                // Product metadata is machine-only. It is parsed separately,
                // hashed into the Skill snapshot, and must never become a
                // model-readable Skill resource containing a URL or command.
                if isReservedMachineMetadataPath(
                    relativePath(
                        child.standardizedFileURL,
                        root: skillDirectory)) {
                    continue
                }
                guard !child.lastPathComponent.hasPrefix(".") else {
                    continue
                }
                guard !isSymbolicLink(child) else {
                    diagnostics.append(SkillDiagnostic(
                        sourceLocator: sourceLocator,
                        message:
                            "A Skill resource symlink was ignored."))
                    continue
                }
                let canonical = child.standardizedFileURL
                guard isWithin(canonical, root: skillDirectory) else {
                    diagnostics.append(SkillDiagnostic(
                        sourceLocator: sourceLocator,
                        message:
                            "A Skill resource outside its Skill directory was ignored."))
                    continue
                }
                if isDirectoryNoFollow(canonical) {
                    guard pending.depth < limits.maxScanDepth else {
                        continue
                    }
                    // A nested Skill is a separate package, not a resource of
                    // its parent package.
                    let nestedSkill = canonical.appendingPathComponent(
                        "SKILL.md",
                        isDirectory: false)
                    if isRegularFileNoFollow(nestedSkill) {
                        continue
                    }
                    queue.append(PendingDirectory(
                        url: canonical,
                        depth: pending.depth + 1))
                    continue
                }
                guard isRegularFileNoFollow(canonical) else { continue }

                let relative = relativePath(
                    canonical,
                    root: skillDirectory)
                guard let normalized =
                        try? SkillSnapshot.normalizedResourcePath(
                            relative) else {
                    diagnostics.append(SkillDiagnostic(
                        sourceLocator: sourceLocator,
                        message:
                            "A sensitive or invalid Skill resource path was ignored."))
                    continue
                }
                let remainingForSkill =
                    limits.maxResourceBytesPerSkill - perSkillBytes
                let maxBytes = min(
                    limits.maxResourceFileBytes,
                    remainingForSkill,
                    remainingSnapshotBytes)
                guard maxBytes > 0 else { return }
                do {
                    let loaded = try readUTF8(
                        canonical,
                        rootedAt: root,
                        maxBytes: maxBytes)
                    guard !SecretScanner.containsSecret(loaded.text) else {
                        diagnostics.append(SkillDiagnostic(
                            sourceLocator:
                                "\(sourceLocator)#\(normalized)",
                            message:
                                "Skill resource was ignored because secret-bearing content is not allowed."))
                        continue
                    }
                    resources[normalized] = loaded.text
                    perSkillBytes += loaded.byteCount
                    remainingSnapshotBytes -= loaded.byteCount
                } catch {
                    diagnostics.append(SkillDiagnostic(
                        sourceLocator:
                            "\(sourceLocator)#\(normalized)",
                        message:
                            "Skill resource was not frozen: \(error.localizedDescription)"))
                }
                if resources.count >= limits.maxResourcesPerSkill {
                    break
                }
            }
        }
    }

    static func loadMCPDependencyMetadata(
        skillDirectory: URL,
        root: DiscoveryRoot,
        sourceLocator: String,
        diagnostics: inout DiagnosticBuffer
    ) -> (
        state: SkillMCPDependencyMetadataState,
        dependencies: [SkillMCPDependency]
    ) {
        do {
            guard let metadataURL =
                    try locateMCPMetadata(
                        skillDirectory:
                            skillDirectory) else {
                return (.absent, [])
            }
            guard !isSymbolicLink(metadataURL),
                  isRegularFileNoFollow(metadataURL) else {
                throw IntatisError.permissionDenied(
                    "Skill MCP metadata is not a safe regular file")
            }
            let loaded = try readUTF8(
                metadataURL,
                rootedAt: root,
                maxBytes:
                    SkillMCPMetadataBounds
                        .maximumFileBytes)
            let parsed =
                try SkillMCPMetadataParser
                    .parse(loaded.text)
            return (
                .valid,
                parsed.dependencies)
        } catch {
            diagnostics.append(SkillDiagnostic(
                sourceLocator:
                    "\(sourceLocator)#agents/openai.yaml",
                message:
                    "agents/openai.yaml MCP dependency metadata was rejected as unsafe or invalid; selecting this Skill will fail dependency preflight."))
            return (.invalid, [])
        }
    }

    /// Locates the reserved machine metadata path without relying on the host
    /// filesystem's case-sensitivity. A case collision is rejected rather
    /// than selecting one arbitrary file by directory enumeration order.
    static func locateMCPMetadata(
        skillDirectory: URL
    ) throws -> URL? {
        let rootEntries = try FileManager.default
            .contentsOfDirectory(
                at: skillDirectory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ],
                options: [])
        let agentsEntries = rootEntries.filter {
            asciiFolded($0.lastPathComponent)
                == "agents"
        }
        guard agentsEntries.count <= 1 else {
            throw IntatisError.decoding(
                "Skill machine metadata directory has a case collision")
        }
        guard let agentsEntry = agentsEntries.first else {
            return nil
        }
        guard !isSymbolicLink(agentsEntry),
              isDirectoryNoFollow(agentsEntry) else {
            throw IntatisError.permissionDenied(
                "Skill machine metadata directory is unsafe")
        }
        let agentsDirectory =
            try canonicalNoFollowDirectory(
                agentsEntry)
        guard isWithin(
                agentsDirectory,
                root: skillDirectory) else {
            throw IntatisError.permissionDenied(
                "Skill machine metadata directory escapes the Skill")
        }
        let metadataEntries = try FileManager.default
            .contentsOfDirectory(
                at: agentsDirectory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [])
            .filter {
                asciiFolded($0.lastPathComponent)
                    == "openai.yaml"
            }
        guard metadataEntries.count <= 1 else {
            throw IntatisError.decoding(
                "Skill MCP metadata has a case collision")
        }
        return metadataEntries.first
    }

    static func isReservedMachineMetadataPath(
        _ relativePath: String
    ) -> Bool {
        asciiFolded(relativePath)
            == "agents/openai.yaml"
    }

    static func asciiFolded(
        _ value: String
    ) -> String {
        let folded = value.utf8.map { byte -> UInt8 in
            guard byte >= 65, byte <= 90 else {
                return byte
            }
            return byte + 32
        }
        return String(
            decoding: folded,
            as: UTF8.self)
    }

    static func parseFrontmatter(
        _ contents: String,
        defaultName: String,
        limits: SkillDiscoveryLimits
    ) throws -> ParsedFrontmatter {
        let lines = contents.split(
            separator: "\n",
            omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .newlines) }
        guard lines.first.map(stripCarriageReturn) == "---" else {
            throw IntatisError.decoding(
                "missing leading --- delimiter")
        }
        guard let closing = lines.dropFirst().firstIndex(where: {
            stripCarriageReturn($0) == "---"
        }) else {
            throw IntatisError.decoding(
                "missing closing --- delimiter")
        }
        let frontmatter = Array(lines[1..<closing])
        let scalars = try topLevelScalars(frontmatter)
        let rawName =
            scalars["name"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (rawName?.isEmpty == false ? rawName! : defaultName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw IntatisError.decoding("Skill name is empty")
        }
        guard name.count <= limits.maxNameCharacters else {
            throw IntatisError.decoding(
                "Skill name exceeds \(limits.maxNameCharacters) characters")
        }
        guard let description = scalars["description"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !description.isEmpty else {
            throw IntatisError.decoding(
                "missing non-empty description")
        }
        guard description.count
                <= limits.maxDescriptionCharacters else {
            throw IntatisError.decoding(
                "Skill description exceeds \(limits.maxDescriptionCharacters) characters")
        }
        return ParsedFrontmatter(
            name: name,
            description: description)
    }

    static func topLevelScalars(
        _ lines: [String]
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = stripCarriageReturn(lines[index])
            let trimmed =
                line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                index += 1
                continue
            }
            guard leadingSpaceCount(line) == 0,
                  let colon = line.firstIndex(of: ":") else {
                index += 1
                continue
            }
            let key = String(line[..<colon])
                .trimmingCharacters(in: .whitespaces)
            var raw = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard key == "name" || key == "description" else {
                index += 1
                continue
            }
            guard result[key] == nil else {
                throw IntatisError.decoding(
                    "duplicate \(key) field")
            }

            if raw == "|" || raw == "|-" || raw == "|+"
                || raw == ">" || raw == ">-" || raw == ">+"
            {
                let folded = raw.hasPrefix(">")
                var block: [String] = []
                index += 1
                while index < lines.count {
                    let candidate =
                        stripCarriageReturn(lines[index])
                    if !candidate.trimmingCharacters(
                        in: .whitespaces).isEmpty,
                        leadingSpaceCount(candidate) == 0 {
                        break
                    }
                    block.append(candidate)
                    index += 1
                }
                let indentation = block
                    .filter {
                        !$0.trimmingCharacters(
                            in: .whitespaces).isEmpty
                    }
                    .map(leadingSpaceCount)
                    .min() ?? 0
                let normalized = block.map {
                    String($0.dropFirst(
                        min(indentation, $0.count)))
                }
                result[key] = folded
                    ? normalized.joined(separator: " ")
                    : normalized.joined(separator: "\n")
                continue
            }

            raw = try decodedScalar(raw)
            result[key] = raw
            index += 1
        }
        return result
    }

    static func decodedScalar(_ raw: String) throws -> String {
        guard raw.count >= 2 else { return raw }
        if raw.hasPrefix("\""), raw.hasSuffix("\"") {
            guard let data = raw.data(using: .utf8),
                  let value =
                    try? JSONDecoder().decode(
                        String.self,
                        from: data) else {
                throw IntatisError.decoding(
                    "invalid double-quoted scalar")
            }
            return value
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    static func readUTF8(
        _ url: URL,
        rootedAt root: DiscoveryRoot,
        maxBytes: Int
    ) throws -> (text: String, byteCount: Int) {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        guard let expectedRootDevice = root.device,
              let expectedRootInode = root.inode else {
            throw IntatisError.permissionDenied(
                "Skill root identity is unavailable")
        }
        let opened = try openRootedFile(url, root: root)
        let descriptor = opened.file
        let rootDescriptor = opened.root
        defer { _ = close(descriptor) }
        defer { _ = close(rootDescriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0 else {
            throw IntatisError.permissionDenied(
                "file is not a safe regular file")
        }
        guard Int64(before.st_size) <= Int64(maxBytes) else {
            throw IntatisError.permissionDenied(
                "file exceeds the \(maxBytes)-byte limit")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return 0 }
                #if canImport(Darwin)
                return Darwin.read(descriptor, base, bytes.count)
                #elseif canImport(Glibc)
                return Glibc.read(descriptor, base, bytes.count)
                #elseif canImport(Musl)
                return Musl.read(descriptor, base, bytes.count)
                #else
                return -1
                #endif
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw IntatisError.io("Skill file read failed")
            }
            guard data.count + count <= maxBytes else {
                throw IntatisError.permissionDenied(
                    "file exceeds the \(maxBytes)-byte limit")
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw IntatisError.io(
                "Skill file identity could not be verified after reading")
        }
        #if canImport(Darwin)
        let modificationTimeUnchanged =
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                && before.st_mtimespec.tv_nsec
                    == after.st_mtimespec.tv_nsec
        #else
        let modificationTimeUnchanged =
            before.st_mtim.tv_sec == after.st_mtim.tv_sec
                && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec
        #endif
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_nlink == after.st_nlink,
              modificationTimeUnchanged else {
            throw IntatisError.permissionDenied(
                "file changed while it was being frozen")
        }
        var rootAfter = stat()
        guard fstat(rootDescriptor, &rootAfter) == 0,
              UInt64(rootAfter.st_dev) == expectedRootDevice,
              UInt64(rootAfter.st_ino) == expectedRootInode else {
            throw IntatisError.permissionDenied(
                "Skill root identity changed while a file was being frozen")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw IntatisError.decoding(
                "file is not valid UTF-8 text")
        }
        return (text, data.count)
        #else
        throw IntatisError.permissionDenied(
            "safe Skill file reads are unavailable on this platform")
        #endif
    }

    static func openRootedFile(
        _ url: URL,
        root: DiscoveryRoot
    ) throws -> (file: Int32, root: Int32) {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        guard let expectedDevice = root.device,
              let expectedInode = root.inode else {
            throw IntatisError.permissionDenied(
                "Skill root identity is unavailable")
        }
        let rootDescriptor = open(
            root.url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard rootDescriptor >= 0 else {
            throw IntatisError.permissionDenied(
                "Skill root could not be reopened safely")
        }
        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0,
              rootStatus.st_mode & S_IFMT == S_IFDIR,
              UInt64(rootStatus.st_dev) == expectedDevice,
              UInt64(rootStatus.st_ino) == expectedInode else {
            _ = close(rootDescriptor)
            throw IntatisError.permissionDenied(
                "Skill root identity no longer matches its snapshot")
        }

        let candidate = url.standardizedFileURL
        guard isWithin(candidate, root: root.url) else {
            _ = close(rootDescriptor)
            throw IntatisError.permissionDenied(
                "Skill file escapes its frozen root")
        }
        let relative = relativePath(candidate, root: root.url)
        let components = relative.split(
            separator: "/",
            omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              relative != ".",
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            _ = close(rootDescriptor)
            throw IntatisError.permissionDenied(
                "Skill file has an invalid rooted path")
        }

        var directoryDescriptor = dup(rootDescriptor)
        guard directoryDescriptor >= 0 else {
            _ = close(rootDescriptor)
            throw IntatisError.io(
                "Skill root descriptor could not be duplicated")
        }
        for component in components.dropLast() {
            let next = component.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
            }
            guard next >= 0 else {
                _ = close(directoryDescriptor)
                _ = close(rootDescriptor)
                throw IntatisError.permissionDenied(
                    "Skill path contains a symlink or unsafe directory")
            }
            _ = close(directoryDescriptor)
            directoryDescriptor = next
        }

        let fileDescriptor = components.last!.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        _ = close(directoryDescriptor)
        guard fileDescriptor >= 0 else {
            _ = close(rootDescriptor)
            throw IntatisError.permissionDenied(
                "Skill file could not be opened without following symbolic links")
        }
        return (fileDescriptor, rootDescriptor)
        #else
        throw IntatisError.permissionDenied(
            "rooted Skill file reads are unavailable on this platform")
        #endif
    }

    static func directories(
        from root: URL,
        through current: URL
    ) -> [URL] {
        var reversed: [URL] = []
        var cursor = current
        while true {
            reversed.append(cursor)
            if cursor.path == root.path { break }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        return reversed.reversed()
    }

    static func locator(
        for url: URL,
        under root: DiscoveryRoot
    ) -> String {
        let relative = relativePath(url, root: root.url)
        if relative == "." { return root.label }
        return "\(root.label)/\(relative)"
    }

    static func relativePath(_ url: URL, root: URL) -> String {
        PathConfinement.relativePath(of: url, root: root)
    }

    static func isWithin(_ url: URL, root: URL) -> Bool {
        let canonicalRoot =
            root.resolvingSymlinksInPath().standardizedFileURL.path
        let canonical =
            url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = canonicalRoot.hasSuffix("/")
            ? canonicalRoot
            : canonicalRoot + "/"
        return canonical == canonicalRoot || canonical.hasPrefix(prefix)
    }

    static func canonicalNoFollowDirectory(_ url: URL) throws -> URL {
        try validatedNoFollowDirectory(url).url
    }

    static func validatedNoFollowDirectory(
        _ url: URL
    ) throws -> ValidatedDirectory {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw IntatisError.permissionDenied(
                "Skill root symlinks are not allowed")
        }
        defer { _ = close(descriptor) }
        var original = stat()
        guard fstat(descriptor, &original) == 0,
              original.st_mode & S_IFMT == S_IFDIR else {
            throw IntatisError.permissionDenied(
                "Skill root is not a safe directory")
        }

        let canonical =
            url.resolvingSymlinksInPath().standardizedFileURL
        let canonicalDescriptor = open(
            canonical.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard canonicalDescriptor >= 0 else {
            throw IntatisError.permissionDenied(
                "Skill root identity could not be verified")
        }
        defer { _ = close(canonicalDescriptor) }
        var resolved = stat()
        guard fstat(canonicalDescriptor, &resolved) == 0,
              resolved.st_mode & S_IFMT == S_IFDIR,
              original.st_dev == resolved.st_dev,
              original.st_ino == resolved.st_ino else {
            throw IntatisError.permissionDenied(
                "Skill root identity changed while it was being resolved")
        }
        return ValidatedDirectory(
            url: canonical,
            device: UInt64(original.st_dev),
            inode: UInt64(original.st_ino))
        #else
        throw IntatisError.permissionDenied(
            "safe Skill directory reads are unavailable on this platform")
        #endif
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return status.st_mode & S_IFMT == S_IFLNK
        #else
        return true
        #endif
    }

    static func pathExistsNoFollow(_ url: URL) -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var status = stat()
        return lstat(url.path, &status) == 0
        #else
        return false
        #endif
    }

    static func isDirectoryNoFollow(_ url: URL) -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return status.st_mode & S_IFMT == S_IFDIR
        #else
        return false
        #endif
    }

    static func isRegularFileNoFollow(_ url: URL) -> Bool {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return status.st_mode & S_IFMT == S_IFREG
        #else
        return false
        #endif
    }

    static func leadingSpaceCount(_ value: String) -> Int {
        value.prefix { $0 == " " || $0 == "\t" }.count
    }

    static func stripCarriageReturn(_ value: String) -> String {
        value.hasSuffix("\r")
            ? String(value.dropLast())
            : value
    }
}
