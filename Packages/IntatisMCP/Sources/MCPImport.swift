#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCP requires CryptoKit or swift-crypto")
#endif
import CoreFoundation
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

public enum MCPImportFormat: String, Codable, Equatable, Hashable, Sendable {
    case mcpJSON = "mcp-json"
    case claudeJSON = "claude-json"

    var sourceKind: MCPConfigurationSourceKind {
        switch self {
        case .mcpJSON: return .importedMCPJSON
        case .claudeJSON: return .importedClaudeJSON
        }
    }
}

public enum MCPImportIssueCode: String, Codable, Equatable, Hashable, Sendable {
    case unknownField = "unknown_field"
    case invalidField = "invalid_field"
    case missingField = "missing_field"
    case unsupportedTransport = "unsupported_transport"
    case unsupportedPrivateSemantics = "unsupported_private_semantics"
    case contributorSecretMaterial = "contributor_secret_material"
    case aliasConflict = "alias_conflict"
    case serverIDConflict = "server_id_conflict"
}

/// Preview issue contains a JSON path and stable reason code only. It never
/// echoes an unknown value that might contain a credential.
public struct MCPImportIssue: Codable, Equatable, Hashable, Sendable {
    public let code: MCPImportIssueCode
    public let path: String
    public let blocking: Bool

    public init(code: MCPImportIssueCode, path: String, blocking: Bool = true) {
        self.code = code
        self.path = path
        self.blocking = blocking
    }
}

public enum MCPImportedSecretKind: String, Codable, Equatable, Hashable, Sendable {
    case environmentValue = "environment_value"
    case headerValue = "header_value"
    case bearerToken = "bearer_token"
    case oauthClientSecret = "oauth_client_secret"
}

public struct MCPImportedSecretDescriptor: Codable, Equatable, Hashable, Sendable {
    public let stagingID: String
    public let fieldPath: String
    public let fieldName: String
    public let kind: MCPImportedSecretKind
    public let sourceFingerprint: String

    fileprivate init(
        stagingID: String,
        fieldPath: String,
        fieldName: String,
        kind: MCPImportedSecretKind,
        sourceFingerprint: String
    ) {
        self.stagingID = stagingID
        self.fieldPath = fieldPath
        self.fieldName = fieldName
        self.kind = kind
        self.sourceFingerprint = sourceFingerprint
    }
}

/// Host-provided secure backend used to migrate inline imported material.
/// Implementations must write to macOS Keychain or the CLI encrypted store and
/// return only an opaque reference. There is intentionally no plaintext-file
/// implementation in IntatisMCP.
public protocol MCPImportSecretSink: Sendable {
    func storeImportedSecret(
        _ secret: Data,
        descriptor: MCPImportedSecretDescriptor
    ) async throws -> MCPSecretReference
}

/// In-memory holding area for explicitly selected import bytes. Values cannot
/// be encoded, logged, exported, or read individually. They are only handed to
/// a secure sink, and `discard()` overwrites the retained buffers.
public actor MCPImportSecretStaging {
    private var values: [String: Data]
    public nonisolated let descriptors: [MCPImportedSecretDescriptor]

    fileprivate init(
        values: [String: Data],
        descriptors: [MCPImportedSecretDescriptor]
    ) {
        self.values = values
        self.descriptors = descriptors.sorted { $0.stagingID < $1.stagingID }
    }

    public func migrate(
        to sink: any MCPImportSecretSink
    ) async throws -> [String: MCPSecretReference] {
        var references: [String: MCPSecretReference] = [:]
        for descriptor in descriptors {
            guard let value = values[descriptor.stagingID] else {
                throw MCPImportError.secretStagingUnavailable
            }
            let reference = try await sink.storeImportedSecret(
                value,
                descriptor: descriptor)
            guard reference.sourceBindingFingerprint
                    == descriptor.sourceFingerprint else {
                throw MCPImportError.secretReferenceNotSourceBound
            }
            references[descriptor.stagingID] = reference
        }
        return references
    }

    public func discard() {
        for key in values.keys {
            guard var bytes = values[key] else { continue }
            bytes.resetBytes(in: 0..<bytes.count)
            values[key] = bytes
        }
        values.removeAll(keepingCapacity: false)
    }

    public var isAvailable: Bool { !values.isEmpty || descriptors.isEmpty }
}

public enum MCPImportedValue: Equatable, Hashable, Sendable {
    case literal(String)
    case reference(MCPSecretReference)
    case pendingSecret(String)

    fileprivate func resolved(
        from references: [String: MCPSecretReference],
        fieldName: String
    ) throws -> MCPConfiguredValue {
        switch self {
        case .literal(let value):
            return try MCPConfiguredValue.literal(value).validated(
                fieldName: fieldName)
        case .reference(let reference):
            return .secret(reference)
        case .pendingSecret(let stagingID):
            guard let reference = references[stagingID] else {
                throw MCPImportError.secretMigrationRequired
            }
            return .secret(reference)
        }
    }
}

public struct MCPImportedStdioProposal: Equatable, Hashable, Sendable {
    public let command: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let environment: [String: MCPImportedValue]
    public let inheritedEnvironmentReferences: [String: MCPSecretReference]
}

