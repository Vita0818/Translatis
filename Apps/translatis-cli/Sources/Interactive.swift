import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation
import IntatisTools
import IntatisPermission
import IntatisAgentKernel
import IntatisCowork
import IntatisSkills
import IntatisArtifacts

enum REPLExit { case quit; case switchTo(Mode) }

private enum S {
    static let reset = "\u{001B}[0m", bold = "\u{001B}[1m", dim = "\u{001B}[2m"
    static let green = "\u{001B}[32m", yellow = "\u{001B}[33m", cyan = "\u{001B}[36m"
}

private func banner(mode: Mode, model: String, host: String) {
    out("\n\(S.bold)\(IntatisHostApplication.identity.name)\(S.reset) \(S.dim)·\(S.reset) \(S.cyan)\(mode.rawValue)\(S.reset) \(S.dim)· \(model) · \(host)\(S.reset)\n")
    out("\(S.dim)/help for commands · /mode to switch · /exit to quit\(S.reset)\n")
}

private func prompt(_ mode: Mode) -> String {
    "\n\(S.green)\(mode.rawValue) ❯\(S.reset) "
}

/// Ctrl-A cycles chat → code → cowork → chat.
private func nextMode(_ m: Mode) -> Mode {
    switch m { case .chat: return .code; case .code: return .cowork; case .cowork: return .chat }
}

/// Strip surrounding [] '' "" that users sometimes copy from `[model]`-style help.
private func unbracket(_ s: String) -> String {
    var r = Substring(s)
    while let f = r.first, "[]\"'".contains(f) { r = r.dropFirst() }
    while let l = r.last, "[]\"'".contains(l) { r = r.dropLast() }
    return String(r)
}

func sessionLog() throws -> EventLog {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            IntatisHostApplication.identity.temporaryPrefix(
                "cli-\(UUID().uuidString)"),
            isDirectory: true)
    return try EventLog(session: SessionID.new(), fileURL: dir.appendingPathComponent("events.jsonl"))
}

private func coworkSessionLog(workspace: URL) throws -> EventLog {
    let canonicalPath = workspace.standardizedFileURL.path
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in canonicalPath.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    let key = String(hash, radix: 16)
    let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true)
    let directory = support
        .appendingPathComponent(
            IntatisHostApplication.identity.storageName,
            isDirectory: true)
        .appendingPathComponent("cli", isDirectory: true)
        .appendingPathComponent("cowork_\(key)", isDirectory: true)
    return try EventLog(
        session: SessionID(rawValue: "cowork_cli_\(key)"),
        fileURL: directory.appendingPathComponent("events.jsonl"))
}

private func sessionArtifactStore(_ log: EventLog) throws -> ArtifactStore {
    try ArtifactStore(
        root: log.sessionDirectoryURL
            .appendingPathComponent(
                "artifacts",
                isDirectory: true))
}

private func preserveAgentImages(
    _ images: [PendingImageAttachment],
    in store: ArtifactStore
) async throws -> [ArtifactID] {
    var ids: [ArtifactID] = []
    ids.reserveCapacity(images.count)
    for image in images {
        try Task.checkCancellation()
        let ref = try await store.addAttachment(
            name: image.name,
            data: image.data,
            mime: image.mime)
        ids.append(ref.id)
    }
    return ids
}

/// Top-level mode driver: runs the current mode's REPL and relaunches when a
/// `/mode` command asks to switch (so chat ⇄ code ⇄ cowork is live).
func runMode(_ config: CLIConfig, mode startMode: Mode, workspace: URL) async throws {
    var mode = startMode
    while true {
        let exit: REPLExit
        switch mode {
        case .chat:
            exit = try await chatCodeREPL(
                config,
                mode: .chat,
                workspace: workspace)
        case .code, .cowork:
            exit = try await codexRuntimeREPL(
                config,
                mode: mode,
                workspace: workspace)
        }
        switch exit {
        case .quit: return
        case .switchTo(let next): mode = next
        }
    }
}

private let replHelp = """
  /attach <path>            queue an image (vision) or text file for the next message
  /attach clear             clear queued attachments
  /model [name]             show or switch the model for this session
  /reasoning [level|off]    show or set reasoning (minimal|low|medium|high)
  /verbose [on|off]         expand tool calls & terminal output (default: collapsed)
  /mcp <command> [options]  manage/connect MCP for the current exact Code session
  /mode <chat|code|cowork>  switch mode
  /clear                    start a fresh session (clears history)
  /config                   show endpoint / model / reasoning
  /help                     this help
  /exit                     quit

  Keys: ←/→ cursor · Home/End jump · ↑/↓ history · Ctrl-U/K/W edit
        Ctrl-A mode · Ctrl-L model · Ctrl-S settings · Ctrl-C quit

"""

