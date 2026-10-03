#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisMCP requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisCore
import IntatisProtocol

public struct MCPPromptAccessPolicy: Sendable {
    public let server: MCPServerReference
    public let attachmentID: MCPAttachmentID
    public let serverAlias: String
    public let serverFilter: MCPNameFilter
    public let attachmentFilter: MCPNameFilter
    public let policyFingerprint: String

    public init(
        server: MCPServerReference,
        attachmentID: MCPAttachmentID,
        serverAlias: String,
        serverFilter: MCPNameFilter = .init(),
        attachmentFilter: MCPNameFilter = .init(),
        policyFingerprint: String
    ) throws {
        guard !serverAlias.isEmpty,
              !serverAlias.contains("\0"),
              !policyFingerprint.isEmpty else {
            throw MCPContentOperationError.invalidArguments(
                "invalid prompt access policy")
        }
        self.server = server
        self.attachmentID = attachmentID
        self.serverAlias = serverAlias
        self.serverFilter = serverFilter
        self.attachmentFilter = attachmentFilter
        self.policyFingerprint = policyFingerprint
    }
}

public struct MCPAgentPromptServerView: Sendable {
    public let connection: MCPConnectionSnapshot
    public let grant: MCPGrant
    public let policy: MCPPromptAccessPolicy
    public let prompts: [MCPRawPromptRecord]
}

public struct MCPAgentPromptCatalogView: Sendable {
    public let connectionSetSnapshotID: MCPConnectionSetSnapshotID
    public let bindingID: MCPBindingID
    public let agentID: AgentID
    public let servers: [MCPAgentPromptServerView]
    public let stableFingerprint: String

    public static func build(
        connectionSet: MCPConnectionSetSnapshot,
        capabilityLease: CapabilityLease,
        policies: [MCPPromptAccessPolicy]
    ) throws -> MCPAgentPromptCatalogView {
        let policyByAttachment = Dictionary(
            uniqueKeysWithValues: policies.map {
                ($0.attachmentID, $0)
            })
        var aliases: Set<String> = []
        var servers: [MCPAgentPromptServerView] = []
        for connection in connectionSet.connections {
            guard connection.bindingIdentity.protocolProfile
                    == .standardExtended,
                  !connection.unavailableCatalogKinds
                    .contains(.prompts) else {
                continue
            }
            let authority = connection.reuseIdentity.authority
            guard authority.hasCurrentExecutionAuthority,
                  authority.agentID == connectionSet.agentID,
                  authority.capabilityLeaseID == capabilityLease.id,
                  authority.capabilityTaskID
                    == capabilityLease.taskID,
                  let policy = policyByAttachment[
                    authority.attachmentID],
                  policy.server == connection.reuseIdentity.server else {
                throw MCPContentOperationError.missingGrant(.prompts)
            }
            guard aliases.insert(policy.serverAlias).inserted else {
                throw MCPContentOperationError.ambiguousServer(
                    policy.serverAlias)
            }
            let grants = capabilityLease.mcpGrants.filter {
                $0.attachmentID == authority.attachmentID
                    && $0.server == connection.reuseIdentity.server
                    && $0.agentID == connectionSet.agentID
                    && $0.capabilityLeaseID
                        == capabilityLease.id
                    && $0.taskID
                        == capabilityLease.taskID
                    && $0.grants(.prompts)
                    && $0.isActive()
            }
            guard grants.count == 1, let grant = grants.first,
                  grant.authorityFingerprint == authority.fingerprint,
                  grant.revocationGeneration
                    == connection.bindingIdentity.revocationGeneration else {
                throw MCPContentOperationError.missingGrant(.prompts)
            }
            let prompts = connection.catalog.prompts.filter {
                Self.allows(
                    $0.name,
                    filters: [
                        policy.serverFilter,
                        policy.attachmentFilter,
                        grant.filter.prompts,
                    ])
            }
            servers.append(MCPAgentPromptServerView(
                connection: connection,
                grant: grant,
                policy: policy,
                prompts: prompts))
        }
        servers.sort { $0.policy.serverAlias < $1.policy.serverAlias }
        let fingerprint = MCPResourceToolHash.hash(
            ["mcp-prompt-view-v1",
             connectionSet.snapshotID.rawValue,
             connectionSet.bindingID.rawValue,
             capabilityLease.id.rawValue]
                + servers.flatMap {
                    [
                        $0.policy.serverAlias,
                        $0.connection.catalog.catalogFingerprint,
                        $0.grant.grantFingerprint,
                        $0.policy.policyFingerprint,
                    ] + $0.prompts.map(\.identityFingerprint)
                })
        return MCPAgentPromptCatalogView(
            connectionSetSnapshotID: connectionSet.snapshotID,
            bindingID: connectionSet.bindingID,
            agentID: connectionSet.agentID,
            servers: servers,
            stableFingerprint: fingerprint)
    }

