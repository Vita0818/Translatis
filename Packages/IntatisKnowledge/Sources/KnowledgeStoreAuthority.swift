import Foundation
import IntatisCore
import IntatisProtocol

public struct KnowledgeExternalAuthorityRequest: Sendable {
    public let requestedRoot: URL
    public let sessionID: SessionID
    public let agentID: AgentID
    public let taskID: TaskID?
    public let operation: KnowledgeLeaseOperation
    public let authorizationID: String

    public init(requestedRoot: URL,
                sessionID: SessionID,
                agentID: AgentID,
                taskID: TaskID?,
                operation: KnowledgeLeaseOperation,
                authorizationID: String) {
        self.requestedRoot = requestedRoot
        self.sessionID = sessionID
        self.agentID = agentID
        self.taskID = taskID
        self.operation = operation
        self.authorizationID = authorizationID
    }
}

/// App/CLI-owned exact-directory authorization seam. The macOS host resolves
/// and retains a security-scoped bookmark; CLI creates an explicit permission
/// reference. Neither implementation is available to the model.
public struct KnowledgeExternalAuthorityProvider: Sendable {
    public typealias Operation = @Sendable (
        KnowledgeExternalAuthorityRequest
    ) async throws -> KnowledgeExternalAuthorityGrant

    private let operation: Operation

    public init(operation: @escaping Operation) {
        self.operation = operation
    }

    public func acquire(
        _ request: KnowledgeExternalAuthorityRequest
    ) async throws -> KnowledgeExternalAuthorityGrant {
        try await operation(request)
    }
}

public struct KnowledgeExternalAuthorityGrant: Sendable {
    public let lease: KnowledgeLease
    private let releaseOperation: @Sendable () async -> Void

    public init(lease: KnowledgeLease,
                release: @escaping @Sendable () async -> Void = {}) {
        self.lease = lease
        releaseOperation = release
    }

    func release() async {
        await releaseOperation()
    }
}

private actor KnowledgeStoreAuthorityCloseState {
    private var closed = false
    private let closeOperation: @Sendable () async -> Void

    init(close: @escaping @Sendable () async -> Void) {
        closeOperation = close
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await closeOperation()
    }
}

/// Invocation-owned store authority. For workspace paths `knowledgeLease` is
/// nil and the existing exact WorkspaceLease remains authoritative. External
/// paths carry a dedicated KnowledgeLease plus only its private store
/// projection.
public final class KnowledgeStoreAuthorityHandle: @unchecked Sendable {
    public let storeRoot: URL
    public let knowledgeLease: KnowledgeLease?
    let storeWorkspaceLease: WorkspaceLease
    private let closeState: KnowledgeStoreAuthorityCloseState

    init(storeRoot: URL,
         knowledgeLease: KnowledgeLease?,
         storeWorkspaceLease: WorkspaceLease,
         close: @escaping @Sendable () async -> Void) {
        self.storeRoot = storeRoot
        self.knowledgeLease = knowledgeLease
        self.storeWorkspaceLease = storeWorkspaceLease
        closeState = KnowledgeStoreAuthorityCloseState(close: close)
    }

    public func close() async {
        await closeState.close()
    }

    deinit {
        let state = closeState
        Task { await state.close() }
    }
}

public struct KnowledgeStoreAuthorityResolver: Sendable {
    public let externalProvider: KnowledgeExternalAuthorityProvider?

    public init(externalProvider: KnowledgeExternalAuthorityProvider? = nil) {
        self.externalProvider = externalProvider
    }

    public func resolve(
        storePath: String,
        operation: KnowledgeLeaseOperation,
        authorization: ResolvedToolAuthorization,
        workspaceLease: WorkspaceLease
    ) async throws -> KnowledgeStoreAuthorityHandle {
        guard let sessionID = authorization.sessionID,
              let agentID = authorization.agent,
              authorization.workspaceLeaseID == workspaceLease.id,
              authorization.workspaceRootIdentity == workspaceLease.rootIdentity,
              let workspaceIdentity = workspaceLease.rootIdentity,
              workspaceIdentity.matchesCurrentDirectory(
                rootPath: workspaceLease.rootPath) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge path resolution lacks an exact active invocation authority.")
        }
        let workspace = URL(
            fileURLWithPath: workspaceIdentity.canonicalPath,
            isDirectory: true)
        let requested: URL
        if NSString(string: storePath).isAbsolutePath {
            requested = URL(
                fileURLWithPath: storePath,
                isDirectory: true).standardizedFileURL
        } else {
            requested = try PathConfinement.resolve(storePath, within: workspace)
        }

        if PathConfinement.isWithin(requested.path, root: workspace) {
            let confined = try PathConfinement.resolve(requested.path, within: workspace)
            guard workspaceLease.access == .readWrite || operation == .search else {
                throw KnowledgeDomainError(
                    .accessDenied,
                    "Knowledge build/update requires a read-write WorkspaceLease.")
            }
            return KnowledgeStoreAuthorityHandle(
                storeRoot: confined,
                knowledgeLease: nil,
                storeWorkspaceLease: workspaceLease,
                close: {})
        }

        let externalRoot = try KnowledgeLease.validateRequestedPath(storePath)
        guard externalRoot.path == requested.path,
              let externalProvider else {
            throw KnowledgeDomainError(
                .accessDenied,
                "This external knowledge directory has no exact host authorization provider.")
        }
        let grant = try await externalProvider.acquire(
            KnowledgeExternalAuthorityRequest(
                requestedRoot: externalRoot,
                sessionID: sessionID,
                agentID: agentID,
                taskID: authorization.taskID,
                operation: operation,
                authorizationID: authorization.authorizationID))
        let lease = grant.lease
        do {
            try lease.validate(
                sessionID: sessionID,
                agentID: agentID,
                taskID: authorization.taskID,
                turnID: nil,
                operation: operation)
            guard lease.rootPath == requested.path else {
                throw KnowledgeDomainError(
                    .accessDenied,
                    "External knowledge authorization selected a different directory.")
            }
            return KnowledgeStoreAuthorityHandle(
                storeRoot: URL(
                    fileURLWithPath: lease.rootPath,
                    isDirectory: true),
                knowledgeLease: lease,
                storeWorkspaceLease: lease.projectedStoreWorkspaceLease(),
                close: { await grant.release() })
        } catch {
            await grant.release()
            throw error
        }
    }
}