private func chatCodeREPL(_ config: CLIConfig, mode: Mode, workspace: URL) async throws -> REPLExit {
    guard mode == .chat else {
        throw IntatisError.config(
            "CLI Code/Cowork must run through Codex App Server")
    }
    let registry = ProviderRegistry(
        config: config.providerConfig(),
        resolver: CLIExactSecretResolver(config: config))
    let knowledgeConfigurationNotice = mode == .code
        ? cliKnowledgeToolsConfigurationNotice(config: config)
        : nil
    let knowledgeAugmenter = mode == .code
        ? makeCLIKnowledgeToolAugmenter(
            config: config,
            registry: registry)
        : nil
    var model = config.model
    var reasoning = config.reasoningEffort
    var pending = PendingAttachments()
    var log = try sessionLog()
    var codeArtifactStore =
        mode == .code
            ? try sessionArtifactStore(log)
            : nil
    var codeMCPHost =
        mode == .code
            ? MCPCLIInteractiveCodeHost(
                log: log,
                workspace: workspace,
                additionalCapabilities:
                    knowledgeAugmenter?.additionalCapabilities ?? [])
            : nil
    if let codeMCPHost {
        _ = try await codeMCPHost
            .activationIfAttached()
    }
    let spinner = TurnSpinner()
    let editor = LineEditor()
    let options = RenderOptions()
    let terminal = ProcessTerminalSessionManager()
    var render = Task { await renderLoop(log, spinner: spinner, options: options) }
    defer { render.cancel(); spinner.stop() }

    func finishChatCode(_ exit: REPLExit) async -> REPLExit {
        if let codeMCPHost {
            await codeMCPHost.shutdown(
                reason:
                    "CLI Code session ended")
        }
        await terminal.shutdown(reason: "CLI \(mode.rawValue) session ended")
        return exit
    }

    banner(mode: mode, model: model, host: config.selectedRouteLabel)
    if let knowledgeConfigurationNotice {
        out("\(S.yellow)\(knowledgeConfigurationNotice)\(S.reset)\n")
    }

    while true {
        if !pending.isEmpty {
            out("\(S.dim)  \(pending.count) attachment(s) queued for your next message\(S.reset)\n")
        }
        let line: String
        switch editor.readLine(prompt: prompt(mode)) {
        case .eof: return await finishChatCode(.quit)
        case .shortcut(.exit): return await finishChatCode(.quit)
        case .shortcut(.cycleMode): return await finishChatCode(.switchTo(nextMode(mode)))
        case .shortcut(.switchModel):
            if case .text(let m) = editor.readLine(prompt: "\(S.green)model ❯\(S.reset) ") {
                let name = unbracket(m.trimmingCharacters(in: .whitespaces))
                if !name.isEmpty { model = name; out("model → \(model)\n") }
            }
            continue
        case .shortcut(.settings):
            try runSettings(); out("(settings saved — restart to apply endpoint/model changes)\n")
            continue
        case .text(let l): line = l
        }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }

        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
            let cmd = parts.first ?? ""
            let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch cmd {
            case "help":
                out(replHelp)
            case "exit", "quit":
                return await finishChatCode(.quit)
            case "model":
                if arg.isEmpty { out("model: \(model)\n") } else { model = arg; out("model → \(model)\n") }
            case "reasoning":
                if arg.isEmpty {
                    out("reasoning: \(reasoning?.rawValue ?? "off")\n")
                } else if arg.lowercased() == "off" {
                    reasoning = nil; out("reasoning → off\n")
                } else if let r = ReasoningEffort(rawValue: arg.lowercased()) {
                    reasoning = r; out("reasoning → \(r.rawValue)\n")
                } else {
                    out("usage: /reasoning minimal|low|medium|high|off\n")
                }
            case "verbose":
                if arg.lowercased() == "off" { options.verbose = false }
                else if arg.lowercased() == "on" { options.verbose = true }
                else { options.verbose.toggle() }
                out("verbose → \(options.verbose ? "on" : "off")\n")
            case "mode":
                if let m = Mode(rawValue: arg.lowercased()) {
                    if m == mode {
                        out("already in \(m.rawValue)\n")
                    } else {
                        return await finishChatCode(.switchTo(m))
                    }
                } else {
                    out("usage: /mode chat|code|cowork\n")
                }
            case "attach":
                if arg.isEmpty || arg == "list" {
                    out(pending.isEmpty ? "no attachments queued. usage: /attach <path>\n"
                                        : "\(pending.count) queued (\(pending.images.count) image, \(pending.textFiles.count) text)\n")
                } else if arg == "clear" {
                    pending.clear(); out("attachments cleared\n")
                } else {
                    switch AttachmentLoader.load(arg) {
                    case .image(let img):
                        pending.images.append(img); out("attached image · \(pending.count) queued\n")
                    case .text(let name, let content):
                        pending.textFiles.append((name, content)); out("attached \(name) · \(pending.count) queued\n")
                    case .failure(let message):
                        errOut(message + "\n")
                    }
                }
            case "mcp":
                guard mode == .code,
                      let codeMCPHost
                else {
                    out("MCP is available in CLI Code and Cowork sessions, not Chat.\n")
                    continue
                }
                do {
                    let activation =
                        try await codeMCPHost
                            .activate()
                    try await runInteractiveMCPCommand(
                        arg,
                        context:
                            activation.context,
                        sessionID:
                            activation.session
                                .sessionID,
                        agentID:
                            activation.session
                                .agentID)
                } catch {
                    errOut(
                        "MCP command failed: \(error.localizedDescription)\n")
                }
            case "clear":
                await terminal.terminateAll(reason: "CLI session history cleared")
                if let old = codeMCPHost {
                    await old.shutdown(
                        reason:
                            "CLI Code /clear replaced the exact session")
                }
                log = try sessionLog()
                codeArtifactStore =
                    mode == .code
                        ? try sessionArtifactStore(log)
                        : nil
                codeMCPHost =
                    mode == .code
                        ? MCPCLIInteractiveCodeHost(
                            log: log,
                            workspace: workspace,
                            additionalCapabilities:
                                knowledgeAugmenter?.additionalCapabilities ?? [])
                        : nil
                render.cancel()
                render = Task {
                    await renderLoop(
                        log,
                        spinner: spinner,
                        options: options)
                }
                out("(new session)\n")
            case "config":
                let knowledge = mode == .code
                    ? (knowledgeAugmenter == nil
                        ? "knowledge unavailable (\(knowledgeConfigurationNotice ?? "invalid configuration"))"
                        : "knowledge ready")
                    : "knowledge not exposed in Chat"
                out("\(config.selectedRouteLabel) · endpoint hidden · model \(model) · reasoning \(reasoning?.rawValue ?? "off") · \(knowledge)\n")
            default:
                out("unknown command /\(cmd) — /help\n")
            }
            continue
        }

        // Compose the message, consuming any queued attachments.
        var sendText = text
        for file in pending.textFiles { sendText += "\n\n[attached file: \(file.name)]\n\(file.content)" }
        let sendImages = pending.images

        spinner.start()
        do {
            switch mode {
            case .chat:
                let route = try await registry.chatRuntimeRoute(
                    model: ModelID(rawValue: model))
                try await ChatLoop(
                    log: log,
                    provider: route.provider,
                    model: route.model,
                    reasoningEffort: reasoning,
                    includeUsage: config.includeUsage,
                    webSearch: route.webSearch)
                    .send(
                        sendText,
                        images: sendImages.map(
                            \.providerAttachment))
            case .code:
                guard let codeArtifactStore else {
                    throw IntatisError.config(
                        "CLI Code artifact storage is unavailable.")
                }
                let attachmentIDs = try await preserveAgentImages(
                    sendImages,
                    in: codeArtifactStore)
                let userMessage = UserMessagePayload(
                    text: sendText,
                    attachments: attachmentIDs.isEmpty
                        ? nil
                        : attachmentIDs,
                    submissionID: SubmissionID.new(),
                    turnID: TurnID.new())
                let imageResolver = AgentImageResolution.resolver(
                    store: codeArtifactStore)
                let mcpActivation:
                    MCPCLIInteractiveCodeActivation?
                if let codeMCPHost {
                    mcpActivation =
                        try await codeMCPHost
                            .activationIfAttached()
                } else {
                    mcpActivation = nil
                }
                let route = try await registry.agentRuntimeRoute(
                    model: ModelID(rawValue: model))
                let skillSnapshot =
                    try await SkillCatalogService.shared.snapshot(
                        configuration: .standard(
                            workspaceRoot: workspace,
                            access: .workspaceAndGlobal),
                        catalogBudget:
                            route.modelContextPolicy
                                .skillCatalogMetadataBudget)
                if let mcpActivation {
                    let codeMCPSession =
                        mcpActivation.session
                    let agent = Agent(
                        name:
                            codeMCPSession.agentID,
                        workspaceRoot: workspace,
                        model: route.model,
                        profile: .reviewed)
                    let hostedWebSearch = codeMCPSession
                        .capabilityLease.tools.contains(.hostedWebSearch)
                        ? route.hostedWebSearch.map {
                            ProviderHostedWebSearchToolService(route: $0)
                        }
                        : nil
                    let unaugmentedRegistry = skillSnapshot.augmenting(
                        ToolRegistry.standard(
                            includesTerminal: true,
                            hostedWebSearch: hostedWebSearch))
                    let knowledgeLease:
                        HostToolRegistryAugmentationLease?
                    let baseRegistry: ToolRegistry
                    if let knowledgeAugmenter {
                        let lease = try await knowledgeAugmenter.augment(
                            HostToolRegistryAugmentationInput(
                                sessionID: codeMCPSession.sessionID,
                                agentID: codeMCPSession.agentID,
                                taskID: nil,
                                capabilityLease:
                                    codeMCPSession.capabilityLease,
                                workspaceLease:
                                    codeMCPSession.workspaceLease,
                                baseRegistry: unaugmentedRegistry))
                        knowledgeLease = lease
                        baseRegistry = lease.registry
                    } else {
                        knowledgeLease = nil
                        baseRegistry = unaugmentedRegistry
                    }
                    let runtime = AgentRuntime.code(
                        registry: baseRegistry,
                        allowsShell: true,
                        reasoningEffort: reasoning,
                        includeUsage:
                            config.includeUsage,
                        maxIterations:
                            config.maxSteps,
                        modelContextPolicy:
                            route.modelContextPolicy)
                    let loop = runtime.makeLoop(
                        log: log,
                        provider: route.provider,
                        responder: TerminalResponder(),
                        agent: agent,
                        context: ContextBuilder(
                            skillSnapshot: skillSnapshot,
                            runtimeEnvironment: .code),
                        terminal: terminal,
                        imageGenerator:
                            ProviderImageGenerationToolService(
                                registry: registry),
                        imageResolver: imageResolver,
                        sessionNaming:
                            EventLogSessionNamingService(
                                log: log,
                                kind: .code),
                        capabilityLease:
                            codeMCPSession
                                .capabilityLease,
                        workspaceLease:
                            codeMCPSession
                                .workspaceLease,
                        toolSnapshotProvider: {
                            providerCapabilities,
                            outputBudget in
                            try await codeMCPSession
                                .owner.runtime.snapshot(
                                    agentID:
                                        codeMCPSession
                                            .agentID,
                                    capabilityLease:
                                        codeMCPSession
                                            .capabilityLease,
                                    workspaceLease:
                                        codeMCPSession
                                            .workspaceLease,
                                    baseRegistry:
                                        baseRegistry,
                                    reason: .send,
                                    providerCapabilities:
                                        providerCapabilities,
                                    turnResultBudget:
                                        outputBudget,
                                    consentConfirmation:
                                        nil)
                        })
                    do {
                        _ = try await loop.send(
                            sendText,
                            userMessage: userMessage)
                    } catch let runError {
                        if let knowledgeLease {
                            try await knowledgeLease.closeRequiringDrain()
                        }
                        throw runError
                    }
                    if let knowledgeLease {
                        try await knowledgeLease.closeRequiringDrain()
                    }
                } else {
                    let agent = Agent(
                        name:
                            AgentID(rawValue: "cli"),
                        workspaceRoot: workspace,
                        model: route.model,
                        profile: .reviewed)
                    let logSessionID = await log.sessionID
                    var capabilityLease =
                        CapabilityLease.worker(
                            workspaceAccess: .readWrite)
                    capabilityLease.id = CapabilityLeaseID(
                        rawValue:
                            "clease_cli_code_\(logSessionID.rawValue)")
                    capabilityLease.expiresAtTaskCompletion = false
                    if let knowledgeAugmenter {
                        capabilityLease.tools.formUnion(
                            knowledgeAugmenter.additionalCapabilities)
                    }
                    let workspaceLease =
                        WorkspaceLease(
                            id: WorkspaceLeaseID(
                                rawValue:
                                    "wlease_cli_code_\(logSessionID.rawValue)"),
                            workspaceID: WorkspaceID(
                                rawValue:
                                    "workspace_cli_code_\(logSessionID.rawValue)"),
                            rootPath: workspace.path,
                            access: .readWrite,
                            expiresAtTaskCompletion: false)
                    let hostedWebSearch = capabilityLease.tools.contains(
                        .hostedWebSearch)
                        ? route.hostedWebSearch.map {
                            ProviderHostedWebSearchToolService(route: $0)
                        }
                        : nil
                    let unaugmentedRegistry = skillSnapshot.augmenting(
                        ToolRegistry.standard(
                            includesTerminal: true,
                            hostedWebSearch: hostedWebSearch))
                    let knowledgeLease:
                        HostToolRegistryAugmentationLease?
                    let baseRegistry: ToolRegistry
                    if let knowledgeAugmenter {
                        let lease = try await knowledgeAugmenter.augment(
                            HostToolRegistryAugmentationInput(
                                sessionID: logSessionID,
                                agentID: agent.name,
                                taskID: nil,
                                capabilityLease: capabilityLease,
                                workspaceLease: workspaceLease,
                                baseRegistry: unaugmentedRegistry))
                        knowledgeLease = lease
                        baseRegistry = lease.registry
                    } else {
                        knowledgeLease = nil
                        baseRegistry = unaugmentedRegistry
                    }
                    let runtime = AgentRuntime.code(
                        registry: baseRegistry,
                        allowsShell: true,
                        reasoningEffort: reasoning,
                        includeUsage: config.includeUsage,
                        maxIterations: config.maxSteps,
                        modelContextPolicy:
                            route.modelContextPolicy)
                    let loop = runtime.makeLoop(
                        log: log,
                        provider: route.provider,
                        responder: TerminalResponder(),
                        agent: agent,
                        context: ContextBuilder(
                            skillSnapshot: skillSnapshot,
                            runtimeEnvironment: .code),
                        terminal: terminal,
                        imageGenerator:
                            ProviderImageGenerationToolService(
                                registry: registry),
                        imageResolver: imageResolver,
                        sessionNaming:
                            EventLogSessionNamingService(
                                log: log,
                                kind: .code),
                        capabilityLease:
                            capabilityLease,
                        workspaceLease:
                            workspaceLease)
                    do {
                        _ = try await loop.send(
                            sendText,
                            userMessage: userMessage)
                    } catch let runError {
                        if let knowledgeLease {
                            try await knowledgeLease.closeRequiringDrain()
                        }
                        throw runError
                    }
                    if let knowledgeLease {
                        try await knowledgeLease.closeRequiringDrain()
                    }
                }
            case .cowork:
                break
            }
            pending.clear()
        } catch {
            errOut("error: \(error.localizedDescription)\n")
        }
        spinner.stop()
    }
}