    private init(
        connectionSetSnapshotID: MCPConnectionSetSnapshotID,
        bindingID: MCPBindingID,
        agentID: AgentID,
        servers: [MCPAgentPromptServerView],
        stableFingerprint: String
    ) {
        self.connectionSetSnapshotID = connectionSetSnapshotID
        self.bindingID = bindingID
        self.agentID = agentID
        self.servers = servers
        self.stableFingerprint = stableFingerprint
    }

    private static func allows(
        _ name: String,
        filters: [MCPNameFilter]
    ) -> Bool {
        filters.allSatisfy { $0.allows(name) }
    }
}

public struct MCPPromptPickerItem: Equatable, Sendable {
    public let serverAlias: String
    public let server: MCPServerReference
    public let name: String
    public let title: String?
    public let summary: String?
    public let arguments: [MCPRawPromptArgument]
    public let provenance: MCPContentProvenance
}

public enum MCPExternalContentTrust:
    String, Codable, Equatable, Hashable, Sendable {
    case serverProvidedUntrusted = "server_provided_untrusted"
}

public enum MCPExternalContextSource:
    String, Codable, Equatable, Hashable, Sendable {
    case userSelectedPrompt = "user_selected_prompt"
    case explicitlyEnabledServerInstructions =
        "explicitly_enabled_server_instructions"
    case resource
}

/// External MCP content deliberately has no system/developer role
/// representation. Convert it explicitly at the AgentKernel host boundary
/// before adding it to a durable user submission.
public struct MCPUntrustedExternalContext:
    Codable, Equatable, Sendable {
    public let source: MCPExternalContextSource
    public let trust: MCPExternalContentTrust
    public let text: String?
    public let structured: JSONValue?
    public let provenance: MCPContentProvenance

    public init(
        source: MCPExternalContextSource,
        text: String? = nil,
        structured: JSONValue? = nil,
        provenance: MCPContentProvenance
    ) {
        self.source = source
        self.trust = .serverProvidedUntrusted
        self.text = text
        self.structured = structured
        self.provenance = provenance
    }

    public func providerNeutralContext()
        -> UntrustedExternalContext
    {
        let neutralSource:
            UntrustedExternalContextSource
        switch source {
        case .userSelectedPrompt:
            neutralSource = .mcpUserSelectedPrompt
        case .explicitlyEnabledServerInstructions:
            neutralSource =
                .mcpExplicitServerInstructions
        case .resource:
            neutralSource = .mcpResource
        }
        return UntrustedExternalContext(
            source: neutralSource,
            text: text,
            structured: structured,
            provenance: .init(mcp: provenance))
    }
}

public struct MCPPromptPreview: Equatable, Sendable {
    public let previewID: String
    public let serverAlias: String
    public let promptName: String
    public let arguments: [String: String]
    public let description: String?
    public let messages: [JSONValue]
    public let provenance: MCPContentProvenance
    public let confirmationDigest: String