public struct MCPImportedHTTPProposal: Equatable, Hashable, Sendable {
    public let endpoint: String
    public let headers: [String: MCPImportedValue]
    public let bearerToken: MCPImportedValue?
}

public enum MCPImportedTransportProposal: Equatable, Hashable, Sendable {
    case stdio(MCPImportedStdioProposal)
    case streamableHTTP(MCPImportedHTTPProposal)
}

/// Fixed-format, secret-safe proposal. It is not executable or saveable until
/// artifact/secret resolution, staging validation, isolated Test, and explicit
/// catalog confirmation all complete.
public struct MCPImportedServerProposal: Equatable, Hashable, Sendable {
    public let proposalID: String
    public let alias: String
    public let serverID: MCPServerID
    public let displayName: String
    public let enabled: Bool
    public let required: Bool
    public let approvalPolicy: MCPApprovalPolicy
    public let parallelCalls: Bool
    public let timeouts: MCPServerTimeouts
    public let filters: MCPServerFilters
    public let transport: MCPImportedTransportProposal
    public let provenance: MCPConfigurationProvenance

    fileprivate func replacingIdentity(
        alias: String,
        serverID: MCPServerID
    ) -> MCPImportedServerProposal {
        MCPImportedServerProposal(
            proposalID: proposalID,
            alias: alias,
            serverID: serverID,
            displayName: displayName,
            enabled: enabled,
            required: required,
            approvalPolicy: approvalPolicy,
            parallelCalls: parallelCalls,
            timeouts: timeouts,
            filters: filters,
            transport: transport,
            provenance: provenance)
    }

    public func makeConfiguration(
        resolution: MCPImportedServerResolution
    ) throws -> MCPServerConfiguration {
        let transportConfiguration: MCPTransportConfiguration
        switch transport {
        case .stdio(let proposal):
            guard let artifact = resolution.launchArtifact else {
                throw MCPImportError.launchArtifactTestRequired
            }
            let executable = artifact.files.first { $0.role == .executable }
            guard let executable else {
                throw MCPImportError.launchArtifactTestRequired
            }
            if proposal.command.hasPrefix("/") {
                guard executable.canonicalPath == proposal.command else {
                    throw MCPImportError.launchArtifactMismatch
                }
            } else {
                guard URL(fileURLWithPath: executable.canonicalPath)
                    .lastPathComponent == proposal.command else {
                    throw MCPImportError.launchArtifactMismatch
                }
            }
            let environment = try proposal.environment.mapValuesWithKeys {
                name, value in
                try value.resolved(
                    from: resolution.secretReferences,
                    fieldName: name)
            }
            transportConfiguration = .stdio(try MCPStdioServerConfiguration(
                launchArtifact: artifact,
                arguments: proposal.arguments,
                workingDirectory: proposal.workingDirectory,
                environment: environment,
                inheritedEnvironmentReferences:
                    proposal.inheritedEnvironmentReferences,
                helperArtifacts: [],
                networkPolicy: .denied))
        case .streamableHTTP(let proposal):
            let headers = try proposal.headers.mapValuesWithKeys {
                name, value in
                try value.resolved(
                    from: resolution.secretReferences,
                    fieldName: name)
            }
            let bearer: MCPSecretReference?
            if let value = proposal.bearerToken {
                guard case .secret(let reference) = try value.resolved(
                    from: resolution.secretReferences,
                    fieldName: "bearer_token") else {
                    throw MCPImportError.secretMigrationRequired
                }
                bearer = reference
            } else {
                bearer = nil
            }
            transportConfiguration = .streamableHTTP(
                try MCPHTTPServerConfiguration(
                    endpoint: proposal.endpoint,
                    allowInsecureLoopbackDevelopmentHTTP:
                        resolution
                            .allowInsecureLoopbackDevelopmentHTTP,
                    headers: headers,
                    bearerTokenReference: bearer))
        }

        return try MCPServerConfiguration(
            serverID: serverID,
            displayName: displayName,
            enabled: enabled,
            required: required,
            requiredCapabilities: [],
            protocolProfile: resolution.protocolProfile,
            maximumProtocolVersion: resolution.maximumProtocolVersion,
            approvalPolicy: approvalPolicy,
            parallelCalls: parallelCalls,
            timeouts: timeouts,
            filters: filters,
            transport: transportConfiguration,
            environmentReference: resolution.environmentReference,
            provenance: provenance)
    }
}

public struct MCPImportedServerResolution: Sendable {
    public let launchArtifact: LaunchArtifactIdentity?
    public let secretReferences: [String: MCPSecretReference]
    public let environmentReference: MCPEnvironmentReference
    public let protocolProfile: MCPProtocolProfile
    public let maximumProtocolVersion: MCPProtocolVersion?
    /// Explicit user/CLI confirmation for a development-only plaintext
    /// loopback endpoint. Imported source files never enable this implicitly.
    public let allowInsecureLoopbackDevelopmentHTTP: Bool