private let coworkHelp = """
  Just talk to @main — it can spawn / list / remove its own helper agents.
  /goal <objective>                    create and run one durable Goal
  /goal status                         show the current Goal and verifier state
  /goal pause|resume|clear             control the current Goal
  /goal edit <objective>               revise the current Goal objective
  /profiles                           list safe, host-approved inference profiles
  /profile [profile-id]               show/set the default for future agents
  /agent add <name> <path> [--profile <profile-id>]
                                      manually attach an exactly bound agent
  /agent restore-main <path> <profile-id>
                                      explicitly rebuild missing recovered @main
  /agent profile <name>               show one agent's exact durable binding
  /agent rebind <name> <profile-id>   idle-only, host-authorized durable rebind
  /agent remove <name>                detach an agent
  /agents                             list attached agents and binding status
  /auto                               re-enable automatic permission review
  /default                            disable automatic permission review
  /model [name]                       compatibility display only; never rebinds
  /verbose [on|off]                   expand tool calls & terminal output
  /mcp <command> [options]            manage/connect MCP for this exact Cowork session
  /attach <path>                      queue an image/text file for the next message
  @name <message>                     send to a specific agent
  <message>                           send to @main
  /mode <chat|code|cowork>            switch mode
  /help   /exit

  Keys: ←/→ cursor · Home/End jump · ↑/↓ history · Ctrl-U/K/W edit
        Ctrl-A mode · Ctrl-L default profile · Ctrl-S settings · Ctrl-C quit

"""