    public init(
        previewID: String,
        serverAlias: String,
        promptName: String,
        arguments: [String: String],
        description: String?,
        messages: [JSONValue],
        provenance: MCPContentProvenance,
        confirmationDigest: String
    ) {
        self.previewID = previewID
        self.serverAlias = serverAlias
        self.promptName = promptName
        self.arguments = arguments
        self.description = description
        self.messages = messages
        self.provenance = provenance
        self.confirmationDigest = confirmationDigest
    }
}

public enum MCPExplicitPromptDecision: Equatable, Sendable {
    case insert(previewID: String, confirmationDigest: String)
    case cancel
}

public struct MCPPromptInsertion: Equatable, Sendable {
    public let externalContexts: [MCPUntrustedExternalContext]
    public let event: MCPPromptInsertedPayload

    public init(
        externalContexts: [MCPUntrustedExternalContext],
        event: MCPPromptInsertedPayload
    ) {
        self.externalContexts = externalContexts
        self.event = event
    }
}

public struct MCPPromptPicker: Sendable {
    public let view: MCPAgentPromptCatalogView
    public let maximumArgumentBytes: Int
    public let maximumPromptBytes: Int
    private let sanitizer: any MCPToolResultSanitizer
    private let authorityVerifier:
        any MCPExternalOperationAuthorityVerifier
    private let workspaceLease: WorkspaceLease?

    public init(
        view: MCPAgentPromptCatalogView,
        authorityVerifier:
            any MCPExternalOperationAuthorityVerifier,
        workspaceLease: WorkspaceLease?,
        maximumArgumentBytes: Int = 16 * 1_024,
        maximumPromptBytes: Int = 512 * 1_024,
        sanitizer: any MCPToolResultSanitizer =
            MCPConservativeToolResultSanitizer()
    ) {
        self.view = view
        self.maximumArgumentBytes = maximumArgumentBytes
        self.maximumPromptBytes = maximumPromptBytes
        self.sanitizer = sanitizer
        self.authorityVerifier = authorityVerifier
        self.workspaceLease = workspaceLease
    }

    public func items() -> [MCPPromptPickerItem] {
        view.servers.flatMap { server in
            server.prompts.map { prompt in
                MCPPromptPickerItem(
                    serverAlias: server.policy.serverAlias,
                    server: server.connection.bindingIdentity.server,
                    name: prompt.name,
                    title: prompt.title,
                    summary: prompt.summary,
                    arguments: prompt.arguments,
                    provenance: provenance(
                        server: server,
                        promptName: prompt.name))
            }
        }.sorted {
            if $0.serverAlias != $1.serverAlias {
                return $0.serverAlias < $1.serverAlias
            }
            return $0.name < $1.name
        }
    }

