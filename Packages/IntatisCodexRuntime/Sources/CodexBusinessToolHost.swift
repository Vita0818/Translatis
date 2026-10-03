import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools
import IntatisPermission
import IntatisConversation

/// Thin client executor for first-party Intatis business tools registered with
/// the official Codex App Server `dynamicTools` extension.
///
/// This host deliberately does not implement an agent loop, scheduler, MCP
/// transport, provider adapter, or fallback backend. App Server decides when a
/// registered function is called; the existing immutable ToolRegistry remains
/// the single source of schema, permission intent, and executor behavior.
public actor CodexBusinessToolHost {
    public typealias PermissionResolver = @Sendable (
        PermissionRequestPayload
    ) async -> PermissionApprovalResolution
    public typealias WorkTaskManagerResolver = @Sendable (
        AgentID
    ) async -> (any WorkTaskManager)?

    private struct PermissionSettlement {
        let decision: PermissionDecision
        let reason: String
        let shouldInterruptTurn: Bool
    }

    private struct RememberedPermissionKey: Hashable {
        let agent: AgentID
        let tool: String
        let canonicalAction: String
        let canonicalPermission: String
        let risksNetwork: Bool
    }

    private struct WorkspaceLeaseKey: Hashable {
        let path: String
        let access: WorkspaceAccess
    }

    private struct RegistryScopeKey: Hashable {
        let agentID: AgentID
        let workspaceLeaseID: WorkspaceLeaseID
        let knowledgeCapabilityIdentity: String
    }

    private struct PreparedRegistryScope: Sendable {
        let registry: ToolRegistry
        let descriptors: [ToolDescriptor]
        let lease: HostToolRegistryAugmentationLease
    }

    private let sessionID: SessionID
    private let agentID: AgentID
    private let workspaceURL: URL
    private let workspaceLease: WorkspaceLease
    private let workspaceLeases: [WorkspaceLeaseKey: WorkspaceLease]
    private let allowsShell: Bool
    private let log: EventLog
    private let permissionResolver: PermissionResolver
    private let workTaskManager: (any WorkTaskManager)?
    private let workTaskManagerResolver: WorkTaskManagerResolver?
    private let imageGenerator: any ImageGenerationToolService
    private let hostedWebSearchServices:
        [CodexRuntimeHostedWebSearchScope:
            any HostedWebSearchToolService]
    private let sessionNaming: (any SessionNamingService)?
    private let hostApplicationIdentity: IntatisHostApplicationIdentity
    private let baseRegistry: ToolRegistry
    private let registryAugmenter: HostToolRegistryAugmenter?
    private var preparedRegistry: ToolRegistry?
    private var preparedDescriptors: [ToolDescriptor]?
    private var augmentationLease: HostToolRegistryAugmentationLease?
    private var rootRegistryPreparationTask:
        Task<PreparedRegistryScope, Error>?
    private var childRegistryScopes:
        [RegistryScopeKey: PreparedRegistryScope] = [:]
    private var childRegistryPreparationTasks:
        [RegistryScopeKey: Task<PreparedRegistryScope, Error>] = [:]
    private var isClosed = false
    private var closeResult: Bool?
    private var closeTask: Task<Bool, Never>?
    private let permissionEngine = PermissionEngine()
    private var rememberedPermissions: Set<RememberedPermissionKey> = []

    public init(
        sessionID: SessionID,
        agentID: AgentID,
        workspaceURL: URL,
        workspaceLease: WorkspaceLease? = nil,
        childProfiles: [CodexRuntimeChildProfile] = [],
        additionalRegistrations: [ToolRegistration] = [],
        registryAugmenter: HostToolRegistryAugmenter? = nil,
        workTaskManager: (any WorkTaskManager)? = nil,
        workTaskManagerResolver: WorkTaskManagerResolver? = nil,
        imageGenerator: any ImageGenerationToolService,
        hostedWebSearchServices:
            [CodexRuntimeHostedWebSearchScope:
                any HostedWebSearchToolService] = [:],
        sessionNaming: (any SessionNamingService)? = nil,
        hostApplicationIdentity: IntatisHostApplicationIdentity =
            IntatisHostApplication.identity,
        allowsShell: Bool,
        log: EventLog,
        permissionResolver: @escaping PermissionResolver
    ) throws {
        var isDirectory: ObjCBool = false
        let canonicalWorkspace = workspaceURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard FileManager.default.fileExists(
            atPath: canonicalWorkspace.path,
            isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw IntatisError.config(
                "Codex business tools require an existing workspace directory")
        }
        let effectiveLease = workspaceLease ?? WorkspaceLease(
            id: WorkspaceLeaseID(
                rawValue: "wlease_codex_\(sessionID.rawValue)"),
            workspaceID: WorkspaceID(
                rawValue: "workspace_codex_\(sessionID.rawValue)"),
            rootPath: canonicalWorkspace.path,
            access: .readWrite)
        guard URL(fileURLWithPath: effectiveLease.rootPath)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path == canonicalWorkspace.path,
              effectiveLease.rootIdentity?.matchesCurrentDirectory(
                rootPath: effectiveLease.rootPath) == true else {
            throw IntatisError.permissionDenied(
                "Codex business tools require one exact live workspace lease")
        }

        let expectedChildSearchScopes = Set(childProfiles.compactMap {
            $0.hostedWebSearchEnabled
                ? CodexRuntimeHostedWebSearchScope.childRole($0.roleName)
                : nil
        })
        let suppliedChildSearchScopes:
            Set<CodexRuntimeHostedWebSearchScope> = Set(
                hostedWebSearchServices.keys.filter { scope in
                    if case .childRole = scope { return true }
                    return false
                })
        guard expectedChildSearchScopes == suppliedChildSearchScopes else {
            throw IntatisError.config(
                "Codex child hosted-search services must exactly match the configured host-approved roles")
        }
        let catalogHostedWebSearch = hostedWebSearchServices
            .sorted {
                Self.hostedWebSearchScopeSortKey($0.key)
                    < Self.hostedWebSearchScopeSortKey($1.key)
            }
            .first?.value
        let standardRegistry = ToolRegistry.standard(
            includesTerminal: false,
            hostedWebSearch: catalogHostedWebSearch)
        var registrations = standardRegistry.descriptors().compactMap {
            standardRegistry.registration(named: $0.name)
        }
        registrations.removeAll {
            [
                GenerateImageTool.descriptor.name,
                EditImageTool.descriptor.name,
                RenameSessionTool.descriptor.name,
            ].contains($0.descriptor.name)
        }
        registrations.append(ToolRegistration(
            tool: GenerateImageTool(),
            grantingCapabilities: [.generateImage]))
        registrations.append(ToolRegistration(
            tool: EditImageTool(),
            grantingCapabilities: [.editImage]))
        if sessionNaming != nil {
            registrations.append(ToolRegistration(
                tool: RenameSessionTool(),
                grantingCapabilities: [.renameSession]))
        }
        registrations.append(contentsOf: additionalRegistrations)
        let registry = ToolRegistry(
            registrations: registrations,
            registryVersion: hostApplicationIdentity
                .namespacedIdentifier("codex-business.v4"))
        guard additionalRegistrations.allSatisfy({
            Self.knowledgeCapability(for: $0.descriptor.name) == nil
        }) else {
            throw IntatisError.config(
                "Codex Knowledge tools must use the existing scoped registry augmenter")
        }
        guard registryAugmenter?.additionalCapabilities.isSubset(
                of: [.buildKnowledge, .searchKnowledge]) ?? true else {
            throw IntatisError.config(
                "Codex business tools accept only the existing Knowledge registry extension")
        }
        let descriptors = registry.descriptors().filter {
            Self.isFirstPartyBusinessTool($0.name)
                || (sessionNaming != nil
                    && $0.name == RenameSessionTool.descriptor.name)
        }
        guard !descriptors.isEmpty,
              descriptors.allSatisfy({
                  $0.modelSpecKind == .function
                    && registry.registration(named: $0.name) != nil
              }) else {
            throw IntatisError.config(
                "The \(hostApplicationIdentity.name) first-party business-tool registry is unavailable")
        }

        let inheritedChildIdentity = String(
            ToolRegistry.authorizationDigest([
                sessionID.rawValue,
                canonicalWorkspace.path,
                effectiveLease.access.rawValue,
            ].joined(separator: "\u{001F}")).prefix(24))
        var workspaceLeases: [WorkspaceLeaseKey: WorkspaceLease] = [
            WorkspaceLeaseKey(
                path: canonicalWorkspace.path,
                access: effectiveLease.access): WorkspaceLease(
                    id: WorkspaceLeaseID(
                        rawValue: "wlease_codex_child_\(inheritedChildIdentity)"),
                    workspaceID: WorkspaceID(
                        rawValue: "workspace_codex_child_\(inheritedChildIdentity)"),
                    rootPath: canonicalWorkspace.path,
                    access: effectiveLease.access),
        ]
        for profile in childProfiles {
            let childWorkspace = profile.workspaceURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            var childIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: childWorkspace.path,
                isDirectory: &childIsDirectory),
                  childIsDirectory.boolValue else {
                throw IntatisError.config(
                    "Codex child business-tool workspace is not an existing directory")
            }
            let access: WorkspaceAccess = profile.sandbox == .readOnly
                ? .readOnly
                : .readWrite
            let identity = String(ToolRegistry.authorizationDigest([
                sessionID.rawValue,
                childWorkspace.path,
                access.rawValue,
            ].joined(separator: "\u{001F}")).prefix(24))
            workspaceLeases[WorkspaceLeaseKey(
                path: childWorkspace.path,
                access: access)] = WorkspaceLease(
                id: WorkspaceLeaseID(
                    rawValue: "wlease_codex_child_\(identity)"),
                workspaceID: WorkspaceID(
                    rawValue: "workspace_codex_child_\(identity)"),
                rootPath: childWorkspace.path,
                access: access)
        }

        self.sessionID = sessionID
        self.agentID = agentID
        self.workspaceURL = canonicalWorkspace
        self.workspaceLease = effectiveLease
        self.workspaceLeases = workspaceLeases
        self.allowsShell = allowsShell
        self.log = log
        self.permissionResolver = permissionResolver
        self.workTaskManager = workTaskManager
        self.workTaskManagerResolver = workTaskManagerResolver
        self.imageGenerator = imageGenerator
        self.hostedWebSearchServices = hostedWebSearchServices
        self.sessionNaming = sessionNaming
        self.hostApplicationIdentity = hostApplicationIdentity
        self.baseRegistry = registry
        self.registryAugmenter = registryAugmenter
        if registryAugmenter == nil {
            self.preparedRegistry = registry
            self.preparedDescriptors = descriptors
        }
    }

    /// Freezes the exact descriptor set into one thread-start registration.
    /// The returned closure retains this host for the lifetime of the runtime;
    /// there is no alternate executor if the host goes away.
    public func dynamicTools() async throws -> CodexRuntimeDynamicTools {
        let (registry, descriptors) = try await prepareRegistry()
        let specs = descriptors.map {
            CodexRuntimeDynamicToolSpec(
                name: $0.name,
                description: $0.description,
                inputSchema: $0.parameters,
                deferLoading: $0.deferLoading)
        }
        let encoded = try JSONEncoder.intatisCodex.encode(
            JSONValue.array(specs.map(\.wireValue)))
        let identityMaterial = registry.registryVersion
            + "\u{001F}"
            + String(decoding: encoded, as: UTF8.self)
        let toolsetID = hostApplicationIdentity
            .namespacedIdentifier("business.")
            + String(ToolRegistry.authorizationDigest(identityMaterial)
                .prefix(24))
        return CodexRuntimeDynamicTools(
            toolsetID: toolsetID,
            specs: specs,
            handler: { [self] call in
                return await self.execute(call)
            },
            shutdownHandler: { [self] in
                await self.close()
            })
    }

    public func registeredToolNames() async throws -> [String] {
        let (_, descriptors) = try await prepareRegistry()
        return descriptors.map(\.name)
    }

    private func prepareRegistry() async throws
        -> (ToolRegistry, [ToolDescriptor])
    {
        guard !isClosed else {
            throw IntatisError.io(
                "Codex business-tool resources are already closed")
        }
        if let preparedRegistry,
           let preparedDescriptors {
            return (preparedRegistry, preparedDescriptors)
        }
        guard let registryAugmenter else {
            throw IntatisError.config(
                "Codex business-tool registry preparation is inconsistent")
        }
        let capabilityLease = businessCapabilityLease(
            agentID: agentID,
            workspaceAccess: workspaceLease.access,
            isRoot: true,
            knowledgeCapabilities: [],
            hostedWebSearchScope:
                hostedWebSearchServices[.root] == nil ? nil : .root)
        let task: Task<PreparedRegistryScope, Error>
        if let rootRegistryPreparationTask {
            task = rootRegistryPreparationTask
        } else {
            task = Self.registryPreparationTask(
                augmenter: registryAugmenter,
                input: HostToolRegistryAugmentationInput(
                    sessionID: sessionID,
                    agentID: agentID,
                    taskID: nil,
                    capabilityLease: capabilityLease,
                    workspaceLease: workspaceLease,
                    baseRegistry: baseRegistry),
                includesSessionNaming: sessionNaming != nil,
                hostApplicationIdentity: hostApplicationIdentity)
            rootRegistryPreparationTask = task
        }
        let scope: PreparedRegistryScope
        do {
            scope = try await task.value
        } catch {
            rootRegistryPreparationTask = nil
            throw error
        }
        rootRegistryPreparationTask = nil
        guard !isClosed else {
            _ = await scope.lease.close()
            throw IntatisError.io(
                "Codex business-tool resources are already closed")
        }
        augmentationLease = scope.lease
        preparedRegistry = scope.registry
        preparedDescriptors = scope.descriptors
        return (scope.registry, scope.descriptors)
    }

    private func close() async -> Bool {
        if let closeResult { return closeResult }
        if let closeTask { return await closeTask.value }
        isClosed = true
        preparedRegistry = nil
        preparedDescriptors = nil
        var leases = childRegistryScopes.values.map(\.lease)
        childRegistryScopes.removeAll()
        if let augmentationLease {
            leases.append(augmentationLease)
        }
        augmentationLease = nil
        var preparationTasks = Array(
            childRegistryPreparationTasks.values)
        childRegistryPreparationTasks.removeAll()
        if let rootRegistryPreparationTask {
            preparationTasks.append(rootRegistryPreparationTask)
        }
        rootRegistryPreparationTask = nil
        for task in preparationTasks { task.cancel() }
        let task = Task<Bool, Never> {
            var allLeases = leases
            for preparation in preparationTasks {
                if case .success(let scope) = await preparation.result {
                    allLeases.append(scope.lease)
                }
            }
            var drained = true
            for lease in allLeases {
                if await lease.close() == false { drained = false }
            }
            return drained
        }
        closeTask = task
        let result = await task.value
        closeResult = result
        return result
    }

    private static func registryPreparationTask(
        augmenter: HostToolRegistryAugmenter,
        input: HostToolRegistryAugmentationInput,
        includesSessionNaming: Bool,
        hostApplicationIdentity: IntatisHostApplicationIdentity
    ) -> Task<PreparedRegistryScope, Error> {
        Task {
            let lease = try await augmenter.augment(input)
            do {
                let registry = lease.registry
                let descriptors = registry.descriptors().filter {
                    Self.isFirstPartyBusinessTool($0.name)
                        || (includesSessionNaming
                            && $0.name
                                == RenameSessionTool.descriptor.name)
                }
                let requiredKnowledgeTools = input.capabilityLease.tools
                    .intersection([.buildKnowledge, .searchKnowledge])
                    .compactMap { capability -> String? in
                        switch capability {
                        case .buildKnowledge: return "build_knowledge"
                        case .searchKnowledge: return "search_knowledge"
                        default: return nil
                        }
                    }
                guard !descriptors.isEmpty,
                      requiredKnowledgeTools.allSatisfy({ name in
                          descriptors.contains { $0.name == name }
                            && registry.registration(named: name) != nil
                      }),
                      descriptors.allSatisfy({
                          $0.modelSpecKind == .function
                            && registry.registration(named: $0.name) != nil
                      }) else {
                    throw IntatisError.config(
                        "The \(hostApplicationIdentity.name) Knowledge business-tool registry is unavailable")
                }
                return PreparedRegistryScope(
                    registry: registry,
                    descriptors: descriptors,
                    lease: lease)
            } catch {
                _ = await lease.close()
                throw error
            }
        }
    }

    private func childRegistryScope(
        agentID: AgentID,
        capabilityLease: CapabilityLease,
        workspaceLease: WorkspaceLease
    ) async throws -> PreparedRegistryScope {
        guard !isClosed,
              let registryAugmenter else {
            throw IntatisError.io(
                "Codex business-tool resources are not active")
        }
        let capabilities = capabilityLease.tools
            .intersection([.buildKnowledge, .searchKnowledge])
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let key = RegistryScopeKey(
            agentID: agentID,
            workspaceLeaseID: workspaceLease.id,
            knowledgeCapabilityIdentity: capabilities)
        if let scope = childRegistryScopes[key] { return scope }
        let task: Task<PreparedRegistryScope, Error>
        if let existing = childRegistryPreparationTasks[key] {
            task = existing
        } else {
            task = Self.registryPreparationTask(
                augmenter: registryAugmenter,
                input: HostToolRegistryAugmentationInput(
                    sessionID: sessionID,
                    agentID: agentID,
                    taskID: nil,
                    capabilityLease: capabilityLease,
                    workspaceLease: workspaceLease,
                    baseRegistry: baseRegistry),
                includesSessionNaming: sessionNaming != nil,
                hostApplicationIdentity: hostApplicationIdentity)
            childRegistryPreparationTasks[key] = task
        }
        let scope: PreparedRegistryScope
        do {
            scope = try await task.value
        } catch {
            childRegistryPreparationTasks[key] = nil
            throw error
        }
        childRegistryPreparationTasks[key] = nil
        guard !isClosed else {
            _ = await scope.lease.close()
            throw IntatisError.io(
                "Codex business-tool resources are already closed")
        }
        childRegistryScopes[key] = scope
        return scope
    }

    private func execute(
        _ call: CodexRuntimeDynamicToolCall
    ) async -> CodexRuntimeDynamicToolResult {
        do {
            return try await executeChecked(call)
        } catch is CancellationError {
            return .text("tool cancelled", success: false)
        } catch {
            let message = RuntimeErrorPresentation.message(for: error)
            let prefix = message.lowercased().hasPrefix("invalid tool input:")
                || message.lowercased().hasPrefix("permission denied:")
                ? ""
                : "tool error: "
            return .text(prefix + message, success: false)
        }
    }

    private func executeChecked(
        _ call: CodexRuntimeDynamicToolCall
    ) async throws -> CodexRuntimeDynamicToolResult {
        guard !isClosed,
              let rootRegistry = preparedRegistry,
              let rootDescriptors = preparedDescriptors else {
            return .text(
                "tool error: the Codex business-tool host is not active",
                success: false)
        }
        guard call.executionLease?.isValid != false else {
            return .text(
                "permission denied: the Codex subagent invocation is no longer live",
                success: false)
        }
        let actingAgentID = call.agentID ?? agentID
        if call.agentID != nil,
           call.tool == RenameSessionTool.descriptor.name {
            return .text(
                "permission denied: only the exact current root agent may rename this session",
                success: false)
        }
        if call.agentID != nil,
           call.tool == "task_create"
                || call.tool == "task_link_agent" {
            return .text(
                "permission denied: only the exact Cowork root may manage WorkTask cards and agent links",
                success: false)
        }
        let executionWorkspaceURL = (call.workspaceURL ?? workspaceURL)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let matchingWorkspaceLeases: [WorkspaceLease]
        if call.agentID == nil {
            let matchesRoot = executionWorkspaceURL.path
                    == workspaceURL.path
                && (call.workspaceAccess == nil
                    || call.workspaceAccess == workspaceLease.access)
            matchingWorkspaceLeases = matchesRoot
                ? [workspaceLease]
                : []
        } else {
            matchingWorkspaceLeases = workspaceLeases.filter { entry in
                entry.key.path == executionWorkspaceURL.path
                    && (call.workspaceAccess == nil
                        || entry.key.access == call.workspaceAccess)
            }.map(\.value)
        }
        guard matchingWorkspaceLeases.count == 1,
              let executionWorkspaceLease = matchingWorkspaceLeases.first else {
            return .text(
                "permission denied: Codex tool call has no unique matching user-approved workspace lease",
                success: false)
        }
        let allowedKnowledgeCapabilities: Set<ToolCapability> = [
            .buildKnowledge,
            .searchKnowledge,
        ]
        guard call.knowledgeCapabilities.isSubset(
                of: allowedKnowledgeCapabilities),
              executionWorkspaceLease.access != .readOnly
                || !call.knowledgeCapabilities.contains(.buildKnowledge) else {
            return .text(
                "permission denied: the verified Codex child Knowledge grant exceeds its workspace authority",
                success: false)
        }
        let requestedHostedWebSearchScope = call.agentID == nil
            ? (hostedWebSearchServices[.root] == nil ? nil : .root)
            : call.hostedWebSearchScope
        let hostedWebSearchScope = requestedHostedWebSearchScope.flatMap {
            hostedWebSearchServices[$0] == nil ? nil : $0
        }
        let capabilityLease = businessCapabilityLease(
            agentID: actingAgentID,
            workspaceAccess: executionWorkspaceLease.access,
            isRoot: call.agentID == nil,
            knowledgeCapabilities: call.knowledgeCapabilities,
            hostedWebSearchScope: hostedWebSearchScope)
        if let requiredKnowledgeCapability = Self.knowledgeCapability(
                for: call.tool),
           !capabilityLease.tools.contains(requiredKnowledgeCapability) {
            return .text(
                "permission denied: the exact Codex child profile does not grant \(call.tool)",
                success: false)
        }
        var registry: ToolRegistry
        let descriptors: [ToolDescriptor]
        if call.agentID != nil,
           Self.knowledgeCapability(for: call.tool) != nil {
            let scope = try await childRegistryScope(
                agentID: actingAgentID,
                capabilityLease: capabilityLease,
                workspaceLease: executionWorkspaceLease)
            registry = scope.registry
            descriptors = scope.descriptors
        } else {
            registry = rootRegistry
            descriptors = rootDescriptors
        }
        if call.tool == HostedWebSearchTool.descriptor.name {
            guard let hostedWebSearchScope,
                  let service = hostedWebSearchServices[
                    hostedWebSearchScope] else {
                return .text(
                    "permission denied: the exact Codex agent route does not grant provider-hosted web search",
                    success: false)
            }
            registry = Self.bindingHostedWebSearch(
                in: registry,
                service: service)
        }
        guard let registration = registry.registration(named: call.tool),
              descriptors.contains(where: { $0.name == call.tool }) else {
            return .text(
                "unknown registered business tool: \(call.tool)",
                success: false)
        }
        let descriptor = registration.descriptor
        let normalizedArguments = try Self.normalizedArguments(
            call.arguments,
            registration: registration,
            descriptor: descriptor)
        let args = ToolArgs(raw: normalizedArguments)
        let touchedPaths = registration.touchedPaths(args)
        let intent = registration.permissionIntent(
            args,
            workspaceRoot: executionWorkspaceURL)
        let risksNetwork = registration.risksNetwork(args)
        if descriptor.name == HostedWebSearchTool.descriptor.name,
           SecretScanner.containsSecret(normalizedArguments) {
            let reason =
                "the proposed hosted web-search query appears to contain a secret"
            try await appendPolicyDenial(
                call: call,
                descriptor: descriptor,
                intent: intent,
                reason: reason,
                authorization: nil,
                source: .deterministicPolicy)
            return .text(
                Self.permissionDeniedMessage(reason),
                success: false)
        }
        if Self.isImageMutationTool(descriptor.name),
           SecretScanner.containsSecret(normalizedArguments) {
            let reason = "the proposed image operation appears to contain a secret"
            try await appendPolicyDenial(
                call: call,
                descriptor: descriptor,
                intent: intent,
                reason: reason,
                authorization: nil,
                source: .deterministicPolicy)
            return .text(
                Self.permissionDeniedMessage(reason),
                success: false)
        }
        if descriptor.name == RenameSessionTool.descriptor.name,
           Self.sessionRenameContainsSecret(normalizedArguments) {
            let reason = "the proposed session name appears to contain a secret"
            try await appendPolicyDenial(
                call: call,
                descriptor: descriptor,
                intent: intent,
                reason: reason,
                authorization: nil,
                source: .deterministicPolicy)
            return .text(
                Self.permissionDeniedMessage(reason),
                success: false)
        }
        if let failure = workspaceLeaseFailure(
            intent: intent,
            touchedPaths: touchedPaths,
            workspaceURL: executionWorkspaceURL,
            workspaceLease: executionWorkspaceLease) {
            try await appendPolicyDenial(
                call: call,
                descriptor: descriptor,
                intent: intent,
                reason: failure,
                authorization: nil,
                source: .authorizationRevalidation)
            return .text(
                Self.permissionDeniedMessage(failure),
                success: false)
        }

        let invocation = ToolAuthorizationInvocationContext(
            sessionID: sessionID,
            agent: actingAgentID,
            toolCallID: Self.durableToolCallID(call))
        var authorization: ResolvedToolAuthorization
        do {
            authorization = try registry.resolveAuthorization(
                toolName: descriptor.name,
                intent: intent,
                risksNetwork: risksNetwork,
                normalizedArguments: normalizedArguments,
                invocation: invocation,
                capabilityLease: capabilityLease,
                workspaceLease: executionWorkspaceLease)
        } catch {
            let reason = RuntimeErrorPresentation.message(for: error)
            try await appendPolicyDenial(
                call: call,
                descriptor: descriptor,
                intent: intent,
                reason: reason,
                authorization: nil,
                source: .authorizationRevalidation)
            return .text(
                Self.permissionDeniedMessage(reason),
                success: false)
        }

        let callContext = ToolCallContext(
            toolName: descriptor.name,
            sideEffect: descriptor.sideEffect,
            touchedPaths: touchedPaths,
            risksNetwork: risksNetwork,
            rawArgs: normalizedArguments,
            intent: intent)
        let permissionContext = PermissionContext(
            workspaceRoot: executionWorkspaceURL,
            profile: call.permissionProfile ?? .reviewed,
            allowsShell: allowsShell,
            agent: actingAgentID)
        let engineDecision = await permissionEngine.decideDetailed(
            callContext,
            permissionContext)
        authorization = authorization.withDeterministicGate(
            gateSnapshot(engineDecision.gate))
        let executionID = IDGen.random(prefix: "tool-execution")
        let replayPolicy = intent.replayPolicy
        let prepared = ToolExecutionPreparedPayload(
            executionID: executionID,
            toolCallID: Self.durableToolCallID(call),
            agent: actingAgentID,
            tool: descriptor.name,
            sideEffect: descriptor.sideEffect,
            intent: intent,
            authorization: authorization,
            replayPolicy: replayPolicy)
        let settlement = try await settlePermission(
            engineDecision.outcome,
            call: call,
            descriptor: descriptor,
            callContext: callContext,
            authorization: authorization,
            executionID: executionID,
            replayPolicy: replayPolicy,
            actingAgentID: actingAgentID,
            workspaceLease: executionWorkspaceLease)
        guard settlement.decision == .allow else {
            return .text(
                Self.permissionDeniedMessage(settlement.reason),
                success: false,
                shouldInterruptTurn: settlement.shouldInterruptTurn)
        }
        if call.executionLease?.isValid == false {
            let reason =
                "the Codex subagent binding changed before execution started"
            try await log.append(.toolExecutionPrepared(prepared))
            try await settleExecution(
                prepared,
                outcome: .denied,
                effectDisposition: .notStarted,
                reason: reason)
            return .text(
                Self.permissionDeniedMessage(reason),
                success: false)
        }
        try Task.checkCancellation()
        try validateAuthorization(
            authorization,
            registry: registry,
            toolName: descriptor.name,
            normalizedArguments: normalizedArguments,
            intent: intent,
            risksNetwork: risksNetwork,
            invocation: invocation,
            capabilityLease: capabilityLease,
            touchedPaths: touchedPaths,
            workspaceURL: executionWorkspaceURL,
            workspaceLease: executionWorkspaceLease)

        try await log.append(.toolExecutionPrepared(prepared))

        do {
            try Task.checkCancellation()
            guard call.executionLease?.isValid != false else {
                let reason =
                    "the Codex subagent binding changed before execution started"
                try await settleExecution(
                    prepared,
                    outcome: .denied,
                    effectDisposition: .notStarted,
                    reason: reason)
                return .text(
                    Self.permissionDeniedMessage(reason),
                    success: false)
            }
            try validateAuthorization(
                authorization,
                registry: registry,
                toolName: descriptor.name,
                normalizedArguments: normalizedArguments,
                intent: intent,
                risksNetwork: risksNetwork,
                invocation: invocation,
                capabilityLease: capabilityLease,
                touchedPaths: touchedPaths,
                workspaceURL: executionWorkspaceURL,
                workspaceLease: executionWorkspaceLease)
        } catch is CancellationError {
            let reason = "tool cancelled before execution started"
            try await settleExecution(
                prepared,
                outcome: .cancelled,
                effectDisposition: .notStarted,
                reason: reason)
            throw CancellationError()
        } catch {
            let reason = RuntimeErrorPresentation.message(for: error)
            try await settleExecution(
                prepared,
                outcome: .denied,
                effectDisposition: .notStarted,
                reason: reason)
            return .text(
                Self.permissionDeniedMessage(reason),
                success: false)
        }

        let scopedWorkTaskManager: (any WorkTaskManager)?
        if let workTaskManagerResolver {
            scopedWorkTaskManager = await workTaskManagerResolver(
                actingAgentID)
        } else {
            scopedWorkTaskManager = workTaskManager
        }
        let context = ToolContext(
            workspaceRoot: executionWorkspaceURL,
            workspaceLease: executionWorkspaceLease,
            workTaskManager: scopedWorkTaskManager,
            imageGenerator: imageGenerator,
            sessionNaming: sessionNaming,
            executionID: executionID,
            authorization: authorization)
        let observation: ToolObservation
        do {
            observation = try await registration.execute(args, in: context)
        } catch is CancellationError {
            let reason = "tool cancelled after execution started"
            try await settleExecution(
                prepared,
                outcome: .cancelled,
                effectDisposition: .unknown,
                reason: reason)
            throw CancellationError()
        } catch let denial as WorkspaceSandboxDeniedError {
            let reason = "sandbox denied tool execution: "
                + RuntimeErrorPresentation.message(for: denial)
            try await settleExecution(
                prepared,
                outcome: .denied,
                effectDisposition: .notStarted,
                reason: reason)
            return .text(reason, success: false)
        } catch let rejection as ToolExecutionRejectedWithoutSideEffect {
            let reason = "tool error: \(rejection.message)"
            try await settleExecution(
                prepared,
                outcome: .failed,
                effectDisposition: .notStarted,
                reason: reason)
            return .text(reason, success: false)
        } catch {
            let reason = "tool error: "
                + RuntimeErrorPresentation.message(for: error)
            try await settleExecution(
                prepared,
                outcome: .failed,
                effectDisposition: .unknown,
                reason: reason)
            return .text(reason, success: false)
        }

        if observation.structuredResult?.isError == true {
            try await settleExecution(
                prepared,
                outcome: .failed,
                effectDisposition: .unknown,
                reason: "tool executor reported failure")
            return .text(observation.text, success: false)
        }

        var events: [Event] = []
        if let diff = observation.diff,
           let files = observation.changedFiles {
            events.append(.patchProposed(PatchProposedPayload(
                patchId: IDGen.random(prefix: "patch"),
                agent: actingAgentID,
                files: files,
                diff: diff)))
        }
        events.append(.toolExecutionSettled(
            ToolExecutionSettledPayload(
                prepared: prepared,
                outcome: .succeeded,
                effectDisposition: .committed)))
        try await log.append(events)
        return .text(
            observation.text.isEmpty ? "completed" : observation.text,
            success: true)
    }

    private func settlePermission(
        _ outcome: PermissionOutcome,
        call: CodexRuntimeDynamicToolCall,
        descriptor: ToolDescriptor,
        callContext: ToolCallContext,
        authorization: ResolvedToolAuthorization,
        executionID: String,
        replayPolicy: ToolExecutionReplayPolicy,
        actingAgentID: AgentID,
        workspaceLease: WorkspaceLease
    ) async throws -> PermissionSettlement {
        let turnID = TurnID(rawValue: "codex:\(call.turnID)")
        let toolCallID = Self.durableToolCallID(call)
        let rememberedKey = RememberedPermissionKey(
            agent: actingAgentID,
            tool: descriptor.name,
            canonicalAction: authorization.canonicalAction,
            canonicalPermission: authorization.canonicalPermission
                ?? authorization.canonicalAction,
            risksNetwork: callContext.risksNetwork)
        if outcome.decision == .askUser,
           rememberedPermissions.contains(rememberedKey) {
            let reason = "permission previously approved for this exact business tool in the current session"
            try await log.append(.permissionResolved(
                PermissionResolvedPayload(
                    turnID: turnID,
                    toolCallID: toolCallID,
                    tool: descriptor.name,
                    decision: .allow,
                    risk: outcome.risk,
                    reason: reason,
                    intent: callContext.intent,
                    authorization: authorization,
                    source: .user,
                    action: .approveAndRemember)))
            return PermissionSettlement(
                decision: .allow,
                reason: reason,
                shouldInterruptTurn: false)
        }
        switch outcome.decision {
        case .allow, .deny:
            try await log.append(.permissionResolved(
                PermissionResolvedPayload(
                    turnID: turnID,
                    toolCallID: toolCallID,
                    tool: descriptor.name,
                    decision: outcome.decision,
                    risk: outcome.risk,
                    reason: outcome.reason,
                    intent: callContext.intent,
                    authorization: authorization,
                    source: .deterministicPolicy,
                    failureSource: outcome.decision == .deny
                        ? .policyDenied
                        : nil)))
            return PermissionSettlement(
                decision: outcome.decision,
                reason: outcome.reason,
                shouldInterruptTurn: false)

        case .askUser:
            let requestID = RequestID.new()
            let request = PermissionRequestPayload(
                requestId: requestID,
                agent: actingAgentID,
                tool: descriptor.name,
                args: "digest=\(authorization.normalizedArgumentsDigest); characters=\(authorization.normalizedArgumentsCharacterCount)",
                risk: outcome.risk,
                reason: outcome.reason,
                context: PermissionRequestContext(
                    turnID: turnID,
                    toolCallID: toolCallID,
                    normalizedArgs:
                        "digest=\(authorization.normalizedArgumentsDigest); characters=\(authorization.normalizedArgumentsCharacterCount)",
                    touchedPaths: callContext.touchedPaths,
                    risksNetwork: callContext.risksNetwork,
                    sideEffect: callContext.sideEffect,
                    intent: callContext.intent,
                    gate: authorization.deterministicGate,
                    workspaceLease: workspaceLease,
                    authorization: authorization,
                    executionID: executionID,
                    replayPolicy: replayPolicy.rawValue),
                approvalMode: .manual)
            _ = try await log.registerPermissionRequest(request)
            var resolution = await permissionResolver(request)
            if Task.isCancelled {
                resolution = PermissionApprovalResolution(
                    decision: .deny,
                    reason: "permission request cancelled",
                    risk: outcome.risk,
                    source: .callerCancellation,
                    reviewStatus: .cancelled,
                    failureKind: .callerCancelled,
                    failureSource: .turnCancelled)
            }
            let decision: PermissionDecision = resolution.decision == .allow
                ? .allow
                : .deny
            let reason = resolution.reason?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let durableReason = reason?.isEmpty == false
                ? reason!
                : (decision == .allow
                    ? "permission approved"
                    : outcome.reason)
            let failureSource = Self.permissionFailureSource(
                resolution,
                decision: decision)
            let durable = PermissionResolvedPayload(
                requestId: requestID,
                turnID: turnID,
                toolCallID: toolCallID,
                tool: descriptor.name,
                decision: decision,
                risk: resolution.risk ?? outcome.risk,
                reason: durableReason,
                intent: callContext.intent,
                authorization: authorization,
                source: resolution.source,
                reviewTaskID: resolution.reviewTaskID,
                reviewStatus: resolution.reviewStatus,
                failureKind: resolution.failureKind,
                failureSource: failureSource,
                action: resolution.action)
            let settlement = try await log.settlePermissionRequest(durable)
            if settlement.resolution.decision == .allow,
               resolution.effectiveAction == .approveAndRemember {
                rememberedPermissions.insert(rememberedKey)
            }
            return PermissionSettlement(
                decision: settlement.resolution.decision,
                reason: settlement.resolution.reason,
                shouldInterruptTurn:
                    resolution.effectiveAction == .cancelTurn)
        }
    }

    private func appendPolicyDenial(
        call: CodexRuntimeDynamicToolCall,
        descriptor: ToolDescriptor,
        intent: PermissionIntent,
        reason: String,
        authorization: ResolvedToolAuthorization?,
        source: PermissionApprovalSource
    ) async throws {
        try await log.append(.permissionResolved(
            PermissionResolvedPayload(
                turnID: TurnID(rawValue: "codex:\(call.turnID)"),
                toolCallID: Self.durableToolCallID(call),
                tool: descriptor.name,
                decision: .deny,
                risk: .high,
                reason: reason,
                intent: intent,
                authorization: authorization,
                source: source,
                failureKind: .authorizationSnapshotInvalid,
                failureSource: .policyDenied)))
    }

    private func validateAuthorization(
        _ authorization: ResolvedToolAuthorization,
        registry: ToolRegistry,
        toolName: String,
        normalizedArguments: String,
        intent: PermissionIntent,
        risksNetwork: Bool,
        invocation: ToolAuthorizationInvocationContext,
        capabilityLease: CapabilityLease,
        touchedPaths: [String],
        workspaceURL: URL,
        workspaceLease: WorkspaceLease
    ) throws {
        guard !isClosed else {
            throw IntatisError.io(
                "Codex business-tool resources are not active")
        }
        try registry.validateAuthorizationSnapshot(
            authorization,
            toolName: toolName,
            normalizedArguments: normalizedArguments,
            intent: intent,
            risksNetwork: risksNetwork,
            invocation: invocation,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease)
        if let failure = workspaceLeaseFailure(
            intent: intent,
            touchedPaths: touchedPaths,
            workspaceURL: workspaceURL,
            workspaceLease: workspaceLease) {
            throw IntatisError.permissionDenied(failure)
        }
    }

    private func settleExecution(
        _ prepared: ToolExecutionPreparedPayload,
        outcome: ToolExecutionOutcome,
        effectDisposition: ToolExecutionEffectDisposition,
        reason: String
    ) async throws {
        try await log.append(.toolExecutionSettled(
            ToolExecutionSettledPayload(
                prepared: prepared,
                outcome: outcome,
                effectDisposition: effectDisposition,
                reason: reason)))
    }

    private func workspaceLeaseFailure(
        intent: PermissionIntent,
        touchedPaths: [String],
        workspaceURL: URL,
        workspaceLease: WorkspaceLease
    ) -> String? {
        guard let rootIdentity = workspaceLease.rootIdentity else {
            return "workspace lease has no stable root identity; reattach the workspace"
        }
        guard rootIdentity.matchesCurrentDirectory(
            rootPath: workspaceLease.rootPath) else {
            return "workspace root changed after the lease was granted; reattach the workspace"
        }
        let leaseRoot = URL(fileURLWithPath: workspaceLease.rootPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard leaseRoot.path == workspaceURL.path else {
            return "workspace lease root does not match the Codex workspace"
        }
        if workspaceLease.access == .readOnly,
           !intent.isReadOnlyWorkspaceCompatible {
            return "workspace lease is read-only"
        }
        for path in touchedPaths {
            let resolved: URL
            do {
                resolved = try PathConfinement.resolve(
                    path,
                    within: leaseRoot)
            } catch {
                return "path is outside the workspace lease: \(path)"
            }
            let relative = Self.relativePath(resolved, root: leaseRoot)
            let deniedPatterns = workspaceLease.deniedPatterns
                + WorkspaceLease.mandatoryManagedStoreDeniedPatterns
            if deniedPatterns.contains(where: {
                Self.path(
                    relative.lowercased(),
                    matches: $0.lowercased())
            }) {
                return "path is denied by the workspace lease: \(relative)"
            }
            let allowed = workspaceLease.allowedPathRules.contains {
                $0.pattern == "."
                    || Self.path(relative, matches: $0.pattern)
            }
            if !allowed {
                return "path is outside the workspace lease allow-list: \(relative)"
            }
        }
        return nil
    }

    private static func normalizedArguments(
        _ value: JSONValue,
        registration: ToolRegistration,
        descriptor: ToolDescriptor
    ) throws -> String {
        guard case .object(let object) = value else {
            throw IntatisError.decoding(
                "invalid tool input: arguments for \(descriptor.name) must be a JSON object matching the tool schema")
        }
        if case .object(let schema) = descriptor.parameters {
            let required: Set<String>
            if case .array(let fields)? = schema["required"] {
                required = Set(fields.compactMap { value in
                    guard case .string(let name) = value else {
                        return nil
                    }
                    return name
                })
            } else {
                required = []
            }
            let missing = required.filter { object[$0] == nil }.sorted()
            if !missing.isEmpty {
                throw IntatisError.decoding(
                    "invalid tool input: arguments for \(descriptor.name) are missing required field(s): \(missing.joined(separator: ", "))")
            }
            let properties: [String: JSONValue]
            if case .object(let declared)? = schema["properties"] {
                properties = declared
            } else {
                properties = [:]
            }
            if schema["additionalProperties"] == .bool(false) {
                let unknown = object.keys.filter {
                    properties[$0] == nil
                }.sorted()
                if !unknown.isEmpty {
                    throw IntatisError.decoding(
                        "invalid tool input: arguments for \(descriptor.name) contain unknown field(s): \(unknown.joined(separator: ", "))")
                }
            }
            for (name, argument) in object {
                guard case .object(let fieldSchema)? = properties[name],
                      case .string(let expectedType)? = fieldSchema["type"]
                else { continue }
                if argument == .null, !required.contains(name) { continue }
                guard Self.matches(argument, expectedType: expectedType) else {
                    throw IntatisError.decoding(
                        "invalid tool input: argument \(name) for \(descriptor.name) must be \(expectedType)")
                }
                try Self.validateScalarConstraints(
                    argument,
                    schema: fieldSchema,
                    name: name,
                    descriptor: descriptor)
            }
        }
        let data = try JSONEncoder.intatisCodex.encode(
            JSONValue.object(object))
        let normalized = String(decoding: data, as: UTF8.self)
        do {
            try registration.validateArguments(
                ToolArgs(raw: normalized))
        } catch {
            throw IntatisError.decoding(
                "invalid tool input: arguments for \(descriptor.name) do not match the complete schema. \(RuntimeErrorPresentation.message(for: error))")
        }
        return normalized
    }

    private static func validateScalarConstraints(
        _ value: JSONValue,
        schema: [String: JSONValue],
        name: String,
        descriptor: ToolDescriptor
    ) throws {
        if case .number(let number) = value {
            if case .number(let minimum)? = schema["minimum"],
               number < minimum {
                throw IntatisError.decoding(
                    "invalid tool input: argument \(name) for \(descriptor.name) is below its minimum")
            }
            if case .number(let maximum)? = schema["maximum"],
               number > maximum {
                throw IntatisError.decoding(
                    "invalid tool input: argument \(name) for \(descriptor.name) exceeds its maximum")
            }
        }
        if case .string(let string) = value {
            if case .number(let minimum)? = schema["minLength"],
               string.count < Int(minimum) {
                throw IntatisError.decoding(
                    "invalid tool input: argument \(name) for \(descriptor.name) is shorter than allowed")
            }
            if case .number(let maximum)? = schema["maxLength"],
               string.count > Int(maximum) {
                throw IntatisError.decoding(
                    "invalid tool input: argument \(name) for \(descriptor.name) is longer than allowed")
            }
        }
    }

    private static func matches(
        _ value: JSONValue,
        expectedType: String
    ) -> Bool {
        switch (expectedType, value) {
        case ("string", .string),
             ("number", .number),
             ("boolean", .bool),
             ("array", .array),
             ("object", .object):
            return true
        case ("integer", .number(let value)):
            return value.rounded(.towardZero) == value
        default:
            return false
        }
    }

    private func gateSnapshot(
        _ result: GateResult
    ) -> PermissionReviewGateSnapshot {
        let policyVersion = hostApplicationIdentity
            .namespacedIdentifier("deterministic-policy.v1")
        switch result {
        case .deny(let reason, let risk):
            return PermissionReviewGateSnapshot(
                decision: .deny,
                risk: risk,
                reason: reason,
                policyVersion: policyVersion)
        case .ask(let reason, let risk):
            return PermissionReviewGateSnapshot(
                decision: .ask,
                risk: risk,
                reason: reason,
                policyVersion: policyVersion)
        case .allow(let reason, let risk):
            return PermissionReviewGateSnapshot(
                decision: .allow,
                risk: risk,
                reason: reason,
                policyVersion: policyVersion)
        case .pass(let reason, let risk):
            return PermissionReviewGateSnapshot(
                decision: .pass,
                risk: risk,
                reason: reason,
                policyVersion: policyVersion)
        }
    }

    private static func permissionFailureSource(
        _ resolution: PermissionApprovalResolution,
        decision: PermissionDecision
    ) -> ExecutionFailureSource? {
        if let failureSource = resolution.failureSource {
            return failureSource
        }
        if resolution.effectiveAction == .cancelTurn {
            return .userCancelled
        }
        if resolution.failureKind == .reviewerTimedOut {
            return .reviewerTimedOut
        }
        if resolution.failureKind != nil {
            return .reviewerFailed
        }
        guard decision == .deny else { return nil }
        switch resolution.source {
        case .user:
            return .userDenied
        case .callerCancellation:
            return .turnCancelled
        case .automaticReviewerFailure:
            return .reviewerFailed
        case .automaticReviewer,
             .deterministicPolicy,
             .authorizationRevalidation:
            return .policyDenied
        }
    }

    private static func permissionDeniedMessage(_ value: String) -> String {
        var reason = value.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let prefix = "permission denied:"
        while reason.lowercased().hasPrefix(prefix) {
            reason = String(reason.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return reason.isEmpty
            ? "permission denied"
            : "permission denied: \(reason)"
    }

    /// Builds the non-task-scoped capability lease used by one shipping Codex
    /// root. Keeping this beside the dynamic-tool executor prevents fresh
    /// session registration and live execution from inventing different tool
    /// ceilings. Native collaboration, Goal, and MCP remain Codex-owned
    /// surfaces; this lease describes only the first-party business tools that
    /// Intatis actually hosts.
    public static func rootBusinessCapabilityLease(
        id: CapabilityLeaseID,
        workspaceAccess: WorkspaceAccess,
        includesSessionNaming: Bool,
        includesWorkTaskManagement: Bool,
        includesHostedWebSearch: Bool = false,
        knowledgeCapabilities: Set<ToolCapability> = []
    ) -> CapabilityLease {
        return CapabilityLease(
            id: id,
            tools: rootBusinessTools(
                workspaceAccess: workspaceAccess,
                includesSessionNaming: includesSessionNaming,
                includesWorkTaskManagement:
                    includesWorkTaskManagement,
                includesHostedWebSearch:
                    includesHostedWebSearch,
                knowledgeCapabilities: knowledgeCapabilities),
            communication: .none,
            delegation: .none,
            expiresAtTaskCompletion: false)
    }

    private static func rootBusinessTools(
        workspaceAccess: WorkspaceAccess,
        includesSessionNaming: Bool,
        includesWorkTaskManagement: Bool,
        includesHostedWebSearch: Bool,
        knowledgeCapabilities: Set<ToolCapability>
    ) -> Set<ToolCapability> {
        var tools = CapabilityLease.worker(
            workspaceAccess: workspaceAccess).tools
        tools.remove(.generateMedia)
        tools.remove(.hostedWebSearch)
        if workspaceAccess == .readWrite {
            tools.formUnion(ToolCapability.exactImageMutationCapabilities)
            if includesHostedWebSearch {
                tools.insert(.hostedWebSearch)
            }
        }
        if includesWorkTaskManagement {
            tools.insert(.manageWorkTasks)
        }
        if includesSessionNaming {
            tools.insert(.renameSession)
        }
        var knowledge = knowledgeCapabilities.intersection(
            [.buildKnowledge, .searchKnowledge])
        if workspaceAccess == .readOnly {
            knowledge.remove(.buildKnowledge)
        }
        tools.formUnion(knowledge)
        return tools
    }

    private func businessCapabilityLease(
        agentID: AgentID,
        workspaceAccess: WorkspaceAccess,
        isRoot: Bool,
        knowledgeCapabilities: Set<ToolCapability>,
        hostedWebSearchScope:
            CodexRuntimeHostedWebSearchScope?
    ) -> CapabilityLease {
        let tools: Set<ToolCapability>
        if isRoot {
            tools = Self.rootBusinessTools(
                workspaceAccess: workspaceAccess,
                includesSessionNaming: sessionNaming != nil,
                includesWorkTaskManagement: true,
                includesHostedWebSearch:
                    hostedWebSearchScope != nil,
                knowledgeCapabilities:
                    registryAugmenter?.additionalCapabilities ?? [])
        } else {
            var childTools = CapabilityLease.worker(
                workspaceAccess: workspaceAccess).tools
            childTools.remove(.generateMedia)
            childTools.remove(.hostedWebSearch)
            if workspaceAccess == .readWrite {
                childTools.formUnion(
                    ToolCapability.exactImageMutationCapabilities)
                if hostedWebSearchScope != nil {
                    childTools.insert(.hostedWebSearch)
                }
            }
            if let registryAugmenter {
                var additions = knowledgeCapabilities.intersection(
                    registryAugmenter.additionalCapabilities)
                if workspaceAccess == .readOnly {
                    additions.remove(.buildKnowledge)
                }
                childTools.formUnion(additions)
            }
            tools = childTools
        }
        let material = [
            sessionID.rawValue,
            agentID.rawValue,
            workspaceAccess.rawValue,
            isRoot ? "root" : "child",
            tools.map(\.rawValue).sorted().joined(separator: ","),
        ].joined(separator: "\u{001F}")
        return CapabilityLease(
            id: CapabilityLeaseID(
                rawValue: "clease_codex_business_"
                    + String(ToolRegistry.authorizationDigest(material)
                        .prefix(24))),
            tools: tools,
            expiresAtTaskCompletion: false)
    }

    private static func knowledgeCapability(
        for toolName: String
    ) -> ToolCapability? {
        switch toolName {
        case "build_knowledge": return .buildKnowledge
        case "search_knowledge": return .searchKnowledge
        default: return nil
        }
    }

    /// Rebinds the existing hosted-search registration to the exact service
    /// selected by the verified root/role scope. The descriptor and registry
    /// identity remain unchanged; no live provider lookup or alternate route
    /// occurs during execution.
    private static func bindingHostedWebSearch(
        in registry: ToolRegistry,
        service: any HostedWebSearchToolService
    ) -> ToolRegistry {
        var registrations = registry.descriptors().compactMap {
            registry.registration(named: $0.name)
        }
        registrations.removeAll {
            $0.descriptor.name
                == HostedWebSearchTool.descriptor.name
        }
        registrations.append(ToolRegistration(
            tool: HostedWebSearchTool(service: service),
            grantingCapabilities: [.hostedWebSearch]))
        return ToolRegistry(
            registrations: registrations,
            registryVersion: registry.registryVersion)
    }

    private static func hostedWebSearchScopeSortKey(
        _ scope: CodexRuntimeHostedWebSearchScope
    ) -> String {
        switch scope {
        case .root:
            return "0:root"
        case .childRole(let roleName):
            return "1:\(roleName)"
        }
    }

    private static func durableToolCallID(
        _ call: CodexRuntimeDynamicToolCall
    ) -> String {
        "codex:\(call.threadID):\(call.turnID):\(call.callID)"
    }

    private static func sessionRenameContainsSecret(
        _ normalizedArguments: String
    ) -> Bool {
        struct Arguments: Decodable { let name: String }
        guard let data = normalizedArguments.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(
                Arguments.self,
                from: data) else {
            return false
        }
        return SecretScanner.containsSecret(arguments.name)
    }

    private static func isImageMutationTool(_ name: String) -> Bool {
        name == GenerateImageTool.descriptor.name
            || name == EditImageTool.descriptor.name
    }

    private static func isFirstPartyBusinessTool(_ name: String) -> Bool {
        if name == "web_fetch" || name.hasPrefix("browser_") {
            return true
        }
        if name.hasPrefix("docx_")
            || name.hasPrefix("pptx_")
            || name.hasPrefix("xlsx_") {
            return true
        }
        return [
            "task_create", "task_update", "task_get", "task_list",
            "task_link_agent",
            "inspect_pdf", "read_pdf",
            "read_docx", "continue_docx_read",
            "read_pptx", "continue_pptx_read",
            "read_xlsx", "continue_xlsx_read",
            "read_html", "continue_html_read",
            "read_epub", "continue_epub_read",
            "ocr_pdf", "pdf_render_page", "compile_latex",
            "generate_image", "edit_image",
            "hosted_web_search",
            "html_export_pdf",
            "build_knowledge", "search_knowledge",
        ].contains(name)
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path != rootPath else { return "." }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func path(
        _ path: String,
        matches pattern: String
    ) -> Bool {
        let normalizedPath = path.replacingOccurrences(
            of: "\\",
            with: "/")
        let normalizedPattern = pattern.replacingOccurrences(
            of: "\\",
            with: "/")
        if !normalizedPattern.contains("/") {
            return normalizedPath.split(separator: "/").contains {
                glob(String($0), matches: normalizedPattern)
            }
        }
        return glob(normalizedPath, matches: normalizedPattern)
    }

    private static func glob(
        _ value: String,
        matches pattern: String
    ) -> Bool {
        var expression = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex,
                   pattern[next] == "*" {
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
        guard let regex = try? NSRegularExpression(
            pattern: expression) else {
            return false
        }
        let range = NSRange(
            value.startIndex..<value.endIndex,
            in: value)
        return regex.firstMatch(
            in: value,
            range: range) != nil
    }
}