@available(*, unavailable, message: "CLI Cowork uses Codex App Server")
private func coworkREPL(_ config: CLIConfig, workspace: URL) async throws -> REPLExit {
    let inferenceProfiles = try await CLIInferenceProfiles.load(config: config)
    let registry = ProviderRegistry(
        config: config.providerConfig(),
        resolver: CLIExactSecretResolver(config: config),
        inferenceCatalogSnapshot: inferenceProfiles.snapshot)
    let knowledgeConfigurationNotice =
        cliKnowledgeToolsConfigurationNotice(config: config)
    let knowledgeAugmenter = makeCLIKnowledgeToolAugmenter(
        config: config,
        registry: registry)
    var defaultProfile = inferenceProfiles.defaultBinding
    let permissionReviewerBinding = inferenceProfiles.permissionReviewerBinding
    let goalVerifierInference = CLIGoalVerifierInferenceBinding()
    var pending = PendingAttachments()
    let log = try coworkSessionLog(workspace: workspace)
    let artifactStore = try sessionArtifactStore(log)
    let coworkMCPHost =
        MCPCLIInteractiveCoworkHost(
            log: log,
            workspace: workspace)
    _ = try await coworkMCPHost
        .activationIfAttached()
    let spinner = TurnSpinner()
    let editor = LineEditor()
    let options = RenderOptions()
    let render = Task { await renderLoop(log, showAgentLabels: true, spinner: spinner, options: options) }
    defer { render.cancel(); spinner.stop() }

    let orchestrator = try Orchestrator.runtime(
        log: log, allowsShell: true, responder: TerminalResponder(),
        // Reasoning and arbitrary request options are frozen into each exact
        // profile revision. A session-wide override must never drift agents.
        reasoningEffort: nil, includeUsage: config.includeUsage,
        maxSteps: config.coworkMaxSteps,
        skillRootAccess: .workspaceAndGlobal,
        availableInferenceProfiles: inferenceProfiles.bindings,
        inferenceProfileRoutingMetadata: inferenceProfiles.options.map {
            InferenceProfileRoutingMetadata(
                inferenceProfileID: $0.binding.inferenceProfileID,
                declaredCapabilities: $0.declaredCapabilities)
        },
        requiresInferenceBindings: true,
        imageGeneratorFor: { _ in ProviderImageGenerationToolService(registry: registry) },
        imageResolver: AgentImageResolution.resolver(
            store: artifactStore),
        toolSnapshotProvider: {
            agent,
            capabilityLease,
            workspaceLease,
            baseRegistry,
            isResume,
            providerCapabilities,
            outputBudget in
            let state =
                try await MCPDurableSessionState
                    .load(from: log)
            guard !state.attachments.isEmpty else {
                return nil
            }
            guard let workspaceLease else {
                throw IntatisError.config(
                    "MCP dispatch requires an exact workspace lease")
            }
            let activation =
                try await coworkMCPHost.activate()
            return try await activation.owner.runtime.snapshot(
                agentID: agent.name,
                capabilityLease: capabilityLease,
                workspaceLease: workspaceLease,
                baseRegistry: baseRegistry,
                reason:
                    isResume ? .resume : .send,
                providerCapabilities:
                    providerCapabilities,
                turnResultBudget:
                    outputBudget,
                consentConfirmation: nil)
        },
        internalToolRegistryAugmenter: knowledgeAugmenter,
        sessionNaming: EventLogSessionNamingService(log: log, kind: .cowork),
        resolvedInferenceFor: { agent in
            guard let binding = agent.agentInferenceBinding else {
                throw InferenceCatalogError.unresolvedProfile
            }
            return try await registry.agentInference(for: binding)
        })

    let replayed = await log.replay()
    let restoredProjection = CoworkProjection.build(from: replayed)
    await orchestrator.restore(from: restoredProjection)

    let restoredEvents = await log.replay()
    let currentProjection = CoworkProjection.build(from: restoredEvents)
    var sessionSettings = currentProjection.sessionSettings?.cowork
    if let persistedDefault = sessionSettings?.defaultInferenceProfileBinding {
        defaultProfile = persistedDefault
    }
    var defaultPermissionProfile = PermissionProfile(
        rawValue: sessionSettings?.defaultPermissionProfile ?? "") ?? .reviewed

    func safeProfileDescription(_ binding: AgentInferenceBinding) -> String {
        let label = binding.safeRouteLabel.map { " · \($0)" } ?? ""
        let variant = binding.variantID.map { " · variant \($0)" } ?? " · base"
        return "\(binding.inferenceProfileID.rawValue)@\(binding.inferenceProfileRevision.rawValue) · \(binding.modelID.rawValue)\(variant)\(label)"
    }

    func option(profileID: String) -> CLIInferenceProfileOption? {
        inferenceProfiles.option(profileID: unbracket(profileID))
    }

    func printProfiles() {
        for profile in inferenceProfiles.options {
            let marker = profile.binding == defaultProfile ? "*" : " "
            out("\(marker) \(safeProfileDescription(profile.binding))\n")
        }
    }

    func resolvableMainBinding() async -> AgentInferenceBinding? {
        guard let main = await orchestrator.agentList().first(where: {
            $0.name == Orchestrator.mainAgentID
        }), let binding = main.agentInferenceBinding else { return nil }
        do {
            let resolved = try await registry.agentInference(for: binding)
            guard resolved.binding == binding, resolved.model == main.model else { return nil }
            return binding
        } catch {
            return nil
        }
    }

    /// Goal verification preserves the compatibility behavior of freezing the
    /// first exact, resolvable @main binding. Permission review is deliberately
    /// separate and always uses the config-derived reviewer binding above.
    func freezeGoalVerifierInferenceIfPossible() async -> AgentInferenceBinding? {
        if let frozen = await goalVerifierInference.binding() { return frozen }
        guard let binding = await resolvableMainBinding() else { return nil }
        return await goalVerifierInference.freeze(binding)
    }

    func enableAutomaticReview() async -> AutomaticPermissionReviewResult {
        guard await orchestrator.agentList().contains(where: {
            $0.name == Orchestrator.mainAgentID
        }) else {
            return .failed("@main must be attached before automatic permission review can start")
        }
        return await orchestrator.enableAutomaticPermissionReview(
            model: permissionReviewerBinding.modelID,
            agentInferenceBinding: permissionReviewerBinding,
            workspaceRoot: workspace)
    }

    // A default exactly-bound agent so you can just talk; add more with
    // `/agent add`. Recovered legacy agents remain visible but deliberately do
    // not receive a guessed variant or the current default binding.
    var mainAttached: Bool
    let autoReviewResult: AutomaticPermissionReviewResult
    var mainBootstrapError: String? = nil
    if currentProjection.agentRoster[Orchestrator.mainAgentID] != nil {
        mainAttached = true
        autoReviewResult = await enableAutomaticReview()
    } else if restoredEvents.isEmpty {
        // The workspace passed to `translatis cowork` is the user's explicit
        // initial-session authorization. Settings and both local identities
        // are committed as one durable batch; no model request occurs here.
        let freshSettings = CoworkSessionSettings(
            sessionID: await log.sessionID,
            mainAgentName: Orchestrator.mainAgentID.rawValue,
            defaultModelID: defaultProfile.modelID.rawValue,
            defaultInferenceProfileBinding: defaultProfile,
            defaultPermissionProfile: PermissionProfile.reviewed.rawValue,
            workspaces: [
                CoworkSessionWorkspace(
                    path: workspace.standardizedFileURL.path,
                    agentName: Orchestrator.mainAgentID.rawValue,
                    isPrimary: true),
            ])
        switch await orchestrator.bootstrapFreshSession(main: Agent(
            name: Orchestrator.mainAgentID,
            workspaceRoot: workspace,
            model: defaultProfile.modelID,
            agentInferenceBinding: defaultProfile,
            profile: .reviewed,
            coordinationDepth: Agent.defaultCoordinationDepth),
            settings: freshSettings,
            permissionReviewerModel: permissionReviewerBinding.modelID,
            permissionReviewerInferenceBinding: permissionReviewerBinding) {
        case .attached, .alreadyAttached:
            mainAttached = true
            sessionSettings = freshSettings
            defaultPermissionProfile = .reviewed
        case .failed(let message):
            mainAttached = false
            mainBootstrapError = message
        }
        autoReviewResult = mainAttached
            ? await enableAutomaticReview()
            : .failed(mainBootstrapError ?? "initial Cowork registration failed")
    } else {
        // A non-empty recovered session is outside initial bootstrap trust.
        // Never use today's default profile to recreate a missing historical
        // @main or start its control plane. The user must explicitly choose
        // both workspace and exact profile through `/agent restore-main`.
        mainAttached = false
        mainBootstrapError = "recovered session has no @main; use /agent restore-main <path> <profile-id>"
        autoReviewResult = .failed(
            "recovered session has no @main; explicitly restore it before automatic review can start")
    }
    // Preserve the Goal verifier's historical first-main freeze without
    // coupling the independently configured reviewer to that binding.
    if mainAttached {
        _ = await freezeGoalVerifierInferenceIfPossible()
    }

    func persistDefaultProfile(_ binding: AgentInferenceBinding) async -> Bool {
        let logSessionID = await log.sessionID
        var updated = sessionSettings ?? CoworkSessionSettings(
            sessionID: logSessionID,
            mainAgentName: Orchestrator.mainAgentID.rawValue,
            defaultPermissionProfile: defaultPermissionProfile.rawValue,
            workspaces: currentProjection.agentRoster.values
                .filter { $0.agent != Orchestrator.automaticPermissionReviewerID }
                .map {
                    CoworkSessionWorkspace(
                        path: $0.path,
                        agentName: $0.agent.rawValue,
                        isPrimary: $0.agent == Orchestrator.mainAgentID)
                })
        updated.defaultProviderID = nil
        updated.defaultModelID = binding.modelID.rawValue
        updated.defaultInferenceProfileBinding = binding
        do {
            let document = try await SessionProjectionStore.updateSettings(
                in: log,
                kind: .cowork,
                coworkSettings: updated)
            guard let canonical = document.coworkSettings else {
                out("default profile was not changed: canonical session settings are unavailable\n")
                return false
            }
            sessionSettings = canonical
            defaultProfile = binding
            defaultPermissionProfile = PermissionProfile(
                rawValue: canonical.defaultPermissionProfile) ?? .reviewed
            return true
        } catch {
            out("default profile was not changed: \(error.localizedDescription)\n")
            return false
        }
    }
    banner(
        mode: .cowork,
        model: defaultProfile.modelID.rawValue,
        host: "profile \(defaultProfile.inferenceProfileID.rawValue)")
    if let knowledgeConfigurationNotice {
        out("\(S.yellow)\(knowledgeConfigurationNotice)\(S.reset)\n")
    }
    let startupPermissionReviewerProfileID =
        permissionReviewerBinding.inferenceProfileID.rawValue
    var automaticReviewRequired = true
    var automaticReviewReady = false
    switch autoReviewResult {
    case .enabled(let id):
        automaticReviewReady = true
        if case .some(.degraded(let reason)) = await orchestrator.automaticPermissionReviewHealth() {
            out("\(S.yellow)automatic permission review is degraded but active (@\(id.rawValue)): \(reason)\(S.reset)\n")
        } else {
            out("\(S.dim)automatic permission review is on (@\(id.rawValue), exact profile \(startupPermissionReviewerProfileID)); reviewer errors deny only the current tool call.\(S.reset)\n")
        }
    case .alreadyEnabled(let id):
        automaticReviewReady = true
        if case .some(.degraded(let reason)) = await orchestrator.automaticPermissionReviewHealth() {
            out("\(S.yellow)automatic permission review is degraded but active (@\(id.rawValue)): \(reason)\(S.reset)\n")
        } else {
            out("\(S.dim)automatic permission review already on (@\(id.rawValue)).\(S.reset)\n")
        }
    case .failed(let message):
        out("\(S.yellow)automatic permission review was not enabled: \(message). Cowork task input is blocked; use /auto to retry or /default to explicitly choose manual approval.\(S.reset)\n")
    }
    if mainAttached {
        out("\(S.dim)@main is ready in \(workspace.lastPathComponent) — just describe the task; it can spawn its own helper agents. /agents to list · /help\(S.reset)\n")
    } else {
        let detail = mainBootstrapError.map { ": \($0)" } ?? "."
        out("\(S.dim)@main was not attached\(detail) Start a new Cowork session or inspect the workspace configuration. /help\(S.reset)\n")
    }

    let goalRuntime = GoalRuntimeController(
        sessionID: await log.sessionID,
        log: log,
        orchestrator: orchestrator,
        verifierProvider: {
            guard let binding = await goalVerifierInference.binding() else {
                throw InferenceCatalogError.unresolvedProfile
            }
            return try await registry.agentInference(for: binding).provider
        },
        verifierModel: {
            await goalVerifierInference.binding()?.modelID
                ?? ModelID(rawValue: "unresolved-goal-verifier-profile")
        })
    var goalRuntimeStarted = false
    var dataPlaneStartedForNewTasks = false
    var dataPlaneResumed = false

    func ensureGoalRuntimeStarted(resumeRestoredTasks: Bool = false) async -> Bool {
        guard mainAttached else {
            errOut("@main is not attached; a durable Goal cannot run\n")
            return false
        }
        guard await freezeGoalVerifierInferenceIfPossible() != nil else {
            errOut("@main has no exact, resolvable inference profile; use /profiles then /agent rebind main <profile-id>\n")
            return false
        }
        let inferenceFailures = await orchestrator.inferenceResolutionFailures()
        guard inferenceFailures[Orchestrator.mainAgentID] == nil else {
            errOut("@main has an unresolved inference profile; use /profiles then /agent rebind main <profile-id> before resuming pending work.\n")
            return false
        }
        if automaticReviewRequired, !automaticReviewReady {
            errOut("automatic permission review is not ready; use /auto to retry or /default to explicitly choose manual approval\n")
            return false
        }
        if !goalRuntimeStarted {
            let recoverySafe = await goalRuntime.start()
            guard recoverySafe else {
                errOut("Goal recovery could not be completed safely; pending Cowork work remains stopped. Resolve the persistence/cancellation error and retry.\n")
                return false
            }
            goalRuntimeStarted = true
        }
        if resumeRestoredTasks, !dataPlaneResumed {
            guard await orchestrator.resumePendingTasks() else {
                errOut("Cowork data-plane resume was cancelled; retry after the session is ready.\n")
                return false
            }
            dataPlaneResumed = true
            dataPlaneStartedForNewTasks = true
        } else if !dataPlaneStartedForNewTasks {
            guard await orchestrator.startNewTasksKeepingRestoredTasksPaused() else {
                errOut("Cowork data-plane startup was cancelled; retry after the session is ready.\n")
                return false
            }
            dataPlaneStartedForNewTasks = true
        }
        return true
    }

    func printGoalStatus() async {
        guard let goal = await goalRuntime.currentGoal() else {
            out("(no current Goal)\n")
            return
        }
        let budget = goal.tokenBudget.map(String.init) ?? "unlimited"
        out("  \(goal.id.rawValue)  \(goal.status.rawValue)  revision \(goal.revision)\n")
        out("  objective: \(goal.objective)\n")
        out("  tokens: \(goal.tokensUsed) / \(budget) · elapsed: \(Int(goal.activeElapsedSeconds.rounded()))s\n")
        if let audit = goal.latestAudit {
            let proven = audit.requirements.filter { $0.status == .proven }.count
            out("  verifier: \(audit.verdict.rawValue) · \(proven)/\(audit.requirements.count) requirements proven\n")
            if !audit.remainingWork.isEmpty {
                out("  remaining: \(audit.remainingWork.joined(separator: "; "))\n")
            }
            if let blocker = audit.blocker, !blocker.isEmpty {
                out("  blocker: \(blocker)\n")
            }
        }
    }

    func createDurableGoal(_ objective: String, mention: AgentID? = nil) async {
        guard await ensureGoalRuntimeStarted() else { return }
        do {
            let durableObjective: String
            if let mention, mention != Orchestrator.mainAgentID {
                durableObjective = "@\(mention.rawValue): \(objective)"
            } else {
                durableObjective = objective
            }
            let goal = try await goalRuntime.createGoal(objective: durableObjective)
            let mentionContext: String
            if let mention, mention != Orchestrator.mainAgentID {
                mentionContext = " · requested via @\(mention.rawValue); @main hosts execution"
            } else {
                mentionContext = " · @main hosts execution"
            }
            out("Goal created: \(goal.id.rawValue)\(mentionContext)\n")
        } catch {
            errOut("Goal not created: \(error.localizedDescription)\n")
        }
    }

    func handleGoalCommand(_ argument: String) async {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            out("usage: /goal <objective> | /goal status|pause|resume|clear|edit <objective>\n")
            return
        }
        let components = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let operation = components[0].lowercased()
        let remainder = components.count > 1
            ? components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        switch operation {
        case "status":
            await printGoalStatus()
        case "pause":
            guard await ensureGoalRuntimeStarted() else { return }
            do {
                let goal = try await goalRuntime.pauseCurrentGoal()
                out("Goal \(goal.id.rawValue) → paused\n")
            } catch {
                errOut("Goal not paused: \(error.localizedDescription)\n")
            }
        case "resume":
            guard await ensureGoalRuntimeStarted() else { return }
            do {
                let goal = try await goalRuntime.resumeCurrentGoal()
                out("Goal \(goal.id.rawValue) → active\n")
            } catch {
                errOut("Goal not resumed: \(error.localizedDescription)\n")
            }
        case "clear":
            guard await ensureGoalRuntimeStarted() else { return }
            do {
                try await goalRuntime.clearCurrentGoal(
                    reason: "Cleared from \(IntatisHostApplication.identity.name) CLI")
                out("current Goal cleared\n")
            } catch {
                errOut("Goal not cleared: \(error.localizedDescription)\n")
            }
        case "edit":
            guard !remainder.isEmpty else {
                out("usage: /goal edit <objective>\n")
                return
            }
            guard await ensureGoalRuntimeStarted() else { return }
            guard let current = await goalRuntime.currentGoal() else {
                errOut("Goal not edited: there is no current Goal\n")
                return
            }
            do {
                let goal = try await goalRuntime.editCurrentGoal(
                    objective: remainder,
                    successCriteria: current.successCriteria,
                    constraints: current.constraints,
                    tokenBudget: current.tokenBudget)
                out("Goal \(goal.id.rawValue) edited · revision \(goal.revision)\n")
            } catch {
                errOut("Goal not edited: \(error.localizedDescription)\n")
            }
        default:
            await createDurableGoal(trimmed)
        }
    }

    func finishCowork(_ exit: REPLExit) async -> REPLExit {
        await goalRuntime.shutdown()
        await orchestrator.cancelAll(reason: "CLI Cowork session ended")
        await coworkMCPHost.shutdown(
            reason:
                "CLI Cowork session ended")
        return exit
    }

    var lastPermissionReviewHealth = await orchestrator.automaticPermissionReviewHealth()
    while true {
        let currentPermissionReviewHealth = await orchestrator.automaticPermissionReviewHealth()
        if currentPermissionReviewHealth != lastPermissionReviewHealth {
            switch currentPermissionReviewHealth {
            case .some(.degraded(let reason)):
                out("\(S.yellow)automatic permission review is degraded but active: \(reason)\(S.reset)\n")
            case .some(.shuttingDown):
                out("\(S.dim)automatic permission review is stopping; permissions require user approval.\(S.reset)\n")
            case .some(.healthy):
                out("\(S.dim)automatic permission review is healthy.\(S.reset)\n")
            case .none:
                out("\(S.dim)automatic permission review is off; permissions require user approval.\(S.reset)\n")
            }
            lastPermissionReviewHealth = currentPermissionReviewHealth
        }
        if !pending.isEmpty {
            out("\(S.dim)  \(pending.count) attachment(s) queued for your next message\(S.reset)\n")
        }
        let line: String
        switch editor.readLine(prompt: prompt(.cowork)) {
        case .eof: return await finishCowork(.quit)
        case .shortcut(.exit): return await finishCowork(.quit)
        case .shortcut(.cycleMode): return await finishCowork(.switchTo(nextMode(.cowork)))
        case .shortcut(.switchModel):
            if case .text(let value) = editor.readLine(prompt: "\(S.green)profile ❯\(S.reset) ") {
                let profileID = unbracket(value.trimmingCharacters(in: .whitespaces))
                if !profileID.isEmpty {
                    if let selected = option(profileID: profileID) {
                        if await persistDefaultProfile(selected.binding) {
                            out("default profile for future agents → \(safeProfileDescription(defaultProfile)); configured reviewer and any frozen Goal verifier are unchanged\n")
                        }
                    } else {
                        out("unknown profile '\(profileID)' — use /profiles\n")
                    }
                }
            }
            continue
        case .shortcut(.settings):
            do {
                try runSettings()
            } catch {
                await goalRuntime.shutdown()
                await orchestrator.cancelAll(reason: "CLI Cowork session failed")
                throw error
            }
            out("(settings saved — restart to apply)\n")
            continue
        case .text(let l): line = l
        }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }

        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(separator: " ").map(String.init)
            let cmd = parts.first ?? ""
            let commandArgument = text.dropFirst().split(separator: " ", maxSplits: 1)
                .dropFirst().first.map(String.init) ?? ""
            switch cmd {
            case "help":
                out(coworkHelp)
            case "exit", "quit":
                return await finishCowork(.quit)
            case "mode":
                if parts.count > 1, let m = Mode(rawValue: parts[1].lowercased()) {
                    return await finishCowork(.switchTo(m))
                }
                else { out("usage: /mode chat|code|cowork\n") }
            case "model":
                if parts.count > 1 {
                    out("Cowork /model is read-only and never rewrites an agent route. Use /profiles, /profile <profile-id>, or /agent rebind <name> <profile-id>.\n")
                }
                else {
                    out("default future-agent model: \(defaultProfile.modelID.rawValue) · profile \(defaultProfile.inferenceProfileID.rawValue)\n")
                }
            case "profiles":
                printProfiles()
            case "profile":
                if parts.count == 1 {
                    out("default future-agent profile: \(safeProfileDescription(defaultProfile))\n")
                } else if parts.count == 2, let selected = option(profileID: parts[1]) {
                    if await persistDefaultProfile(selected.binding) {
                        out("default profile for future agents → \(safeProfileDescription(defaultProfile)); existing agents, configured reviewer, and any frozen Goal verifier are unchanged\n")
                    }
                } else if parts.count == 2 {
                    out("unknown profile '\(unbracket(parts[1]))' — use /profiles\n")
                } else {
                    out("usage: /profile [profile-id]\n")
                }
            case "goal":
                await handleGoalCommand(commandArgument)
            case "verbose":
                if parts.count > 1, parts[1].lowercased() == "off" { options.verbose = false }
                else if parts.count > 1, parts[1].lowercased() == "on" { options.verbose = true }
                else { options.verbose.toggle() }
                out("verbose → \(options.verbose ? "on" : "off")\n")
            case "agents":
                let list = await orchestrator.agentList()
                let failures = await orchestrator.inferenceResolutionFailures()
                if list.isEmpty {
                    out("(no agents attached)\n")
                } else {
                    for agent in list {
                        let route: String
                        if let binding = agent.agentInferenceBinding {
                            let state = failures[agent.name].map { " · UNRESOLVED: \($0)" } ?? ""
                            route = safeProfileDescription(binding) + state
                        } else {
                            route = "UNRESOLVED legacy binding; explicit rebind required"
                        }
                        out("  @\(agent.name.rawValue)  \(S.dim)\(route) · \(agent.workspaceRoot.path)\(S.reset)\n")
                    }
                }
            case "auto":
                let result = await enableAutomaticReview()
                switch result {
                case .enabled(let id):
                    automaticReviewRequired = true
                    automaticReviewReady = true
                    _ = await ensureGoalRuntimeStarted(resumeRestoredTasks: true)
                    if case .some(.degraded(let reason)) = await orchestrator.automaticPermissionReviewHealth() {
                        out("automatic permission review is degraded but active (@\(id.rawValue)): \(reason)\n")
                    } else {
                        out("automatic permission review → on (@\(id.rawValue), exact profile \(permissionReviewerBinding.inferenceProfileID.rawValue))\n")
                    }
                case .alreadyEnabled(let id):
                    automaticReviewRequired = true
                    automaticReviewReady = true
                    _ = await ensureGoalRuntimeStarted(resumeRestoredTasks: true)
                    if case .some(.degraded(let reason)) = await orchestrator.automaticPermissionReviewHealth() {
                        out("automatic permission review is degraded but active (@\(id.rawValue)): \(reason)\n")
                    } else {
                        out("automatic permission review already on (@\(id.rawValue))\n")
                    }
                case .failed(let message):
                    automaticReviewRequired = true
                    automaticReviewReady = false
                    if goalRuntimeStarted {
                        await goalRuntime.shutdown()
                        goalRuntimeStarted = false
                    }
                    out("automatic permission review not enabled: \(message)\n")
                }
            case "default":
                switch await orchestrator.disableAutomaticPermissionReview() {
                case .disabled:
                    automaticReviewRequired = false
                    automaticReviewReady = false
                    _ = await ensureGoalRuntimeStarted(resumeRestoredTasks: true)
                    out("automatic permission review → off\n")
                case .alreadyDisabled:
                    automaticReviewRequired = false
                    automaticReviewReady = false
                    _ = await ensureGoalRuntimeStarted(resumeRestoredTasks: true)
                    out("automatic permission review already off\n")
                case .failed(let message):
                    out("automatic permission review could not be disabled: \(message)\n")
                }
            case "attach":
                if parts.count < 2 || parts[1] == "list" {
                    out(pending.isEmpty ? "no attachments queued. usage: /attach <path>\n" : "\(pending.count) queued\n")
                } else if parts[1] == "clear" {
                    pending.clear(); out("attachments cleared\n")
                } else {
                    switch AttachmentLoader.load(parts[1]) {
                    case .image(let img): pending.images.append(img); out("attached image · \(pending.count) queued\n")
                    case .text(let name, let content): pending.textFiles.append((name, content)); out("attached \(name) · \(pending.count) queued\n")
                    case .failure(let message): errOut(message + "\n")
                    }
                }
            case "mcp":
                do {
                    let activation =
                        try await coworkMCPHost
                            .activate()
                    try await runInteractiveMCPCommand(
                        commandArgument,
                        context:
                            activation.context,
                        sessionID:
                            activation.owner.runtime
                                .sessionID,
                        agentID:
                            Orchestrator.mainAgentID,
                        confinesAgent: false)
                } catch {
                    errOut(
                        "MCP command failed: \(error.localizedDescription)\n")
                }
            case "agent":
                if parts.count == 4, parts[1] == "restore-main" {
                    guard !(await orchestrator.agentList().contains(where: {
                        $0.name == Orchestrator.mainAgentID
                    })) else {
                        out("@main is already attached; use /agent rebind main <profile-id>\n")
                        continue
                    }
                    guard let selected = option(profileID: parts[3]) else {
                        out("unknown profile '\(unbracket(parts[3]))' — use /profiles\n")
                        continue
                    }
                    let url = URL(
                        fileURLWithPath: (parts[2] as NSString).expandingTildeInPath)
                        .standardizedFileURL
                    guard let canonicalSettings = sessionSettings else {
                        out("@main was not restored: canonical session settings are unavailable\n")
                        continue
                    }
                    let restored = await orchestrator.restoreHistoricalMainAgent(Agent(
                        name: Orchestrator.mainAgentID,
                        workspaceRoot: url,
                        model: selected.binding.modelID,
                        agentInferenceBinding: selected.binding,
                        profile: defaultPermissionProfile,
                        coordinationDepth: Agent.defaultCoordinationDepth),
                        settings: canonicalSettings,
                        hostAuthorized: true)
                    switch restored {
                    case .attached, .alreadyAttached:
                        mainAttached = true
                        mainBootstrapError = nil
                        _ = await freezeGoalVerifierInferenceIfPossible()
                        out("restored @main · \(safeProfileDescription(selected.binding)) · \(url.path); use /auto to start the configured automatic reviewer\n")
                    case .failed(let message):
                        out("@main was not restored · \(url.path) · \(message)\n")
                    }
                } else if parts.count >= 4, parts[1] == "add" {
                    guard await ensureGoalRuntimeStarted() else { continue }
                    let name = parts[2]
                    let path = parts[3]
                    let selectedBinding: AgentInferenceBinding
                    if parts.count == 4 {
                        selectedBinding = defaultProfile
                    } else if parts.count == 6, parts[4] == "--profile",
                              let selected = option(profileID: parts[5]) {
                        selectedBinding = selected.binding
                    } else if parts.count == 6, parts[4] == "--profile" {
                        out("unknown profile '\(unbracket(parts[5]))' — use /profiles\n")
                        continue
                    } else {
                        out("usage: /agent add <name> <path> [--profile <profile-id>]\n")
                        continue
                    }
                    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
                    let attached = await orchestrator.attach(Agent(
                        name: AgentID(rawValue: name),
                        workspaceRoot: url,
                        model: selectedBinding.modelID,
                        agentInferenceBinding: selectedBinding,
                        profile: defaultPermissionProfile,
                        coordinationDepth: 0))
                    out(attached
                        ? "attached @\(name) · \(safeProfileDescription(selectedBinding)) · \(url.path)\n"
                        : "not attached @\(name) · \(url.path)\n")
                } else if parts.count == 3, parts[1] == "profile" {
                    let agentID = AgentID(rawValue: parts[2])
                    guard let agent = await orchestrator.agentList().first(where: {
                        $0.name == agentID
                    }) else {
                        out("no agent named @\(parts[2])\n")
                        continue
                    }
                    if let binding = agent.agentInferenceBinding {
                        let failure = await orchestrator.inferenceResolutionFailures()[agentID]
                        let state = failure.map { " · UNRESOLVED: \($0)" } ?? " · resolved"
                        out("@\(parts[2]): \(safeProfileDescription(binding))\(state)\n")
                    } else {
                        out("@\(parts[2]): UNRESOLVED legacy binding; choose /profiles then explicitly rebind\n")
                    }
                } else if parts.count == 4, parts[1] == "rebind" {
                    guard let selected = option(profileID: parts[3]) else {
                        out("unknown profile '\(unbracket(parts[3]))' — use /profiles\n")
                        continue
                    }
                    switch await orchestrator.rebindAgentInferenceProfile(
                        agentID: AgentID(rawValue: parts[2]),
                        binding: selected.binding,
                        hostAuthorized: true) {
                    case .rebound(let agentID, let binding):
                        _ = await freezeGoalVerifierInferenceIfPossible()
                        out("rebound @\(agentID.rawValue) → \(safeProfileDescription(binding))\n")
                        if agentID == Orchestrator.mainAgentID, !automaticReviewReady,
                           automaticReviewRequired {
                            out("@main is exactly bound; use /auto to start the configured automatic reviewer\n")
                        }
                    case .unchanged(let agentID, let binding):
                        out("@\(agentID.rawValue) already uses \(safeProfileDescription(binding))\n")
                    case .failed(let message):
                        out("not rebound @\(parts[2]): \(message)\n")
                    }
                } else if parts.count >= 3, parts[1] == "remove" {
                    guard await ensureGoalRuntimeStarted() else { continue }
                    let removed = await orchestrator.detach(AgentID(rawValue: parts[2]))
                    out(removed
                        ? "removed @\(parts[2])\n"
                        : "not removed @\(parts[2]) (reserved, missing, or busy)\n")
                } else {
                    out("usage: /agent add <name> <path> [--profile <id>] | /agent restore-main <path> <profile-id> | /agent profile <name> | /agent rebind <name> <id> | /agent remove <name>\n")
                }
            default:
                out("unknown command /\(cmd) — /help\n")
            }
            continue
        }

        // Determine target agent + message, consuming any queued attachments.
        // No @mention → the default @main agent.
        var target: AgentID? = AgentID(rawValue: "main")
        var message = text
        if text.hasPrefix("@") {
            let bits = String(text.dropFirst()).split(separator: " ", maxSplits: 1).map(String.init)
            target = AgentID(rawValue: bits.first ?? "")
            message = bits.count > 1 ? bits[1] : ""
        }
        let parsedInput: ParsedUserInput
        if automaticReviewRequired, !automaticReviewReady {
            errOut("automatic permission review is not ready; use /auto to retry or /default to explicitly choose manual approval\n")
            continue
        }
        switch GoalInputParser.parse(message) {
        case .success(let parsed):
            parsedInput = parsed
            message = parsed.text
        case .failure(let error):
            errOut(error.message + "\n")
            continue
        }
        if let objective = parsedInput.goal {
            await createDurableGoal(objective, mention: target)
            continue
        }
        guard await ensureGoalRuntimeStarted() else { continue }
        for file in pending.textFiles { message += "\n\n[attached file: \(file.name)]\n\(file.content)" }
        let mainInferenceBinding: AgentInferenceBinding?
        if target == Orchestrator.mainAgentID {
            guard let binding = await resolvableMainBinding() else {
                errOut(
                    "@main has no exact, resolvable inference profile; rebind it before sending\n")
                continue
            }
            mainInferenceBinding = binding
        } else {
            mainInferenceBinding = nil
        }
        let images = pending.images
        let attachmentIDs: [ArtifactID]
        do {
            attachmentIDs = try await preserveAgentImages(
                images,
                in: artifactStore)
        } catch {
            errOut(
                "attachments could not be preserved: \(error.localizedDescription)\n")
            continue
        }
        spinner.start()
        let sendResult = await goalRuntime.sendUserTurn(
            message,
            to: target,
            userMessage: UserMessagePayload(
                text: message,
                attachments: attachmentIDs.isEmpty
                    ? nil
                    : attachmentIDs,
                to: target,
                tags: parsedInput.tags.isEmpty ? nil : parsedInput.tags,
                goal: parsedInput.goal,
                submissionID: SubmissionID.new(),
                mainAgentInferenceBinding: mainInferenceBinding,
                turnID: TurnID.new()))
        spinner.stop()
        if let error = sendResult.errorMessage {
            errOut("error: \(error)\n")
        } else {
            pending.clear()
        }
    }
}
