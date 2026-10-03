import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

/// Host-only input for mounting one exact current retrieval snapshot. The
/// store root never enters a model-facing descriptor or tool argument.
public struct KnowledgeSearchToolHostInput: Sendable {
    public let storeRoot: URL
    public let sessionID: SessionID
    public let agentID: AgentID
    public let taskID: TaskID?
    public let capabilityLease: CapabilityLease
    public let workspaceLease: WorkspaceLease
    public let baseRegistry: ToolRegistry

    public init(storeRoot: URL,
                sessionID: SessionID,
                agentID: AgentID,
                taskID: TaskID?,
                capabilityLease: CapabilityLease,
                workspaceLease: WorkspaceLease,
                baseRegistry: ToolRegistry) {
        self.storeRoot = storeRoot
        self.sessionID = sessionID
        self.agentID = agentID
        self.taskID = taskID
        self.capabilityLease = capabilityLease
        self.workspaceLease = workspaceLease
        self.baseRegistry = baseRegistry
    }
}

/// Thin host adapter from an exact store/workspace authority to one
/// snapshot-bound `search_knowledge` registration. It owns no global mount
/// configuration and can therefore be injected into Code/Cowork without
/// changing Chat, iOS, or their dependency graph.
public struct KnowledgeSearchToolHostAdapter: Sendable {
    public let mountRegistry: KnowledgeMountRegistry
    public let embeddingRegistry: KnowledgeEmbeddingRuntimeRegistry
    public let rerankerRegistry: KnowledgeRerankerRuntimeRegistry?
    public let policy: KnowledgeSearchPolicy
    public let executionSemantics: KnowledgeSearchExecutionSemantics
    public let closeTimeoutNanoseconds: UInt64

    public init(
        mountRegistry: KnowledgeMountRegistry,
        embeddingRegistry: KnowledgeEmbeddingRuntimeRegistry,
        rerankerRegistry: KnowledgeRerankerRuntimeRegistry? = nil,
        policy: KnowledgeSearchPolicy,
        executionSemantics: KnowledgeSearchExecutionSemantics = .localOnly,
        closeTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.mountRegistry = mountRegistry
        self.embeddingRegistry = embeddingRegistry
        self.rerankerRegistry = rerankerRegistry
        self.policy = policy
        self.executionSemantics = executionSemantics
        self.closeTimeoutNanoseconds = max(1, closeTimeoutNanoseconds)
    }

    /// Bridges this concrete knowledge host into the generic Code/Cowork seam.
    /// The root remains captured by host code and is never placed in the
    /// returned registry.
    public func augmenter(storeRoot: URL) -> HostToolRegistryAugmenter {
        HostToolRegistryAugmenter(
            additionalCapabilities: [.searchKnowledge]) { input in
                try await augment(KnowledgeSearchToolHostInput(
                    storeRoot: storeRoot,
                    sessionID: input.sessionID,
                    agentID: input.agentID,
                    taskID: input.taskID,
                    capabilityLease: input.capabilityLease,
                    workspaceLease: input.workspaceLease,
                    baseRegistry: input.baseRegistry))
            }
    }

    public func augment(
        _ input: KnowledgeSearchToolHostInput
    ) async throws -> HostToolRegistryAugmentationLease {
        let workspaceRootIdentity = try Self.validateAuthority(input)
        guard input.baseRegistry.registration(named: "search_knowledge") == nil else {
            throw KnowledgeDomainError(
                .accessDenied,
                "The base tool registry already reserves search_knowledge.")
        }

        let store = try KnowledgeSnapshotStore(
            root: input.storeRoot,
            workspaceLease: input.workspaceLease)
        let pointer = try store.loadCurrentPointer()
        let authority = KnowledgeMountAuthority(
            sessionID: input.sessionID,
            agentID: input.agentID,
            taskID: input.taskID,
            capabilityLeaseID: input.capabilityLease.id,
            workspaceLeaseID: input.workspaceLease.id,
            workspaceRootIdentity: workspaceRootIdentity)
        let binding = try await mountRegistry.mountExactSnapshot(
            store: store,
            snapshotID: pointer.currentSnapshot,
            snapshotRevision: pointer.currentSnapshotRevision,
            authority: authority)

        do {
            let confirmedPointer = try store.loadCurrentPointer()
            guard confirmedPointer == pointer,
                  binding.storeID == confirmedPointer.storeID,
                  binding.storePointerRevision == confirmedPointer.revision,
                  binding.snapshotID == confirmedPointer.currentSnapshot,
                  binding.snapshotRevision
                    == confirmedPointer.currentSnapshotRevision else {
                throw KnowledgeDomainError(
                    .revisionChanged,
                    retryable: true,
                    "The knowledge store changed during exact current-snapshot mounting.")
            }
            let registration = try SearchKnowledgeTool.registration(
                mountRegistry: mountRegistry,
                embeddingRegistry: embeddingRegistry,
                rerankerRegistry: rerankerRegistry,
                policy: policy,
                boundTo: binding,
                executionSemantics: executionSemantics)
            let component = try SearchKnowledgeTool.registryVersionComponent(
                binding: binding,
                embeddingRegistry: embeddingRegistry,
                rerankerRegistry: rerankerRegistry,
                policy: policy,
                executionSemantics: executionSemantics)
            let registryVersion = KnowledgeHostIdentity
                .namespaced("host-tools.v1.")
                + ToolRegistry.authorizationDigest([
                    input.baseRegistry.registryVersion,
                    component,
                ].joined(separator: "\u{1f}"))
            let registry = input.baseRegistry.adding(
                registrations: [registration],
                registryVersion: registryVersion)
            guard registry.registration(named: "search_knowledge") != nil else {
                throw KnowledgeDomainError(
                    .accessDenied,
                    "The augmented registry could not bind search_knowledge uniquely.")
            }
            let handle = binding.handle
            let mountRegistry = mountRegistry
            let timeout = closeTimeoutNanoseconds
            return HostToolRegistryAugmentationLease(
                registry: registry,
                close: {
                    await mountRegistry.revokeAndDrain(
                        handle,
                        timeoutNanoseconds: timeout)
                })
        } catch {
            _ = await mountRegistry.revokeAndDrain(
                binding.handle,
                timeoutNanoseconds: closeTimeoutNanoseconds)
            throw error
        }
    }

    private static func validateAuthority(
        _ input: KnowledgeSearchToolHostInput
    ) throws -> WorkspaceRootIdentity {
        guard input.capabilityLease.tools.contains(.searchKnowledge),
              input.capabilityLease.taskID == nil
                || input.capabilityLease.taskID == input.taskID,
              input.workspaceLease.taskID == nil
                || input.workspaceLease.taskID == input.taskID,
              let rootIdentity = input.workspaceLease.rootIdentity,
              rootIdentity.matchesCurrentDirectory(
                rootPath: input.workspaceLease.rootPath) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge tool mounting requires exact capability, task, and workspace leases.")
        }
        return rootIdentity
    }
}
