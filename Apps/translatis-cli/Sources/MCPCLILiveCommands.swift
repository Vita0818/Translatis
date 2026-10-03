import Foundation
import IntatisAgentKernel
import IntatisCore
import IntatisMCP
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisSkills
import IntatisTools

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private enum MCPCLILiveCommandError:
    Error, LocalizedError
{
    case noLiveConnection
    case targetConnectionMissing(String)
    case ambiguousTarget(String)

    var errorDescription: String? {
        switch self {
        case .noLiveConnection:
            return "No exact live MCP connection exists in this CLI session owner. Run an explicit connect in the same long-lived CLI process first."
        case .targetConnectionMissing(let target):
            return "No live MCP connection matches '\(target)'."
        case .ambiguousTarget(let target):
            return "More than one live MCP connection matches '\(target)'; specify an immutable server ID."
        }
    }
}

struct MCPCLILiveSession: Sendable {
    let agentID: AgentID
    let capabilityLease: CapabilityLease
    let workspaceLease: WorkspaceLease
    let runtime: MCPCLIShippingRuntimeHandle
    let processRetained: Bool
}

private struct MCPCLIConnectionReport:
    Codable, Sendable
{
    let alias: String
    let serverID: String
    let serverRevision: String
    let attachmentID: String
    let connectionGeneration: String
    let rawCatalogRevision: String
    let agentCatalogViewRevision: String
    let bindingID: String
    let protocolProfile: String
    let maximumProtocolVersion: String
    let negotiatedProtocolVersion: String
    let toolCount: Int
    let resourceCount: Int
    let resourceTemplateCount: Int
    let promptCount: Int
}

private struct MCPCLIStatusReport:
    Codable, Sendable
{
    struct Attachment:
        Codable, Sendable
    {
        let alias: String
        let serverID: String
        let serverRevision: String
        let attachmentID: String
        let required: Bool
        let approvalMode: String
        let activeGrantCount: Int
    }

    let sessionID: String?
    let agentID: String?
    let catalog: [MCPServerInventoryRecord]
    let attachments: [Attachment]
    let liveConnections: [MCPCLIConnectionReport]
}

private struct MCPCLIToolCatalogReport:
    Codable, Sendable
{
    struct Server:
        Codable, Sendable
    {
        let alias: String
        let serverID: String
        let generation: String
        let rawCatalogRevision: String
        let tools: [MCPRawToolRecord]
    }

    let untrustedServerCatalog: Bool
    let servers: [Server]
}

private struct MCPCLIResourceCatalogReport:
    Codable, Sendable
{
    struct Server:
        Codable, Sendable
    {
        let alias: String
        let serverID: String
        let generation: String
        let rawCatalogRevision: String
        let resources: [MCPRawResourceRecord]
        let resourceTemplates:
            [MCPRawResourceTemplateRecord]
    }

    let untrustedServerCatalog: Bool
    let servers: [Server]
}

private struct MCPCLIPromptCatalogReport:
    Codable, Sendable
{
    struct Server:
        Codable, Sendable
    {
        let alias: String
        let serverID: String
        let generation: String
        let rawCatalogRevision: String
        let prompts: [MCPRawPromptRecord]
    }

    let untrustedServerCatalog: Bool
    let requiresExplicitPromptSelectionAndInsertion: Bool
    let servers: [Server]
}

private struct MCPCLIReloadReport:
    Codable, Sendable
{
    let generation: UInt64
    let catalogFingerprint: String
    let affectedSessionCount: Int
}

