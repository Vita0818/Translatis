import Foundation
import IntatisCore
import IntatisProtocol
import IntatisTools

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Hard limits for one host-owned knowledge snapshot build. These limits are
/// enforced independently of the parser and secure-filesystem limits so a
/// caller cannot turn a valid but very large draft into an unbounded embedding
/// or index operation.
public struct KnowledgeBuildBudget: Equatable, Sendable {
    public var maximumDraftFiles = 20_000
    public var maximumDraftBytes = 512 * 1_024 * 1_024
    public var maximumChunks = 100_000
    public var maximumEmbeddingInputBytes = 256 * 1_024 * 1_024
    public var maximumVectorScalars = 100_000_000
    public var maximumLexicalTokens = 5_000_000
    public var maximumDerivedBytes = 768 * 1_024 * 1_024
    public var embeddingBatchSize = 64
    public var maximumWallTimeSeconds = 30 * 60
    public var maximumWriterWaitSeconds = 30

    public init() {}
}

/// Canonical non-secret identity that the future `build_knowledge`
/// ToolRegistration must use as its `authorizationArgumentIdentity`. Keeping
/// the projection here lets the executor prove that reviewed paths, store
/// generation, trust policy and exact embedding route are the ones it runs.
public enum KnowledgeBuildAuthorizationIdentity {
    public static func canonical(
        draftRoot: URL,
        storeRoot: URL,
        expectedStoreID: String?,
        expectedSnapshotID: String? = nil,
        workspaceLease: WorkspaceLease,
        storeLease: KnowledgeLease? = nil,
        embeddingModel: KnowledgeEmbeddingModelIdentity,
        rerankerModel: KnowledgeRerankerModelIdentity? = nil,
        trustedVerificationActors: Set<String>
    ) throws -> String {
        guard let workspaceIdentity = workspaceLease.rootIdentity,
              workspaceIdentity.matchesCurrentDirectory(
                rootPath: workspaceLease.rootPath) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge build authorization workspace identity changed.")
        }
        let workspace = URL(
            fileURLWithPath: workspaceIdentity.canonicalPath,
            isDirectory: true)
        let draft = try PathConfinement.resolve(draftRoot.path, within: workspace)
        let standardizedStore = storeRoot.standardizedFileURL
        let storeAuthority: String
        let workspacePrefix = workspace.path.hasSuffix("/")
            ? workspace.path
            : workspace.path + "/"
        if standardizedStore.path == workspace.path
            || standardizedStore.path.hasPrefix(workspacePrefix) {
            let store = try PathConfinement.resolve(storeRoot.path, within: workspace)
            storeAuthority = "workspace:" + PathConfinement.relativePath(
                of: store,
                root: workspace)
        } else {
            guard standardizedStore.path.hasPrefix("/"),
                  storeLease == nil
                    || (standardizedStore.path == storeLease?.rootPath
                        && storeLease?.rootIdentity.matchesCurrentDirectory(
                            rootPath: standardizedStore.path) == true) else {
                throw KnowledgeDomainError(
                    .accessDenied,
                    "Knowledge build store authority changed.")
            }
            storeAuthority = "external-request:"
                + KnowledgeDigest.sha256(standardizedStore.path)
        }
        struct Projection: Codable {
            let version: String
            let draftPath: String
            let storeAuthority: String
            let expectedStoreID: String?
            let expectedSnapshotID: String?
            let embeddingModel: KnowledgeEmbeddingModelIdentity
            let rerankerModel: KnowledgeRerankerModelIdentity?
            let trustedVerificationActors: [String]
        }
        let data = try KnowledgeJSON.encode(Projection(
            version: KnowledgeHostIdentity.schema(
                "knowledge-build-authorization/2"),
            draftPath: PathConfinement.relativePath(of: draft, root: workspace),
            storeAuthority: storeAuthority,
            expectedStoreID: expectedStoreID,
            expectedSnapshotID: expectedSnapshotID,
            embeddingModel: embeddingModel,
            rerankerModel: rerankerModel,
            trustedVerificationActors: trustedVerificationActors.sorted()))
        guard let value = String(data: data, encoding: .utf8) else {
            throw KnowledgeDomainError(
                .internalError,
                "Knowledge build authorization identity could not be encoded.")
        }
        return value
    }

    public static func digest(_ canonicalIdentity: String) -> String {
        String(KnowledgeDigest.sha256(canonicalIdentity).dropFirst("sha256:".count))
    }
}

/// Exact, already-reviewed build request. `authorization` is not a substitute
/// for the durable execution ticket: the host must first validate it against
/// the frozen ToolRegistry entry and settle the existing permission workflow.
/// The build service rechecks the immutable execution facts again at its own
/// filesystem boundary.
public struct KnowledgeBundleBuildRequest: Sendable {
    public let draftRoot: URL
    public let storeRoot: URL
    public let expectedStoreID: String?
    public let expectedSnapshotID: String?
    public let workspaceLease: WorkspaceLease
    public let storeLease: KnowledgeLease?
    public let authorization: ResolvedToolAuthorization
    /// Host policy input. This set must be resolved outside model-authored
    /// arguments; an OKF draft cannot grant trust to its own `verified.by`.
    public let trustedVerificationActors: Set<String>

    public init(draftRoot: URL,
                storeRoot: URL,
                expectedStoreID: String? = nil,
                expectedSnapshotID: String? = nil,
                workspaceLease: WorkspaceLease,
                storeLease: KnowledgeLease? = nil,
                authorization: ResolvedToolAuthorization,
                trustedVerificationActors: Set<String> = []) {
        self.draftRoot = draftRoot
        self.storeRoot = storeRoot
        self.expectedStoreID = expectedStoreID
        self.expectedSnapshotID = expectedSnapshotID
        self.workspaceLease = workspaceLease
        self.storeLease = storeLease
        self.authorization = authorization
        self.trustedVerificationActors = trustedVerificationActors
    }
}

public struct KnowledgeBundleBuildResult: Equatable, Sendable {
    public let storeID: String
    public let storeRevision: Int
    public let snapshotID: String
    public let snapshotRevision: String
    public let bundleRevision: String
    public let conceptCount: Int
    public let chunkCount: Int
    public let vectorCount: Int
    public let reusedVectorCount: Int
    public let embeddedVectorCount: Int
    public let embeddingRequestTextCount: Int
    public let diagnostics: [KnowledgeDiagnostic]
}

