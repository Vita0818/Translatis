import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation
import IntatisCodexRuntime
import IntatisCowork
import IntatisTools
import IntatisAgentKernel
import IntatisMCP

private enum CodexCLIStyle {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let cyan = "\u{001B}[36m"
}

private var codexCLIHelp: String {
    let identity = IntatisHostApplication.identity
    return """
  Codex Runtime commands
  /goal <objective>          set the official Codex thread goal and run it
  /agents                    list native Codex subagents and exact runtime state
  /thread <agent>            read one subagent's complete Codex conversation
  /archive <agent>           archive one native subagent and retain its history
  @agent <message>           send through the native Codex agent control plane
  /model                     show the fixed Responses model for this runtime
  /config                    show the safe runtime route summary
  /mode <chat|code|cowork>   switch \(identity.name) surface
  /auto                      show automatic approval-review status
  /attach                    not exposed in this first CLI runtime version
  /mcp <command> [...]       manage root native MCP authority; grants use complete Interactive access
  /clear                     start a new \(identity.name) session from the UI (next slice)
  /help                      show this help
  /exit                      stop the runtime and quit

  The CLI uses codex app-server 0.145.0-intatis.4, an isolated CODEX_HOME, and the
  selected \(identity.name) Responses route. First-party document, browser, image, and
  exact-route hosted-search tools are registered directly through App Server dynamicTools.
  ChatGPT login is never
  consulted.

"""
}