func runMCPCLIShippingCommand(
    _ command: String,
    context: MCPCLIContext,
    arguments: MCPCLIParsedArguments
) async throws {
    switch command {
    case "status":
        try await statusMCP(context, arguments)
    case "reload":
        let report = try await MCPProcessCatalogRuntimeRegistry
            .shared.reloadCatalog(
                from: context.catalogStore)
        let output = MCPCLIReloadReport(
            generation: report.publication.generation,
            catalogFingerprint:
                report.publication.catalogFingerprint,
            affectedSessionCount:
                report.sessionDiffs.count)
        if arguments.flags.contains("json") {
            try writeJSON(output)
        } else {
            out(
                "Reloaded MCP catalog generation \(output.generation); \(output.affectedSessionCount) live session owner(s) observed the publication.\n")
        }
    case "connect":
        try await withOneShotLiveSession(
            context,
            arguments: arguments
        ) { live in
            let confirmation = try controlConfirmation(
                arguments,
                action:
                    "connect exact MCP authorities for session \(live.runtime.sessionID.rawValue)")
            let snapshot = try await live.runtime.connect(
                agentID: live.agentID,
                capabilityLease: live.capabilityLease,
                workspaceLease: live.workspaceLease,
                baseRegistry: managementRegistry(),
                confirmation: confirmation)
            let aliases = try await aliasesByServer(context)
            let selected = try await selectedConnections(
                snapshot.connections,
                arguments: arguments,
                context: context)
            try emitConnections(
                selected,
                aliases: aliases,
                json: arguments.flags.contains("json"),
                verb: "Connected")
        }
    case "inspect", "tools", "resources", "prompts":
        try await withConnectedOneShotSession(
            context,
            arguments: arguments,
            action: command
        ) { live, snapshot in
            let aliases = try await aliasesByServer(context)
            let selected = try await selectedConnections(
                snapshot.connections,
                arguments: arguments,
                context: context)
            switch command {
            case "inspect":
                try emitConnections(
                    selected,
                    aliases: aliases,
                    json:
                        arguments.flags.contains("json"),
                    verb: "Inspected")
            case "tools":
                let value = MCPCLIToolCatalogReport(
                    untrustedServerCatalog: true,
                    servers: selected.map {
                        MCPCLIToolCatalogReport.Server(
                            alias: alias(
                                for: $0,
                                aliases: aliases),
                            serverID: $0.bindingIdentity
                                .server.serverID.rawValue,
                            generation: $0.bindingIdentity
                                .connectionGeneration.rawValue,
                            rawCatalogRevision:
                                $0.bindingIdentity
                                    .rawCatalogRevision
                                    .rawValue,
                            tools: $0.catalog.tools)
                    })
                try emitCatalog(
                    value,
                    json:
                        arguments.flags.contains("json"),
                    summary:
                        "\(value.servers.reduce(0) { $0 + $1.tools.count }) MCP tool(s) across \(value.servers.count) server(s); descriptions and schemas are untrusted server data.")
            case "resources":
                let value =
                    MCPCLIResourceCatalogReport(
                        untrustedServerCatalog: true,
                        servers: selected.map {
                            MCPCLIResourceCatalogReport
                                .Server(
                                    alias: alias(
                                        for: $0,
                                        aliases: aliases),
                                    serverID: $0
                                        .bindingIdentity
                                        .server.serverID
                                        .rawValue,
                                    generation: $0
                                        .bindingIdentity
                                        .connectionGeneration
                                        .rawValue,
                                    rawCatalogRevision: $0
                                        .bindingIdentity
                                        .rawCatalogRevision
                                        .rawValue,
                                    resources:
                                        $0.catalog.resources,
                                    resourceTemplates:
                                        $0.catalog
                                            .resourceTemplates)
                        })
                try emitCatalog(
                    value,
                    json:
                        arguments.flags.contains("json"),
                    summary:
                        "\(value.servers.reduce(0) { $0 + $1.resources.count }) resource(s) and \(value.servers.reduce(0) { $0 + $1.resourceTemplates.count }) template(s); values are untrusted server data.")
            case "prompts":
                let value = MCPCLIPromptCatalogReport(
                    untrustedServerCatalog: true,
                    requiresExplicitPromptSelectionAndInsertion:
                        true,
                    servers: selected.map {
                        MCPCLIPromptCatalogReport.Server(
                            alias: alias(
                                for: $0,
                                aliases: aliases),
                            serverID: $0.bindingIdentity
                                .server.serverID.rawValue,
                            generation: $0.bindingIdentity
                                .connectionGeneration.rawValue,
                            rawCatalogRevision:
                                $0.bindingIdentity
                                    .rawCatalogRevision
                                    .rawValue,
                            prompts: $0.catalog.prompts)
                    })
                try emitCatalog(
                    value,
                    json:
                        arguments.flags.contains("json"),
                    summary:
                        "\(value.servers.reduce(0) { $0 + $1.prompts.count }) prompt(s); prompt content remains untrusted and is never auto-inserted.")
            default:
                break
            }
            _ = live
        }
    case "refresh":
        try await withExistingLiveSession(
            context,
            arguments: arguments
        ) { live, connections in
            let caller = controlCallerFingerprint(
                action: "refresh",
                sessionID: live.runtime.sessionID,
                agentID: live.agentID)
            let selected = try await selectedConnections(
                connections,
                arguments: arguments,
                context: context)
            var refreshed: [MCPCLIConnectionReport] = []
            let aliases = try await aliasesByServer(context)
            for connection in selected {
                _ = try await live.runtime.refresh(
                    connection: connection,
                    callerFingerprint: caller)
                refreshed.append(connectionReport(
                    connection,
                    aliases: aliases))
            }
            if arguments.flags.contains("json") {
                try writeJSON(refreshed)
            } else {
                out(
                    "Refreshed \(refreshed.count) exact live MCP connection(s).\n")
            }
        }
    case "disconnect":
        try await withExistingLiveSession(
            context,
            arguments: arguments
        ) { live, connections in
            let caller = controlCallerFingerprint(
                action: "disconnect",
                sessionID: live.runtime.sessionID,
                agentID: live.agentID)
            let selected = try await selectedConnections(
                connections,
                arguments: arguments,
                context: context)
            for connection in selected {
                try await live.runtime.disconnect(
                    connection: connection,
                    callerFingerprint: caller)
            }
            if arguments.flags.contains("json") {
                try writeJSON([
                    "disconnected": selected.count,
                ])
            } else {
                out(
                    "Disconnected \(selected.count) exact live MCP connection(s).\n")
            }
        }
    default:
        throw MCPCLIError.unknownSubcommand(command)
    }
}