    public init(
        launchArtifact: LaunchArtifactIdentity? = nil,
        secretReferences: [String: MCPSecretReference] = [:],
        environmentReference: MCPEnvironmentReference,
        protocolProfile: MCPProtocolProfile = .codexCompat,
        maximumProtocolVersion: MCPProtocolVersion? = nil,
        allowInsecureLoopbackDevelopmentHTTP: Bool = false
    ) {
        self.launchArtifact = launchArtifact
        self.secretReferences = secretReferences
        self.environmentReference = environmentReference
        self.protocolProfile = protocolProfile
        self.maximumProtocolVersion = maximumProtocolVersion
        self.allowInsecureLoopbackDevelopmentHTTP =
            allowInsecureLoopbackDevelopmentHTTP
    }
}

public struct MCPImportPreview: Sendable {
    public let format: MCPImportFormat
    public let parserVersion: Int
    public let sourceLabel: String
    public let sourceFingerprint: String
    public let proposals: [MCPImportedServerProposal]
    public let issues: [MCPImportIssue]
    public let secretDescriptors: [MCPImportedSecretDescriptor]

    public var canProceedToResolution: Bool {
        !proposals.isEmpty && !issues.contains(where: \.blocking)
    }

    public func importMarker() throws -> MCPImportMarker {
        try MCPImportMarker(
            sourceKind: format.sourceKind,
            sourceFingerprint: sourceFingerprint,
            formatVersion: parserVersion,
            importedServerIDs: proposals.map(\.serverID))
    }
}

public struct MCPImportParseResult: Sendable {
    public let preview: MCPImportPreview
    public let secretStaging: MCPImportSecretStaging
}

public enum MCPImportConflictDecision: Equatable, Hashable, Sendable {
    case rename(String)
    case replaceExisting(MCPServerID)
    case skip
}

public struct MCPImportConflict: Equatable, Hashable, Sendable {
    public let proposalID: String
    public let alias: String
    public let proposedServerID: MCPServerID
    public let existingServerID: MCPServerID
}

/// Conflict planning never overwrites an alias implicitly.
public enum MCPImportPlanner {
    public static func plan(
        preview: MCPImportPreview,
        catalog: MCPServerCatalog
    ) throws -> MCPPlannedImport {
        guard preview.canProceedToResolution else {
            throw MCPImportError.previewHasBlockingIssues
        }
        var clean: [MCPImportedServerProposal] = []
        var conflicts: [MCPImportConflict] = []
        for proposal in preview.proposals {
            if let existing = catalog.head(alias: proposal.alias),
               existing.serverID != proposal.serverID {
                conflicts.append(MCPImportConflict(
                    proposalID: proposal.proposalID,
                    alias: proposal.alias,
                    proposedServerID: proposal.serverID,
                    existingServerID: existing.serverID))
            } else {
                clean.append(proposal)
            }
        }
        return MCPPlannedImport(
            proposalsWithoutConflicts: clean,
            conflicts: conflicts,
            conflictingProposals: Dictionary(
                uniqueKeysWithValues: preview.proposals.map {
                    ($0.proposalID, $0)
                }))
    }

}

/// Self-contained conflict plan; decisions cannot accidentally resolve against
/// proposals from another import.
public struct MCPPlannedImport: Sendable {
    public let proposalsWithoutConflicts: [MCPImportedServerProposal]
    public let conflicts: [MCPImportConflict]
    private let conflictingProposals: [String: MCPImportedServerProposal]

    fileprivate init(
        proposalsWithoutConflicts: [MCPImportedServerProposal],
        conflicts: [MCPImportConflict],
        conflictingProposals: [String: MCPImportedServerProposal]
    ) {
        self.proposalsWithoutConflicts = proposalsWithoutConflicts
        self.conflicts = conflicts
        self.conflictingProposals = conflictingProposals
    }

    public func resolving(
        _ decisions: [String: MCPImportConflictDecision],
        catalog: MCPServerCatalog
    ) throws -> [MCPImportedServerProposal] {
        guard Set(decisions.keys) == Set(conflicts.map(\.proposalID)) else {
            throw MCPImportError.unresolvedConflict
        }
        var result = proposalsWithoutConflicts
        var usedAliases = Set(catalog.heads.map(\.alias))
        for conflict in conflicts {
            guard let decision = decisions[conflict.proposalID],
                  let original = conflictingProposals[conflict.proposalID] else {
                throw MCPImportError.unresolvedConflict
            }
            switch decision {
            case .skip:
                continue
            case .rename(let alias):
                try MCPConfigurationValidation.validateIdentifier(
                    alias,
                    field: "alias")
                guard !usedAliases.contains(alias) else {
                    throw MCPImportError.unresolvedConflict
                }
                usedAliases.insert(alias)
                result.append(original.replacingIdentity(
                    alias: alias,
                    serverID: original.serverID))
            case .replaceExisting(let serverID):
                guard serverID == conflict.existingServerID,
                      let head = catalog.head(for: serverID),
                      head.alias == conflict.alias else {
                    throw MCPImportError.unresolvedConflict
                }
                result.append(original.replacingIdentity(
                    alias: head.alias,
                    serverID: serverID))
            }
        }
        return result
    }
}