/// Builds one complete immutable OKF/Profile retrieval snapshot and publishes
/// it by atomically switching the store pointer. It never edits an active
/// snapshot in place and never falls back to a merely similar embedding route.
public struct KnowledgeBundleBuildService: Sendable {
    public let fileSystem: KnowledgeSecureFileSystem
    public let okfReader: OKFReader
    public let chunker: DeterministicKnowledgeChunker
    public let validator: KnowledgeValidator
    public let embeddingProvider: any KnowledgeEmbeddingProvider
    public let rerankerModel: KnowledgeRerankerModelIdentity?

    private let now: @Sendable () -> Date
    private let opaqueID: @Sendable () -> String

    public init(fileSystem: KnowledgeSecureFileSystem = KnowledgeSecureFileSystem(),
                okfReader: OKFReader = OKFReader(),
                chunker: DeterministicKnowledgeChunker = DeterministicKnowledgeChunker(),
                validator: KnowledgeValidator? = nil,
                embeddingProvider: any KnowledgeEmbeddingProvider,
                rerankerModel: KnowledgeRerankerModelIdentity? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                opaqueID: @escaping @Sendable () -> String = {
                    UUID().uuidString.lowercased()
                }) throws {
        self.fileSystem = fileSystem
        self.okfReader = okfReader
        self.chunker = chunker
        self.validator = try validator ?? KnowledgeValidator(
            fileSystem: fileSystem,
            okfReader: okfReader)
        self.embeddingProvider = embeddingProvider
        self.rerankerModel = rerankerModel
        self.now = now
        self.opaqueID = opaqueID
    }

    public func buildAndPublish(
        _ request: KnowledgeBundleBuildRequest,
        budget: KnowledgeBuildBudget = KnowledgeBuildBudget()
    ) async throws -> KnowledgeBundleBuildResult {
        do {
            return try await buildAndPublishAuthorized(request, budget: budget)
        } catch is CancellationError {
            throw KnowledgeDomainError(
                .searchCancelled,
                "Knowledge snapshot build was cancelled before its commit boundary.")
        } catch let domain as KnowledgeDomainError {
            throw domain
        } catch let error as DurableOwnerOnlyFileError {
            switch error {
            case .unsafeFile, .verificationFailed, .fileTooLarge:
                throw KnowledgeDomainError(
                    .unsafeStorage,
                    "Knowledge store metadata did not satisfy the owner-only storage contract.")
            case .commitUncertain:
                throw KnowledgeDomainError(
                    .commitUncertain,
                    retryable: false,
                    "Knowledge store publication may have committed and requires disk reconciliation.")
            case .lockFailed:
                throw KnowledgeDomainError(
                    .searchTimeout,
                    retryable: true,
                    "Knowledge store writer admission could not be acquired.")
            case .readFailed, .writeFailed:
                throw KnowledgeDomainError(
                    .internalError,
                    retryable: true,
                    "Knowledge store metadata could not be persisted durably.")
            }
        } catch {
            throw KnowledgeDomainError(
                .internalError,
                retryable: true,
                "Knowledge snapshot build failed at a bounded host operation.")
        }
    }