private func statusMCP(
    _ context: MCPCLIContext,
    _ arguments: MCPCLIParsedArguments
) async throws {
    let inventory = try await context.management.inventory()
    guard let rawSession = arguments.value("session") else {
        let value = MCPCLIStatusReport(
            sessionID: nil,
            agentID: nil,
            catalog: inventory,
            attachments: [],
            liveConnections: [])
        if arguments.flags.contains("json") {
            try writeJSON(value)
        } else if inventory.isEmpty {
            out("No MCP servers configured.\n")
        } else {
            for row in inventory {
                out(
                    "\(row.alias)\t\(row.setupStatus.rawValue)\t\(row.enabled ? "enabled" : "disabled")\t\(row.transport?.rawValue ?? "unknown")\n")
            }
        }
        return
    }

    let log = try await context.sessionLog(rawSession)
    let state = try await mcpSessionState(log)
    let catalog = try await context.management.catalog()
    let requestedAgent = arguments.value("agent").map {
        AgentID(rawValue: $0)
    }
    let attachments = state.attachments.values
        .sorted {
            $0.attachmentID.rawValue
                < $1.attachmentID.rawValue
        }
        .map { attachment in
            let head = catalog.head(
                for: attachment.server.serverID)
            let grants = state.grants.values.filter {
                $0.attachmentID == attachment.attachmentID
                    && $0.server == attachment.server
                    && $0.isActive()
                    && (requestedAgent == nil
                        || $0.agentID == requestedAgent)
            }
            return MCPCLIStatusReport.Attachment(
                alias: head?.alias
                    ?? attachment.server.serverID.rawValue,
                serverID:
                    attachment.server.serverID.rawValue,
                serverRevision:
                    attachment.server.serverRevision.rawValue,
                attachmentID:
                    attachment.attachmentID.rawValue,
                required: attachment.policy.required,
                approvalMode:
                    attachment.policy.approvalMode.rawValue,
                activeGrantCount: grants.count)
        }
    let retainedRuntime =
        await context.retainedRuntime(
            sessionID:
                SessionID(rawValue: rawSession))
    let liveConnections: [MCPCLIConnectionReport]
    if let retainedRuntime {
        let aliases = try await aliasesByServer(
            context)
        liveConnections =
            await retainedRuntime
                .liveConnectionSnapshots()
                .map {
                    connectionReport(
                        $0,
                        aliases: aliases)
                }
    } else {
        liveConnections = []
    }
    let value = MCPCLIStatusReport(
        sessionID: rawSession,
        agentID: requestedAgent?.rawValue,
        catalog: inventory,
        attachments: attachments,
        liveConnections: liveConnections)
    if arguments.flags.contains("json") {
        try writeJSON(value)
    } else {
        out(
            "Session \(rawSession): \(attachments.count) attachment(s); \(liveConnections.count) exact live connection(s) in this CLI process owner.\n")
        for row in attachments {
            out(
                "\(row.alias)\t\(row.required ? "required" : "optional")\t\(row.approvalMode)\t\(row.activeGrantCount) active grant(s)\n")
        }
        for row in liveConnections {
            out(
                "\(row.alias)\t\(row.connectionGeneration)\t\(row.negotiatedProtocolVersion)\tready\ttools=\(row.toolCount)\n")
        }
    }
}