    /// `explicitUserAction` must come from the composer picker. Agents and
    /// server content cannot invoke prompt/get through this API implicitly.
    public func preview(
        serverAlias: String,
        promptName: String,
        arguments: [String: String],
        explicitUserAction: Bool
    ) async throws -> MCPPromptPreview {
        guard explicitUserAction else {
            throw MCPContentOperationError.explicitUserConfirmationRequired
        }
        let server = try resolve(serverAlias)
        guard server.grant.isActive(),
              let prompt = server.prompts.first(where: {
                  $0.name == promptName
              }) else {
            throw MCPContentOperationError.promptNotGranted(promptName)
        }
        try validate(arguments: arguments, for: prompt)
        let argumentFingerprint =
            MCPRawCatalogHash.sha256(
                try MCPPromptHash.canonical(
                    arguments))
        let fence = MCPExternalOperationFence(
            request:
                try MCPExternalOperationAuthorityRequest(
                    operation: .getPrompt,
                    connection: server.connection,
                    grant: server.grant,
                    workspaceLease: workspaceLease,
                    target:
                        "\(promptName)\u{1f}\(argumentFingerprint)"),
            verifier: authorityVerifier)
        let result = try await server.connection.route.getPrompt(
            name: promptName,
            arguments: arguments,
            fence: fence)
        let sanitizedDescription = try result.description.map(
            sanitizer.sanitizeMCPText)
        let sanitizedMessages = try result.messages.map {
            try MCPOutputSanitization
                .sanitizeJSON(
                    $0,
                    using: sanitizer)
        }
        let payload = JSONValue.object([
            "description": sanitizedDescription.map(JSONValue.string)
                ?? .null,
            "messages": .array(sanitizedMessages),
        ])
        let data = try MCPJSONSchema.canonicalData(payload)
        guard data.count <= maximumPromptBytes else {
            throw MCPContentOperationError.contentTooLarge(
                maximum: maximumPromptBytes)
        }
        let previewID = UUID().uuidString.lowercased()
        let argsData = try MCPPromptHash.canonical(arguments)
        let digest = MCPRawCatalogHash.sha256(
            Data([
                "mcp-prompt-preview-v1",
                previewID,
                server.connection.bindingIdentity.bindingID.rawValue,
                promptName,
                argsData.base64EncodedString(),
                data.base64EncodedString(),
            ].joined(separator: "\u{1f}").utf8))
        // Sanitization and bounded conversion happen after the transport
        // response. Re-check durable authority at the final reader-facing
        // publication edge as well.
        try await fence.verifyBeforePublication()
        return MCPPromptPreview(
            previewID: previewID,
            serverAlias: serverAlias,
            promptName: promptName,
            arguments: arguments,
            description: sanitizedDescription,
            messages: sanitizedMessages,
            provenance: provenance(
                server: server,
                promptName: promptName),
            confirmationDigest: digest)
    }

    public func confirmInsertion(
        preview: MCPPromptPreview,
        decision: MCPExplicitPromptDecision,
        requestID: RequestID,
        insertedMessageID: MessageID,
        selectedByAgentID: AgentID?
    ) throws -> MCPPromptInsertion? {
        switch decision {
        case .cancel:
            return nil
        case .insert(let previewID, let digest):
            guard previewID == preview.previewID,
                  digest == preview.confirmationDigest else {
                throw MCPContentOperationError
                    .explicitUserConfirmationRequired
            }
        }
        let argsData = try MCPPromptHash.canonical(preview.arguments)
        let event = MCPPromptInsertedPayload(
            requestID: requestID,
            promptName: preview.promptName,
            arguments: MCPPayloadFingerprint(
                sha256: MCPRawCatalogHash.sha256(argsData),
                characterCount: preview.arguments.values.reduce(0) {
                    $0 + $1.count
                }),
            insertedMessageID: insertedMessageID,
            provenance: preview.provenance,
            selectedByAgentID: selectedByAgentID)
        let contexts = preview.messages.map {
            MCPUntrustedExternalContext(
                source: .userSelectedPrompt,
                structured: $0,
                provenance: preview.provenance)
        }
        return MCPPromptInsertion(
            externalContexts: contexts,
            event: event)
    }

    private func resolve(
        _ alias: String
    ) throws -> MCPAgentPromptServerView {
        let matches = view.servers.filter {
            $0.policy.serverAlias == alias
        }
        guard !matches.isEmpty else {
            throw MCPContentOperationError.unknownServer(alias)
        }
        guard matches.count == 1, let first = matches.first else {
            throw MCPContentOperationError.ambiguousServer(alias)
        }
        return first
    }

    private func validate(
        arguments: [String: String],
        for prompt: MCPRawPromptRecord
    ) throws {
        let declared = Set(prompt.arguments.map(\.name))
        guard Set(arguments.keys).isSubset(of: declared) else {
            throw MCPContentOperationError.invalidArguments(
                "prompt contains an undeclared argument")
        }
        for required in prompt.arguments where required.required {
            guard let value = arguments[required.name],
                  !value.isEmpty else {
                throw MCPContentOperationError.invalidArguments(
                    "missing required prompt argument '\(required.name)'")
            }
        }
        guard arguments.allSatisfy({
            $0.key.utf8.count <= 1_024
                && $0.value.utf8.count <= maximumArgumentBytes
        }) else {
            throw MCPContentOperationError.invalidArguments(
                "prompt argument exceeds a bounded limit")
        }
    }