public enum MCPImportError: Error, LocalizedError, Equatable, Sendable {
    case sourceTooLarge
    case unsafeSource
    case sourceChangedDuringRead
    case malformedJSON
    case invalidRoot
    case previewHasBlockingIssues
    case secretStagingUnavailable
    case secretMigrationRequired
    case secretReferenceNotSourceBound
    case launchArtifactTestRequired
    case launchArtifactMismatch
    case unresolvedConflict
    case exportFailed

    public var errorDescription: String? {
        switch self {
        case .sourceTooLarge: return "The selected MCP import source is too large."
        case .unsafeSource: return "The selected MCP import source is not a safe regular file."
        case .sourceChangedDuringRead: return "The selected MCP import source changed while being read."
        case .malformedJSON: return "The selected MCP import source is not valid JSON."
        case .invalidRoot: return "The selected MCP import source has an invalid root object."
        case .previewHasBlockingIssues: return "The MCP import preview contains unresolved blocking issues."
        case .secretStagingUnavailable: return "The MCP import secret staging area is unavailable."
        case .secretMigrationRequired: return "Imported secret material must be migrated to a secure store."
        case .secretReferenceNotSourceBound: return "The secure secret reference is not bound to this import source."
        case .launchArtifactTestRequired: return "The imported command must be resolved and tested as an exact launch artifact."
        case .launchArtifactMismatch: return "The tested launch artifact does not match the imported command."
        case .unresolvedConflict: return "Every MCP import conflict requires an explicit decision."
        case .exportFailed: return "The MCP catalog could not be exported safely."
        }
    }
}

// MARK: - Fixed parsers

public enum MCPConfigurationImporter {
    public static let parserVersion = 1
    public static let maximumSourceBytes = 4 * 1024 * 1024

    public static func parse(
        data: Data,
        format: MCPImportFormat,
        sourceLabel: String
    ) throws -> MCPImportParseResult {
        guard data.count <= maximumSourceBytes else {
            throw MCPImportError.sourceTooLarge
        }
        let safeLabel = (sourceLabel as NSString).lastPathComponent
        guard safeLabel == sourceLabel, !safeLabel.isEmpty,
              safeLabel.utf8.count <= 256 else {
            throw MCPImportError.unsafeSource
        }
        let fingerprint = MCPConfigurationCanonical.sha256(data)
        let object: [String: Any]
        do {
            guard let root = try JSONSerialization.jsonObject(
                with: data,
                options: []) as? [String: Any] else {
                throw MCPImportError.invalidRoot
            }
            object = root
        } catch let error as MCPImportError {
            throw error
        } catch {
            throw MCPImportError.malformedJSON
        }

        var state = ImportParserState(
            format: format,
            sourceLabel: safeLabel,
            sourceFingerprint: fingerprint)
        state.parseRoot(object)
        let preview = MCPImportPreview(
            format: format,
            parserVersion: parserVersion,
            sourceLabel: safeLabel,
            sourceFingerprint: fingerprint,
            proposals: state.proposals,
            issues: state.issues,
            secretDescriptors: state.secretDescriptors)
        return MCPImportParseResult(
            preview: preview,
            secretStaging: MCPImportSecretStaging(
                values: state.secretValues,
                descriptors: state.secretDescriptors))
    }

    /// UI/CLI naming convenience: previewing and parsing are intentionally the
    /// same read-only operation and neither can save or launch.
    public static func preview(
        data: Data,
        format: MCPImportFormat,
        sourceLabel: String
    ) throws -> MCPImportParseResult {
        try parse(data: data, format: format, sourceLabel: sourceLabel)
    }

    /// Reads only a user-selected file through O_NOFOLLOW. No discovery,
    /// credential lookup, process launch, network request, or source write is
    /// performed.
    public static func parseExplicitFile(
        at url: URL,
        format: MCPImportFormat
    ) throws -> MCPImportParseResult {
        let data = try readExplicitSource(at: url)
        return try parse(
            data: data,
            format: format,
            sourceLabel: url.lastPathComponent)
    }

    private static func readExplicitSource(at url: URL) throws -> Data {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MCPImportError.unsafeSource }
        defer { _ = close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              before.st_size <= maximumSourceBytes else {
            throw before.st_size > maximumSourceBytes
                ? MCPImportError.sourceTooLarge
                : MCPImportError.unsafeSource
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
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
                throw MCPImportError.unsafeSource
            }
            guard data.count + count <= maximumSourceBytes else {
                throw MCPImportError.sourceTooLarge
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw MCPImportError.sourceChangedDuringRead
        }
        #if canImport(Darwin)
        let modificationTimeUnchanged =
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        #else
        let modificationTimeUnchanged =
            before.st_mtim.tv_sec == after.st_mtim.tv_sec
                && before.st_mtim.tv_nsec == after.st_mtim.tv_nsec
        #endif
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              modificationTimeUnchanged else {
            throw MCPImportError.sourceChangedDuringRead
        }
        return data
        #else
        throw MCPImportError.unsafeSource
        #endif
    }
}

private struct ImportParserState {
    let format: MCPImportFormat
    let sourceLabel: String
    let sourceFingerprint: String
    var proposals: [MCPImportedServerProposal] = []
    var issues: [MCPImportIssue] = []
    var secretDescriptors: [MCPImportedSecretDescriptor] = []
    var secretValues: [String: Data] = [:]