func makeLiveSession(
    _ context: MCPCLIContext,
    arguments: MCPCLIParsedArguments
) async throws -> MCPCLILiveSession {
    let rawSession = try arguments.required("session")
    let agentID = AgentID(
        rawValue: try arguments.required("agent"))
    let taskID = arguments.value("task").map {
        TaskID(rawValue: $0)
    }
    let log = try await context.sessionLog(rawSession)
    let state = try await mcpSessionState(log)
    let capabilityMatches =
        state.capabilityLeases.values.filter {
            state.capabilityLeaseAgents[$0.id]
                == agentID
                && $0.taskID == taskID
        }
    guard capabilityMatches.count == 1,
          let capabilityLease =
            capabilityMatches.first else {
        throw MCPCLIError.durableLeaseRequired(
            "expected one capability lease for \(agentID.rawValue) and exact task \(taskID?.rawValue ?? "session-root"), found \(capabilityMatches.count)")
    }
    let workspaceMatches =
        state.workspaceLeases.values.filter {
            state.workspaceLeaseAgents[$0.id]
                == agentID
                && $0.taskID == taskID
                && $0.rootIdentity?
                    .matchesCurrentDirectory(
                        rootPath: $0.rootPath) == true
        }
    guard workspaceMatches.count == 1,
          let workspaceLease =
            workspaceMatches.first else {
        throw MCPCLIError.durableLeaseRequired(
            "expected one current workspace lease for \(agentID.rawValue) and exact task \(taskID?.rawValue ?? "session-root"), found \(workspaceMatches.count)")
    }
    let sessionID = await log.sessionID
    let retained =
        await context.retainedRuntime(
            sessionID: sessionID)
    let runtime: MCPCLIShippingRuntimeHandle
    let processRetained: Bool
    if let retained {
        runtime = retained
        processRetained = true
    } else {
        runtime = try await context.makeShippingRuntime(
            log: log,
            workspaceRoot:
                URL(fileURLWithPath:
                        workspaceLease.rootPath)
                    .standardizedFileURL)
        processRetained = false
    }
    return MCPCLILiveSession(
        agentID: agentID,
        capabilityLease: capabilityLease,
        workspaceLease: workspaceLease,
        runtime: runtime,
        processRetained: processRetained)
}