func codexRuntimeREPL(
    _ config: CLIConfig,
    mode: Mode,
    workspace: URL
) async throws -> REPLExit {
    precondition(mode == .code || mode == .cowork)
    let canonicalWorkspace = workspace
        .resolvingSymlinksInPath()
        .standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
        atPath: canonicalWorkspace.path,
        isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw IntatisError.config(
            "Codex Runtime workspace is not an existing directory")
    }

    let inferenceProfiles = mode == .cowork
        ? try await CLIInferenceProfiles.load(config: config)
        : nil
    let registry = ProviderRegistry(
        config: config.providerConfig(),
        resolver: CLIExactSecretResolver(config: config),
        inferenceCatalogSnapshot: inferenceProfiles?.snapshot)
    let resolvedRoute: ResolvedCodexRuntimeRoute
    if let inferenceProfiles {
        resolvedRoute = try await registry.codexRuntimeRoute(
            for: inferenceProfiles.defaultBinding)
    } else {
        resolvedRoute = try await registry.codexRuntimeRoute(
            model: ModelID(rawValue: config.model))
    }
    let route = resolvedRoute.responses
    var hostedWebSearchServices:
        [CodexRuntimeHostedWebSearchScope:
            any HostedWebSearchToolService] = [:]
    if let hostedWebSearch = resolvedRoute.hostedWebSearch {
        hostedWebSearchServices[.root] =
            ProviderHostedWebSearchToolService(
                route: hostedWebSearch)
    }
    let knowledgeConfigurationNotice =
        cliKnowledgeToolsConfigurationNotice(config: config)
    let knowledgeAugmenter = makeCLIKnowledgeToolAugmenter(
        config: config,
        registry: registry)
    let configuredKnowledgeCapabilities = knowledgeAugmenter?
        .additionalCapabilities
        .intersection([.buildKnowledge, .searchKnowledge]) ?? []
    var childProfiles: [CodexRuntimeChildProfile] = []
    var excludedChildProfileModels: [String] = []
    if let inferenceProfiles {
        childProfiles.reserveCapacity(inferenceProfiles.options.count)
        for option in inferenceProfiles.options {
            let roleName = try codexCLIProfileRoleName(option)
            let capabilities = option.declaredCapabilities
                .map(\.rawValue)
                .sorted()
            let capabilityDescription = capabilities.isEmpty
                ? "no additional declared capabilities"
                : "declared capabilities: "
                    + capabilities.joined(separator: ", ")
            let childRoute: ResolvedCodexRuntimeRoute
            do {
                childRoute = try await registry.codexRuntimeRoute(
                    for: option.binding)
            } catch {
                excludedChildProfileModels.append(
                    option.modelID.rawValue)
                continue
            }
            let hostedWebSearchScope =
                CodexRuntimeHostedWebSearchScope.childRole(
                    roleName)
            if let hostedWebSearch = childRoute.hostedWebSearch {
                hostedWebSearchServices[hostedWebSearchScope] =
                    ProviderHostedWebSearchToolService(
                        route: hostedWebSearch)
            }
            childProfiles.append(CodexRuntimeChildProfile(
                roleName: roleName,
                description: "Configured \(option.modelID.rawValue) · \(option.variantDescription) · \(capabilityDescription).",
                workspaceURL: canonicalWorkspace,
                route: childRoute.responses,
                sandbox: .workspaceWrite,
                permissionProfile: .reviewed,
                knowledgeCapabilities:
                    configuredKnowledgeCapabilities,
                hostedWebSearchEnabled:
                    childRoute.hostedWebSearch != nil))
        }
    }
    for model in excludedChildProfileModels.sorted() {
        errOut(
            "notice: configured model \(model) is not advertised as a Codex child preset because its exact route cannot be represented by the pinned Responses runtime\n")
    }
    let identity = try codexCLISessionIdentity(
        mode: mode,
        workspace: canonicalWorkspace)
    let toolLog = try EventLog(
        session: identity.sessionID,
        fileURL: identity.toolEventLogURL)
    let rootAgentID = AgentID(
        rawValue: mode == .cowork ? "main" : "Coder")
    let rootCapabilityLeaseID = CapabilityLeaseID(
        rawValue: "clease_cli_codex_\(identity.sessionID.rawValue)")
    let workTaskController: CodexWorkTaskController? = mode == .cowork
        ? CodexWorkTaskController(
            log: toolLog,
            rootAgentID: rootAgentID)
        : nil
    let workTaskManagerResolver:
        CodexBusinessToolHost.WorkTaskManagerResolver?
    if let workTaskController {
        workTaskManagerResolver = { agentID in
            await workTaskController.manager(
                for: agentID)
        }
    } else {
        workTaskManagerResolver = nil
    }
    let workspaceLease = WorkspaceLease(
        id: WorkspaceLeaseID(
            rawValue: "wlease_cli_codex_\(identity.sessionID.rawValue)"),
        workspaceID: WorkspaceID(
            rawValue: "workspace_cli_codex_\(identity.sessionID.rawValue)"),
        rootPath: canonicalWorkspace.path,
        access: .readWrite)
    let rootCapabilityLease = CodexBusinessToolHost
        .rootBusinessCapabilityLease(
            id: rootCapabilityLeaseID,
            workspaceAccess: .readWrite,
            includesSessionNaming: true,
            includesWorkTaskManagement: mode == .cowork,
            includesHostedWebSearch:
                resolvedRoute.hostedWebSearch != nil,
            knowledgeCapabilities: configuredKnowledgeCapabilities)
    let mcpContext = MCPCLIContext()
    try await mcpContext.bindInteractiveSessionLog(
        toolLog,
        nativeCodexRootAgentID: rootAgentID)
    try await ensureCodexCLIRootLeases(
        log: toolLog,
        agentID: rootAgentID,
        capabilityLease: rootCapabilityLease,
        workspaceLease: workspaceLease)
    let nativeMCP: CodexRuntimeMCPConfiguration
    do {
        nativeMCP = try await mcpContext.codexRuntimeConfiguration(
            log: toolLog,
            agentID: rootAgentID,
            capabilityLeaseID: rootCapabilityLeaseID)
    } catch MCPSecretStoreError.locked {
        try await mcpContext.unlockSecrets(createIfMissing: false)
        nativeMCP = try await mcpContext.codexRuntimeConfiguration(
            log: toolLog,
            agentID: rootAgentID,
            capabilityLeaseID: rootCapabilityLeaseID)
    }
    let nativeSkills = try CodexRuntimeSkillConfiguration
        .hostUserCodexHome()
    let businessToolHost = try CodexBusinessToolHost(
        sessionID: identity.sessionID,
        agentID: rootAgentID,
        workspaceURL: canonicalWorkspace,
        workspaceLease: workspaceLease,
        childProfiles: childProfiles,
        additionalRegistrations: mode == .cowork
            ? CodexWorkTaskToolRegistry.registrations
            : [],
        registryAugmenter: knowledgeAugmenter,
        workTaskManagerResolver: workTaskManagerResolver,
        imageGenerator: ProviderImageGenerationToolService(
            registry: registry),
        hostedWebSearchServices: hostedWebSearchServices,
        sessionNaming: EventLogSessionNamingService(
            log: toolLog,
            kind: mode == .cowork ? .cowork : .code),
        allowsShell: true,
        log: toolLog,
        permissionResolver: { request in
            let source = request.agent.map {
                " · @\($0.rawValue.replacingOccurrences(of: "codex:", with: ""))"
            } ?? ""
            out("\n\(CodexCLIStyle.yellow)Permission\(source) · \(request.tool)\(CodexCLIStyle.reset)\n")
            out(request.reason + "\n")
            out("Approve? [y]es / [a]lways this session / [n]o / [c]ancel turn: ")
            let answer = Swift.readLine()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? "n"
            switch answer {
            case "y", "yes":
                return PermissionApprovalResolution(
                    decision: .allow,
                    action: .approve,
                    reason: "Permission approved by user",
                    risk: request.risk,
                    source: .user)
            case "a", "always":
                return PermissionApprovalResolution(
                    decision: .allow,
                    action: .approveAndRemember,
                    reason: "Permission approved by user",
                    risk: request.risk,
                    source: .user)
            case "c", "cancel":
                return PermissionApprovalResolution(
                    decision: .deny,
                    action: .cancelTurn,
                    reason: "Turn cancelled by user",
                    risk: request.risk,
                    source: .user,
                    failureSource: .userCancelled)
            default:
                return PermissionApprovalResolution(
                    decision: .deny,
                    action: .decline,
                    reason: "Permission declined by user",
                    risk: request.risk,
                    source: .user,
                    failureSource: .userDenied)
            }
        })
    let dynamicTools = try await businessToolHost.dynamicTools()
    let runtime = CodexAppServerSession(configuration:
        CodexRuntimeConfiguration(
            sessionID: identity.sessionID,
            mode: mode == .cowork ? .cowork : .code,
            workspaceURL: canonicalWorkspace,
            runtimeRootURL: identity.runtimeRoot,
            route: route,
            approvalReviewer: .automatic,
            reasoningEffort: config.reasoningEffort?.rawValue
                ?? route.reasoningEffort,
            dynamicTools: dynamicTools,
            mcpConfiguration: nativeMCP,
            skillConfiguration: nativeSkills,
            childProfiles: childProfiles,
            inheritedChildKnowledgeCapabilities:
                mode == .cowork
                    ? configuredKnowledgeCapabilities
                    : [],
            rootHostedWebSearchEnabled:
                resolvedRoute.hostedWebSearch != nil,
            rootPermissionProfile: .reviewed,
            pauseActiveGoalBeforeResume: mode == .cowork))
    let events = await runtime.events()
    let eventTask = Task {
        var streamedMessageIDs: Set<String> = []
        var childNamesByThreadID: [String: String] = [:]
        var childTaskNamesByThreadID: [String: String] = [:]
        for await event in events {
            guard !Task.isCancelled else { return }
            switch event {
            case .ready(let identity):
                out("\(CodexCLIStyle.dim)Codex Runtime \(identity.runtimeVersion) · thread \(identity.threadID.prefix(8))… ready\(CodexCLIStyle.reset)\n")
            case .turnStarted:
                break
            case .assistantDelta(let itemID, let text, let phase):
                streamedMessageIDs.insert(itemID)
                if phase == .commentary {
                    out(CodexCLIStyle.dim + text + CodexCLIStyle.reset)
                } else {
                    out(text)
                }
            case .assistantCompleted(let itemID, let text, let phase):
                if streamedMessageIDs.remove(itemID) != nil {
                    out("\n")
                } else if phase == .commentary {
                    out(CodexCLIStyle.dim + text + CodexCLIStyle.reset + "\n")
                } else {
                    out(text + "\n")
                }
            case .reasoningDelta:
                break
            case .appServerEvent(let event):
                var fields: [String] = []
                if let itemType = event.itemType {
                    fields.append("type: \(itemType)")
                }
                if let phase = event.phase {
                    fields.append("phase: \(phase.rawValue)")
                }
                if let status = event.status {
                    fields.append("status: \(status)")
                }
                if let textDelta = event.textDelta {
                    fields.append(textDelta)
                }
                let detail = fields.isEmpty
                    ? ""
                    : "\n" + fields.joined(separator: "\n")
                out("\n\(CodexCLIStyle.dim)\(event.method)\(detail)\(CodexCLIStyle.reset)\n")
            case .itemStarted, .itemCompleted:
                break
            case .approvalRequested(let request):
                let source = childNamesByThreadID[request.threadID]
                    .map { " · @\($0)" }
                    ?? ""
                out("\n\(CodexCLIStyle.yellow)Permission\(source) · \(request.title)\(CodexCLIStyle.reset)\n")
                out(request.summary + "\n")
                out("Approve? [y]es / [a]lways this session / [n]o / [c]ancel turn: ")
                let answer = Swift.readLine()?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? "n"
                let decision: CodexRuntimeApprovalDecision
                switch answer {
                case "y", "yes": decision = .accept
                case "a", "always": decision = .acceptForSession
                case "c", "cancel": decision = .cancel
                default: decision = .decline
                }
                do {
                    try await runtime.resolveApproval(
                        requestID: request.requestID,
                        decision: decision)
                } catch {
                    errOut("approval failed: \(error.localizedDescription)\n")
                }
            case .approvalResolved:
                break
            case .responsesUsage(let usage):
                let duration = usage.durationMs.map(String.init)
                    ?? "unknown"
                out(
                    "\(CodexCLIStyle.dim)input=\(usage.inputTokens) "
                    + "cache_hit=\(usage.cachedInputTokens) "
                    + "cache_write=\(usage.cacheWriteInputTokens) "
                    + "output=\(usage.outputTokens) "
                    + "reasoning=\(usage.reasoningOutputTokens) "
                    + "total=\(usage.totalTokens) "
                    + "duration_ms=\(duration)"
                    + "\(CodexCLIStyle.reset)\n")
            case .goalUpdated(let goal):
                if let goal {
                    let budget = goal.tokenBudget.map(String.init)
                        ?? "unlimited"
                    out(
                        "\(CodexCLIStyle.dim)goal \(goal.status) · "
                        + "\(goal.tokensUsed)/\(budget) tokens · "
                        + "\(goal.objective)\(CodexCLIStyle.reset)\n")
                } else {
                    out("\(CodexCLIStyle.dim)goal cleared\(CodexCLIStyle.reset)\n")
                }
            case .turnCompleted:
                break
            case .runtimeError(_, let message, _):
                errOut("runtime: \(message)\n")
            case .child(let childEvent):
                switch childEvent {
                case .threadUpdated(let thread):
                    childNamesByThreadID[thread.threadID] =
                        thread.displayName
                    if let workTaskController,
                       thread.isArchived || thread.status == "shutdown" {
                        if let previous = childTaskNamesByThreadID
                            .removeValue(forKey: thread.threadID) {
                            await workTaskController.agentDirectory.unregister(
                                taskName: previous,
                                verifiedAgentID: thread.agentID)
                        }
                    } else if let taskName = thread.agentPath,
                              let workTaskController {
                        do {
                            let previous = childTaskNamesByThreadID[
                                thread.threadID]
                            try await workTaskController.agentDirectory.replace(
                                previousTaskName: previous,
                                taskName: taskName,
                                verifiedAgentID: thread.agentID)
                            childTaskNamesByThreadID[thread.threadID] =
                                taskName
                        } catch {
                            errOut(
                                "runtime: canonical Codex task identity is ambiguous; WorkTask linking is disabled for @\(thread.displayName)\n")
                        }
                    }
                    out(
                        "\n\(CodexCLIStyle.dim)@\(thread.displayName) · "
                        + "\(thread.status) · thread "
                        + "\(thread.threadID.prefix(8))…"
                        + "\(CodexCLIStyle.reset)\n")
                case .assistantDelta(
                    let threadID,
                    _,
                    let itemID,
                    let text,
                    _):
                    let key = "\(threadID):\(itemID)"
                    if streamedMessageIDs.insert(key).inserted {
                        let name = childNamesByThreadID[threadID]
                            ?? String(threadID.prefix(8))
                        out("\n\(CodexCLIStyle.dim)[@\(name)] \(CodexCLIStyle.reset)")
                    }
                    out(CodexCLIStyle.dim + text + CodexCLIStyle.reset)
                case .assistantCompleted(
                    let threadID,
                    _,
                    let itemID,
                    let text,
                    _):
                    let key = "\(threadID):\(itemID)"
                    if streamedMessageIDs.remove(key) != nil {
                        out("\n")
                    } else {
                        let name = childNamesByThreadID[threadID]
                            ?? String(threadID.prefix(8))
                        out("\n\(CodexCLIStyle.dim)[@\(name)] \(text)\(CodexCLIStyle.reset)\n")
                    }
                case .turnStarted,
                     .userMessage,
                     .reasoningDelta,
                     .appServerEvent,
                     .itemStarted,
                     .itemCompleted,
                     .responsesUsage,
                     .turnCompleted:
                    break
                }
            }
        }
    }
    do {
        _ = try await runtime.start()
    } catch {
        eventTask.cancel()
        await runtime.shutdown()
        throw error
    }

    func childDescriptor(
        named rawName: String,
        requiresLiveInput: Bool = false
    ) async throws -> CodexRuntimeThreadDescriptor {
        var name = rawName.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if name.hasPrefix("@") {
            name.removeFirst()
        }
        let all = await runtime.descendantThreadDescriptors()
        let exact = all.filter {
            let taskName = $0.agentPath?
                .split(separator: "/")
                .last
                .map(String.init)
            return $0.displayName == name
                || $0.threadID == name
                || $0.agentPath == name
                || taskName == name
        }
        let matches: [CodexRuntimeThreadDescriptor]
        if exact.isEmpty {
            let folded = name.lowercased()
            matches = all.filter {
                let taskName = $0.agentPath?
                    .split(separator: "/")
                    .last?
                    .lowercased()
                return $0.displayName.lowercased() == folded
                    || $0.agentPath?.lowercased() == folded
                    || taskName == folded
            }
        } else {
            matches = exact
        }
        guard matches.count == 1,
              let descriptor = matches.first else {
            if matches.count > 1 {
                throw IntatisError.config(
                    "More than one Codex subagent matches @\(name).")
            }
            throw IntatisError.config(
                "No Codex subagent matches @\(name).")
        }
        if requiresLiveInput,
           descriptor.isArchived || descriptor.status == "shutdown" {
            throw IntatisError.config(
                "@\(descriptor.displayName) has ended; its conversation is read-only.")
        }
        return descriptor
    }

    func printAgents() async {
        let descriptors = await runtime.descendantThreadDescriptors()
        guard !descriptors.isEmpty else {
            out("No native Codex subagents in this session.\n")
            return
        }
        let descriptorsByID = Dictionary(
            uniqueKeysWithValues: descriptors.map { ($0.threadID, $0) })

        func displayedInference(
            for descriptor: CodexRuntimeThreadDescriptor,
            visited: Set<String> = []
        ) -> (provider: String, model: String, effort: String?)? {
            guard !visited.contains(descriptor.threadID) else { return nil }
            var visited = visited
            visited.insert(descriptor.threadID)

            if let model = descriptor.requestedModel,
               !model.isEmpty {
                return (
                    descriptor.modelProvider.isEmpty
                        ? IntatisHostApplication.identity.fileNameStem
                        : descriptor.modelProvider,
                    model,
                    descriptor.reasoningEffort)
            }
            if let role = descriptor.agentRole {
                guard let profile = childProfiles.first(where: {
                    $0.roleName == role
                }) else { return nil }
                return (
                    descriptor.modelProvider.isEmpty
                        ? IntatisHostApplication.identity.fieldNameStem
                            + "_agent_" + role
                        : descriptor.modelProvider,
                    profile.route.model.rawValue,
                    descriptor.reasoningEffort
                        ?? profile.route.reasoningEffort)
            }
            if descriptor.parentThreadID == descriptor.sessionID {
                return (
                    descriptor.modelProvider.isEmpty
                        ? IntatisHostApplication.identity.fileNameStem
                        : descriptor.modelProvider,
                    route.model.rawValue,
                    descriptor.reasoningEffort
                        ?? config.reasoningEffort?.rawValue
                        ?? route.reasoningEffort)
            }
            guard let parent = descriptorsByID[
                descriptor.parentThreadID],
                  let inherited = displayedInference(
                    for: parent,
                    visited: visited) else {
                return nil
            }
            return (
                descriptor.modelProvider.isEmpty
                    ? inherited.provider
                    : descriptor.modelProvider,
                inherited.model,
                descriptor.reasoningEffort ?? inherited.effort)
        }

        for descriptor in descriptors {
            let inference = displayedInference(for: descriptor)
            let provider = inference?.provider
                ?? (descriptor.modelProvider.isEmpty
                    ? "unknown provider"
                    : descriptor.modelProvider)
            let model = inference?.model ?? "unknown model"
            let effort = inference?.effort
                .map { " · effort \($0)" } ?? ""
            let tier = descriptor.serviceTier
                .map { " · tier \($0)" } ?? ""
            let archived = descriptor.isArchived ? " · archived" : ""
            out(
                "@\(descriptor.displayName) · \(descriptor.status)"
                + " · \(provider)/\(model)"
                + effort + tier + archived + "\n")
            out(
                "  thread \(descriptor.threadID) · parent "
                + "\(descriptor.parentThreadID) · cwd \(descriptor.cwd)\n")
        }
    }

    func printThread(_ descriptor: CodexRuntimeThreadDescriptor) async throws {
        let history = try await runtime.threadHistory(
            threadID: descriptor.threadID)
        guard !history.items.isEmpty else {
            out("@\(descriptor.displayName) has no conversation items.\n")
            return
        }
        for item in history.items {
            switch item {
            case .user(_, _, let text):
                out("\n\(CodexCLIStyle.green)you → @\(descriptor.displayName)\(CodexCLIStyle.reset)\n")
                out(text + "\n")
            case .assistant(_, _, let text, let phase, _):
                let phaseLabel = phase.map { " · \($0.rawValue)" } ?? ""
                out("\n\(CodexCLIStyle.cyan)@\(descriptor.displayName)\(phaseLabel)\(CodexCLIStyle.reset)\n")
                out(text + "\n")
            case .runtime(_, let item):
                let status = item.status.map { " · \($0)" } ?? ""
                out("\n\(CodexCLIStyle.dim)[\(item.kind.rawValue)] \(item.title)\(status)\(CodexCLIStyle.reset)\n")
                if !item.detail.isEmpty {
                    out(item.detail + "\n")
                }
            }
        }
    }

    let editor = LineEditor()
    out("\n\(CodexCLIStyle.bold)\(IntatisHostApplication.identity.name)\(CodexCLIStyle.reset) \(CodexCLIStyle.dim)·\(CodexCLIStyle.reset) \(CodexCLIStyle.cyan)\(mode.rawValue)\(CodexCLIStyle.reset) \(CodexCLIStyle.dim)· Codex Runtime · \(config.model)\(CodexCLIStyle.reset)\n")
    out("\(CodexCLIStyle.dim)/help for commands · /mode to switch · /exit to quit\(CodexCLIStyle.reset)\n")
    if let knowledgeConfigurationNotice {
        out("\(CodexCLIStyle.yellow)\(knowledgeConfigurationNotice)\(CodexCLIStyle.reset)\n")
    }

    func finish(_ result: REPLExit) async -> REPLExit {
        eventTask.cancel()
        await runtime.shutdown()
        await eventTask.value
        await mcpContext.unbindInteractiveSessionLog(toolLog)
        return result
    }

    while true {
        let line: String
        switch editor.readLine(
            prompt: "\n\(CodexCLIStyle.green)\(mode.rawValue) ❯\(CodexCLIStyle.reset) ") {
        case .eof, .shortcut(.exit):
            return await finish(.quit)
        case .shortcut(.cycleMode):
            return await finish(.switchTo(codexNextMode(mode)))
        case .shortcut(.switchModel):
            out("model is fixed to the selected \(IntatisHostApplication.identity.name) Responses route for this runtime: \(config.model)\n")
            continue
        case .shortcut(.settings):
            try runSettings()
            out("settings saved — restart this runtime to apply route changes\n")
            continue
        case .text(let value):
            line = value
        }
        let text = line.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if text.isEmpty { continue }

        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(
                separator: " ",
                maxSplits: 1).map(String.init)
            let command = parts.first?.lowercased() ?? ""
            let argument = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces)
                : ""
            switch command {
            case "help":
                out(codexCLIHelp)
                continue
            case "exit", "quit":
                return await finish(.quit)
            case "mode":
                guard let next = Mode(rawValue: argument.lowercased()) else {
                    out("usage: /mode chat|code|cowork\n")
                    continue
                }
                if next == mode {
                    out("already in \(mode.rawValue)\n")
                    continue
                }
                return await finish(.switchTo(next))
            case "model":
                out("model: \(config.model) · Responses API\n")
                continue
            case "agents":
                guard mode == .cowork else {
                    out("/agents is available in Cowork mode.\n")
                    continue
                }
                await printAgents()
                continue
            case "thread":
                guard mode == .cowork, !argument.isEmpty else {
                    out("usage: /thread <agent>\n")
                    continue
                }
                do {
                    let descriptor = try await childDescriptor(
                        named: argument)
                    try await printThread(descriptor)
                } catch {
                    errOut("error: \(error.localizedDescription)\n")
                }
                continue
            case "archive":
                guard mode == .cowork, !argument.isEmpty else {
                    out("usage: /archive <agent>\n")
                    continue
                }
                do {
                    let descriptor = try await childDescriptor(
                        named: argument,
                        requiresLiveInput: true)
                    try await runtime.archiveDescendantThread(
                        threadID: descriptor.threadID)
                    out("@\(descriptor.displayName) archived; its Codex history remains readable.\n")
                } catch {
                    errOut("error: \(error.localizedDescription)\n")
                }
                continue
            case "config":
                out("\(config.selectedRouteLabel) · endpoint hidden · model \(config.model) · session \(identity.sessionID.rawValue) · Codex Runtime \(CodexAppServerSession.pinnedRuntimeVersion)\n")
                continue
            case "auto":
                out("approval reviewer: Codex auto_review\n")
                continue
            case "attach":
                out("attachments are not exposed by this first CLI Codex Runtime slice; macOS Code/Cowork image attachments are supported\n")
                continue
            case "mcp":
                let arguments = argument.split(
                    whereSeparator: \.isWhitespace).map(String.init)
                guard !arguments.isEmpty else {
                    out("usage: /mcp <command> [options]; run /mcp help for details\n")
                    continue
                }
                do {
                    try await runMCPCommand(
                        ArraySlice(arguments),
                        context: mcpContext)
                    out("If MCP authority changed, restart this Code/Cowork runtime to project the new exact native configuration.\n")
                } catch {
                    errOut("error: \(error.localizedDescription)\n")
                }
                continue
            case "clear":
                out("/clear is intentionally unavailable until App Server thread replacement is wired without deleting history\n")
                continue
            case "goal":
                guard !argument.isEmpty else {
                    out("usage: /goal <objective>\n")
                    continue
                }
                do {
                    try await runtime.setGoal(objective: argument)
                } catch {
                    errOut("error: \(error.localizedDescription)\n")
                }
                continue
            default:
                out("unknown command /\(command) — /help\n")
                continue
            }
        }

        if mode == .cowork, text.hasPrefix("@") {
            let route = CoworkMentionRouter.routeSubmittedIntent(
                input: text,
                defaultTarget: AgentID(rawValue: "main"))
            switch route.outcome {
            case .blocked(let error):
                errOut("error: \(error.message)\n")
            case .send(let message, let target):
                if target.rawValue.lowercased() == "main" {
                    do {
                        _ = try await runtime.runTurn(text: message)
                    } catch {
                        errOut("error: \(error.localizedDescription)\n")
                    }
                } else {
                    do {
                        let descriptor = try await childDescriptor(
                            named: target.rawValue,
                            requiresLiveInput: true)
                        let submissionID = try await runtime.sendMessage(
                            toDescendantThreadID: descriptor.threadID,
                            text: message,
                            triggerTurn: true)
                        out("@\(descriptor.displayName) received native message \(submissionID).\n")
                    } catch {
                        errOut("error: \(error.localizedDescription)\n")
                    }
                }
            }
            continue
        }

        do {
            _ = try await runtime.runTurn(text: text)
        } catch {
            errOut("error: \(error.localizedDescription)\n")
        }
    }
}