    private func provenance(
        server: MCPAgentPromptServerView,
        promptName: String
    ) -> MCPContentProvenance {
        let binding = server.connection.bindingIdentity
        return MCPContentProvenance(
            sourceKind: .prompt,
            server: binding.server,
            connectionGeneration: binding.connectionGeneration,
            rawCatalogRevision: binding.rawCatalogRevision,
            agentCatalogViewRevision:
                binding.agentCatalogViewRevision,
            bindingID: binding.bindingID,
            protocolProfile: binding.protocolProfile,
            maximumProtocolVersion:
                binding.maximumProtocolVersion,
            negotiatedProtocolVersion:
                binding.negotiatedProtocolVersion,
            remoteName: promptName,
            accountReference:
                server.connection.reuseIdentity.oauthAccountReference,
            environmentReference:
                server.connection.reuseIdentity.environmentReference)
    }

}

public struct MCPCompletionSuggestions: Equatable, Sendable {
    public let values: [String]
    public let total: Int?
    public let hasMore: Bool
    /// The UI must require a user click/keyboard selection; suggestions never
    /// mutate or submit a composer field automatically.
    public let requiresExplicitSelection: Bool

    public init(
        values: [String],
        total: Int?,
        hasMore: Bool
    ) {
        self.values = values
        self.total = total
        self.hasMore = hasMore
        self.requiresExplicitSelection = true
    }
}