/// Runs one non-interactive Code turn against the exact durable session,
/// agent, task, capability lease, workspace lease, and MCP authorities.
///
/// The dynamic MCP snapshot is resolved before every provider dispatch.
/// Therefore a required connection/Test/consent failure exits non-zero without
/// sending any request to the inference provider.
@available(*, unavailable, message: "CLI execution uses Codex App Server")
func runExecCommand(
    _ raw: ArraySlice<String>
) async throws {
    let arguments = try MCPCLIParsedArguments(raw)
    let prompt =
        arguments.value("prompt")
        ?? arguments.positionals
            .joined(separator: " ")
            .trimmingCharacters(
                in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
        throw MCPCLIError
            .missingRequiredOption("prompt")
    }
    let config = try CLIConfig.load()
    let context = MCPCLIContext()
    let live = try await makeLiveSession(
        context,
        arguments: arguments)
    let terminal =
        ProcessTerminalSessionManager()
    do {
        let providers = ProviderRegistry(
            config: config.providerConfig(),
            resolver:
                CLIExactSecretResolver(
                    config: config))
        let route =
            try await providers
                .agentRuntimeRoute(
                    model: ModelID(
                        rawValue: config.model))
        let hostedWebSearch = live.capabilityLease.tools.contains(
            .hostedWebSearch)
            ? route.hostedWebSearch.map {
                ProviderHostedWebSearchToolService(route: $0)
            }
            : nil
        let skillSnapshot =
            try await SkillCatalogService.shared.snapshot(
                configuration: .standard(
                    workspaceRoot: URL(
                        fileURLWithPath:
                            live.workspaceLease.rootPath),
                    access: .workspaceAndGlobal),
                catalogBudget:
                    route.modelContextPolicy
                        .skillCatalogMetadataBudget)
        let baseRegistry = skillSnapshot.augmenting(
            ToolRegistry.standard(
                includesTerminal: true,
                hostedWebSearch: hostedWebSearch))
        let consent = arguments.flags
            .contains("yes")
            ? MCPCLIConsentConfirmation(
                callerFingerprint:
                    controlCallerFingerprint(
                        action:
                            "exec exact MCP authorities",
                        sessionID:
                            live.runtime.sessionID,
                        agentID: live.agentID))
            : nil
        let runtime = AgentRuntime.code(
            registry: baseRegistry,
            allowsShell: true,
            reasoningEffort:
                config.reasoningEffort,
            includeUsage: config.includeUsage,
            maxIterations: config.maxSteps,
            modelContextPolicy:
                route.modelContextPolicy)
        let agent = Agent(
            name: live.agentID,
            workspaceRoot:
                URL(fileURLWithPath:
                        live.workspaceLease.rootPath)
                    .standardizedFileURL,
            model: route.model,
            profile: .reviewed)
        let loop = runtime.makeLoop(
            log: live.runtime.log,
            provider: route.provider,
            responder: TerminalResponder(),
            agent: agent,
            context: ContextBuilder(
                skillSnapshot: skillSnapshot,
                runtimeEnvironment: .code),
            terminal: terminal,
            capabilityLease:
                live.capabilityLease,
            workspaceLease:
                live.workspaceLease,
            rootTaskID:
                live.capabilityLease.taskID,
            toolSnapshotProvider: {
                capabilities,
                outputBudget in
                try await live.runtime.snapshot(
                    agentID: live.agentID,
                    capabilityLease:
                        live.capabilityLease,
                    workspaceLease:
                        live.workspaceLease,
                    baseRegistry: baseRegistry,
                    reason: .send,
                    providerCapabilities:
                        capabilities,
                    turnResultBudget:
                        outputBudget,
                    consentConfirmation:
                        consent)
            })
        let answer = try await loop.send(prompt)
        await terminal.shutdown(
            reason: "CLI exec completed")
        _ = await live.runtime.shutdown(
            reason: "CLI exec completed")
        out(answer)
        if !answer.hasSuffix("\n") {
            out("\n")
        }
    } catch {
        await terminal.shutdown(
            reason: "CLI exec failed")
        _ = await live.runtime.shutdown(
            reason: "CLI exec failed")
        throw error
    }
}