private func ensureCodexCLIRootLeases(
    log: EventLog,
    agentID: AgentID,
    capabilityLease: CapabilityLease,
    workspaceLease: WorkspaceLease
) async throws {
    let state = try await mcpSessionState(log)
    var events: [Event] = []
    if let existing = state.capabilityLeases[capabilityLease.id] {
        guard state.capabilityLeaseAgents[capabilityLease.id] == agentID,
              existing == capabilityLease else {
            throw IntatisError.permissionDenied(
                "The persisted CLI Codex capability lease does not match the current root Agent.")
        }
    } else {
        events.append(.capabilityLeaseCreated(
            CapabilityLeaseCreatedPayload(
                agent: agentID,
                lease: capabilityLease)))
    }
    if let existing = state.workspaceLeases[workspaceLease.id] {
        guard state.workspaceLeaseAgents[workspaceLease.id] == agentID,
              existing.taskID == nil,
              existing.access == .readWrite,
              existing.rootIdentity?.matchesCurrentDirectory(
                rootPath: workspaceLease.rootPath) == true else {
            throw IntatisError.permissionDenied(
                "The persisted CLI Codex workspace lease does not match the current root workspace.")
        }
    } else {
        events.append(.workspaceLeaseGranted(
            WorkspaceLeaseGrantedPayload(
                agent: agentID,
                lease: workspaceLease)))
    }
    if !events.isEmpty {
        _ = try await log.append(events)
    }
}

