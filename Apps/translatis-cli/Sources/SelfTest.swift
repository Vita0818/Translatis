import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation
import IntatisTools
import IntatisPermission
import IntatisAgentKernel
import IntatisCowork

// Built-in fake models — let `translatis selftest` prove the chat + code paths work
// offline, with no API key and no network. They drive the exact same ChatLoop /
// AgentLoop / renderer / approval code the real commands use.

private struct FakeChat: ChatProvider {
    let parts: [String]
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { c in
            for p in parts { c.yield(.delta(p)) }
            c.yield(.done); c.finish()
        }
    }
}

private final class FakeAgent: ToolCallingProvider, @unchecked Sendable {
    private var turns: [[AgentChunk]]
    private var i = 0
    private let lock = NSLock()
    init(_ turns: [[AgentChunk]]) { self.turns = turns }
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let turn = turns.isEmpty ? [.done(finishReason: "stop")] : turns[min(i, turns.count - 1)]
        i += 1
        lock.unlock()
        return AsyncThrowingStream { c in
            for x in turn { c.yield(x) }
            c.finish()
        }
    }
}

private func tempLog(_ tag: String) throws -> EventLog {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            IntatisHostApplication.identity.temporaryPrefix(
                "\(tag)-\(UUID().uuidString)"),
            isDirectory: true)
    return try EventLog(session: SessionID.new(), fileURL: dir.appendingPathComponent("events.jsonl"))
}

private let green = "\u{001B}[32m", red = "\u{001B}[31m", bold = "\u{001B}[1m", reset = "\u{001B}[0m"