private func withOneShotLiveSession<T: Sendable>(
    _ context: MCPCLIContext,
    arguments: MCPCLIParsedArguments,
    operation:
        @escaping @Sendable (
            MCPCLILiveSession
        ) async throws -> T
) async throws -> T {
    let live = try await makeLiveSession(
        context,
        arguments: arguments)
    do {
        let value = try await operation(live)
        if !live.processRetained {
            _ = await live.runtime.shutdown(
                reason:
                    "MCP CLI one-shot command completed")
        }
        return value
    } catch {
        if !live.processRetained {
            _ = await live.runtime.shutdown(
                reason:
                    "MCP CLI one-shot command failed")
        }
        throw error
    }
}

private func withConnectedOneShotSession<T: Sendable>(
    _ context: MCPCLIContext,
    arguments: MCPCLIParsedArguments,
    action: String,
    operation:
        @escaping @Sendable (
            MCPCLILiveSession,
            MCPConnectionSetSnapshot
        ) async throws -> T
) async throws -> T {
    try await withOneShotLiveSession(
        context,
        arguments: arguments
    ) { live in
        let confirmation = try controlConfirmation(
            arguments,
            action:
                "\(action) exact MCP authorities for session \(live.runtime.sessionID.rawValue)")
        let snapshot = try await live.runtime.connect(
            agentID: live.agentID,
            capabilityLease: live.capabilityLease,
            workspaceLease: live.workspaceLease,
            baseRegistry: managementRegistry(),
            confirmation: confirmation)
        return try await operation(live, snapshot)
    }
}

/// Refresh and Disconnect never manufacture a connection. A future
/// long-lived CLI REPL owner can pass its retained handle through this same
/// seam; a one-shot process therefore fails closed when no generation exists.
private func withExistingLiveSession<T: Sendable>(
    _ context: MCPCLIContext,
    arguments: MCPCLIParsedArguments,
    operation:
        @escaping @Sendable (
            MCPCLILiveSession,
            [MCPConnectionSnapshot]
        ) async throws -> T
) async throws -> T {
    try await withOneShotLiveSession(
        context,
        arguments: arguments
    ) { live in
        let connections =
            await live.runtime.liveConnectionSnapshots()
        guard !connections.isEmpty else {
            throw MCPCLILiveCommandError
                .noLiveConnection
        }
        return try await operation(live, connections)
    }
}

private func selectedConnections(
    _ connections: [MCPConnectionSnapshot],
    arguments: MCPCLIParsedArguments,
    context: MCPCLIContext
) async throws -> [MCPConnectionSnapshot] {
    guard let target = arguments.value("server") else {
        return connections
    }
    let definition = try await context.management.definition(
        serverOrAlias: target)
    let matches = connections.filter {
        $0.bindingIdentity.server
            == definition.reference
    }
    guard !matches.isEmpty else {
        throw MCPCLILiveCommandError
            .targetConnectionMissing(target)
    }
    guard matches.count == 1 else {
        throw MCPCLILiveCommandError
            .ambiguousTarget(target)
    }
    return matches
}

private func aliasesByServer(
    _ context: MCPCLIContext
) async throws -> [MCPServerID: String] {
    Dictionary(
        uniqueKeysWithValues:
            try await context.management.inventory()
                .map { ($0.serverID, $0.alias) })
}

