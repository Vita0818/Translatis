import Foundation
import IntatisCore
import IntatisMCP
import IntatisProtocol

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct MCPStdioSandboxPlan: Sendable {
    let wrapperExecutable: String
    let wrapperArguments: [String]
    let environment: [String: String]
    let workingDirectory: String
    let runtimeDirectory: URL
    let executionGuard: MCPStdioExecutionGuardPlan
    let networkGateway: MCPStdioExactNetworkGateway?
}

struct MCPStdioLinuxReadOnlyMask: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case file
        case directory
    }

    let targetPath: String
    let kind: Kind
}

enum MCPStdioSandboxCompiler {
    static let maximumLinuxWorkspaceEntries = 100_000

    static func compile(
        ticket: MCPAuthorizedStdioLaunchTicket
    ) throws -> MCPStdioSandboxPlan {
        let request = ticket.request
        let lease = try effectiveLease(request.workspaceLease)
        let workspace = try validatedWorkspace(lease)
        let workingDirectory = try validatedWorkingDirectory(
            request.configuration.workingDirectory,
            lease: lease,
            workspace: workspace)
        let runtime = try makeRuntimeDirectory()
        var networkGateway: MCPStdioExactNetworkGateway?
        do {
            let executionGuard =
                try MCPStdioExecutionGuard.compile(ticket: ticket)
            switch request.configuration.networkPolicy {
            case .denied:
                networkGateway = nil
            case .exactOrigins(let origins):
                networkGateway =
                    try MCPStdioExactNetworkGateway(origins: origins)
            }
            let environment = try minimalEnvironment(
                ticket: ticket,
                runtime: runtime,
                networkGateway: networkGateway)
            #if os(macOS)
            return try macOSPlan(
                ticket: ticket,
                lease: lease,
                workspace: workspace,
                workingDirectory: workingDirectory,
                runtime: runtime,
                environment: environment,
                executionGuard: executionGuard,
                networkGateway: networkGateway)
            #elseif os(Linux)
            return try linuxPlan(
                ticket: ticket,
                lease: lease,
                workspace: workspace,
                workingDirectory: workingDirectory,
                runtime: runtime,
                environment: environment,
                executionGuard: executionGuard,
                networkGateway: networkGateway)
            #else
            throw MCPManagedPipeError.localStdioUnsupported
            #endif
        } catch {
            networkGateway?.stop()
            try? FileManager.default.removeItem(at: runtime)
            throw error
        }
    }

    private static func effectiveLease(
        _ source: WorkspaceLease
    ) throws -> WorkspaceLease {
        guard let identity = source.rootIdentity,
              identity.matchesCurrentDirectory(rootPath: source.rootPath) else {
            throw MCPManagedPipeError.workspaceIdentityChanged
        }
        var lease = source
        var seen = Set(lease.deniedPatterns.map { $0.lowercased() })
        for pattern in WorkspaceLease.mandatoryTerminalDeniedPatterns {
            if seen.insert(pattern.lowercased()).inserted {
                lease.deniedPatterns.append(pattern)
            }
        }
        guard !lease.allowedPathRules.isEmpty else {
            throw MCPManagedPipeError.workspacePolicyUnsupported
        }
        return lease
    }