    private func buildAndPublishAuthorized(
        _ request: KnowledgeBundleBuildRequest,
        budget: KnowledgeBuildBudget
    ) async throws -> KnowledgeBundleBuildResult {
        try Self.validate(budget)
        let deadline = KnowledgeBuildDeadline(seconds: budget.maximumWallTimeSeconds)
        try deadline.check()

        let roots = try validateAdmission(request)
        let storage = KnowledgeBuildStorage()
        let snapshotStore = try KnowledgeSnapshotStore(
            root: roots.store,
            workspaceLease: roots.storeWorkspaceLease,
            createIfMissing: true,
            fileSystem: fileSystem)
        let writer = try await acquireWriterLease(
            store: snapshotStore,
            deadline: deadline,
            maximumWaitSeconds: budget.maximumWriterWaitSeconds)
        defer { writer.release() }
        try deadline.check()

        // The pointer is read only after the exclusive cross-process lease is
        // held. A valid pointer is also a required integrity boundary for
        // incremental reuse; a corrupt current snapshot is never silently
        // searched for a compatible historical fallback.
        let existingPointer = try writer.currentPointer()
        guard (request.expectedStoreID == nil)
                == (request.expectedSnapshotID == nil) else {
            throw KnowledgeDomainError(
                .toolInputInvalid,
                "Existing-store updates require both expected_store_id and expected_snapshot_id.")
        }
        if let expected = request.expectedStoreID {
            guard Self.validStoreID(expected), existingPointer?.storeID == expected else {
                throw KnowledgeDomainError(
                    .revisionChanged,
                    retryable: true,
                    "The selected knowledge store identity changed before build admission.")
            }
        }
        if let expected = request.expectedSnapshotID {
            guard Self.validSnapshotID(expected),
                  existingPointer?.currentSnapshot == expected else {
                throw KnowledgeDomainError(
                    .revisionChanged,
                    retryable: true,
                    "The selected knowledge snapshot changed before build admission.")
            }
        }
        if request.expectedStoreID == nil, existingPointer != nil {
            throw KnowledgeDomainError(
                .revisionChanged,
                retryable: true,
                "An existing knowledge store requires expected_store_id and expected_snapshot_id.")
        }

        let storeID = existingPointer?.storeID ?? "kb_\(opaqueID())"
        let snapshotID = "snap_\(opaqueID())"
        guard Self.validStoreID(storeID), Self.validSnapshotID(snapshotID) else {
            throw KnowledgeDomainError(
                .internalError,
                "The host generated an invalid opaque knowledge identity.")
        }

        let staging = try writer.createStagingSnapshot(snapshotID: snapshotID)
        let stagingRoot = staging.root
        var ownsStaging = true
        defer {
            if ownsStaging {
                try? writer.abortStagingSnapshot(staging)
            }
        }

        let createdAt = Self.timestamp(now())
        let copied = try copyCanonicalDraft(
            from: roots.draft,
            to: stagingRoot,
            rootIdentity: roots.draftIdentity,
            workspaceLease: request.workspaceLease,
            budget: budget,
            storage: storage,
            deadline: deadline)
        guard copied.contains("index.md") else {
            throw KnowledgeDomainError(.okfInvalid, "OKF draft is missing its root index.md.")
        }

        let knowledgeInventory = try fileSystem.leafInventory(root: stagingRoot)
        try rejectSensitiveDraftMaterial(
            root: stagingRoot,
            inventory: knowledgeInventory,
            deadline: deadline)
        let bundleRevision = try KnowledgeSecureFileSystem.canonicalBundleDigest(
            knowledgeInventory)
        let concepts = try readConcepts(
            root: stagingRoot,
            inventory: knowledgeInventory,
            deadline: deadline)
        guard !concepts.isEmpty else {
            throw KnowledgeDomainError(.okfInvalid, "OKF draft contains no valid concepts.")
        }

        let chunking = try chunker.chunk(
            concepts: concepts,
            bundleRevision: bundleRevision,
            producedAt: createdAt)
        guard !chunking.chunks.isEmpty else {
            throw KnowledgeDomainError(
                .okfInvalid,
                "OKF draft produced no grounded chunks with source identities.")
        }
        guard chunking.chunks.count <= budget.maximumChunks else {
            throw Self.budgetExceeded("Knowledge chunk count exceeds the build budget.")
        }
        let totalEmbeddingBytes = try Self.boundedSum(
            chunking.chunks.map { Data($0.text.utf8).count },
            maximum: budget.maximumEmbeddingInputBytes,
            message: "Knowledge embedding input exceeds the build budget.")
        _ = totalEmbeddingBytes

        let ragRoot = stagingRoot.appendingPathComponent(
            KnowledgeHostIdentity.bundleDirectory,
            isDirectory: true)
        let denseRoot = ragRoot.appendingPathComponent("dense", isDirectory: true)
        let lexicalRoot = ragRoot.appendingPathComponent("lexical", isDirectory: true)
        try storage.createOwnedDirectory(ragRoot)
        try storage.createOwnedDirectory(denseRoot)
        try storage.createOwnedDirectory(lexicalRoot)
        try storage.writeExclusive(
            chunking.jsonLines,
            to: ragRoot.appendingPathComponent("chunks.jsonl"))

        let previous = try existingPointer.map {
            try validatedCurrentSnapshot(
                pointer: $0,
                storeRoot: roots.store,
                workspaceLease: snapshotStore.managedContentWorkspaceLease,
                evaluationDate: createdAt,
                trustedVerificationActors: request.trustedVerificationActors)
        }
        let vectorBuild = try await buildVectors(
            chunks: chunking.chunks,
            chunking: chunking,
            previous: previous,
            budget: budget,
            deadline: deadline)
        let denseFile = KnowledgeDenseIndexFile(
            dimensions: embeddingProvider.modelIdentity.dimensions,
            vectors: vectorBuild.records)
        let lexicalFile = try buildLexicalIndex(
            chunks: chunking.chunks,
            budget: budget,
            deadline: deadline)
        let denseData = try KnowledgeJSON.encode(denseFile)
        let lexicalData = try KnowledgeJSON.encode(lexicalFile)
        _ = try Self.boundedSum(
            [chunking.jsonLines.count, denseData.count, lexicalData.count],
            maximum: budget.maximumDerivedBytes,
            message: "Knowledge derived indexes exceed the build budget.")
        let densePath = KnowledgeHostIdentity.bundlePath(
            "dense/exact-knn.json")
        let lexicalPath = KnowledgeHostIdentity.bundlePath(
            "lexical/bm25.json")
        try storage.writeExclusive(
            denseData,
            to: stagingRoot.appendingPathComponent(densePath))
        try storage.writeExclusive(
            lexicalData,
            to: stagingRoot.appendingPathComponent(lexicalPath))

        let profile = try makeProfile(
            storeID: storeID,
            snapshotID: snapshotID,
            createdAt: createdAt,
            bundleRevision: bundleRevision,
            chunking: chunking,
            densePath: densePath,
            denseData: denseData,
            denseFile: denseFile,
            lexicalPath: lexicalPath,
            lexicalData: lexicalData,
            lexicalFile: lexicalFile)
        let profileData = try KnowledgeJSON.encode(profile, pretty: true)
        try storage.writeExclusive(
            profileData,
            to: ragRoot.appendingPathComponent("profile.json"))

        let inventory = try fileSystem.leafInventory(root: stagingRoot)
        let checksums = KnowledgeChecksums(files: inventory)
        let checksumsData = try KnowledgeJSON.encode(checksums, pretty: true)
        _ = try Self.boundedSum(
            [chunking.jsonLines.count, denseData.count, lexicalData.count,
             profileData.count, checksumsData.count],
            maximum: budget.maximumDerivedBytes,
            message: "Knowledge snapshot metadata exceeds the build budget.")
        try storage.writeExclusive(
            checksumsData,
            to: ragRoot.appendingPathComponent("checksums.json"))

        try deadline.check()
        let validated = try validator.validateSnapshot(
            at: stagingRoot,
            mode: .publish,
            policy: KnowledgeValidationPolicy(
                evaluationDate: createdAt,
                trustedVerificationActors: request.trustedVerificationActors),
            workspaceLease: snapshotStore.managedContentWorkspaceLease)
        guard validated.profile == profile,
              validated.profile.retrievalSnapshot.id == snapshotID,
              validated.profile.retrievalSnapshot.revision
                == profile.retrievalSnapshot.revision else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Validated knowledge profile does not match the staged publication identity.")
        }