    mutating func parseRoot(_ root: [String: Any]) {
        let allowed: Set<String> = ["$schema", "version", "mcpServers"]
        reportUnknown(keys: root.keys, allowed: allowed, path: "$")
        guard let servers = root["mcpServers"] as? [String: Any] else {
            issues.append(.init(code: .missingField, path: "$.mcpServers"))
            return
        }
        if let version = root["version"], !(version is String) && !(version is NSNumber) {
            issues.append(.init(code: .invalidField, path: "$.version"))
        }
        for alias in servers.keys.sorted() {
            let path = "$.mcpServers.\(alias)"
            guard let raw = servers[alias] as? [String: Any] else {
                issues.append(.init(code: .invalidField, path: path))
                continue
            }
            parseServer(alias: alias, raw: raw, path: path)
        }
        if proposals.isEmpty {
            issues.append(.init(code: .missingField, path: "$.mcpServers.*"))
        }
    }

    mutating func parseServer(
        alias: String,
        raw: [String: Any],
        path: String
    ) {
        let allowed: Set<String> = [
            "type", "transport", "command", "args", "env", "env_vars", "cwd",
            "url", "headers", "bearer_token", "timeout", "startup_timeout",
            "call_timeout", "shutdown_timeout", "disabled", "required",
            "parallel", "approval_mode", "tool_approval_modes", "tools",
            "resources", "prompts", "completions",
        ]
        let forbiddenPrivate: Set<String> = [
            "auth", "plugin", "privatePlugin", "selectedPlugin", "hostedApp",
            "hostedApps", "form", "knowledge", "rag",
        ]
        for key in raw.keys where forbiddenPrivate.contains(key) {
            issues.append(.init(
                code: .unsupportedPrivateSemantics,
                path: "\(path).\(key)"))
        }
        reportUnknown(
            keys: raw.keys.filter { !forbiddenPrivate.contains($0) },
            allowed: allowed,
            path: path)
        do {
            try MCPConfigurationValidation.validateIdentifier(alias, field: "alias")
        } catch {
            issues.append(.init(code: .invalidField, path: path))
            return
        }

        let proposalSeed = Data("\(sourceFingerprint)\u{1f}\(alias)".utf8)
        let proposalDigest = MCPConfigurationCanonical.sha256(proposalSeed)
        let serverID = MCPServerID(
            rawValue: "mcpimport_\(proposalDigest.prefix(24))")
        let proposalID = "mcpproposal_\(proposalDigest.prefix(32))"
        do {
            let approval = try parseApproval(raw, path: path)
            let filters = try parseFilters(raw, path: path)
            let timeouts = try parseTimeouts(raw, path: path)
            let transport = try parseTransport(raw, path: path)
            let enabled = !(try bool(raw["disabled"], default: false,
                                     path: "\(path).disabled"))
            let required = try bool(
                raw["required"], default: false, path: "\(path).required")
            let parallel = try bool(
                raw["parallel"], default: false, path: "\(path).parallel")
            let provenance = try MCPConfigurationProvenance(
                sourceKind: format.sourceKind,
                sourceLabel: sourceLabel,
                formatVersion: MCPConfigurationImporter.parserVersion,
                sourceFingerprint: sourceFingerprint)
            proposals.append(MCPImportedServerProposal(
                proposalID: proposalID,
                alias: alias,
                serverID: serverID,
                displayName: alias,
                enabled: enabled,
                required: required,
                approvalPolicy: approval,
                parallelCalls: parallel,
                timeouts: timeouts,
                filters: filters,
                transport: transport,
                provenance: provenance))
        } catch let issue as ParserIssue {
            issues.append(issue.issue)
        } catch {
            issues.append(.init(code: .invalidField, path: path))
        }
    }