    private static func validatedWorkspace(
        _ lease: WorkspaceLease
    ) throws -> URL {
        let root = URL(fileURLWithPath: lease.rootPath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard root.path == lease.rootIdentity?.canonicalPath else {
            throw MCPManagedPipeError.workspaceIdentityChanged
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory),
            isDirectory.boolValue else {
            throw MCPManagedPipeError.workspaceUnavailable
        }
        return root
    }

    private static func validatedWorkingDirectory(
        _ configured: String?,
        lease: WorkspaceLease,
        workspace: URL
    ) throws -> URL {
        let candidate = URL(
            fileURLWithPath: configured ?? workspace.path,
            relativeTo: configured?.hasPrefix("/") == true ? nil : workspace)
            .resolvingSymlinksInPath().standardizedFileURL
        let root = workspace.path
        guard candidate.path == root
                || candidate.path.hasPrefix(root + "/"),
              pathAllowed(
                candidate.path,
                workspaceRoot: root,
                allowed: lease.allowedPathRules,
                denied: lease.deniedPatterns) else {
            throw MCPManagedPipeError.workingDirectoryOutsideLease
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory),
            isDirectory.boolValue else {
            throw MCPManagedPipeError.workingDirectoryUnavailable
        }
        return candidate
    }

    private static func pathAllowed(
        _ absolutePath: String,
        workspaceRoot: String,
        allowed: [PathRule],
        denied: [String]
    ) -> Bool {
        let relative: String
        if absolutePath == workspaceRoot {
            relative = "."
        } else {
            relative = String(absolutePath.dropFirst(workspaceRoot.count + 1))
        }
        let isAllowed = allowed.contains {
            globMatches(relative, pattern: $0.pattern, caseInsensitive: false)
        }
        let isDenied = denied.contains { pattern in
            globMatches(relative, pattern: pattern, caseInsensitive: true)
                || relative.split(separator: "/").contains { component in
                    globMatches(
                        String(component),
                        pattern: pattern,
                        caseInsensitive: true)
                }
        }
        return isAllowed && !isDenied
    }

    private static func globMatches(
        _ value: String,
        pattern rawPattern: String,
        caseInsensitive: Bool
    ) -> Bool {
        var pattern = rawPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while pattern.hasPrefix("./") { pattern.removeFirst(2) }
        if pattern == "." { return true }
        guard !pattern.isEmpty,
              !pattern.hasPrefix("/"),
              !pattern.split(separator: "/").contains("..") else {
            return false
        }
        let expression = globExpression(pattern)
        return value.range(
            of: "^\(expression)(/.*)?$",
            options: caseInsensitive
                ? [.regularExpression, .caseInsensitive]
                : [.regularExpression]) != nil
            || (pattern.contains("/") == false
                && value.range(
                    of: "(^|/)\(expression)(/|$)",
                    options: caseInsensitive
                        ? [.regularExpression, .caseInsensitive]
                        : [.regularExpression]) != nil)
    }

    private static func makeRuntimeDirectory() throws -> URL {
        let runtime = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                IntatisHostApplication.identity.temporaryPrefix(
                    "mcp-stdio-\(UUID().uuidString)"),
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        for name in ["home", "tmp"] {
            try FileManager.default.createDirectory(
                at: runtime.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        return runtime
    }

    private static func minimalEnvironment(
        ticket: MCPAuthorizedStdioLaunchTicket,
        runtime: URL,
        networkGateway: MCPStdioExactNetworkGateway?
    ) throws -> [String: String] {
        let home = runtime.appendingPathComponent("home", isDirectory: true)
        let temporary = runtime.appendingPathComponent("tmp", isDirectory: true)
        var result = [
            "HOME": home.path,
            "TMPDIR": temporary.path + "/",
            "XDG_CONFIG_HOME":
                home.appendingPathComponent(".config", isDirectory: true).path,
            "XDG_CACHE_HOME":
                home.appendingPathComponent(".cache", isDirectory: true).path,
            "PATH": "",
            "LANG": "C",
            "LC_ALL": "C",
            "USER": IntatisHostApplication.identity
                .temporaryPrefix("mcp"),
            "LOGNAME": IntatisHostApplication.identity
                .temporaryPrefix("mcp"),
            "NO_COLOR": "1",
            IntatisHostApplication.identity.environmentVariable(
                "MCP_SANDBOX"): "1",
        ]
        let proxyValue = networkGateway?.proxyURL ?? ""
        for name in [
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
            "http_proxy", "https_proxy", "all_proxy",
        ] {
            result[name] = proxyValue
        }
        // An empty bypass list is intentional. A child must not turn an
        // admitted origin into a direct connection by naming it in NO_PROXY.
        result["NO_PROXY"] = ""
        result["no_proxy"] = ""
        for (name, value) in ticket.authorization.resolvedEnvironment {
            guard !result.keys.contains(name),
                  validEnvironmentName(name),
                  !value.contains("\0") else {
                throw MCPManagedPipeError.resolvedEnvironmentMismatch
            }
            result[name] = value
        }
        return result
    }

    private static func validEnvironmentName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.letters
                .union(CharacterSet(charactersIn: "_"))
                .contains(first) else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "_"))
                .contains($0)
        }
    }

    #if os(macOS)
    private static func macOSPlan(
        ticket: MCPAuthorizedStdioLaunchTicket,
        lease: WorkspaceLease,
        workspace: URL,
        workingDirectory: URL,
        runtime: URL,
        environment: [String: String],
        executionGuard: MCPStdioExecutionGuardPlan,
        networkGateway: MCPStdioExactNetworkGateway?
    ) throws -> MCPStdioSandboxPlan {
        let sandboxExecutable = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(
            atPath: sandboxExecutable) else {
            throw MCPManagedPipeError.sandboxUnavailable
        }
        let profile = try macOSSandboxProfile(
            ticket: ticket,
            lease: lease,
            workspace: workspace,
            runtime: runtime,
            networkGateway: networkGateway)
        let target = ticket.request.configuration.executableCanonicalPath
        return MCPStdioSandboxPlan(
            wrapperExecutable: sandboxExecutable,
            wrapperArguments: ["-p", profile, target]
                + ticket.request.configuration.arguments,
            environment: environment,
            workingDirectory: workingDirectory.path,
            runtimeDirectory: runtime,
            executionGuard: executionGuard,
            networkGateway: networkGateway)
    }

    private static func macOSSandboxProfile(
        ticket: MCPAuthorizedStdioLaunchTicket,
        lease: WorkspaceLease,
        workspace: URL,
        runtime: URL,
        networkGateway: MCPStdioExactNetworkGateway?
    ) throws -> String {
        let launchFiles = ticket.request.configuration.launchArtifact.files
        guard let primaryExecutable = launchFiles.first(
            where: { $0.role == .executable }) else {
            throw MCPManagedPipeError.invalidLaunchArtifact
        }

        let systemReadPaths = [
            "/System",
            "/usr/lib",
            "/Library/Apple",
            "/Library/Frameworks",
            "/private/var/db/timezone",
            "/private/var/select",
            "/private/etc/ssl",
            "/private/etc/pki",
            "/dev/null",
            "/dev/random",
            "/dev/urandom",
        ].filter { FileManager.default.fileExists(atPath: $0) }
        let artifactPaths = launchFiles.map(\.canonicalPath)
        let readPaths = canonicalUnique(
            systemReadPaths + [workspace.path, runtime.path] + artifactPaths)
        let writePaths = lease.access == .readWrite
            ? canonicalUnique([workspace.path, runtime.path])
            : canonicalUnique([runtime.path])
        let readRules = readPaths.map {
            "(subpath \"\(seatbeltLiteral($0))\")"
        }.joined(separator: "\n        ")
        let metadataRules = readPaths.map {
            "(path-ancestors \"\(seatbeltLiteral($0))\")"
        }.joined(separator: "\n        ")
        let writeRules = writePaths.map {
            "(subpath \"\(seatbeltLiteral($0))\")"
        }.joined(separator: "\n        ")
        let initialExecRule =
            MCPStdioExecutionGuard.macOSInitialExecRule(
                wrapperPath: "/usr/bin/sandbox-exec",
                executablePath:
                    macOSCanonicalPath(primaryExecutable.canonicalPath))
        let immutableArtifactRules = canonicalUnique(artifactPaths)
            .map {
                "(deny file-write* (literal \"\(seatbeltLiteral($0))\"))"
            }
            .joined(separator: "\n")

        let root = macOSCanonicalPath(workspace.path)
        let allowsWholeWorkspace = lease.allowedPathRules.contains {
            $0.pattern.trimmingCharacters(in: .whitespacesAndNewlines) == "."
        }
        let outsideAllowRule: String
        if allowsWholeWorkspace {
            outsideAllowRule = ""
        } else {
            let allowRegexes = try lease.allowedPathRules.map {
                try seatbeltWorkspaceRegex(
                    pattern: $0.pattern,
                    workspaceRoot: root,
                    caseInsensitive: false)
            }
            let exclusions = allowRegexes.map {
                "(require-not (regex \"\(seatbeltLiteral($0))\"))"
            }.joined(separator: "\n          ")
            outsideAllowRule = """
            (deny file-read-data file-map-executable file-write*
              (require-all
                (subpath "\(seatbeltLiteral(root))")
                \(exclusions)))
            """
        }
        let deniedRules = try lease.deniedPatterns.map {
            try seatbeltWorkspaceRegex(
                pattern: $0,
                workspaceRoot: root,
                caseInsensitive: true)
        }.map {
            "(deny file-read-data file-map-executable file-write* (regex \"\(seatbeltLiteral($0))\"))"
        }.joined(separator: "\n")
        let readOnlyRule = lease.access == .readOnly
            ? "(deny file-write* (subpath \"\(seatbeltLiteral(root))\"))"
            : ""

        let networkRules: String
        switch ticket.request.configuration.networkPolicy {
        case .denied:
            networkRules = "(deny network*)"
        case .exactOrigins:
            guard let networkGateway else {
                throw MCPManagedPipeError.exactNetworkPolicyUnavailable
            }
            networkRules = exactSeatbeltGatewayRule(
                port: networkGateway.port)
        }

        return """
        (version 1)
        (deny default)
        (import "system.sb")
        \(initialExecRule)
        (allow signal (target same-sandbox))
        (allow process-info* (target same-sandbox))
        (allow file-read*
          \(readRules))
        (allow file-read-metadata file-test-existence
          \(metadataRules))
        (allow file-write*
          \(writeRules))
        \(outsideAllowRule)
        \(deniedRules)
        \(immutableArtifactRules)
        \(readOnlyRule)
        \(networkRules)
        """
    }

    static func exactSeatbeltGatewayRule(
        port: UInt16
    ) -> String {
        // The child receives an IP-literal proxy URL, so it needs no DNS
        // authority. Host/SNI stay end-to-end inside the CONNECT tunnel. The
        // explicit negative rule is required because `system.sb` is imported:
        // no imported allow may widen outbound authority beyond this tuple.
        """
        (deny network-inbound)
        (deny network-outbound
          (require-not
            (remote tcp "127.0.0.1:\(port)")))
        (allow network-outbound
          (remote tcp "127.0.0.1:\(port)"))
        """
    }
    #endif

    #if os(Linux)
    private static func linuxPlan(
        ticket: MCPAuthorizedStdioLaunchTicket,
        lease: WorkspaceLease,
        workspace: URL,
        workingDirectory: URL,
        runtime: URL,
        environment: [String: String],
        executionGuard: MCPStdioExecutionGuardPlan,
        networkGateway: MCPStdioExactNetworkGateway?
    ) throws -> MCPStdioSandboxPlan {
        let exactNetwork: Bool
        switch ticket.request.configuration.networkPolicy {
        case .denied:
            exactNetwork = false
        case .exactOrigins:
            guard networkGateway != nil else {
                throw MCPManagedPipeError.exactNetworkPolicyUnavailable
            }
            exactNetwork = true
        }
        let bwrap = try resolveLinuxBubblewrap()
        // A mutable tree could create a new denied name after the host scans
        // it, so Linux local MCP authority is deliberately exact read-only.
        // Existing denied leaves are additionally hidden by read-only bind
        // mounts after the workspace mount is installed.
        guard lease.access == .readOnly,
              lease.allowedPathRules.count == 1,
              lease.allowedPathRules[0].pattern == "." else {
            throw MCPManagedPipeError.workspacePolicyUnsupported
        }
        let masks = try linuxReadOnlyMasks(
            lease: lease,
            workspace: workspace)

        let launchFiles = ticket.request.configuration.launchArtifact.files
            + ticket.request.configuration.helperArtifacts.flatMap(\.files)
        let launchPaths = launchFiles.map(\.canonicalPath)
        guard masks.allSatisfy({ mask in
            !launchPaths.contains(where: { launchPath in
                launchPath == mask.targetPath
                    || launchPath.hasPrefix(mask.targetPath + "/")
            })
        }) else {
            throw MCPManagedPipeError.workspacePolicyUnsupported
        }
        let maskRoot = runtime.appendingPathComponent(
            "linux-denied-masks",
            isDirectory: true)
        let directoryMask = maskRoot.appendingPathComponent(
            "directory",
            isDirectory: true)
        let fileMask = maskRoot.appendingPathComponent(
            "file",
            isDirectory: false)
        try FileManager.default.createDirectory(
            at: directoryMask,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o500])
        guard FileManager.default.createFile(
            atPath: fileMask.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o400]) else {
            throw MCPManagedPipeError.workspacePolicyUnsupported
        }
        var arguments = [
            // The host already creates one exact process group. Do not pass
            // bwrap `--new-session`: that would deliberately create a second
            // group and weaken group-wide TERM/KILL ownership.
            "--die-with-parent", "--unshare-all",
        ]
        if exactNetwork {
            // The ptrace/seccomp guard admits only one exact TCP sockaddr:
            // this generation's loopback gateway. No wider direct socket is
            // possible even though bwrap shares the host network namespace.
            arguments.append("--share-net")
        } else {
            arguments.append("--unshare-net")
        }
        arguments.append(contentsOf: [
            "--proc", "/proc", "--dev", "/dev",
            "--tmpfs", "/tmp", "--seccomp", "3",
        ])
        var madeDirectories: Set<String> = ["/"]
        func addParents(_ path: String) {
            var current = URL(fileURLWithPath: path).deletingLastPathComponent()
            var pending: [String] = []
            while current.path != "/",
                  madeDirectories.contains(current.path) == false {
                pending.append(current.path)
                current.deleteLastPathComponent()
            }
            for parent in pending.reversed()
            where madeDirectories.insert(parent).inserted {
                arguments.append(contentsOf: ["--dir", parent])
            }
        }
        let libraryRoots = [
            "/usr/lib", "/lib", "/lib64", "/etc/ld.so.cache",
        ].filter { FileManager.default.fileExists(atPath: $0) }
        for path in canonicalUnique(libraryRoots + launchFiles.map(\.canonicalPath)) {
            addParents(path)
            arguments.append(contentsOf: ["--ro-bind", path, path])
        }
        addParents(workspace.path)
        arguments.append(contentsOf: ["--ro-bind", workspace.path, workspace.path])
        // Sensitive submounts must follow the workspace bind. The mask
        // sources themselves are never mounted at their host paths.
        for mask in masks {
            let source = mask.kind == .directory
                ? directoryMask.path : fileMask.path
            arguments.append(
                contentsOf: ["--ro-bind", source, mask.targetPath])
        }
        for writable in [
            runtime.appendingPathComponent("home", isDirectory: true),
            runtime.appendingPathComponent("tmp", isDirectory: true),
        ] {
            addParents(writable.path)
            arguments.append(
                contentsOf: ["--bind", writable.path, writable.path])
        }
        // The C launcher already execs bwrap with only this exact minimal
        // `environment`. Let bwrap pass it through. `--clearenv` + `--setenv`
        // would copy every secret (including the per-generation proxy
        // credential) into world-observable process argv.
        arguments.append(contentsOf: [
            "--chdir", workingDirectory.path, "--",
            ticket.request.configuration.executableCanonicalPath,
        ])
        arguments.append(contentsOf: ticket.request.configuration.arguments)
        guard lease.rootIdentity
                == WorkspaceRootIdentity.capture(
                    rootPath: workspace.path) else {
            throw MCPManagedPipeError.workspaceIdentityChanged
        }
        return MCPStdioSandboxPlan(
            wrapperExecutable: bwrap,
            wrapperArguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory.path,
            runtimeDirectory: runtime,
            executionGuard: executionGuard,
            networkGateway: networkGateway)
    }
    #endif

    static func resolveLinuxBubblewrap(
        candidates: [String] = [
            "/usr/bin/bwrap",
            "/bin/bwrap",
        ]
    ) throws -> String {
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw MCPManagedPipeError.sandboxUnavailable
        }
        return executable
    }

    /// Produces a no-follow, bounded and repeat-validated mask set. This helper
    /// is compiled on every platform so the security logic has host tests even
    /// when the bwrap integration test runs only on Linux.
    static func linuxReadOnlyMasks(
        lease: WorkspaceLease,
        workspace: URL,
        maximumEntries: Int = maximumLinuxWorkspaceEntries
    ) throws -> [MCPStdioLinuxReadOnlyMask] {
        guard lease.access == .readOnly,
              maximumEntries > 0,
              lease.allowedPathRules.count == 1,
              lease.allowedPathRules[0].pattern == ".",
              let expectedRoot = lease.rootIdentity,
              expectedRoot.matchesCurrentDirectory(
                rootPath: workspace.path) else {
            throw MCPManagedPipeError.workspacePolicyUnsupported
        }
        let normalizedDenied = Set(
            lease.deniedPatterns.map {
                $0.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                    .lowercased()
            })
        guard WorkspaceLease.mandatoryTerminalDeniedPatterns
            .allSatisfy({
                normalizedDenied.contains($0.lowercased())
            }) else {
            throw MCPManagedPipeError.workspacePolicyUnsupported
        }

        struct Observed {
            let path: String
            let relative: String
            let identity: MCPStdioNoFollowIdentity
        }
        var observed: [Observed] = []
        var masks: [MCPStdioLinuxReadOnlyMask] = []
        var traversalError = false
        guard let enumerator = FileManager.default.enumerator(
            at: workspace,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                traversalError = true
                return false
            })
        else {
            throw MCPManagedPipeError.workspacePolicyUnsupported
        }
        while let item = enumerator.nextObject() as? URL {
            guard observed.count < maximumEntries else {
                throw MCPManagedPipeError.workspacePolicyUnsupported
            }
            let path = item.standardizedFileURL.path
            let root = workspace.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else {
                throw MCPManagedPipeError.workspacePolicyUnsupported
            }
            let relative = String(path.dropFirst(root.count + 1))
            let identity = try noFollowIdentity(path)
            observed.append(Observed(
                path: path,
                relative: relative,
                identity: identity))

            let denied = lease.deniedPatterns.contains { pattern in
                globMatches(
                    relative,
                    pattern: pattern,
                    caseInsensitive: true)
                    || relative.split(separator: "/").contains { component in
                        globMatches(
                            String(component),
                            pattern: pattern,
                            caseInsensitive: true)
                    }
            }
            // No symlink or special-file target is trusted in the launch
            // tree. A regular file with another hard link could make a mask
            // alias-sensitive, so it is rejected as well.
            switch identity.kind {
            case .symbolicLink, .special:
                throw MCPManagedPipeError.workspacePolicyUnsupported
            case .regularFile where identity.linkCount != 1:
                throw MCPManagedPipeError.workspacePolicyUnsupported
            case .directory:
                if denied {
                    masks.append(.init(
                        targetPath: path,
                        kind: .directory))
                    enumerator.skipDescendants()
                }
            case .regularFile:
                if denied {
                    masks.append(.init(
                        targetPath: path,
                        kind: .file))
                }
            }
        }
        guard !traversalError,
              expectedRoot.matchesCurrentDirectory(
                rootPath: workspace.path) else {
            throw MCPManagedPipeError.workspaceIdentityChanged
        }
        for entry in observed {
            guard try noFollowIdentity(entry.path)
                    == entry.identity else {
                throw MCPManagedPipeError.workspaceIdentityChanged
            }
        }
        return masks.sorted {
            let lhsDepth = $0.targetPath.split(separator: "/").count
            let rhsDepth = $1.targetPath.split(separator: "/").count
            if lhsDepth != rhsDepth {
                return lhsDepth < rhsDepth
            }
            return $0.targetPath < $1.targetPath
        }
    }

    private enum MCPStdioNoFollowKind: Equatable {
        case regularFile
        case directory
        case symbolicLink
        case special
    }

    private struct MCPStdioNoFollowIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let linkCount: UInt64
        let kind: MCPStdioNoFollowKind
    }

    private static func noFollowIdentity(
        _ path: String
    ) throws -> MCPStdioNoFollowIdentity {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw MCPManagedPipeError.workspaceIdentityChanged
        }
        let mode = mode_t(status.st_mode)
        let fileType = mode & mode_t(S_IFMT)
        let kind: MCPStdioNoFollowKind
        switch fileType {
        case mode_t(S_IFREG):
            kind = .regularFile
        case mode_t(S_IFDIR):
            kind = .directory
        case mode_t(S_IFLNK):
            kind = .symbolicLink
        default:
            kind = .special
        }
        return MCPStdioNoFollowIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt32(status.st_mode),
            linkCount: UInt64(status.st_nlink),
            kind: kind)
    }

    private static func canonicalUnique(_ values: [String]) -> [String] {
        Array(Set(values.map {
            let canonical = URL(fileURLWithPath: $0)
                .resolvingSymlinksInPath().standardizedFileURL.path
            #if os(macOS)
            return macOSCanonicalPath(canonical)
            #else
            return canonical
            #endif
        })).sorted()
    }

    private static func seatbeltWorkspaceRegex(
        pattern rawPattern: String,
        workspaceRoot: String,
        caseInsensitive: Bool
    ) throws -> String {
        var pattern = rawPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while pattern.hasPrefix("./") { pattern.removeFirst(2) }
        guard !pattern.isEmpty,
              !pattern.hasPrefix("/"),
              !pattern.split(separator: "/").contains("..") else {
            throw MCPManagedPipeError.workspacePolicyUnsupported
        }
        if pattern == "." {
            return "^\(NSRegularExpression.escapedPattern(for: workspaceRoot))(/.*)?$"
        }
        let root = NSRegularExpression.escapedPattern(for: workspaceRoot)
        var expression = globExpression(pattern)
        if caseInsensitive {
            expression = asciiCaseInsensitive(expression)
        }
        if pattern.contains("/") {
            return "^\(root)/\(expression)(/.*)?$"
        }
        return "^\(root)(/[^/]*)*/\(expression)(/.*)?$"
    }

    private static func globExpression(_ pattern: String) -> String {
        var result = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterDouble = pattern.index(after: next)
                    if afterDouble < pattern.endIndex,
                       pattern[afterDouble] == "/" {
                        // `**/name` includes `name` at the workspace root as
                        // well as at any descendant depth.
                        result += "(.*/)?"
                        index = pattern.index(after: afterDouble)
                    } else {
                        result += ".*"
                        index = afterDouble
                    }
                } else {
                    result += "[^/]*"
                    index = next
                }
            } else if character == "?" {
                result += "[^/]"
                index = pattern.index(after: index)
            } else {
                result += NSRegularExpression.escapedPattern(
                    for: String(character))
                index = pattern.index(after: index)
            }
        }
        return result
    }

    private static func asciiCaseInsensitive(_ expression: String) -> String {
        var output = ""
        for scalar in expression.unicodeScalars {
            let value = scalar.value
            if (65...90).contains(value) || (97...122).contains(value) {
                let character = Character(String(scalar))
                output += "[\(String(character).lowercased())\(String(character).uppercased())]"
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    private static func seatbeltLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func macOSCanonicalPath(_ value: String) -> String {
        #if os(macOS)
        for alias in ["/var", "/tmp", "/etc"]
        where value == alias || value.hasPrefix(alias + "/") {
            return "/private" + value
        }
        #endif
        return value
    }
}

private extension Array where Element == String {
    func uniqueSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}