func runSelfTest() async throws {
    let identity = IntatisHostApplication.identity
    func environmentVariable(_ suffix: String) -> String {
        identity.environmentVariable(suffix)
    }
    out("\(bold)\(identity.name) self-test\(reset) — offline, no API key, no network.\n")

    // 1) CHAT: a full streamed turn.
    out("\n\(bold)[chat]\(reset)\n› hi")
    let chatLog = try tempLog("chat")
    let chatLoop = ChatLoop(log: chatLog,
                            provider: FakeChat(parts: [
                                "Hello! ", "I am \(identity.name).",
                            ]),
                            model: ModelID(rawValue: "fake"))
    let r1 = Task { await renderLoop(chatLog) }
    try await chatLoop.send("hi")
    try? await Task.sleep(nanoseconds: 60_000_000)
    r1.cancel()
    let chatMsgs = ConversationProjection.build(from: await chatLog.replay()).messages
    let okChat = chatMsgs.contains {
        $0.role == .assistant
            && $0.text == "Hello! I am \(identity.name)."
    }
    out(okChat ? "\(green)PASS\(reset) streamed a complete reply\n"
               : "\(red)FAIL\(reset) chat reply not assembled\n")

    // 2) CODE: write a file, then read it back.
    out("\n\(bold)[code]\(reset)\n› create note.txt and read it back")
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            identity.temporaryPrefix("ws-\(UUID().uuidString)"),
            isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let codeLog = try tempLog("code")
    let writeArgs = String(decoding: try JSONSerialization.data(
        withJSONObject: [
            "path": "note.txt",
            "content": "hello from \(identity.fileNameStem)",
        ]), as: UTF8.self)
    let agent = Agent(name: AgentID(rawValue: "selftest"), workspaceRoot: workspace,
                      model: ModelID(rawValue: "fake"), profile: .reviewed)
    let codeLoop = AgentLoop(
        log: codeLog,
        provider: FakeAgent([
            [.toolCalls([ToolCall(id: "c1", name: "write_file", arguments: writeArgs)]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(id: "c2", name: "read_file", arguments: #"{"path":"note.txt"}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Wrote and read note.txt."), .done(finishReason: "stop")],
        ]),
        registry: .standard(),
        engine: PermissionEngine(),
        responder: FixedResponder(.allow),   // auto-approve writes for the self-test
        agent: agent,
        allowsShell: true
    )
    let r2 = Task { await renderLoop(codeLog) }
    _ = try await codeLoop.send("create note.txt and read it back")
    try? await Task.sleep(nanoseconds: 60_000_000)
    r2.cancel()
    let onDisk = (try? String(contentsOf: workspace.appendingPathComponent("note.txt"), encoding: .utf8)) ?? ""
    let okCode = onDisk == "hello from \(identity.fileNameStem)"
    out(okCode ? "\(green)PASS\(reset) wrote + read note.txt in the workspace\n"
               : "\(red)FAIL\(reset) file not written (got: \(onDisk.isEmpty ? "<empty>" : onDisk))\n")

    // 3) COWORK INFERENCE: compile two routes/models/variants from the shared
    // advanced config schema, resolve both in one session, retain an old exact
    // binding after route A changes, and prove credentials never cross routes.
    out("\n\(bold)[cowork inference profiles]\(reset)\n")
    let profileDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            identity.temporaryPrefix(
                "profile-selftest-\(UUID().uuidString)"),
            isDirectory: true)
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    let catalogURL = profileDirectory.appendingPathComponent("catalog.json")
    let configURL = profileDirectory.appendingPathComponent(
        identity.configurationFileName)
    let routeAKeyURL = profileDirectory.appendingPathComponent("route-a.key")
    let routeBKeyURL = profileDirectory.appendingPathComponent("route-b.key")
    let routeAKey = "offline-route-a-key"
    let routeBKey = "offline-route-b-key"
    try Data(routeAKey.utf8).write(to: routeAKeyURL, options: .atomic)
    try Data(routeBKey.utf8).write(to: routeBKeyURL, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: routeAKeyURL.path)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: routeBKeyURL.path)

    func writeMultiRouteConfig(routeAPort: Int, selectedModel: String) throws {
        let object: [String: Any] = [
            "model": selectedModel,
            "enabled_providers": ["route-a", "route-b", "anthropic"],
            "provider": [
                "route-a": [
                    "name": "Offline A",
                    "options": [
                        "baseURL": "http://127.0.0.1:\(routeAPort)/v1",
                        "apiKey": "{file:route-a.key}",
                    ],
                    "models": [
                        "model-alpha": [
                            "name": "Alpha",
                            "options": ["temperature": 0.2],
                            "variants": [
                                "careful": [
                                    "reasoning_effort": "low",
                                    "temperature": 0.15,
                                ],
                            ],
                        ],
                    ],
                ],
                "route-b": [
                    "name": "Offline B",
                    "options": [
                        "baseURL": "http://127.0.0.1:28282/v1",
                        "apiKey": "{file:route-b.key}",
                    ],
                    "models": [
                        "model-beta": [
                            "name": "Beta",
                            "options": ["temperature": 0.4],
                            "variants": [
                                "deep": [
                                    "reasoning_effort": "high",
                                    "temperature": 0.1,
                                ],
                            ],
                        ],
                        "anthropic/claude-sonnet": [
                            "name": "Gateway Sonnet",
                            "options": ["temperature": 0.25],
                        ],
                    ],
                ],
                "anthropic": [
                    "name": "Offline Anthropic-compatible",
                    "options": [
                        "baseURL": "http://127.0.0.1:29292/v1",
                        "apiKey": "{file:route-a.key}",
                    ],
                    "models": [
                        "claude-sonnet": [
                            "name": "Direct Sonnet",
                            "options": ["temperature": 0.5],
                        ],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    let offlineEnvironment = [
        environmentVariable("MODE"): "cowork",
        environmentVariable("USAGE"): "0",
        environmentVariable("MAX_STEPS"): "3",
        environmentVariable("REASONING"): "low",
    ]
    try writeMultiRouteConfig(
        routeAPort: 18181,
        selectedModel: "route-a/model-alpha")
    let firstConfig = try CLIConfig.load(
        configurationFileURL: configURL,
        environment: offlineEnvironment)
    var uniqueUnqualifiedEnvironment = offlineEnvironment
    uniqueUnqualifiedEnvironment[environmentVariable("MODEL")] = "model-beta"
    uniqueUnqualifiedEnvironment[environmentVariable("REASONING")] = "high"
    let uniqueUnqualifiedConfig = try CLIConfig.load(
        configurationFileURL: configURL,
        environment: uniqueUnqualifiedEnvironment)
    let uniqueUnqualifiedModelSelectedItsRoute =
        uniqueUnqualifiedConfig.selectedProviderID == "route-b"
            && uniqueUnqualifiedConfig.model == "model-beta"
            && uniqueUnqualifiedConfig.selectedVariantID == "deep"

    var slashModelEnvironment = offlineEnvironment
    slashModelEnvironment.removeValue(
        forKey: environmentVariable("REASONING"))
    slashModelEnvironment[environmentVariable("MODEL")] =
        "anthropic/claude-sonnet"
    let slashModelOverrideConfig = try CLIConfig.load(
        configurationFileURL: configURL,
        environment: slashModelEnvironment)
    let slashModelOverridePreferredExactKey =
        slashModelOverrideConfig.selectedProviderID == "route-b"
            && slashModelOverrideConfig.model == "anthropic/claude-sonnet"

    try writeMultiRouteConfig(
        routeAPort: 18181,
        selectedModel: "anthropic/claude-sonnet")
    var slashTopLevelEnvironment = offlineEnvironment
    slashTopLevelEnvironment.removeValue(
        forKey: environmentVariable("REASONING"))
    let slashTopLevelConfig = try CLIConfig.load(
        configurationFileURL: configURL,
        environment: slashTopLevelEnvironment)
    let slashTopLevelPreferredExactKey =
        slashTopLevelConfig.selectedProviderID == "route-b"
            && slashTopLevelConfig.model == "anthropic/claude-sonnet"
    try writeMultiRouteConfig(
        routeAPort: 18181,
        selectedModel: "route-a/model-alpha")

    var unavailableReasoningEnvironment = offlineEnvironment
    unavailableReasoningEnvironment[environmentVariable("MODEL")] =
        "route-a/model-alpha"
    unavailableReasoningEnvironment[environmentVariable("REASONING")] =
        "minimal"
    let unavailableReasoningRejected: Bool
    do {
        _ = try CLIConfig.load(
            configurationFileURL: configURL,
            environment: unavailableReasoningEnvironment)
        unavailableReasoningRejected = false
    } catch {
        unavailableReasoningRejected = true
    }
    var invalidReasoningEnvironment = offlineEnvironment
    invalidReasoningEnvironment[environmentVariable("REASONING")] =
        "not-a-reasoning-effort"
    let invalidReasoningRejected: Bool
    do {
        _ = try CLIConfig.load(
            configurationFileURL: configURL,
            environment: invalidReasoningEnvironment)
        invalidReasoningRejected = false
    } catch {
        invalidReasoningRejected = true
    }

    var ambiguousRoot = try JSONSerialization.jsonObject(
        with: Data(contentsOf: configURL)) as! [String: Any]
    var ambiguousProviders = ambiguousRoot["provider"] as! [String: Any]
    var ambiguousRoute = ambiguousProviders["route-b"] as! [String: Any]
    var ambiguousModels = ambiguousRoute["models"] as! [String: Any]
    var ambiguousModel = ambiguousModels["model-beta"] as! [String: Any]
    var ambiguousVariants = ambiguousModel["variants"] as! [String: Any]
    ambiguousVariants["deep-alternate"] = [
        "reasoning_effort": "high",
        "temperature": 0.3,
    ]
    ambiguousModel["variants"] = ambiguousVariants
    ambiguousModels["model-beta"] = ambiguousModel
    ambiguousRoute["models"] = ambiguousModels
    ambiguousProviders["route-b"] = ambiguousRoute
    ambiguousRoot["provider"] = ambiguousProviders
    try JSONSerialization.data(
        withJSONObject: ambiguousRoot,
        options: [.prettyPrinted, .sortedKeys])
        .write(to: configURL, options: .atomic)
    let ambiguousReasoningRejected: Bool
    do {
        _ = try CLIConfig.load(
            configurationFileURL: configURL,
            environment: uniqueUnqualifiedEnvironment)
        ambiguousReasoningRejected = false
    } catch {
        ambiguousReasoningRejected = true
    }
    try writeMultiRouteConfig(
        routeAPort: 18181,
        selectedModel: "route-a/model-alpha")

    let firstProfiles = try await CLIInferenceProfiles.load(
        config: firstConfig,
        fileURL: catalogURL)
    guard let firstRouteA = firstProfiles.option(
        routeID: "route-a",
        model: "model-alpha",
        variantID: "careful") else {
        throw IntatisError.config("offline profile fixture did not compile")
    }

    // Change route A's upstream while retaining both route credentials and all
    // logical profiles. The old exact binding must remain resolvable.
    try writeMultiRouteConfig(
        routeAPort: 38383,
        selectedModel: "route-b/model-beta")
    var secondEnvironment = offlineEnvironment
    secondEnvironment[environmentVariable("REASONING")] = "high"
    let secondConfig = try CLIConfig.load(
        configurationFileURL: configURL,
        environment: secondEnvironment)
    let secondProfiles = try await CLIInferenceProfiles.load(
        config: secondConfig,
        fileURL: catalogURL)

    guard let currentRouteA = secondProfiles.option(
            routeID: "route-a",
            model: "model-alpha",
            variantID: "careful"),
          let currentRouteB = secondProfiles.option(
            routeID: "route-b",
            model: "model-beta",
            variantID: "deep") else {
        throw IntatisError.config("offline multi-route profiles did not compile")
    }

    let exactRegistry = ProviderRegistry(
        config: secondConfig.providerConfig(),
        resolver: CLIExactSecretResolver(config: secondConfig),
        inferenceCatalogSnapshot: secondProfiles.snapshot)
    let oldDefinition = try secondProfiles.snapshot.resolve(firstRouteA.binding)
    let currentADefinition = try secondProfiles.snapshot.resolve(currentRouteA.binding)
    let currentBDefinition = try secondProfiles.snapshot.resolve(currentRouteB.binding)
    let profileIDsStable = Set(firstProfiles.options.map(\.id))
        == Set(secondProfiles.options.map(\.id))
    let oldRevisionStillRetained = oldDefinition.binding == firstRouteA.binding
        && oldDefinition.connection.connectionRef.inferenceConnectionID
            == currentADefinition.connection.connectionRef.inferenceConnectionID
        && oldDefinition.connection.connectionRef.inferenceConnectionRevision
            != currentADefinition.connection.connectionRef.inferenceConnectionRevision
    let routeIdentitiesAreDistinct = currentADefinition.connection.connectionRef
        != currentBDefinition.connection.connectionRef
        && currentADefinition.connection.credentialRef
            != currentBDefinition.connection.credentialRef
        && currentADefinition.connection.trust.trustDomain
            != currentBDefinition.connection.trust.trustDomain
    let routeIdentitiesHideURLs = [
        oldDefinition.connection.connectionRef.inferenceConnectionID.rawValue,
        currentADefinition.connection.connectionRef.inferenceConnectionID.rawValue,
        currentBDefinition.connection.connectionRef.inferenceConnectionID.rawValue,
        firstRouteA.binding.inferenceProfileID.rawValue,
        currentRouteB.binding.inferenceProfileID.rawValue,
        oldDefinition.connection.trust.trustDomain,
        currentADefinition.connection.trust.trustDomain,
        currentBDefinition.connection.trust.trustDomain,
    ].allSatisfy {
        !$0.contains("127.0.0.1")
            && !$0.contains("18181")
            && !$0.contains("28282")
            && !$0.contains("38383")
    }
    let exactResolver = CLIExactSecretResolver(config: secondConfig)
    let recoveredOldRouteAKey = try await exactResolver.secret(
        for: oldDefinition.connection.credentialRef)
    let exactRouteBKey = try await exactResolver.secret(
        for: currentBDefinition.connection.credentialRef)
    let credentialsStayRouteScoped = recoveredOldRouteAKey == routeAKey
        && exactRouteBKey == routeBKey
        && recoveredOldRouteAKey != exactRouteBKey
    let recoveredOldProvider = try await exactRegistry.agentInference(
        for: firstRouteA.binding)
    let currentAResolution = try await exactRegistry.agentInference(
        for: currentRouteA.binding)
    let currentBResolution = try await exactRegistry.agentInference(
        for: currentRouteB.binding)
    let oldAndBothCurrentRoutesResolve = recoveredOldProvider.binding == firstRouteA.binding
        && currentAResolution.binding == currentRouteA.binding
        && currentBResolution.binding == currentRouteB.binding
        && currentAResolution.model.rawValue == "model-alpha"
        && currentBResolution.model.rawValue == "model-beta"
    let variantOverlayIsExact = currentBDefinition.profile.effectiveRequestOptions["temperature"]
        == .number(0.1)
        && currentBDefinition.profile.effectiveRequestOptions["reasoning_effort"]
            == .string("high")

    let frozenControlPlane = CLIGoalVerifierInferenceBinding()
    let firstFrozen = await frozenControlPlane.freeze(firstProfiles.defaultBinding)
    let secondFreezeAttempt = await frozenControlPlane.freeze(secondProfiles.defaultBinding)
    let controlPlaneStayedFrozen = firstFrozen == secondFreezeAttempt

    let bindingData = try JSONEncoder().encode(firstProfiles.defaultBinding)
    let bindingJSON = String(decoding: bindingData, as: UTF8.self)
    let bindingIsRouteSafe = !bindingJSON.contains("127.0.0.1")
        && !bindingJSON.contains("reasoning_effort")
        && !bindingJSON.contains(routeAKey)
        && !bindingJSON.contains(routeBKey)

    let coworkWorkspace = profileDirectory.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: coworkWorkspace, withIntermediateDirectories: true)
    let coworkLog = try tempLog("cowork-profile")
    let strictOrchestrator = try Orchestrator.runtime(
        log: coworkLog,
        allowsShell: true,
        responder: FixedResponder(.allow),
        availableInferenceProfiles: secondProfiles.bindings,
        requiresInferenceBindings: true,
        resolvedInferenceFor: { agent in
            guard let binding = agent.agentInferenceBinding else {
                throw InferenceCatalogError.unresolvedProfile
            }
            return try await exactRegistry.agentInference(for: binding)
        })
    let missingBindingRejected: Bool
    switch await strictOrchestrator.bootstrapMainAgent(Agent(
        name: Orchestrator.mainAgentID,
        workspaceRoot: coworkWorkspace,
        model: secondProfiles.defaultBinding.modelID,
        profile: .reviewed,
        coordinationDepth: Agent.defaultCoordinationDepth)) {
    case .failed:
        missingBindingRejected = true
    default:
        missingBindingRejected = false
    }
    let boundBootstrapAccepted: Bool
    switch await strictOrchestrator.bootstrapMainAgent(Agent(
        name: Orchestrator.mainAgentID,
        workspaceRoot: coworkWorkspace,
        model: secondProfiles.defaultBinding.modelID,
        agentInferenceBinding: secondProfiles.defaultBinding,
        profile: .reviewed,
        coordinationDepth: Agent.defaultCoordinationDepth)) {
    case .attached, .alreadyAttached:
        boundBootstrapAccepted = true
    case .failed:
        boundBootstrapAccepted = false
    }
    let alternate = secondProfiles.options.first {
        $0.binding != secondProfiles.defaultBinding
    }!.binding
    let idleRebindAccepted: Bool
    switch await strictOrchestrator.rebindAgentInferenceProfile(
        agentID: Orchestrator.mainAgentID,
        binding: alternate,
        hostAuthorized: true) {
    case .rebound:
        idleRebindAccepted = true
    case .unchanged, .failed:
        idleRebindAccepted = false
    }
    let coworkEvents = await coworkLog.replay()
    let eventData = try JSONEncoder().encode(coworkEvents)
    let eventJSON = String(decoding: eventData, as: UTF8.self)
    let eventLogIsRouteSafe = !eventJSON.contains("127.0.0.1")
        && !eventJSON.contains("reasoning_effort")
        && !eventJSON.contains(routeAKey)
        && !eventJSON.contains(routeBKey)
    await strictOrchestrator.cancelAll(reason: "offline self-test complete")

    let legacyLog = try tempLog("cowork-profile-legacy")
    try await legacyLog.append(.agentAttached(AgentAttachedPayload(
        agent: Orchestrator.mainAgentID,
        path: coworkWorkspace.path,
        model: secondProfiles.defaultBinding.modelID,
        profile: PermissionProfile.reviewed.rawValue,
        agentInferenceBinding: nil)))
    let legacyProjection = CoworkProjection.build(from: await legacyLog.replay())
    let legacyOrchestrator = try Orchestrator.runtime(
        log: legacyLog,
        allowsShell: true,
        responder: FixedResponder(.allow),
        availableInferenceProfiles: secondProfiles.bindings,
        requiresInferenceBindings: true,
        resolvedInferenceFor: { agent in
            guard let binding = agent.agentInferenceBinding else {
                throw InferenceCatalogError.unresolvedProfile
            }
            return try await exactRegistry.agentInference(for: binding)
        })
    await legacyOrchestrator.restore(from: legacyProjection)
    let restoredLegacyMain = await legacyOrchestrator.agentList().first {
        $0.name == Orchestrator.mainAgentID
    }
    let legacyInferenceFailures = await legacyOrchestrator.inferenceResolutionFailures()
    let legacyRestoreStayedUnbound = restoredLegacyMain?.agentInferenceBinding == nil
        && legacyInferenceFailures[Orchestrator.mainAgentID] != nil
    await legacyOrchestrator.cancelAll(reason: "offline legacy restore self-test complete")

    let okProfiles = profileIDsStable
        && uniqueUnqualifiedModelSelectedItsRoute
        && slashModelOverridePreferredExactKey
        && slashTopLevelPreferredExactKey
        && unavailableReasoningRejected
        && invalidReasoningRejected
        && ambiguousReasoningRejected
        && oldRevisionStillRetained
        && routeIdentitiesAreDistinct
        && routeIdentitiesHideURLs
        && credentialsStayRouteScoped
        && oldAndBothCurrentRoutesResolve
        && variantOverlayIsExact
        && controlPlaneStayedFrozen
        && bindingIsRouteSafe
        && missingBindingRejected
        && boundBootstrapAccepted
        && idleRebindAccepted
        && eventLogIsRouteSafe
        && legacyRestoreStayedUnbound
    out(okProfiles
        ? "\(green)PASS\(reset) two-route/model resolution, retained exact revisions, route-scoped credentials, strict/legacy fail-closed binding, frozen controls, idle rebind, and route-safe audit\n"
        : "\(red)FAIL\(reset) Cowork inference profile invariant failed\n")

    out("\n" + (okChat && okCode && okProfiles
        ? "\(green)\(bold)All good.\(reset) Point it at a real endpoint:\n  \(environmentVariable("API_KEY"))=sk-... swift run \(identity.commandName) chat\n"
        : "\(red)\(bold)Self-test failed.\(reset)\n"))
}