private func alias(
    for connection: MCPConnectionSnapshot,
    aliases: [MCPServerID: String]
) -> String {
    aliases[
        connection.bindingIdentity.server.serverID]
        ?? connection.bindingIdentity.server
            .serverID.rawValue
}

private func connectionReport(
    _ connection: MCPConnectionSnapshot,
    aliases: [MCPServerID: String]
) -> MCPCLIConnectionReport {
    let binding = connection.bindingIdentity
    let authority =
        connection.reuseIdentity.authority
    return MCPCLIConnectionReport(
        alias: alias(
            for: connection,
            aliases: aliases),
        serverID: binding.server.serverID.rawValue,
        serverRevision:
            binding.server.serverRevision.rawValue,
        attachmentID:
            authority.attachmentID.rawValue,
        connectionGeneration:
            binding.connectionGeneration.rawValue,
        rawCatalogRevision:
            binding.rawCatalogRevision.rawValue,
        agentCatalogViewRevision:
            binding.agentCatalogViewRevision.rawValue,
        bindingID: binding.bindingID.rawValue,
        protocolProfile:
            binding.protocolProfile.rawValue,
        maximumProtocolVersion:
            binding.maximumProtocolVersion.rawValue,
        negotiatedProtocolVersion:
            binding.negotiatedProtocolVersion
                .value.rawValue,
        toolCount: connection.catalog.tools.count,
        resourceCount:
            connection.catalog.resources.count,
        resourceTemplateCount:
            connection.catalog.resourceTemplates.count,
        promptCount:
            connection.catalog.prompts.count)
}

private func emitConnections(
    _ connections: [MCPConnectionSnapshot],
    aliases: [MCPServerID: String],
    json: Bool,
    verb: String
) throws {
    let values = connections.map {
        connectionReport($0, aliases: aliases)
    }
    if json {
        try writeJSON(values)
    } else {
        for value in values {
            out(
                "\(value.alias)\t\(value.connectionGeneration)\t\(value.rawCatalogRevision)\t\(value.negotiatedProtocolVersion)\ttools=\(value.toolCount) resources=\(value.resourceCount) prompts=\(value.promptCount)\n")
        }
        out("\(verb) \(values.count) MCP server(s).\n")
    }
}

private func emitCatalog<T: Encodable>(
    _ value: T,
    json: Bool,
    summary: String
) throws {
    if json {
        try writeJSON(value)
    } else {
        out("\(summary)\n")
        try writeJSON(value)
    }
}

private func managementRegistry() -> ToolRegistry {
    ToolRegistry(
        [],
        registryVersion:
            IntatisHostApplication.identity
                .namespacedIdentifier("cli.mcp.management.v1"))
}

private func controlConfirmation(
    _ arguments: MCPCLIParsedArguments,
    action: String
) throws -> MCPCLIConsentConfirmation {
    if !arguments.flags.contains("yes") {
        guard isatty(STDIN_FILENO) == 1 else {
            throw MCPCLIError.confirmationRequired
        }
        out("\(action)? [y/N] ")
        let answer = readLine()?
            .trimmingCharacters(
                in: .whitespacesAndNewlines)
            .lowercased()
        guard answer == "y" || answer == "yes" else {
            throw MCPCLIError.confirmationRequired
        }
    }
    let session = SessionID(
        rawValue:
            arguments.value("session") ?? "missing")
    let agent = AgentID(
        rawValue:
            arguments.value("agent") ?? "missing")
    return MCPCLIConsentConfirmation(
        callerFingerprint:
            controlCallerFingerprint(
                action: action,
                sessionID: session,
                agentID: agent))
}

private func controlCallerFingerprint(
    action: String,
    sessionID: SessionID,
    agentID: AgentID
) -> String {
    MCPHostDigest.sha256([
        IntatisHostApplication.identity.temporaryPrefix(
            "cli-mcp-control-v1"),
        action,
        sessionID.rawValue,
        agentID.rawValue,
        String(ProcessInfo.processInfo
            .processIdentifier),
    ])
}