    mutating func parseTransport(
        _ raw: [String: Any],
        path: String
    ) throws -> MCPImportedTransportProposal {
        let explicitType = (raw["type"] as? String)
            ?? (raw["transport"] as? String)
        if let explicitType,
           ["sse", "legacy-sse", "legacy_sse"].contains(explicitType.lowercased()) {
            throw ParserIssue(.init(
                code: .unsupportedTransport,
                path: "\(path).type"))
        }
        let hasCommand = raw["command"] != nil
        let hasURL = raw["url"] != nil
        guard hasCommand != hasURL else {
            throw ParserIssue(.init(code: .invalidField, path: path))
        }
        if hasCommand {
            if let explicitType,
               !["stdio"].contains(explicitType.lowercased()) {
                throw ParserIssue(.init(
                    code: .unsupportedTransport,
                    path: "\(path).type"))
            }
            guard let command = raw["command"] as? String,
                  !command.isEmpty, command.utf8.count <= 8 * 1024,
                  !command.contains("\0") else {
                throw ParserIssue(.init(
                    code: .invalidField,
                    path: "\(path).command"))
            }
            let arguments = try stringArray(
                raw["args"], default: [], path: "\(path).args")
            let cwd: String?
            if let value = raw["cwd"] {
                guard let string = value as? String else {
                    throw ParserIssue(.init(
                        code: .invalidField,
                        path: "\(path).cwd"))
                }
                cwd = try MCPConfigurationValidation.canonicalAbsolutePath(string)
            } else {
                cwd = nil
            }
            let environment = try parseValueMap(
                raw["env"],
                path: "\(path).env",
                kind: .environmentValue)
            var inherited: [String: MCPSecretReference] = [:]
            let names = try stringArray(
                raw["env_vars"],
                default: [],
                path: "\(path).env_vars")
            for name in names {
                try MCPConfigurationValidation.validateEnvironmentName(name)
                inherited[name] = try MCPSecretReference(
                    storageClass: .environment,
                    identifier: name,
                    sourceBindingFingerprint: sourceFingerprint)
            }
            return .stdio(MCPImportedStdioProposal(
                command: command,
                arguments: arguments,
                workingDirectory: cwd,
                environment: environment,
                inheritedEnvironmentReferences: inherited))
        }

        if let explicitType,
           !["http", "streamable-http", "streamable_http"].contains(
               explicitType.lowercased()) {
            throw ParserIssue(.init(
                code: .unsupportedTransport,
                path: "\(path).type"))
        }
        guard let url = raw["url"] as? String else {
            throw ParserIssue(.init(code: .invalidField, path: "\(path).url"))
        }
        let endpoint: String
        if URLComponents(string: url)?
                .scheme?.lowercased() == "http" {
            // Preserve only an exact loopback HTTP proposal so the review
            // surface can ask for the explicit development exception. This
            // does not authorize or save it; resolution remains default-deny.
            endpoint = try MCPConfigurationValidation
                .canonicalHTTPURL(
                    url,
                    allowPath: true,
                    allowInsecureLoopbackDevelopmentHTTP: true)
        } else {
            endpoint = try MCPConfigurationValidation
                .canonicalHTTPSURL(
                    url,
                    allowPath: true)
        }
        let headers = try parseValueMap(
            raw["headers"],
            path: "\(path).headers",
            kind: .headerValue)
        let bearer: MCPImportedValue?
        if let value = raw["bearer_token"] {
            bearer = try parseImportedValue(
                value,
                fieldPath: "\(path).bearer_token",
                fieldName: "bearer_token",
                kind: .bearerToken)
        } else {
            bearer = nil
        }
        return .streamableHTTP(MCPImportedHTTPProposal(
            endpoint: endpoint,
            headers: headers,
            bearerToken: bearer))
    }

    mutating func parseValueMap(
        _ value: Any?,
        path: String,
        kind: MCPImportedSecretKind
    ) throws -> [String: MCPImportedValue] {
        guard let value else { return [:] }
        guard let object = value as? [String: Any],
              object.count <= MCPConfigurationLimits.maximumEnvironmentEntries else {
            throw ParserIssue(.init(code: .invalidField, path: path))
        }
        var result: [String: MCPImportedValue] = [:]
        for key in object.keys.sorted() {
            if kind == .environmentValue {
                try MCPConfigurationValidation.validateEnvironmentName(key)
            } else {
                try MCPConfigurationValidation.validateHeaderName(key)
            }
            guard let rawValue = object[key] else {
                throw ParserIssue(.init(
                    code: .invalidField,
                    path: "\(path).\(key)"))
            }
            result[key] = try parseImportedValue(
                rawValue,
                fieldPath: "\(path).\(key)",
                fieldName: key,
                kind: kind)
        }
        return result
    }

    mutating func parseImportedValue(
        _ rawValue: Any,
        fieldPath: String,
        fieldName: String,
        kind: MCPImportedSecretKind
    ) throws -> MCPImportedValue {
        if let object = rawValue as? [String: Any] {
            let currentReferenceField = IntatisHostApplication.identity
                .secretReferenceFieldName
            let legacyReferenceField = IntatisHostApplicationIdentity
                .intatis.secretReferenceFieldName
            let candidateReferenceFields = currentReferenceField
                == legacyReferenceField
                ? [currentReferenceField]
                : [currentReferenceField, legacyReferenceField]
            let allowed: Set<String> = [
                currentReferenceField,
                legacyReferenceField,
                "storage",
                "sourceBindingFingerprint",
            ]
            let referenceFields = candidateReferenceFields.filter {
                object[$0] != nil
            }
            guard Set(object.keys).isSubset(of: allowed),
                  referenceFields.count == 1,
                  let identifier = object[referenceFields[0]] as? String,
                  let storageName = object["storage"] as? String,
                  let storage = MCPSecretStorageClass(rawValue: storageName),
                  object["sourceBindingFingerprint"] == nil
                    || object["sourceBindingFingerprint"] is String else {
                throw ParserIssue(.init(
                    code: .invalidField,
                    path: fieldPath))
            }
            let binding = object["sourceBindingFingerprint"] as? String
            return .reference(try MCPSecretReference(
                storageClass: storage,
                identifier: identifier,
                sourceBindingFingerprint: binding))
        }
        guard let string = rawValue as? String else {
            throw ParserIssue(.init(
                code: .invalidField,
                path: fieldPath))
        }
        if let environmentName = environmentReferenceName(string) {
            return .reference(try MCPSecretReference(
                storageClass: .environment,
                identifier: environmentName,
                sourceBindingFingerprint: sourceFingerprint))
        }
        if MCPConfigurationValidation.sensitiveName(fieldName)
            || MCPConfigurationValidation.looksLikeSecret(string) {
            return stageSecret(
                string,
                fieldPath: fieldPath,
                fieldName: fieldName,
                kind: kind)
        }
        return .literal(string)
    }