private func codexCLIProfileRoleName(
    _ option: CLIInferenceProfileOption
) throws -> String {
    let binding = option.binding
    let material = [
        option.id,
        binding.inferenceProfileRevision.rawValue,
        binding.inferenceConnectionID.rawValue,
        binding.inferenceConnectionRevision.rawValue,
        binding.modelID.rawValue,
        binding.variantID ?? "",
        binding.immutableDefinitionFingerprint,
    ].joined(separator: "\u{001F}")
    let digest = ToolRegistry.authorizationDigest(material)
    guard digest.count >= 32 else {
        throw IntatisError.config(
            "CLI inference profile has no safe Codex role identity")
    }
    return "profile_\(digest.prefix(32))"
}

private func codexNextMode(_ mode: Mode) -> Mode {
    switch mode {
    case .chat: return .code
    case .code: return .cowork
    case .cowork: return .chat
    }
}

private struct CodexCLISessionIdentity {
    let sessionID: SessionID
    let runtimeRoot: URL
    let toolEventLogURL: URL
}

private func codexCLISessionIdentity(
    mode: Mode,
    workspace: URL
) throws -> CodexCLISessionIdentity {
    var hash: UInt64 = 14_695_981_039_346_656_037
    let identity = IntatisHostApplication.identity
    let sessionSalt = identity == .intatis
        ? "codex-v6-hosted-search:\(mode.rawValue):\(workspace.path)"
        : "\(identity.fileNameStem):codex-v6-hosted-search:\(mode.rawValue):\(workspace.path)"
    for byte in sessionSalt.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    let key = String(hash, radix: 16)
    let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true)
    let root = support
        .appendingPathComponent(
            IntatisHostApplication.identity.storageName,
            isDirectory: true)
        .appendingPathComponent("cli", isDirectory: true)
        .appendingPathComponent(
            "codex_\(mode.rawValue)_\(key)_hosted_search_v6",
            isDirectory: true)
    return CodexCLISessionIdentity(
        sessionID: SessionID(
            rawValue: "\(mode.rawValue)_cli_\(key)"),
        runtimeRoot: root.appendingPathComponent(
            "codex-runtime",
            isDirectory: true),
        toolEventLogURL: root.appendingPathComponent(
            "events.jsonl"))
}