        // Revalidate the exact reviewed admission immediately before the
        // store-owned irreversible publish boundary. Cancellation is honored
        // through this point; the writer lease owns freeze, fsync, rename and
        // pointer activation as one storage protocol.
        try deadline.check()
        _ = try validateAdmission(request)
        let nextPointer = try writer.publishValidatedStaging(
            staging,
            validatedSnapshot: validated,
            expectedPointerRevision: existingPointer?.revision)
        ownsStaging = false
        return KnowledgeBundleBuildResult(
            storeID: storeID,
            storeRevision: nextPointer.revision,
            snapshotID: snapshotID,
            snapshotRevision: profile.retrievalSnapshot.revision,
            bundleRevision: bundleRevision,
            conceptCount: concepts.count,
            chunkCount: chunking.chunks.count,
            vectorCount: vectorBuild.records.count,
            reusedVectorCount: vectorBuild.reusedCount,
            embeddedVectorCount: vectorBuild.embeddedCount,
            embeddingRequestTextCount: vectorBuild.requestTextCount,
            diagnostics: validated.report.diagnostics)
    }

    private func validateAdmission(
        _ request: KnowledgeBundleBuildRequest
    ) throws -> (
        draft: URL,
        draftIdentity: WorkspaceRootIdentity,
        store: URL,
        storeWorkspaceLease: WorkspaceLease
    ) {
        let lease = request.workspaceLease
        let authorization = request.authorization
        guard request.trustedVerificationActors.count <= 256,
              request.trustedVerificationActors.allSatisfy({
                  !$0.isEmpty && $0.count <= 256
              }) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge verification trust policy exceeds its host-owned bounds.")
        }
        let authorizationIdentity = try KnowledgeBuildAuthorizationIdentity.canonical(
            draftRoot: request.draftRoot,
            storeRoot: request.storeRoot,
            expectedStoreID: request.expectedStoreID,
            expectedSnapshotID: request.expectedSnapshotID,
            workspaceLease: lease,
            storeLease: request.storeLease,
            embeddingModel: embeddingProvider.modelIdentity,
            rerankerModel: rerankerModel,
            trustedVerificationActors: request.trustedVerificationActors)
        struct ModelIdentityProjection: Codable {
            let embedding: KnowledgeEmbeddingModelIdentity
            let reranker: KnowledgeRerankerModelIdentity?
        }
        let modelIdentityData = try KnowledgeJSON.encode(ModelIdentityProjection(
            embedding: embeddingProvider.modelIdentity,
            reranker: rerankerModel))
        guard let modelIdentityText = String(
            data: modelIdentityData,
            encoding: .utf8),
              !PermissionReviewTextSanitizer.containsSensitiveMaterial(
                  modelIdentityText) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge embedding identity contains credential-like material.")
        }
        guard lease.access == .readWrite,
              let leaseIdentity = lease.rootIdentity,
              leaseIdentity.matchesCurrentDirectory(rootPath: lease.rootPath),
              authorization.schemaVersion == 1,
              authorization.toolName == "build_knowledge",
              authorization.canonicalAction == "build_knowledge",
              authorization.canonicalPermission == "build_knowledge",
              authorization.intent.action == "build_knowledge",
              authorization.requiredCapabilities.contains(.buildKnowledge),
              authorization.membership == .granted,
              authorization.sideEffect == .write || authorization.sideEffect == .network,
              authorization.workspaceLeaseID == lease.id,
              authorization.workspaceID == lease.workspaceID,
              authorization.workspaceTaskID == lease.taskID,
              authorization.workspaceRootPath == lease.rootPath,
              authorization.workspaceAccess == .readWrite,
              authorization.workspaceRootIdentity == lease.rootIdentity,
              authorization.workspaceLeaseFingerprint
                == ToolRegistry.authorizationFingerprint(lease),
              authorization.normalizedArgumentsDigest
                == KnowledgeBuildAuthorizationIdentity.digest(authorizationIdentity),
              authorization.normalizedArgumentsCharacterCount
                == authorizationIdentity.count,
              authorization.replayPolicy == .doNotReplay,
              authorization.intent.replayPolicy == .doNotReplay,
              authorization.deterministicGate?.decision != .deny,
              authorization.deterministicGate != nil else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge build lacks an exact reviewed read-write execution admission.")
        }
        if embeddingProvider.modelIdentity.runtimeBindingKind == .remote,
           !authorization.risksNetwork {
            throw KnowledgeDomainError(
                .accessDenied,
                "Remote embedding was not included in the reviewed knowledge build risk.")
        }

        let workspace = URL(fileURLWithPath: leaseIdentity.canonicalPath, isDirectory: true)
        let draft = try fileSystem.authorizeRoot(
            request.draftRoot,
            workspaceLease: lease)
        let storeWorkspaceLease: WorkspaceLease
        let requestedStore: URL
        if let knowledgeLease = request.storeLease {
            guard let sessionID = authorization.sessionID,
                  let agentID = authorization.agent else {
                throw KnowledgeDomainError(
                    .accessDenied,
                    "External knowledge authority requires exact session and agent identity.")
            }
            try knowledgeLease.validate(
                sessionID: sessionID,
                agentID: agentID,
                taskID: authorization.taskID,
                turnID: nil,
                operation: request.expectedStoreID == nil ? .build : .update)
            guard request.storeRoot.standardizedFileURL.path
                    == knowledgeLease.rootPath else {
                throw KnowledgeDomainError(
                    .accessDenied,
                    "The requested knowledge directory does not match its exact lease.")
            }
            storeWorkspaceLease = knowledgeLease.projectedStoreWorkspaceLease()
            requestedStore = URL(
                fileURLWithPath: knowledgeLease.rootPath,
                isDirectory: true)
        } else {
            storeWorkspaceLease = lease
            requestedStore = try PathConfinement.resolve(
                request.storeRoot.path,
                within: workspace)
        }
        let store: URL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: requestedStore.path,
            isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw KnowledgeDomainError(
                    .unsafeStorage,
                    "Knowledge store path is not a directory.")
            }
            store = try fileSystem.authorizeRoot(
                requestedStore,
                workspaceLease: storeWorkspaceLease).canonical
        } else {
            guard request.storeLease == nil else {
                throw KnowledgeDomainError(
                    .unsafeStorage,
                    "An external KnowledgeLease must bind an existing exact directory.")
            }
            var ancestor = requestedStore.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: ancestor.path) {
                let parent = ancestor.deletingLastPathComponent()
                guard parent.path != ancestor.path else {
                    throw KnowledgeDomainError(
                        .accessDenied,
                        "Knowledge store has no authorized existing ancestor.")
                }
                ancestor = parent
            }
            _ = try fileSystem.authorizeRoot(
                ancestor,
                workspaceLease: storeWorkspaceLease)
            store = requestedStore
        }
        guard draft.canonical.path != store.path,
              !PathConfinement.isWithin(draft.canonical.path, root: store),
              !PathConfinement.isWithin(store.path, root: draft.canonical) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge draft and versioned store must be separate workspace directories.")
        }
        try Self.validateLeasePath(draft.canonical, workspace: workspace, lease: lease)
        if request.storeLease == nil {
            try Self.validateLeasePath(store, workspace: workspace, lease: lease)
        }
        return (
            draft.canonical,
            draft.identity,
            store,
            storeWorkspaceLease)
    }

    private func copyCanonicalDraft(
        from draft: URL,
        to staging: URL,
        rootIdentity: WorkspaceRootIdentity,
        workspaceLease: WorkspaceLease,
        budget: KnowledgeBuildBudget,
        storage: KnowledgeBuildStorage,
        deadline: KnowledgeBuildDeadline
    ) throws -> Set<String> {
        let scanned = try fileSystem.scan(
            root: draft,
            expectedRootIdentity: rootIdentity)
        guard scanned.count <= budget.maximumDraftFiles else {
            throw Self.budgetExceeded("OKF draft file count exceeds the build budget.")
        }
        _ = try Self.boundedSum(
            scanned.map(\.identity.size),
            maximum: budget.maximumDraftBytes,
            message: "OKF draft bytes exceed the build budget.")

        var copied = Set<String>()
        var normalizedBytes = 0
        let knownPaths = Set(scanned.map(\.relativePath))
        let canonicalWriter = OKFCanonicalWriter(reader: okfReader)
        let workspace = URL(
            fileURLWithPath: workspaceLease.rootIdentity?.canonicalPath
                ?? workspaceLease.rootPath,
            isDirectory: true)
        for file in scanned {
            try deadline.check()
            let path = file.relativePath
            try Self.validateLeasePath(
                draft.appendingPathComponent(path),
                workspace: workspace,
                lease: workspaceLease)
            let name = URL(fileURLWithPath: path).lastPathComponent
            let isIndex = name == "index.md"
            let isLog = name == "log.md"
            let isConcept = OKFBundleLayout.isConcept(path)
            let isMarkdownKnowledge = isIndex || isLog || isConcept
            let isReference = path.split(separator: "/")
                .contains("references")
            guard !path.hasPrefix(
                    KnowledgeHostIdentity.bundleDirectory + "/"),
                  path != KnowledgeHostIdentity.bundleDirectory,
                  isMarkdownKnowledge || isReference else {
                throw KnowledgeDomainError(
                    .okfInvalid,
                    "OKF draft contains a file outside the fixed knowledge snapshot layout.")
            }
            var data = try fileSystem.readFile(
                root: draft,
                relativePath: path,
                maximumBytes: file.identity.size,
                expectedRootIdentity: rootIdentity)
            if isIndex {
                data = try canonicalWriter.canonicalIndex(
                    data: data,
                    relativePath: path)
            } else if isLog {
                data = try canonicalWriter.canonicalLog(
                    data: data,
                    relativePath: path)
            } else if isConcept {
                data = try canonicalWriter.canonicalConcept(
                    data: data,
                    relativePath: path,
                    draftRoot: draft,
                    knownPaths: knownPaths)
            }
            normalizedBytes = try Self.checkedAdding(normalizedBytes, data.count)
            guard normalizedBytes <= budget.maximumDraftBytes else {
                throw Self.budgetExceeded("Canonical OKF draft bytes exceed the build budget.")
            }
            let destination = staging.appendingPathComponent(path)
            try storage.ensureOwnedDirectory(destination.deletingLastPathComponent())
            try storage.writeExclusive(data, to: destination)
            copied.insert(path)
        }
        return copied
    }

    private func readConcepts(
        root: URL,
        inventory: [KnowledgeChecksumEntry],
        deadline: KnowledgeBuildDeadline
    ) throws -> [OKFConcept] {
        var concepts: [OKFConcept] = []
        var IDs = Set<String>()
        for entry in inventory where OKFBundleLayout.isConcept(entry.path) {
            try deadline.check()
            let concept = try okfReader.readConcept(
                data: fileSystem.readFile(
                    root: root,
                    relativePath: entry.path,
                    maximumBytes: okfReader.limits.maximumConceptBytes),
                relativePath: entry.path)
            guard IDs.insert(concept.conceptID).inserted else {
                throw KnowledgeDomainError(.okfInvalid, "OKF concept identity is duplicated.")
            }
            concepts.append(concept)
        }
        return concepts.sorted { $0.conceptID < $1.conceptID }
    }

    /// Secrets in canonical draft bytes must fail before any chunk text can be
    /// sent to an embedding runtime. The final Validator repeats this check
    /// across generated metadata and indexes immediately before publication.
    private func rejectSensitiveDraftMaterial(
        root: URL,
        inventory: [KnowledgeChecksumEntry],
        deadline: KnowledgeBuildDeadline
    ) throws {
        for entry in inventory {
            try deadline.check()
            let metadata = "\(entry.path)\n\(entry.role)"
            let data = try fileSystem.readFile(
                root: root,
                relativePath: entry.path,
                maximumBytes: entry.size)
            guard !PermissionReviewTextSanitizer.containsSensitiveMaterial(metadata),
                  !PermissionReviewTextSanitizer.containsSensitiveMaterial(
                      String(decoding: data, as: UTF8.self)) else {
                throw KnowledgeDomainError(
                    .integrityFailed,
                    "Knowledge draft contains credential-like material.")
            }
        }
    }

    private func validatedCurrentSnapshot(
        pointer: KnowledgeStorePointer,
        storeRoot: URL,
        workspaceLease: WorkspaceLease,
        evaluationDate: String,
        trustedVerificationActors: Set<String>
    ) throws -> KnowledgeValidatedSnapshot {
        guard Self.validSnapshotID(pointer.currentSnapshot),
              KnowledgeDigest.isValid(pointer.currentSnapshotRevision) else {
            throw KnowledgeDomainError(.integrityFailed, "Knowledge store pointer shape is invalid.")
        }
        let snapshot = storeRoot
            .appendingPathComponent(
                KnowledgeSnapshotStore.publishedSnapshotsDirectoryName,
                isDirectory: true)
            .appendingPathComponent(pointer.currentSnapshot, isDirectory: true)
        let validated = try validator.validateSnapshot(
            at: snapshot,
            mode: .mount,
            policy: KnowledgeValidationPolicy(
                evaluationDate: evaluationDate,
                trustedVerificationActors: trustedVerificationActors),
            workspaceLease: workspaceLease)
        guard validated.profile.bundle.id == pointer.storeID,
              validated.profile.retrievalSnapshot.id == pointer.currentSnapshot,
              validated.profile.retrievalSnapshot.revision
                == pointer.currentSnapshotRevision else {
            throw KnowledgeDomainError(
                .revisionChanged,
                retryable: true,
                "Current knowledge pointer does not bind the validated snapshot.")
        }
        return validated
    }

    private struct VectorBuild {
        let records: [KnowledgeDenseVectorRecord]
        let reusedCount: Int
        let embeddedCount: Int
        let requestTextCount: Int
    }

    private func buildVectors(
        chunks: [KnowledgeChunk],
        chunking: KnowledgeChunkingResult,
        previous: KnowledgeValidatedSnapshot?,
        budget: KnowledgeBuildBudget,
        deadline: KnowledgeBuildDeadline
    ) async throws -> VectorBuild {
        let dimensions = embeddingProvider.modelIdentity.dimensions
        guard dimensions > 0,
              chunks.count <= budget.maximumVectorScalars / dimensions else {
            throw Self.budgetExceeded("Knowledge vector scalar count exceeds the build budget.")
        }
        let scalarCount = chunks.count * dimensions
        // Bound JSON materialization before asking a provider for vectors. A
        // float token plus separators can exceed its four-byte in-memory form;
        // this conservative estimate prevents an otherwise bounded scalar
        // count from allocating an unbounded serialized dense index.
        guard scalarCount <= budget.maximumDerivedBytes / 24 else {
            throw Self.budgetExceeded(
                "Knowledge dense index serialization exceeds the build budget.")
        }

        var reusableByTextDigest: [String: [Float]] = [:]
        if let previous,
           let selected = previous.profile.embeddingIndexes.first(where: {
               $0.id == previous.profile.retrievalSnapshot.dense.id
           }),
           selected.model == embeddingProvider.modelIdentity,
           previous.profile.normalization == Self.normalizationProfile,
           previous.profile.chunking.algorithm
                == KnowledgeContract.deterministicChunkerIdentity,
           previous.profile.chunking.version
                == KnowledgeContract.deterministicChunkerVersion,
           previous.profile.chunking.parametersDigest == chunking.parametersDigest {
            let chunksByID = Dictionary(
                uniqueKeysWithValues: previous.chunks.map { ($0.chunkID, $0) })
            for record in previous.denseFile.vectors {
                guard let oldChunk = chunksByID[record.chunkID],
                      record.values.count == dimensions,
                      KnowledgeVectorMath.isUnitNormalized(record.values) else {
                    throw KnowledgeDomainError(
                        .integrityFailed,
                        "Current knowledge snapshot contains a non-reusable embedding vector.")
                }
                if let existing = reusableByTextDigest[oldChunk.textSha256],
                   existing != record.values {
                    throw KnowledgeDomainError(
                        .integrityFailed,
                        "Equal knowledge content hashes map to different embedding bytes.")
                }
                reusableByTextDigest[oldChunk.textSha256] = record.values
            }
        }

        var vectorByDigest: [String: [Float]] = [:]
        var textByDigest: [String: String] = [:]
        var reusedCount = 0
        for chunk in chunks {
            if let existingText = textByDigest[chunk.textSha256],
               existingText != chunk.text {
                throw KnowledgeDomainError(
                    .integrityFailed,
                    "Equal chunk hashes map to different canonical text.")
            }
            textByDigest[chunk.textSha256] = chunk.text
            if let reusable = reusableByTextDigest[chunk.textSha256] {
                vectorByDigest[chunk.textSha256] = reusable
                reusedCount += 1
            }
        }

        let pendingDigests = textByDigest.keys
            .filter { vectorByDigest[$0] == nil }
            .sorted()
        var requestTextCount = 0
        for batchStart in stride(
            from: 0,
            to: pendingDigests.count,
            by: budget.embeddingBatchSize) {
            try deadline.check()
            let batchDigests = Array(pendingDigests[
                batchStart..<min(pendingDigests.count, batchStart + budget.embeddingBatchSize)])
            let texts = try batchDigests.map { digest -> String in
                guard let text = textByDigest[digest] else {
                    throw KnowledgeDomainError(.internalError, "Embedding batch identity was lost.")
                }
                return text
            }
            let vectors: [[Float]]
            do {
                vectors = try await withDeadline(deadline: deadline) {
                    try await embeddingProvider.embedDocuments(texts)
                }
            } catch is CancellationError {
                throw KnowledgeDomainError(
                    .searchCancelled,
                    "Knowledge embedding was cancelled before publication.")
            } catch let domain as KnowledgeDomainError {
                throw domain
            } catch {
                throw KnowledgeDomainError(
                    .embeddingUnavailable,
                    retryable: true,
                    "The exact embedding runtime failed to build document vectors.")
            }
            try deadline.check()
            guard vectors.count == batchDigests.count else {
                throw KnowledgeDomainError(
                    .embeddingIncompatible,
                    "Embedding runtime returned an incompatible vector count.")
            }
            for (offset, raw) in vectors.enumerated() {
                guard raw.count == dimensions else {
                    throw KnowledgeDomainError(
                        .embeddingIncompatible,
                        "Embedding runtime returned an incompatible dimension.")
                }
                vectorByDigest[batchDigests[offset]] = try KnowledgeVectorMath.normalized(raw)
            }
            requestTextCount = try Self.checkedAdding(requestTextCount, texts.count)
        }

        let records = try chunks.sorted { $0.chunkID < $1.chunkID }.map { chunk in
            guard let vector = vectorByDigest[chunk.textSha256] else {
                throw KnowledgeDomainError(
                    .embeddingUnavailable,
                    "Knowledge embedding build is incomplete.")
            }
            return KnowledgeDenseVectorRecord(chunkID: chunk.chunkID, values: vector)
        }
        return VectorBuild(
            records: records,
            reusedCount: reusedCount,
            embeddedCount: chunks.count - reusedCount,
            requestTextCount: requestTextCount)
    }

    /// Races one request-owned embedding call against the remaining build
    /// deadline, then cancels and joins both children before returning. This
    /// keeps staging cleanup and writer-lease release ordered after provider
    /// cleanup for cancellation-responsive runtimes.
    private func withDeadline<Value: Sendable>(
        deadline: KnowledgeBuildDeadline,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let remaining = try deadline.remainingNanoseconds()
        return try await withThrowingTaskGroup(
            of: KnowledgeBuildDeadlineResult<Value>.self,
            returning: Value.self
        ) { group in
            group.addTask {
                .value(try await operation())
            }
            group.addTask {
                try await Task.sleep(nanoseconds: remaining)
                return .timedOut
            }
            do {
                guard let first = try await group.next() else {
                    throw KnowledgeDomainError(
                        .internalError,
                        "Knowledge build provider race produced no result.")
                }
                group.cancelAll()
                while true {
                    do {
                        guard try await group.next() != nil else { break }
                    } catch {
                        continue
                    }
                }
                switch first {
                case .value(let value):
                    return value
                case .timedOut:
                    throw KnowledgeDomainError(
                        .searchTimeout,
                        retryable: true,
                        "Knowledge snapshot build exceeded its wall-time budget.")
                }
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func buildLexicalIndex(
        chunks: [KnowledgeChunk],
        budget: KnowledgeBuildBudget,
        deadline: KnowledgeBuildDeadline
    ) throws -> KnowledgeLexicalIndexFile {
        var totalTokens = 0
        let documents = try chunks.sorted { $0.chunkID < $1.chunkID }.map { chunk in
            try deadline.check()
            let tokens = KnowledgeTextTokenizer.tokens(chunk.text)
            guard !tokens.isEmpty else {
                throw KnowledgeDomainError(
                    .okfInvalid,
                    "A grounded chunk produced no tokens for the required lexical index.")
            }
            totalTokens = try Self.checkedAdding(totalTokens, tokens.count)
            guard totalTokens <= budget.maximumLexicalTokens else {
                throw Self.budgetExceeded(
                    "Knowledge lexical token count exceeds the build budget.")
            }
            var terms: [String: Int] = [:]
            for token in tokens { terms[token, default: 0] += 1 }
            return KnowledgeLexicalDocumentRecord(
                chunkID: chunk.chunkID,
                length: tokens.count,
                terms: terms)
        }
        return KnowledgeLexicalIndexFile(
            tokenizer: KnowledgeTextTokenizer.identity,
            documents: documents)
    }

    private func makeProfile(
        storeID: String,
        snapshotID: String,
        createdAt: String,
        bundleRevision: String,
        chunking: KnowledgeChunkingResult,
        densePath: String,
        denseData: Data,
        denseFile: KnowledgeDenseIndexFile,
        lexicalPath: String,
        lexicalData: Data,
        lexicalFile: KnowledgeLexicalIndexFile
    ) throws -> KnowledgeProfile {
        let denseBackend = KnowledgeBackendIdentity(
            identity: KnowledgeContract.exactKNNBackendIdentity,
            formatVersion: KnowledgeContract.exactKNNFormatVersion,
            runtimeVersion: KnowledgeContract.exactKNNRuntimeVersion)
        var dense = KnowledgeEmbeddingIndexProfile(
            id: "dense_primary",
            componentRevision: "",
            indexPath: densePath,
            backend: denseBackend,
            model: embeddingProvider.modelIdentity,
            chunkManifestDigest: chunking.manifestDigest,
            vectorCount: denseFile.vectors.count,
            indexDigest: KnowledgeDigest.sha256(denseData))
        dense = KnowledgeEmbeddingIndexProfile(
            id: dense.id,
            componentRevision: try KnowledgeValidator.denseComponentRevision(dense),
            indexPath: dense.indexPath,
            backend: dense.backend,
            model: dense.model,
            chunkManifestDigest: dense.chunkManifestDigest,
            vectorCount: dense.vectorCount,
            indexDigest: dense.indexDigest)

        let lexicalBackend = KnowledgeBackendIdentity(
            identity: KnowledgeContract.lexicalBackendIdentity,
            formatVersion: KnowledgeContract.lexicalFormatVersion,
            runtimeVersion: KnowledgeContract.lexicalRuntimeVersion)
        var lexical = KnowledgeLexicalIndexProfile(
            id: "lexical_primary",
            componentRevision: "",
            indexPath: lexicalPath,
            backend: lexicalBackend,
            tokenizer: lexicalFile.tokenizer,
            languagePolicy: "multilingual-code/1",
            chunkManifestDigest: chunking.manifestDigest,
            documentCount: lexicalFile.documents.count,
            indexDigest: KnowledgeDigest.sha256(lexicalData))
        lexical = KnowledgeLexicalIndexProfile(
            id: lexical.id,
            componentRevision: try KnowledgeValidator.lexicalComponentRevision(lexical),
            indexPath: lexical.indexPath,
            backend: lexical.backend,
            tokenizer: lexical.tokenizer,
            languagePolicy: lexical.languagePolicy,
            chunkManifestDigest: lexical.chunkManifestDigest,
            documentCount: lexical.documentCount,
            indexDigest: lexical.indexDigest)

        let reranker = KnowledgeRerankerProfile(
            mode: rerankerModel == nil ? .disabled : .required,
            model: rerankerModel)
        let retrieval = KnowledgeProfile.Retrieval(
            dense: "required",
            lexical: "required",
            fusion: "rrf",
            reranker: reranker,
            evidenceContract: KnowledgeContract.evidenceContract)
        let policyDigest = try KnowledgeDigest.canonical(retrieval)
        let rerankerDigest = try KnowledgeDigest.canonical(reranker)
        var retrievalSnapshot = KnowledgeProfile.RetrievalSnapshot(
            id: snapshotID,
            revision: "",
            bundleRevision: bundleRevision,
            chunkManifestDigest: chunking.manifestDigest,
            dense: KnowledgeComponentReference(
                id: dense.id,
                componentRevision: dense.componentRevision),
            lexical: KnowledgeComponentReference(
                id: lexical.id,
                componentRevision: lexical.componentRevision),
            retrievalPolicyDigest: policyDigest,
            rerankerBindingDigest: rerankerDigest)
        retrievalSnapshot = KnowledgeProfile.RetrievalSnapshot(
            id: retrievalSnapshot.id,
            revision: try KnowledgeValidator.retrievalSnapshotDigest(retrievalSnapshot),
            bundleRevision: retrievalSnapshot.bundleRevision,
            chunkManifestDigest: retrievalSnapshot.chunkManifestDigest,
            dense: retrievalSnapshot.dense,
            lexical: retrievalSnapshot.lexical,
            retrievalPolicyDigest: retrievalSnapshot.retrievalPolicyDigest,
            rerankerBindingDigest: retrievalSnapshot.rerankerBindingDigest)

        return KnowledgeProfile(
            schema: KnowledgeContract.profileSchema,
            profile: KnowledgeContract.profileIdentity,
            profileVersion: KnowledgeContract.profileVersion,
            okf: KnowledgeProfile.OKF(
                version: KnowledgeContract.okfVersion,
                specCommit: KnowledgeContract.okfSpecCommit),
            bundle: KnowledgeProfile.Bundle(
                id: storeID,
                revision: bundleRevision,
                createdAt: createdAt),
            normalization: Self.normalizationProfile,
            chunking: KnowledgeProfile.Chunking(
                manifest: KnowledgeHostIdentity.bundlePath(
                    "chunks.jsonl"),
                algorithm: KnowledgeContract.deterministicChunkerIdentity,
                version: KnowledgeContract.deterministicChunkerVersion,
                parametersDigest: chunking.parametersDigest,
                manifestDigest: chunking.manifestDigest),
            embeddingIndexes: [dense],
            lexicalIndexes: [lexical],
            retrieval: retrieval,
            retrievalSnapshot: retrievalSnapshot,
            integrity: KnowledgeProfile.Integrity(
                algorithm: "sha256",
                inventory: KnowledgeHostIdentity.bundlePath(
                    "checksums.json")))
    }

    private func acquireWriterLease(
        store: KnowledgeSnapshotStore,
        deadline: KnowledgeBuildDeadline,
        maximumWaitSeconds: Int
    ) async throws -> KnowledgeStoreWriterLease {
        let waitDeadline = ContinuousClock.now.advanced(
            by: .seconds(maximumWaitSeconds))
        while true {
            try deadline.check()
            if let writer = try store.tryAcquireWriterLease() {
                return writer
            }
            guard ContinuousClock.now < waitDeadline else {
                throw KnowledgeDomainError(
                    .searchTimeout,
                    retryable: true,
                    "Knowledge store writer lease is busy.")
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private static let normalizationProfile = KnowledgeProfile.Normalization(
        textEncoding: "utf-8",
        lineEndings: "lf",
        unicode: "nfc",
        version: KnowledgeContract.textNormalizationVersion)

    private static func validate(_ budget: KnowledgeBuildBudget) throws {
        guard budget.maximumDraftFiles > 0,
              budget.maximumDraftBytes > 0,
              budget.maximumChunks > 0,
              budget.maximumEmbeddingInputBytes > 0,
              budget.maximumVectorScalars > 0,
              budget.maximumLexicalTokens > 0,
              budget.maximumDerivedBytes > 0,
              budget.embeddingBatchSize > 0,
              budget.embeddingBatchSize <= 4_096,
              budget.maximumWallTimeSeconds > 0,
              budget.maximumWriterWaitSeconds > 0,
              budget.maximumWriterWaitSeconds <= budget.maximumWallTimeSeconds else {
            throw budgetExceeded("Knowledge build budget is invalid.")
        }
    }

    private static func validStoreID(_ value: String) -> Bool {
        value.range(
            of: #"^kb_[A-Za-z0-9._-]{1,125}$"#,
            options: .regularExpression) != nil
    }

    private static func validSnapshotID(_ value: String) -> Bool {
        value.range(
            of: #"^snap_[A-Za-z0-9._-]{1,128}$"#,
            options: .regularExpression) != nil
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func budgetExceeded(_ message: String) -> KnowledgeDomainError {
        KnowledgeDomainError(.searchBudgetExceeded, message)
    }

    private static func checkedAdding(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw budgetExceeded("Knowledge build size arithmetic exceeded its safe range.")
        }
        return sum
    }

    private static func boundedSum(_ values: [Int],
                                   maximum: Int,
                                   message: String) throws -> Int {
        var total = 0
        for value in values {
            guard value >= 0 else { throw budgetExceeded(message) }
            total = try checkedAdding(total, value)
            guard total <= maximum else { throw budgetExceeded(message) }
        }
        return total
    }

    private static func validateLeasePath(_ url: URL,
                                          workspace: URL,
                                          lease: WorkspaceLease) throws {
        let relative = PathConfinement.relativePath(of: url, root: workspace)
        let deniedPatterns = lease.deniedPatterns
            + WorkspaceLease.mandatoryManagedStoreDeniedPatterns
        guard relative != url.path,
              !deniedPatterns.contains(where: {
                  leasePath(relative, matches: $0, caseInsensitive: true)
              }),
              lease.allowedPathRules.contains(where: {
                  $0.pattern == "." || leasePath(relative, matches: $0.pattern)
              }) else {
            throw KnowledgeDomainError(
                .accessDenied,
                "Knowledge build path is outside the reviewed workspace scope.")
        }
    }

    private static func leasePath(_ path: String,
                                  matches pattern: String,
                                  caseInsensitive: Bool = false) -> Bool {
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        let normalizedPattern = pattern.replacingOccurrences(of: "\\", with: "/")
        if normalizedPattern.contains("/") == false {
            return normalizedPath.split(separator: "/").contains {
                leaseGlob(String($0), matches: normalizedPattern,
                          caseInsensitive: caseInsensitive)
            }
        }
        return leaseGlob(normalizedPath, matches: normalizedPattern,
                         caseInsensitive: caseInsensitive)
    }

    private static func leaseGlob(_ value: String,
                                  matches pattern: String,
                                  caseInsensitive: Bool) -> Bool {
        var expression = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterStars = pattern.index(after: next)
                    if afterStars < pattern.endIndex, pattern[afterStars] == "/" {
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
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = pattern.index(after: index)
        }
        expression += "$"
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: expression, options: options) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }
}

private enum KnowledgeBuildDeadlineResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}

private struct KnowledgeBuildDeadline: Sendable {
    private let deadlineNanoseconds: UInt64

    init(seconds: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        let multiplied = UInt64(seconds).multipliedReportingOverflow(
            by: 1_000_000_000)
        let added = now.addingReportingOverflow(multiplied.partialValue)
        deadlineNanoseconds = multiplied.overflow || added.overflow
            ? UInt64.max
            : added.partialValue
    }

    func check() throws {
        if Task.isCancelled { throw CancellationError() }
        guard DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds else {
            throw KnowledgeDomainError(
                .searchTimeout,
                retryable: true,
                "Knowledge snapshot build exceeded its wall-time budget.")
        }
    }

    func remainingNanoseconds() throws -> UInt64 {
        if Task.isCancelled { throw CancellationError() }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineNanoseconds else {
            throw KnowledgeDomainError(
                .searchTimeout,
                retryable: true,
                "Knowledge snapshot build exceeded its wall-time budget.")
        }
        return deadlineNanoseconds - now
    }
}

private struct KnowledgeBuildStorage: Sendable {
    func createOwnedDirectory(_ url: URL) throws {
        guard mkdir(url.path, S_IRWXU) == 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge staging directory could not be created safely.")
        }
        guard chmod(url.path, S_IRWXU) == 0,
              Self.safeOwnedDirectory(url) else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge staging directory is not owner-controlled.")
        }
        guard Self.syncDirectory(url.deletingLastPathComponent()) else {
            throw KnowledgeDomainError(.revisionChanged, retryable: true, "Knowledge staging directory durability is uncertain.")
        }
    }

    func ensureOwnedDirectory(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard Self.safeOwnedDirectory(url) else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge build directory is unsafe.")
            }
            return
        }
        guard errno == ENOENT else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge build directory identity could not be read.")
        }
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path { try ensureOwnedDirectory(parent) }
        try createOwnedDirectory(url)
    }

    func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw KnowledgeDomainError(.unsafeStorage, "Knowledge staging file could not be created exclusively.")
        }
        var removeOnFailure = true
        defer {
            _ = close(descriptor)
            if removeOnFailure { _ = unlink(url.path) }
        }
        let wroteAll = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < raw.count {
                let count = write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0 else {
            throw KnowledgeDomainError(.internalError, retryable: true, "Knowledge staging file could not be written durably.")
        }
        removeOnFailure = false
        guard Self.syncDirectory(url.deletingLastPathComponent()) else {
            throw KnowledgeDomainError(.revisionChanged, retryable: true, "Knowledge staging file durability is uncertain.")
        }
    }

    fileprivate static func syncDirectory(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        return fsync(descriptor) == 0
    }

    private static func safeOwnedDirectory(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              (status.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
            return false
        }
        return true
    }
}