    mutating func stageSecret(
        _ value: String,
        fieldPath: String,
        fieldName: String,
        kind: MCPImportedSecretKind
    ) -> MCPImportedValue {
        let stagingID = "mcpsecret_\(UUID().uuidString.lowercased())"
        let descriptor = MCPImportedSecretDescriptor(
            stagingID: stagingID,
            fieldPath: fieldPath,
            fieldName: fieldName,
            kind: kind,
            sourceFingerprint: sourceFingerprint)
        secretDescriptors.append(descriptor)
        secretValues[stagingID] = Data(value.utf8)
        return .pendingSecret(stagingID)
    }

    mutating func parseApproval(
        _ raw: [String: Any],
        path: String
    ) throws -> MCPApprovalPolicy {
        let server = try approvalMode(
            raw["approval_mode"],
            default: .prompt,
            path: "\(path).approval_mode")
        var overrides: [String: MCPApprovalMode] = [:]
        if let value = raw["tool_approval_modes"] {
            guard let object = value as? [String: Any] else {
                throw ParserIssue(.init(
                    code: .invalidField,
                    path: "\(path).tool_approval_modes"))
            }
            for key in object.keys.sorted() {
                try MCPConfigurationValidation.validateRemoteName(key)
                overrides[key] = try approvalMode(
                    object[key],
                    default: server,
                    path: "\(path).tool_approval_modes.\(key)")
            }
        }
        return try MCPApprovalPolicy(
            serverDefault: server,
            toolOverrides: overrides)
    }

    mutating func parseFilters(
        _ raw: [String: Any],
        path: String
    ) throws -> MCPServerFilters {
        try MCPServerFilters(
            tools: parseNameFilter(raw["tools"], path: "\(path).tools"),
            resources: parseNameFilter(
                raw["resources"], path: "\(path).resources"),
            prompts: parseNameFilter(raw["prompts"], path: "\(path).prompts"),
            completions: parseNameFilter(
                raw["completions"], path: "\(path).completions"))
    }

    mutating func parseNameFilter(
        _ value: Any?,
        path: String
    ) -> MCPNameFilter {
        guard let value else { return .init() }
        guard let object = value as? [String: Any] else {
            issues.append(.init(code: .invalidField, path: path))
            return .init(allowList: [], denyList: [])
        }
        reportUnknown(keys: object.keys, allowed: ["allow", "deny"], path: path)
        do {
            let allow = try object["allow"].map {
                try stringArray($0, default: [], path: "\(path).allow")
            }
            let deny = try stringArray(
                object["deny"], default: [], path: "\(path).deny")
            return MCPNameFilter(allowList: allow, denyList: deny)
        } catch {
            issues.append(.init(code: .invalidField, path: path))
            return .init(allowList: [], denyList: [])
        }
    }

    func parseTimeouts(
        _ raw: [String: Any],
        path: String
    ) throws -> MCPServerTimeouts {
        let common = try integer(
            raw["timeout"], default: 60_000, path: "\(path).timeout")
        return try MCPServerTimeouts(
            startupMilliseconds: try integer(
                raw["startup_timeout"],
                default: min(common, 30_000),
                path: "\(path).startup_timeout"),
            callMilliseconds: try integer(
                raw["call_timeout"],
                default: common,
                path: "\(path).call_timeout"),
            shutdownMilliseconds: try integer(
                raw["shutdown_timeout"],
                default: min(common, 5_000),
                path: "\(path).shutdown_timeout"))
    }

    mutating func reportUnknown<S: Sequence>(
        keys: S,
        allowed: Set<String>,
        path: String
    ) where S.Element == String {
        for key in keys.sorted() where !allowed.contains(key) {
            issues.append(.init(
                code: .unknownField,
                path: "\(path).\(key)"))
        }
    }

    func stringArray(
        _ value: Any?,
        default defaultValue: [String],
        path: String
    ) throws -> [String] {
        guard let value else { return defaultValue }
        guard let array = value as? [Any],
              array.count <= MCPConfigurationLimits.maximumArguments else {
            throw ParserIssue(.init(code: .invalidField, path: path))
        }
        return try array.enumerated().map { index, value in
            guard let string = value as? String,
                  string.utf8.count <= MCPConfigurationLimits.maximumScalarBytes,
                  !string.contains("\0") else {
                throw ParserIssue(.init(
                    code: .invalidField,
                    path: "\(path)[\(index)]"))
            }
            return string
        }
    }

    func bool(
        _ value: Any?,
        default defaultValue: Bool,
        path: String
    ) throws -> Bool {
        guard let value else { return defaultValue }
        guard let result = value as? Bool else {
            throw ParserIssue(.init(code: .invalidField, path: path))
        }
        return result
    }

