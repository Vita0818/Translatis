import Foundation
import IntatisCore
import IntatisKnowledge
import IntatisProtocol
import IntatisProviders
import IntatisTools

/// Composes the shipping CLI Knowledge surface only when both independent
/// model roles are configured. This keeps Chat and partially configured
/// processes from advertising tools that cannot satisfy the RAG contract.
func cliKnowledgeToolsConfigurationNotice(
    config: CLIConfig
) -> String? {
    do {
        try ProviderRegistry.validateKnowledgeConfiguration(
            config.providerConfig())
        return nil
    } catch {
        return error.localizedDescription
    }
}

func makeCLIKnowledgeToolAugmenter(
    config: CLIConfig,
    registry: ProviderRegistry
) -> HostToolRegistryAugmenter? {
    guard cliKnowledgeToolsConfigurationNotice(config: config) == nil else {
        return nil
    }

    let authority = KnowledgeExternalAuthorityProvider { request in
        let requested = try prepareCLIKnowledgeDirectory(
            request.requestedRoot,
            operation: request.operation)

        let access: KnowledgeLeaseAccess = request.operation == .search
            ? .readOnly
            : .readWrite
        let reference = KnowledgeDigest.sha256(
            IntatisHostApplication.identity.temporaryPrefix(
                "cli-knowledge-authorization/1") + "\n"
                + request.authorizationID + "\n" + requested.path)
        let lease = try KnowledgeLease(
            root: requested,
            sessionID: request.sessionID,
            agentID: request.agentID,
            taskID: request.taskID,
            reuseScope: .session,
            access: access,
            operations: [request.operation],
            authorizationReferenceKind: .cliPermission,
            authorizationReferenceDigest: reference)
        return KnowledgeExternalAuthorityGrant(lease: lease)
    }

    return HostToolRegistryAugmenter(
        additionalCapabilities: [.buildKnowledge, .searchKnowledge]) { input in
            // Route resolution is secret-free. Each provider adapter resolves
            // its credential lazily at the actual embedding/rerank request.
            let models = try await registry.configuredKnowledgeModels()
            let embedding = try ProviderKnowledgeEmbeddingAdapter(
                provider: models.embedding)
            let reranker = try ProviderKnowledgeRerankerAdapter(
                provider: models.reranker)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let host = try ModelDrivenKnowledgeToolHost(
                embeddingProvider: embedding,
                rerankerProvider: reranker,
                authorityResolver: KnowledgeStoreAuthorityResolver(
                    externalProvider: authority),
                policy: KnowledgeSearchPolicy(
                    evaluationDate: formatter.string(from: Date())))
            return try await host.augment(input)
        }
}

/// Materializes at most the final exact directory component after the tool call
/// has passed permission review. Missing ancestors are never created as an
/// incidental expansion of the requested Knowledge authority.
func prepareCLIKnowledgeDirectory(
    _ requestedRoot: URL,
    operation: KnowledgeLeaseOperation
) throws -> URL {
    let requested = try KnowledgeLease.validateRequestedPath(
        requestedRoot.path)
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    let exists = fileManager.fileExists(
        atPath: requested.path,
        isDirectory: &isDirectory)

    if exists {
        guard isDirectory.boolValue else {
            throw KnowledgeDomainError(
                .unsafeStorage,
                "The authorized knowledge path is not a directory.")
        }
        return requested
    }

    guard operation == .build else {
        throw KnowledgeDomainError(
            .accessDenied,
            "The external knowledge directory does not exist.")
    }
    let parent = requested.deletingLastPathComponent()
    var parentIsDirectory: ObjCBool = false
    guard fileManager.fileExists(
            atPath: parent.path,
            isDirectory: &parentIsDirectory),
          parentIsDirectory.boolValue else {
        throw KnowledgeDomainError(
            .accessDenied,
            "The external knowledge directory parent must already exist.")
    }
    do {
        try fileManager.createDirectory(
            at: requested,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
    } catch {
        throw KnowledgeDomainError(
            .unsafeStorage,
            "The exact external knowledge directory could not be created safely.")
    }
    return try KnowledgeLease.validateRequestedPath(requested.path)
}