public actor MCPCompletionController {
    private struct ServerReference: Sendable {
        let connection: MCPConnectionSnapshot
        let grant: MCPGrant
    }

    private let debounceNanoseconds: UInt64
    private let timeoutNanoseconds: UInt64
    private let maximumValues: Int
    private let maximumTotalBytes: Int
    private let sanitizer: any MCPToolResultSanitizer
    private let authorityVerifier:
        any MCPExternalOperationAuthorityVerifier
    private var serials: [String: UInt64] = [:]
    private var tasks: [
        String: Task<MCPCompletionSuggestions, Error>
    ] = [:]

    public init(
        authorityVerifier:
            any MCPExternalOperationAuthorityVerifier,
        debounceMilliseconds: Int = 150,
        timeoutMilliseconds: Int = 5_000,
        maximumValues: Int = 100,
        maximumTotalBytes: Int = 64 * 1_024,
        sanitizer: any MCPToolResultSanitizer =
            MCPConservativeToolResultSanitizer()
    ) {
        debounceNanoseconds =
            UInt64(max(1, debounceMilliseconds)) * 1_000_000
        timeoutNanoseconds =
            UInt64(max(100, timeoutMilliseconds)) * 1_000_000
        self.maximumValues = min(100, max(1, maximumValues))
        self.maximumTotalBytes = max(1_024, maximumTotalBytes)
        self.sanitizer = sanitizer
        self.authorityVerifier = authorityVerifier
    }

    public func complete(
        fieldID: String,
        view: MCPConnectionSetSnapshot,
        capabilityLease: CapabilityLease,
        workspaceLease: WorkspaceLease?,
        serverAlias: String,
        aliases: [MCPAttachmentID: String],
        reference: MCPCompletionReference,
        argumentName: String,
        argumentValue: String,
        context: [String: String] = [:],
        sanitizerOverride:
            (any MCPToolResultSanitizer)? = nil
    ) async throws -> MCPCompletionSuggestions {
        guard !fieldID.isEmpty,
              fieldID.utf8.count <= 512 else {
            throw MCPContentOperationError.invalidArguments(
                "invalid completion field identity")
        }
        let target = try resolve(
            view: view,
            capabilityLease: capabilityLease,
            serverAlias: serverAlias,
            aliases: aliases,
            reference: reference)
        try validateInput(
            argumentName: argumentName,
            argumentValue: argumentValue,
            context: context)

        let serial = (serials[fieldID] ?? 0) &+ 1
        serials[fieldID] = serial
        tasks[fieldID]?.cancel()
        let delay = debounceNanoseconds
        let timeout = timeoutNanoseconds
        let maximumValues = self.maximumValues
        let maximumBytes = maximumTotalBytes
        let sanitizer =
            sanitizerOverride
                ?? self.sanitizer
        let verifier = authorityVerifier
        let operationKind:
            MCPExternalOperationKind
        switch reference {
        case .prompt:
            operationKind = .completePrompt
        case .resource:
            operationKind = .completeResource
        }
        let targetFingerprint =
            MCPRawCatalogHash.sha256(
                Data([
                    String(describing: reference),
                    argumentName,
                    argumentValue,
                    context.keys.sorted()
                        .joined(separator: "\u{1e}"),
                ].joined(separator: "\u{1f}").utf8))
        let fence = MCPExternalOperationFence(
            request:
                try MCPExternalOperationAuthorityRequest(
                    operation: operationKind,
                    connection: target.connection,
                    grant: target.grant,
                    workspaceLease: workspaceLease,
                    target: targetFingerprint),
            verifier: verifier)
        let task = Task<MCPCompletionSuggestions, Error> {
            try await Task.sleep(nanoseconds: delay)
            let operation = Task {
                try await target.connection.route.complete(
                    reference: reference,
                    argumentName: argumentName,
                    argumentValue: argumentValue,
                    context: context,
                    fence: fence)
            }
            let timer = Task<MCPCompletionResult, Error> {
                try await Task.sleep(nanoseconds: timeout)
                operation.cancel()
                throw MCPClientSessionError.requestTimedOut(
                    method: "completion/complete",
                    milliseconds: Int(timeout / 1_000_000))
            }
            defer {
                operation.cancel()
                timer.cancel()
            }
            let raw = try await withThrowingTaskGroup(
                of: MCPCompletionResult.self
            ) { group in
                group.addTask { try await operation.value }
                group.addTask { try await timer.value }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            guard raw.values.count <= maximumValues else {
                throw MCPContentOperationError.contentTooLarge(
                    maximum: maximumValues)
            }
            let values = try raw.values.map(
                sanitizer.sanitizeMCPText)
            guard values.reduce(0, {
                $0 + $1.utf8.count
            }) <= maximumBytes else {
                throw MCPContentOperationError.contentTooLarge(
                    maximum: maximumBytes)
            }
            try await fence.verifyBeforePublication()
            return MCPCompletionSuggestions(
                values: values,
                total: raw.total,
                hasMore: raw.hasMore ?? false)
        }
        tasks[fieldID] = task
        do {
            let result = try await task.value
            guard serials[fieldID] == serial else {
                throw MCPContentOperationError.staleRequest
            }
            tasks.removeValue(forKey: fieldID)
            return result
        } catch {
            if serials[fieldID] == serial {
                tasks.removeValue(forKey: fieldID)
            }
            throw error
        }
    }

    public func cancel(fieldID: String) {
        serials[fieldID] = (serials[fieldID] ?? 0) &+ 1
        tasks.removeValue(forKey: fieldID)?.cancel()
    }

    public func shutdownAndDrain() async {
        let current = Array(tasks.values)
        tasks.removeAll()
        for task in current { task.cancel() }
        for task in current { _ = await task.result }
    }

    private func resolve(
        view: MCPConnectionSetSnapshot,
        capabilityLease: CapabilityLease,
        serverAlias: String,
        aliases: [MCPAttachmentID: String],
        reference: MCPCompletionReference
    ) throws -> ServerReference {
        let connections = view.connections.filter {
            aliases[$0.reuseIdentity.authority.attachmentID]
                == serverAlias
        }
        guard connections.count == 1, let connection = connections.first,
              connection.bindingIdentity.protocolProfile
                == .standardExtended,
              !connection.unavailableCatalogKinds.contains(
                reference.catalogKind) else {
            throw MCPContentOperationError.unknownServer(serverAlias)
        }
        let authority = connection.reuseIdentity.authority
        guard authority.hasCurrentExecutionAuthority,
              authority.agentID == view.agentID,
              authority.capabilityLeaseID
                == capabilityLease.id,
              authority.capabilityTaskID
                == capabilityLease.taskID else {
            throw MCPContentOperationError
                .missingGrant(.completions)
        }
        let grants = capabilityLease.mcpGrants.filter {
            $0.attachmentID == authority.attachmentID
                && $0.server == connection.bindingIdentity.server
                && $0.agentID == view.agentID
                && $0.capabilityLeaseID
                    == capabilityLease.id
                && $0.taskID
                    == capabilityLease.taskID
                && $0.grants(.completions)
                && $0.isActive()
                && $0.authorityFingerprint == authority.fingerprint
                && $0.revocationGeneration
                    == connection.bindingIdentity.revocationGeneration
        }
        guard grants.count == 1, let grant = grants.first else {
            throw MCPContentOperationError.missingGrant(.completions)
        }
        switch reference {
        case .prompt(let name):
            guard grant.grants(.prompts),
                  grant.filter.prompts.allows(name),
                  grant.filter.completions.allows(name),
                  connection.catalog.prompts.contains(where: {
                      $0.name == name
                  }) else {
                throw MCPContentOperationError.completionNotGranted
            }
        case .resource(let template):
            guard grant.grants(.resources),
                  grant.filter.resources.allows(template),
                  grant.filter.completions.allows(template),
                  connection.catalog.resourceTemplates.contains(where: {
                      $0.uriTemplate == template
                  }) else {
                throw MCPContentOperationError.completionNotGranted
            }
        }
        return ServerReference(connection: connection, grant: grant)
    }

    private func validateInput(
        argumentName: String,
        argumentValue: String,
        context: [String: String]
    ) throws {
        guard !argumentName.isEmpty,
              argumentName.utf8.count <= 1_024,
              argumentValue.utf8.count <= 16 * 1_024,
              context.count <= 256,
              context.allSatisfy({
                  $0.key.utf8.count <= 1_024
                      && $0.value.utf8.count <= 16 * 1_024
              }) else {
            throw MCPContentOperationError.invalidArguments(
                "completion input exceeds a bounded limit")
        }
    }
}

private extension MCPCompletionReference {
    var catalogKind: MCPCatalogChangeKind {
        switch self {
        case .prompt:
            return .prompts
        case .resource:
            return .resources
        }
    }
}

public enum MCPServerInstructionsVisibility:
    Codable, Equatable, Hashable, Sendable {
    case detailsOnly
    case externalContext(policyRevision: MCPPolicyRevision)
}

public struct MCPServerInstructionsMaterializer: Sendable {
    public let maximumBytes: Int
    private let sanitizer: any MCPToolResultSanitizer

    public init(
        maximumBytes: Int = 64 * 1_024,
        sanitizer: any MCPToolResultSanitizer =
            MCPConservativeToolResultSanitizer()
    ) {
        self.maximumBytes = max(1_024, maximumBytes)
        self.sanitizer = sanitizer
    }

    /// Default `detailsOnly` returns no model context. Explicit enablement
    /// still produces a provenance-tagged untrusted external context.
    public func materialize(
        _ instructions: MCPExternalServerInstructions?,
        visibility: MCPServerInstructionsVisibility,
        connection: MCPConnectionSnapshot,
        grant: MCPGrant,
        workspaceLease: WorkspaceLease?,
        authorityVerifier:
            any MCPExternalOperationAuthorityVerifier
    ) async throws -> MCPUntrustedExternalContext? {
        guard let instructions else { return nil }
        guard instructions.server == connection.bindingIdentity.server,
              instructions.generation
                == connection.bindingIdentity.connectionGeneration,
              let frozen =
                connection.serverInstructions,
              frozen.text == instructions.text else {
            throw MCPContentOperationError.staleRequest
        }
        return try await materialize(
            visibility: visibility,
            connection: connection,
            grant: grant,
            workspaceLease: workspaceLease,
            authorityVerifier:
                authorityVerifier)
    }

    /// Materializes only the instructions frozen into this exact published
    /// connection snapshot. Default details-only visibility never creates
    /// model context.
    public func materialize(
        visibility: MCPServerInstructionsVisibility,
        connection: MCPConnectionSnapshot,
        grant: MCPGrant,
        workspaceLease: WorkspaceLease?,
        authorityVerifier:
            any MCPExternalOperationAuthorityVerifier
    ) async throws -> MCPUntrustedExternalContext? {
        guard let instructions =
                connection.serverInstructions else {
            return nil
        }
        let binding = connection.bindingIdentity
        let provenance = instructions.provenance
        guard provenance.server == binding.server,
              provenance.connectionGeneration
                == binding.connectionGeneration,
              provenance.rawCatalogRevision
                == binding.rawCatalogRevision,
              provenance.agentCatalogViewRevision
                == binding.agentCatalogViewRevision,
              provenance.bindingID
                == binding.bindingID else {
            throw MCPContentOperationError.staleRequest
        }
        guard case .externalContext = visibility else { return nil }
        guard instructions.text.utf8.count <= maximumBytes else {
            throw MCPContentOperationError.contentTooLarge(
                maximum: maximumBytes)
        }
        let fence = MCPExternalOperationFence(
            request:
                try MCPExternalOperationAuthorityRequest(
                    operation:
                        .useServerInstructions,
                    connection: connection,
                    grant: grant,
                    workspaceLease:
                        workspaceLease,
                    target:
                        instructions.text),
            verifier: authorityVerifier)
        try fence.validateExactRoute(
            identity:
                connection.reuseIdentity,
            binding:
                connection.bindingIdentity)
        try await fence.verifyBeforeRequest()
        try await connection.route.revalidate(
            catalogKind: nil)
        let context = MCPUntrustedExternalContext(
            source: .explicitlyEnabledServerInstructions,
            text: try sanitizer.sanitizeMCPText(instructions.text),
            provenance: provenance)
        try await connection.route.revalidate(
            catalogKind: nil)
        try await fence.verifyBeforePublication()
        return context
    }
}

public struct MCPRootsTransition: Equatable, Sendable {
    public let previous: MCPAuthorizedRootsSnapshot
    public let replacement: MCPAuthorizedRootsSnapshot
    public let requiresConnectionRetirement: Bool

    public init(
        previous: MCPAuthorizedRootsSnapshot,
        replacement: MCPAuthorizedRootsSnapshot
    ) {
        self.previous = previous
        self.replacement = replacement
        self.requiresConnectionRetirement = true
    }
}

public actor MCPRootsController {
    public let current: MCPAuthorizedRootsSnapshot

    public init(current: MCPAuthorizedRootsSnapshot) {
        self.current = current
    }

    /// Root authority is immutable for a connection generation. The old
    /// generation receives list_changed, then the host must retire it and
    /// create a new authority/generation serving `replacement`.
    public func prepareTransition(
        to replacement: MCPAuthorizedRootsSnapshot,
        oldConnection: MCPConnectionSnapshot
    ) async throws -> MCPRootsTransition {
        guard oldConnection.bindingIdentity.protocolProfile
                == .standardExtended,
              replacement.policyRevision != current.policyRevision,
              replacement.revocationGeneration
                != current.revocationGeneration else {
            throw MCPContentOperationError.invalidArguments(
                "roots transition must advance policy and revocation generations")
        }
        try await oldConnection.route.notifyRootsChanged()
        return MCPRootsTransition(
            previous: current,
            replacement: replacement)
    }
}

private enum MCPPromptHash {
    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