    func integer(
        _ value: Any?,
        default defaultValue: Int,
        path: String
    ) throws -> Int {
        guard let value else { return defaultValue }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ParserIssue(.init(code: .invalidField, path: path))
        }
        return number.intValue
    }

    func approvalMode(
        _ value: Any?,
        default defaultValue: MCPApprovalMode,
        path: String
    ) throws -> MCPApprovalMode {
        guard let value else { return defaultValue }
        guard let string = value as? String,
              let mode = MCPApprovalMode(rawValue: string) else {
            throw ParserIssue(.init(code: .invalidField, path: path))
        }
        return mode
    }

    func environmentReferenceName(_ value: String) -> String? {
        if value.hasPrefix("${"), value.hasSuffix("}") {
            let name = String(value.dropFirst(2).dropLast())
            return (try? MCPConfigurationValidation
                .validateEnvironmentName(name)) == nil ? nil : name
        }
        if value.hasPrefix("{env:"), value.hasSuffix("}") {
            let name = String(value.dropFirst(5).dropLast())
            return (try? MCPConfigurationValidation
                .validateEnvironmentName(name)) == nil ? nil : name
        }
        return nil
    }
}

private struct ParserIssue: Error {
    let issue: MCPImportIssue
    init(_ issue: MCPImportIssue) { self.issue = issue }
}

private extension Dictionary {
    func mapValuesWithKeys<T>(
        _ transform: (Key, Value) throws -> T
    ) rethrows -> [Key: T] {
        var result: [Key: T] = [:]
        result.reserveCapacity(count)
        for (key, value) in self {
            result[key] = try transform(key, value)
        }
        return result
    }
}

// MARK: - Sanitized export

public enum MCPConfigurationExporter {
    /// Emits a stable Intatis MCP export. Secret values are structurally
    /// impossible: only opaque references are serialized.
    public static func sanitizedMCPJSON(
        catalog: MCPServerCatalog,
        includeDisabled: Bool = true
    ) throws -> Data {
        var servers: [String: Any] = [:]
        for head in catalog.heads.sorted(by: { $0.alias < $1.alias }) {
            guard includeDisabled || !head.disabled,
                  let revision = head.currentRevision else { continue }
            let reference = MCPServerReference(
                serverID: head.serverID,
                serverRevision: revision)
            guard !catalog.isTombstoned(reference),
                  let definition = catalog.definition(for: reference) else {
                continue
            }
            servers[head.alias] = try exportedDefinition(
                definition,
                disabled: head.disabled)
        }
        let root: [String: Any] = [
            "$schema": "https://\(IntatisHostApplication.identity.fileNameStem).invalid/schemas/mcp-import-v1.json",
            "version": 1,
            "mcpServers": servers,
        ]
        guard JSONSerialization.isValidJSONObject(root) else {
            throw MCPImportError.exportFailed
        }
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func exportedDefinition(
        _ definition: MCPServerDefinition,
        disabled: Bool
    ) throws -> [String: Any] {
        let config = definition.configuration
        var object: [String: Any] = [
            "disabled": disabled || !config.enabled,
            "required": config.required,
            "parallel": config.parallelCalls,
            "approval_mode": config.approvalPolicy.serverDefault.rawValue,
            "tool_approval_modes": config.approvalPolicy.toolOverrides
                .mapValues(\.rawValue),
            "startup_timeout": config.timeouts.startupMilliseconds,
            "call_timeout": config.timeouts.callMilliseconds,
            "shutdown_timeout": config.timeouts.shutdownMilliseconds,
        ]
        switch config.transport {
        case .stdio(let stdio):
            object["type"] = "stdio"
            object["command"] = stdio.executableCanonicalPath
            object["args"] = stdio.arguments
            if let cwd = stdio.workingDirectory { object["cwd"] = cwd }
            object["env"] = stdio.environment.mapValues(exportedValue)
            object["env_vars"] = stdio.inheritedEnvironmentReferences.keys.sorted()
        case .streamableHTTP(let http):
            object["type"] = "http"
            object["url"] = http.endpoint
            object["headers"] = http.headers.mapValues(exportedValue)
            if let bearer = http.bearerTokenReference {
                object["bearer_token"] = exportedReference(bearer)
            }
        }
        object["tools"] = exportedFilter(config.filters.tools)
        object["resources"] = exportedFilter(config.filters.resources)
        object["prompts"] = exportedFilter(config.filters.prompts)
        object["completions"] = exportedFilter(config.filters.completions)
        return object
    }

    private static func exportedValue(_ value: MCPConfiguredValue) -> Any {
        switch value {
        case .literal(let string): return string
        case .secret(let reference): return exportedReference(reference)
        }
    }

    private static func exportedReference(_ reference: MCPSecretReference) -> [String: Any] {
        var result: [String: Any] = [
            IntatisHostApplication.identity.secretReferenceFieldName:
                reference.identifier,
            "storage": reference.storageClass.rawValue,
        ]
        if let fingerprint = reference.sourceBindingFingerprint {
            result["sourceBindingFingerprint"] = fingerprint
        }
        return result
    }

    private static func exportedFilter(_ filter: MCPNameFilter) -> [String: Any] {
        var result: [String: Any] = ["deny": filter.denyList]
        if let allow = filter.allowList { result["allow"] = allow }
        return result
    }
}
