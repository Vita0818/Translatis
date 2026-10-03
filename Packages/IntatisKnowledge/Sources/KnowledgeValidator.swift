import Foundation
import IntatisCore
import IntatisProtocol

public enum KnowledgeValidationMode: String, Sendable {
    case publish
    case mount
    case evidence
}

public struct KnowledgeValidationPolicy: Equatable, Sendable {
    public let evaluationDate: String
    public let requireRootOKFVersion: Bool
    public let allowGeneratedDerivatives: Bool
    public let trustedVerificationActors: Set<String>

    public init(evaluationDate: String,
                requireRootOKFVersion: Bool = true,
                allowGeneratedDerivatives: Bool = true,
                trustedVerificationActors: Set<String> = []) {
        self.evaluationDate = evaluationDate
        self.requireRootOKFVersion = requireRootOKFVersion
        self.allowGeneratedDerivatives = allowGeneratedDerivatives
        self.trustedVerificationActors = trustedVerificationActors
    }
}

public struct KnowledgeBackendRegistry: Equatable, Sendable {
    public let dense: Set<KnowledgeBackendIdentity>
    public let lexical: Set<KnowledgeBackendIdentity>
    public let sourceLocatorAdapters: KnowledgeSourceLocatorAdapterRegistry
    public let digest: String

    public var sourceLocators: Set<String> {
        sourceLocatorAdapters.adapterKeys
    }

    public init(dense: Set<KnowledgeBackendIdentity> = [
                    KnowledgeBackendIdentity(
                        identity: KnowledgeContract.exactKNNBackendIdentity,
                        formatVersion: KnowledgeContract.exactKNNFormatVersion,
                        runtimeVersion: KnowledgeContract.exactKNNRuntimeVersion),
                ],
                lexical: Set<KnowledgeBackendIdentity> = [
                    KnowledgeBackendIdentity(
                        identity: KnowledgeContract.lexicalBackendIdentity,
                        formatVersion: KnowledgeContract.lexicalFormatVersion,
                        runtimeVersion: KnowledgeContract.lexicalRuntimeVersion),
                ],
                sourceLocatorAdapters: KnowledgeSourceLocatorAdapterRegistry? = nil) throws {
        self.dense = dense
        self.lexical = lexical
        self.sourceLocatorAdapters = try sourceLocatorAdapters
            ?? KnowledgeSourceLocatorAdapterRegistry()
        struct Projection: Codable {
            let dense: [KnowledgeBackendIdentity]
            let lexical: [KnowledgeBackendIdentity]
            let sourceLocatorRegistryDigest: String
            let sourceLocatorAdapters: [KnowledgeSourceLocatorAdapterDescriptor]
        }
        digest = try KnowledgeDigest.canonical(Projection(
            dense: dense.sorted(by: Self.order),
            lexical: lexical.sorted(by: Self.order),
            sourceLocatorRegistryDigest: self.sourceLocatorAdapters.digest,
            sourceLocatorAdapters: self.sourceLocatorAdapters.descriptors))
    }

    private static func order(_ lhs: KnowledgeBackendIdentity,
                              _ rhs: KnowledgeBackendIdentity) -> Bool {
        if lhs.identity != rhs.identity { return lhs.identity < rhs.identity }
        if lhs.formatVersion != rhs.formatVersion {
            return lhs.formatVersion < rhs.formatVersion
        }
        return lhs.runtimeVersion < rhs.runtimeVersion
    }
}

/// Exact, Sendable evidence-validation seam captured when a snapshot is
/// admitted. Search must reuse this file-system policy, schema runtime, and
/// executable adapter registry rather than reconstructing process defaults.
public struct KnowledgeEvidenceValidationContext: Sendable {
    public let fileSystem: KnowledgeSecureFileSystem
    public let backendRegistry: KnowledgeBackendRegistry
    public let schemaValidator: KnowledgeJSONSchemaValidator

    public init(fileSystem: KnowledgeSecureFileSystem,
                backendRegistry: KnowledgeBackendRegistry,
                schemaValidator: KnowledgeJSONSchemaValidator) {
        self.fileSystem = fileSystem
        self.backendRegistry = backendRegistry
        self.schemaValidator = schemaValidator
    }

    func makeValidator() throws -> KnowledgeValidator {
        try KnowledgeValidator(
            fileSystem: fileSystem,
            backendRegistry: backendRegistry,
            schemaValidator: schemaValidator)
    }
}

public struct KnowledgeValidatedSnapshot: Sendable {
    public let root: URL
    public let rootIdentity: WorkspaceRootIdentity
    public let profile: KnowledgeProfile
    public let concepts: [String: OKFConcept]
    public let chunks: [KnowledgeChunk]
    public let denseFile: KnowledgeDenseIndexFile
    public let lexicalFile: KnowledgeLexicalIndexFile?
    public let checksums: KnowledgeChecksums
    /// Exact backend/locator registry admitted by the Validator. Receipts use
    /// this value rather than silently reconstructing the default registry.
    public let backendRegistryDigest: String
    /// Executable evidence-validation dependencies frozen by mount validation.
    public let evidenceValidationContext: KnowledgeEvidenceValidationContext
    /// Host-computed digest of every leaf byte, including checksums.json.
    /// It is not written into the snapshot and therefore cannot self-reference.
    public let contentSealDigest: String
    public let report: KnowledgeValidationReport
}

public struct KnowledgeValidator: Sendable {
    public let fileSystem: KnowledgeSecureFileSystem
    public let okfReader: OKFReader
    public let backendRegistry: KnowledgeBackendRegistry
    public let schemaValidator: KnowledgeJSONSchemaValidator

    public init(fileSystem: KnowledgeSecureFileSystem = KnowledgeSecureFileSystem(),
                okfReader: OKFReader = OKFReader(),
                backendRegistry: KnowledgeBackendRegistry? = nil,
                schemaValidator: KnowledgeJSONSchemaValidator = KnowledgeJSONSchemaValidator()) throws {
        self.fileSystem = fileSystem
        self.okfReader = okfReader
        self.backendRegistry = try backendRegistry ?? KnowledgeBackendRegistry()
        self.schemaValidator = schemaValidator
    }

    public func validateSnapshot(
        at root: URL,
        mode: KnowledgeValidationMode,
        policy: KnowledgeValidationPolicy,
        workspaceLease: WorkspaceLease? = nil
    ) throws -> KnowledgeValidatedSnapshot {
        guard let evaluationInstant = ISO8601DateFormatter().date(
            from: policy.evaluationDate) else {
            throw KnowledgeDomainError(
                .profileInvalid,
                "Knowledge validation policy contains an invalid evaluation date.")
        }
        let authorized: (canonical: URL, identity: WorkspaceRootIdentity)
        if let workspaceLease {
            authorized = try fileSystem.authorizeRoot(root, workspaceLease: workspaceLease)
        } else {
            guard let identity = WorkspaceRootIdentity.capture(rootPath: root.path) else {
                throw KnowledgeDomainError(.unsafeStorage, "Knowledge snapshot root identity is unavailable.")
            }
            authorized = (URL(fileURLWithPath: identity.canonicalPath), identity)
        }
        let scanned = try fileSystem.scan(
            root: authorized.canonical,
            expectedRootIdentity: authorized.identity)
        let paths = Set(scanned.map(\.relativePath))
        var diagnostics: [KnowledgeDiagnostic] = []

        func recordError(_ code: String, _ subject: String, _ message: String) {
            diagnostics.append(KnowledgeDiagnostic(
                severity: .error,
                code: code,
                subject: subject,
                message: message))
        }
        func warning(_ code: String, _ subject: String, _ message: String) {
            diagnostics.append(KnowledgeDiagnostic(
                severity: .warning,
                code: code,
                subject: subject,
                message: message))
        }

        let required = [
            "index.md",
            KnowledgeHostIdentity.bundlePath("profile.json"),
            KnowledgeHostIdentity.bundlePath("checksums.json"),
            KnowledgeHostIdentity.bundlePath("chunks.jsonl"),
        ]
        for path in required where !paths.contains(path) {
            recordError("required_file_missing", path, "A required snapshot file is missing.")
        }
        guard diagnostics.isEmpty else {
            throw KnowledgeDomainError(
                .indexNotReady,
                retryable: true,
                "Knowledge snapshot is incomplete.",
                diagnostics: diagnostics)
        }

        let profile: KnowledgeProfile
        do {
            let profileData = try fileSystem.readFile(
                root: authorized.canonical,
                relativePath: KnowledgeHostIdentity.bundlePath(
                    "profile.json"),
                maximumBytes: 2 * 1_024 * 1_024,
                expectedRootIdentity: authorized.identity)
            try schemaValidator.validate(data: profileData, against: .profile)
            profile = try KnowledgeJSON.decode(
                KnowledgeProfile.self,
                from: profileData)
        } catch let error as KnowledgeDomainError {
            throw error
        } catch {
            throw KnowledgeDomainError(.profileInvalid, "Knowledge profile could not be decoded.")
        }
        validateProfileShape(profile, recordError: recordError)
        if profile.integrity.algorithm != "sha256"
            || profile.integrity.inventory
                != KnowledgeHostIdentity.bundlePath("checksums.json") {
            recordError(
                "integrity_contract",
                "profile",
                "Profile integrity inventory identity is unsupported.")
        }
        if profile.retrievalSnapshot.bundleRevision != profile.bundle.revision {
            recordError(
                "retrieval_bundle_revision",
                "profile",
                "Retrieval snapshot does not bind the exact bundle revision.")
        }

        let checksums: KnowledgeChecksums
        do {
            let checksumData = try fileSystem.readFile(
                root: authorized.canonical,
                relativePath: KnowledgeHostIdentity.bundlePath(
                    "checksums.json"),
                maximumBytes: 32 * 1_024 * 1_024,
                expectedRootIdentity: authorized.identity)
            if PermissionReviewTextSanitizer.containsSensitiveMaterial(
                String(decoding: checksumData, as: UTF8.self)) {
                recordError(
                    "secret_material",
                    KnowledgeHostIdentity.bundlePath("checksums.json"),
                    "Knowledge metadata contains credential-like material.")
            }
            try schemaValidator.validate(data: checksumData, against: .checksums)
            checksums = try KnowledgeJSON.decode(
                KnowledgeChecksums.self,
                from: checksumData)
        } catch {
            throw KnowledgeDomainError(.integrityFailed, "Knowledge checksum inventory could not be decoded.")
        }
        validateChecksums(
            checksums,
            scanned: scanned,
            root: authorized.canonical,
            rootIdentity: authorized.identity,
            recordError: recordError)

        var concepts: [String: OKFConcept] = [:]
        let conceptPaths = paths.filter {
            !$0.hasPrefix(KnowledgeHostIdentity.bundleDirectory + "/")
                && OKFBundleLayout.isConcept($0)
        }.sorted()
        for path in conceptPaths {
            do {
                let concept = try okfReader.readConcept(
                    data: fileSystem.readFile(
                        root: authorized.canonical,
                        relativePath: path,
                        maximumBytes: okfReader.limits.maximumConceptBytes,
                        expectedRootIdentity: authorized.identity),
                    relativePath: path)
                guard concepts[concept.conceptID] == nil else {
                    recordError("duplicate_concept", concept.conceptID, "Concept identity is duplicated.")
                    continue
                }
                concepts[concept.conceptID] = concept
                do {
                    try okfReader.validateFootnoteAttribution(concept)
                } catch {
                    recordError(
                        "source_attribution",
                        concept.conceptID,
                        "Concept footnote attribution does not bind declared source identities.")
                }
                if !["draft", "stable", "deprecated"].contains(concept.status) {
                    recordError(
                        "concept_status",
                        concept.conceptID,
                        "Concept status is outside the frozen lifecycle states.")
                }
                if concept.sources.contains(where: {
                    guard let id = $0.id else { return false }
                    return !KnowledgeSourceIdentity.isPortable(id)
                }) {
                    recordError(
                        "source_id",
                        concept.conceptID,
                        "Concept source identity is not a portable opaque identifier.")
                }
                if concept.verifications.contains(where: {
                    ISO8601DateFormatter().date(from: $0.at) == nil
                }) || concept.generatedAt.map({
                    ISO8601DateFormatter().date(from: $0) == nil
                }) == true {
                    recordError(
                        "provenance_time",
                        concept.conceptID,
                        "Concept generation or verification time is invalid.")
                }
                if concept.verifications.contains(where: {
                    !policy.trustedVerificationActors.contains($0.by)
                }) {
                    recordError(
                        "verification_actor_untrusted",
                        concept.conceptID,
                        "Concept verification actor was not attested by the host validation policy.")
                }
                if concept.status == "deprecated" {
                    warning("deprecated_concept", concept.conceptID, "Concept is deprecated and is excluded by the default query policy.")
                }
                if let staleAfter = concept.staleAfter {
                    if let staleDate = OKFReader.parseISODateOnly(staleAfter) {
                        if staleDate <= evaluationInstant {
                            warning(
                                "stale_concept",
                                concept.conceptID,
                                "Concept is stale under the validation date policy.")
                        }
                    } else {
                        recordError(
                            "stale_after_invalid",
                            concept.conceptID,
                            "Concept stale_after must use YYYY-MM-DD.")
                    }
                }
                validateSourceReferences(
                    concept,
                    knownPaths: paths,
                    recordError: recordError)
                validateOrdinaryLinks(
                    concept,
                    knownPaths: paths,
                    warning: warning)
            } catch let domain as KnowledgeDomainError
                where domain.failure.code == .unsafeStorage {
                // YAML alias/custom-tag policy is a host parser safety
                // boundary, not evidence that the OKF vocabulary is invalid.
                throw domain
            } catch let domain as KnowledgeDomainError {
                recordError("okf_concept_invalid", path, domain.failure.message)
            } catch {
                recordError("okf_concept_invalid", path, "OKF concept could not be decoded.")
            }
        }
        if concepts.isEmpty {
            recordError("no_concepts", "bundle", "Knowledge snapshot contains no valid concepts.")
        }

        let indexPaths = paths.filter {
            URL(fileURLWithPath: $0).lastPathComponent == "index.md"
                && !$0.hasPrefix(
                    KnowledgeHostIdentity.bundleDirectory + "/")
        }.sorted()
        for path in indexPaths {
            do {
                let indexData = try fileSystem.readFile(
                    root: authorized.canonical,
                    relativePath: path,
                    maximumBytes: okfReader.limits.maximumConceptBytes,
                    expectedRootIdentity: authorized.identity)
                let index = try okfReader.readIndexDocument(
                    data: indexData,
                    relativePath: path)
                if path == "index.md",
                   policy.requireRootOKFVersion,
                   index.declaredVersion != KnowledgeContract.okfVersion {
                    recordError(
                        "okf_version",
                        path,
                        "Root index must declare OKF version 0.2.")
                }
            } catch let domain as KnowledgeDomainError
                where domain.failure.code == .unsafeStorage {
                // Reserved-document aliases/custom tags are a host parser
                // safety boundary, not an OKF vocabulary diagnostic.
                throw domain
            } catch let domain as KnowledgeDomainError {
                recordError("okf_index_invalid", path, domain.failure.message)
            } catch {
                recordError("okf_index_invalid", path, "OKF index could not be read.")
            }
        }

        let logPaths = paths.filter {
            URL(fileURLWithPath: $0).lastPathComponent == "log.md"
                && !$0.hasPrefix(
                    KnowledgeHostIdentity.bundleDirectory + "/")
        }.sorted()
        for path in logPaths {
            do {
                _ = try okfReader.readLogDocument(
                    data: fileSystem.readFile(
                        root: authorized.canonical,
                        relativePath: path,
                        maximumBytes: okfReader.limits.maximumConceptBytes,
                        expectedRootIdentity: authorized.identity),
                    relativePath: path)
            } catch let domain as KnowledgeDomainError
                where domain.failure.code == .unsafeStorage {
                throw domain
            } catch let domain as KnowledgeDomainError {
                recordError("okf_log_invalid", path, domain.failure.message)
            } catch {
                recordError("okf_log_invalid", path, "OKF log could not be read.")
            }
        }

        let chunkData = try fileSystem.readFile(
            root: authorized.canonical,
            relativePath: profile.chunking.manifest,
            maximumBytes: 512 * 1_024 * 1_024,
            expectedRootIdentity: authorized.identity)
        let chunks = decodeChunks(chunkData, recordError: recordError)
        validateChunks(
            chunks,
            concepts: concepts,
            checksums: checksums,
            snapshotRoot: authorized.canonical,
            rootIdentity: authorized.identity,
            policy: policy,
            recordError: recordError)

        let inventoryEntries = checksums.files.sorted { $0.path < $1.path }
        let computedBundleRevision: String
        do {
            computedBundleRevision = try KnowledgeSecureFileSystem
                .canonicalBundleDigest(inventoryEntries)
        } catch let domain as KnowledgeDomainError {
            recordError("bundle_digest", "bundle", domain.failure.message)
            computedBundleRevision = ""
        } catch {
            recordError("bundle_digest", "bundle", "Bundle digest could not be computed.")
            computedBundleRevision = ""
        }
        if profile.bundle.revision != computedBundleRevision {
            recordError("bundle_revision", "profile", "Profile bundle revision does not match canonical knowledge files.")
        }

        do {
            let expectedManifest = try Self.chunkManifestDigest(
                bundleRevision: profile.bundle.revision,
                chunking: profile.chunking,
                jsonLines: chunkData)
            if expectedManifest != profile.chunking.manifestDigest
                || expectedManifest != profile.retrievalSnapshot.chunkManifestDigest {
                recordError("chunk_manifest_digest", "chunks", "Chunk manifest digest is inconsistent.")
            }
        } catch {
            recordError("chunk_manifest_digest", "chunks", "Chunk manifest digest could not be computed.")
        }

        guard let denseProfile = profile.embeddingIndexes.first(where: {
            $0.id == profile.retrievalSnapshot.dense.id
        }) else {
            throw KnowledgeDomainError(.indexNotReady, retryable: true, "Selected dense index is absent.")
        }
        if profile.retrievalSnapshot.dense.componentRevision
            != denseProfile.componentRevision {
            recordError(
                "dense_selection_revision",
                denseProfile.id,
                "Retrieval snapshot does not bind the selected dense component revision.")
        }
        if denseProfile.chunkManifestDigest != profile.chunking.manifestDigest
            || profile.retrievalSnapshot.chunkManifestDigest
                != profile.chunking.manifestDigest {
            recordError(
                "dense_chunk_binding",
                denseProfile.id,
                "Dense and retrieval snapshot inputs do not bind the exact chunk manifest.")
        }
        let denseData = try fileSystem.readFile(
            root: authorized.canonical,
            relativePath: denseProfile.indexPath,
            maximumBytes: 512 * 1_024 * 1_024,
            expectedRootIdentity: authorized.identity)
        var denseFile: KnowledgeDenseIndexFile
        do {
            denseFile = try KnowledgeJSON.decode(
                KnowledgeDenseIndexFile.self,
                from: denseData)
            _ = try KnowledgeDenseIndex(file: denseFile)
        } catch let domain as KnowledgeDomainError {
            recordError("dense_index_invalid", denseProfile.id, domain.failure.message)
            denseFile = KnowledgeDenseIndexFile(dimensions: 1, vectors: [
                KnowledgeDenseVectorRecord(chunkID: "invalid", values: [1]),
            ])
        } catch {
            recordError("dense_index_invalid", denseProfile.id, "Dense index could not be decoded.")
            denseFile = KnowledgeDenseIndexFile(dimensions: 1, vectors: [
                KnowledgeDenseVectorRecord(chunkID: "invalid", values: [1]),
            ])
        }
        validateDense(
            denseProfile,
            denseFile: denseFile,
            denseData: denseData,
            chunks: chunks,
            recordError: recordError)

        var lexicalFile: KnowledgeLexicalIndexFile?
        if let selected = profile.retrievalSnapshot.lexical {
            guard let lexicalProfile = profile.lexicalIndexes.first(where: {
                $0.id == selected.id
            }) else {
                throw KnowledgeDomainError(.indexNotReady, retryable: true, "Selected lexical index is absent.")
            }
            if selected.componentRevision != lexicalProfile.componentRevision {
                recordError(
                    "lexical_selection_revision",
                    lexicalProfile.id,
                    "Retrieval snapshot does not bind the selected lexical component revision.")
            }
            if lexicalProfile.chunkManifestDigest
                != profile.chunking.manifestDigest {
                recordError(
                    "lexical_chunk_binding",
                    lexicalProfile.id,
                    "Lexical index does not bind the exact chunk manifest.")
            }
            let lexicalData = try fileSystem.readFile(
                root: authorized.canonical,
                relativePath: lexicalProfile.indexPath,
                maximumBytes: 512 * 1_024 * 1_024,
                expectedRootIdentity: authorized.identity)
            do {
                let decoded = try KnowledgeJSON.decode(
                    KnowledgeLexicalIndexFile.self,
                    from: lexicalData)
                _ = try KnowledgeBM25Index(file: decoded)
                lexicalFile = decoded
                validateLexical(
                    lexicalProfile,
                    lexicalFile: decoded,
                    lexicalData: lexicalData,
                    chunks: chunks,
                    recordError: recordError)
            } catch let domain as KnowledgeDomainError {
                recordError("lexical_index_invalid", lexicalProfile.id, domain.failure.message)
            } catch {
                recordError("lexical_index_invalid", lexicalProfile.id, "Lexical index could not be decoded.")
            }
        }

        do {
            let policyDigest = try KnowledgeDigest.canonical(profile.retrieval)
            if policyDigest != profile.retrievalSnapshot.retrievalPolicyDigest {
                recordError("retrieval_policy_digest", "profile", "Retrieval policy digest is inconsistent.")
            }
            let rerankerDigest = try KnowledgeDigest.canonical(profile.retrieval.reranker)
            if rerankerDigest != profile.retrievalSnapshot.rerankerBindingDigest {
                recordError("reranker_binding_digest", "profile", "Reranker binding digest is inconsistent.")
            }
            let snapshotDigest = try Self.retrievalSnapshotDigest(
                profile.retrievalSnapshot)
            if snapshotDigest != profile.retrievalSnapshot.revision {
                recordError("retrieval_snapshot_digest", "profile", "Composite retrieval snapshot digest is inconsistent.")
            }
        } catch {
            recordError("retrieval_snapshot_digest", "profile", "Composite retrieval identity could not be computed.")
        }

        if profile.retrieval.lexical == "required",
           profile.retrievalSnapshot.lexical == nil {
            recordError("lexical_required", "profile", "Required lexical retrieval component is unavailable.")
        }
        if mode == .publish, profile.retrieval.reranker.mode != .disabled {
            warning("reranker_not_baked_off", "profile", "Reranker remains outside the completed backend bake-off.")
        }

        let report = KnowledgeValidationReport(
            profile: profile,
            chunks: chunks,
            diagnostics: diagnostics)
        guard report.semanticVerdict else {
            throw KnowledgeDomainError(
                diagnostics.contains(where: { $0.code.hasPrefix("okf") })
                    ? .okfInvalid
                    : .integrityFailed,
                "Knowledge snapshot failed deterministic validation.",
                diagnostics: report.diagnostics)
        }
        return KnowledgeValidatedSnapshot(
            root: authorized.canonical,
            rootIdentity: authorized.identity,
            profile: profile,
            concepts: concepts,
            chunks: chunks,
            denseFile: denseFile,
            lexicalFile: lexicalFile,
            checksums: checksums,
            backendRegistryDigest: backendRegistry.digest,
            evidenceValidationContext: KnowledgeEvidenceValidationContext(
                fileSystem: fileSystem,
                backendRegistry: backendRegistry,
                schemaValidator: schemaValidator),
            contentSealDigest: try fileSystem.snapshotSealDigest(
                root: authorized.canonical),
            report: report)
    }

    public func validateEvidence(
        _ evidence: KnowledgeSearchEvidence,
        in snapshot: KnowledgeValidatedSnapshot
    ) throws {
        guard backendRegistry.digest == snapshot.backendRegistryDigest,
              snapshot.evidenceValidationContext.backendRegistry.digest
                == snapshot.backendRegistryDigest else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Evidence validation backend registry does not match the mounted snapshot.")
        }
        do {
            try schemaValidator.validate(evidence, against: .evidence)
        } catch {
            throw KnowledgeDomainError(.integrityFailed, "Grounded evidence does not satisfy the frozen evidence schema.")
        }
        guard evidence.rank >= 1, evidence.rank <= 20,
              !evidence.text.isEmpty,
              evidence.text.count <= 4_096,
              Data(evidence.text.utf8).count <= 16 * 1_024,
              !PermissionReviewTextSanitizer.containsSensitiveMaterial(
                  evidence.text),
              KnowledgeDigest.sha256(evidence.text) == evidence.textSha256,
              !evidence.sourceIDs.isEmpty,
              evidence.sourceIDs.allSatisfy(
                  KnowledgeSourceIdentity.isPortable) else {
            throw KnowledgeDomainError(.integrityFailed, "Grounded evidence shape or hash is invalid.")
        }
        switch evidence.evidenceClass {
        case .exactConceptSlice:
            guard let conceptID = evidence.conceptID,
                  let revision = evidence.conceptRevision,
                  let locator = evidence.conceptLocator,
                  let concept = snapshot.concepts[conceptID],
                  concept.revision == revision,
                  try Self.slice(concept.normalizedText, locator: locator) == evidence.text,
                  evidence.sourceIDs == (try OKFReader.attributedSourceIDs(
                    in: evidence.text,
                    declaredSourceIDs: concept.sources.compactMap(\.id))),
                  evidence.producer == nil,
                  evidence.supportingConcepts == nil else {
                throw KnowledgeDomainError(.integrityFailed, "Exact evidence no longer maps to its concept.")
            }
            try validateSourceLocators(
                evidence.sourceLocators,
                allowedSourceIDs: Set(evidence.sourceIDs),
                concepts: [concept],
                checksums: snapshot.checksums,
                snapshotRoot: snapshot.root,
                rootIdentity: snapshot.rootIdentity)
        case .generatedDerivative:
            guard evidence.producer != nil,
                  let supports = evidence.supportingConcepts,
                  !supports.isEmpty,
                  evidence.conceptLocator == nil else {
                throw KnowledgeDomainError(.integrityFailed, "Generated evidence provenance is incomplete.")
            }
            var resolvedConcepts: [OKFConcept] = []
            var supportingSourceIDs = Set<String>()
            for support in supports {
                guard let concept = snapshot.concepts[support.conceptID],
                      concept.revision == support.conceptRevision else {
                    throw KnowledgeDomainError(.integrityFailed, "Generated evidence support changed.")
                }
                _ = try Self.slice(concept.normalizedText, locator: support.conceptLocator)
                resolvedConcepts.append(concept)
                supportingSourceIDs.formUnion(
                    concept.sources.compactMap(\.id))
            }
            guard Set(evidence.sourceIDs).isSubset(of: supportingSourceIDs) else {
                throw KnowledgeDomainError(
                    .integrityFailed,
                    "Generated evidence source is not declared by its supporting concepts.")
            }
            try validateSourceLocators(
                evidence.sourceLocators,
                allowedSourceIDs: Set(evidence.sourceIDs),
                concepts: resolvedConcepts,
                checksums: snapshot.checksums,
                snapshotRoot: snapshot.root,
                rootIdentity: snapshot.rootIdentity)
        }
    }

    public static func chunkManifestDigest(
        bundleRevision: String,
        chunking: KnowledgeProfile.Chunking,
        jsonLines: Data
    ) throws -> String {
        try KnowledgeChunkManifestIdentity.digest(
            bundleRevision: bundleRevision,
            algorithm: chunking.algorithm,
            algorithmVersion: chunking.version,
            parametersDigest: chunking.parametersDigest,
            chunks: KnowledgeChunkManifestIdentity.decode(jsonLines))
    }

    public static func denseComponentRevision(
        _ profile: KnowledgeEmbeddingIndexProfile
    ) throws -> String {
        struct Projection: Codable {
            let version: String
            let id: String
            let backend: KnowledgeBackendIdentity
            let model: KnowledgeEmbeddingModelIdentity
            let chunkManifestDigest: String
            let vectorCount: Int
            let indexDigest: String
        }
        return try KnowledgeDigest.canonical(Projection(
            version: KnowledgeHostIdentity.schema(
                "dense-component-digest/1"),
            id: profile.id,
            backend: profile.backend,
            model: profile.model,
            chunkManifestDigest: profile.chunkManifestDigest,
            vectorCount: profile.vectorCount,
            indexDigest: profile.indexDigest))
    }

    public static func lexicalComponentRevision(
        _ profile: KnowledgeLexicalIndexProfile
    ) throws -> String {
        struct Projection: Codable {
            let version: String
            let id: String
            let backend: KnowledgeBackendIdentity
            let tokenizer: String
            let languagePolicy: String
            let chunkManifestDigest: String
            let documentCount: Int
            let indexDigest: String
        }
        return try KnowledgeDigest.canonical(Projection(
            version: KnowledgeHostIdentity.schema(
                "lexical-component-digest/1"),
            id: profile.id,
            backend: profile.backend,
            tokenizer: profile.tokenizer,
            languagePolicy: profile.languagePolicy,
            chunkManifestDigest: profile.chunkManifestDigest,
            documentCount: profile.documentCount,
            indexDigest: profile.indexDigest))
    }

    public static func retrievalSnapshotDigest(
        _ snapshot: KnowledgeProfile.RetrievalSnapshot
    ) throws -> String {
        struct Projection: Codable {
            let version: String
            let id: String
            let bundleRevision: String
            let chunkManifestDigest: String
            let dense: KnowledgeComponentReference
            let lexical: KnowledgeComponentReference?
            let retrievalPolicyDigest: String
            let rerankerBindingDigest: String
        }
        return try KnowledgeDigest.canonical(Projection(
            version: KnowledgeHostIdentity.schema(
                "retrieval-snapshot-digest/1"),
            id: snapshot.id,
            bundleRevision: snapshot.bundleRevision,
            chunkManifestDigest: snapshot.chunkManifestDigest,
            dense: snapshot.dense,
            lexical: snapshot.lexical,
            retrievalPolicyDigest: snapshot.retrievalPolicyDigest,
            rerankerBindingDigest: snapshot.rerankerBindingDigest))
    }

    private func validateProfileShape(
        _ profile: KnowledgeProfile,
        recordError: (String, String, String) -> Void
    ) {
        if profile.schema != KnowledgeContract.profileSchema
            || profile.profile != KnowledgeContract.profileIdentity
            || profile.profileVersion != KnowledgeContract.profileVersion {
            recordError("profile_identity", "profile", "Profile identity or version is unsupported.")
        }
        if profile.okf.version != KnowledgeContract.okfVersion
            || profile.okf.specCommit != KnowledgeContract.okfSpecCommit {
            recordError("okf_pin", "profile", "Profile does not bind the fixed OKF specification.")
        }
        if profile.bundle.id.range(
            of: #"^kb_[A-Za-z0-9._-]{1,125}$"#,
            options: .regularExpression) == nil
            || !KnowledgeDigest.isValid(profile.bundle.revision)
            || ISO8601DateFormatter().date(from: profile.bundle.createdAt) == nil {
            recordError("bundle_identity", "profile", "Bundle identity, revision, or creation time is invalid.")
        }
        if profile.normalization.textEncoding != "utf-8"
            || profile.normalization.lineEndings != "lf"
            || profile.normalization.unicode != "nfc"
            || profile.normalization.version != KnowledgeContract.textNormalizationVersion {
            recordError("normalization", "profile", "Text normalization identity is unsupported.")
        }
        if profile.chunking.algorithm != KnowledgeContract.deterministicChunkerIdentity
            || profile.chunking.version != KnowledgeContract.deterministicChunkerVersion
            || profile.chunking.manifest
                != KnowledgeHostIdentity.bundlePath("chunks.jsonl")
            || !KnowledgeDigest.isValid(profile.chunking.parametersDigest)
            || !KnowledgeDigest.isValid(profile.chunking.manifestDigest) {
            recordError("chunker", "profile", "Chunker identity is unsupported.")
        }
        if profile.embeddingIndexes.isEmpty {
            recordError("dense_missing", "profile", "At least one dense retrieval component is required.")
        }
        var denseIDs = Set<String>()
        var densePaths = Set<String>()
        for dense in profile.embeddingIndexes {
            if dense.id.range(
                of: #"^[A-Za-z0-9._-]{1,128}$"#,
                options: .regularExpression) == nil
                || !denseIDs.insert(dense.id).inserted
                || !densePaths.insert(dense.indexPath).inserted
                || !KnowledgeDigest.isValid(dense.componentRevision)
                || !KnowledgeDigest.isValid(dense.chunkManifestDigest)
                || !KnowledgeDigest.isValid(dense.indexDigest)
                || dense.vectorCount < 1 {
                recordError("dense_identity", dense.id, "Dense component identity, path, count, or digest is invalid.")
            }
            if !backendRegistry.dense.contains(dense.backend) {
                recordError("dense_backend", dense.id, "Dense backend is not registered.")
            }
            if dense.model.dimensions <= 0
                || dense.model.identity.isEmpty
                || dense.model.revision.isEmpty
                || dense.model.tokenizerRevision.isEmpty
                || dense.model.scalarType != "float32"
                || dense.model.quantization != "none"
                || dense.model.pooling.isEmpty
                || dense.model.normalization != "l2"
                || dense.model.similarity != "cosine"
                || dense.model.maxInputTokens < 1
                || dense.model.truncation != "end"
                || !KnowledgeDigest.isValid(dense.model.runtimeBindingDigest) {
                recordError("embedding_identity", dense.id, "Embedding compatibility identity is incomplete.")
            }
        }
        var lexicalIDs = Set<String>()
        var lexicalPaths = Set<String>()
        for lexical in profile.lexicalIndexes {
            if lexical.id.range(
                of: #"^[A-Za-z0-9._-]{1,128}$"#,
                options: .regularExpression) == nil
                || !lexicalIDs.insert(lexical.id).inserted
                || !lexicalPaths.insert(lexical.indexPath).inserted
                || !KnowledgeDigest.isValid(lexical.componentRevision)
                || !KnowledgeDigest.isValid(lexical.chunkManifestDigest)
                || !KnowledgeDigest.isValid(lexical.indexDigest)
                || lexical.documentCount < 1
                || lexical.tokenizer.isEmpty
                || lexical.languagePolicy.isEmpty {
                recordError("lexical_identity", lexical.id, "Lexical component identity, path, count, or digest is invalid.")
            }
            if !backendRegistry.lexical.contains(lexical.backend) {
                recordError("lexical_backend", lexical.id, "Lexical backend is not registered.")
            }
        }
        if profile.retrieval.dense != "required"
            || !["required", "optional", "disabled"].contains(profile.retrieval.lexical)
            || !["rrf", "dense_only"].contains(profile.retrieval.fusion)
            || (profile.retrieval.reranker.mode == .disabled
                && profile.retrieval.reranker.model != nil)
            || (profile.retrieval.reranker.mode != .disabled
                && profile.retrieval.reranker.model == nil) {
            recordError("retrieval_policy", "profile", "Retrieval and reranker policy shape is invalid.")
        }
        if profile.retrievalSnapshot.id.range(
            of: #"^snap_[A-Za-z0-9._-]{1,123}$"#,
            options: .regularExpression) == nil
            || !KnowledgeDigest.isValid(profile.retrievalSnapshot.revision)
            || !KnowledgeDigest.isValid(profile.retrievalSnapshot.bundleRevision)
            || !KnowledgeDigest.isValid(profile.retrievalSnapshot.chunkManifestDigest)
            || !KnowledgeDigest.isValid(profile.retrievalSnapshot.retrievalPolicyDigest)
            || !KnowledgeDigest.isValid(profile.retrievalSnapshot.rerankerBindingDigest) {
            recordError("retrieval_snapshot_identity", "profile", "Composite retrieval snapshot identity is invalid.")
        }
        if profile.retrieval.evidenceContract != KnowledgeContract.evidenceContract {
            recordError("evidence_contract", "profile", "Evidence contract is unsupported.")
        }
    }

    private func validateChecksums(
        _ checksums: KnowledgeChecksums,
        scanned: [KnowledgeScannedFile],
        root: URL,
        rootIdentity: WorkspaceRootIdentity,
        recordError: (String, String, String) -> Void
    ) {
        if checksums.schema != KnowledgeContract.checksumsSchema
            || checksums.algorithm != "sha256" {
            recordError("checksums_identity", "checksums", "Checksum inventory identity is invalid.")
        }
        var paths = Set<String>()
        for entry in checksums.files {
            if entry.path == KnowledgeHostIdentity.bundlePath(
                "checksums.json")
                || !paths.insert(entry.path).inserted {
                recordError("checksums_path", entry.path, "Checksum inventory contains a self-reference or duplicate.")
                continue
            }
            guard let scannedFile = scanned.first(where: { $0.relativePath == entry.path }) else {
                recordError("checksums_missing", entry.path, "Inventoried file is missing.")
                continue
            }
            do {
                let data = try fileSystem.readFile(
                    root: root,
                    relativePath: entry.path,
                    maximumBytes: scannedFile.identity.size,
                    expectedRootIdentity: rootIdentity)
                if data.count != entry.size
                    || KnowledgeDigest.sha256(data) != entry.sha256 {
                    recordError("checksums_mismatch", entry.path, "Inventoried size or hash does not match.")
                }
                if PermissionReviewTextSanitizer.containsSensitiveMaterial(
                    String(decoding: data, as: UTF8.self)) {
                    recordError(
                        "secret_material",
                        entry.path,
                        "Knowledge snapshot contains credential-like material.")
                }
            } catch {
                recordError("checksums_read", entry.path, "Inventoried file could not be re-read safely.")
            }
        }
        let actual = Set(scanned.map(\.relativePath))
            .subtracting([
                KnowledgeHostIdentity.bundlePath("checksums.json"),
            ])
        if actual != paths {
            recordError("checksums_completeness", "checksums", "Leaf inventory is missing files or contains extra entries.")
        }
    }

    private func decodeChunks(
        _ data: Data,
        recordError: (String, String, String) -> Void
    ) -> [KnowledgeChunk] {
        var chunks: [KnowledgeChunk] = []
        for (offset, rawLine) in data.split(separator: 0x0A, omittingEmptySubsequences: true).enumerated() {
            guard rawLine.count <= 1 * 1_024 * 1_024 else {
                recordError("chunk_line_size", "chunk-line-\(offset + 1)", "Chunk line exceeds the bounded size.")
                continue
            }
            do {
                try schemaValidator.validate(
                    data: Data(rawLine),
                    against: .chunk)
                chunks.append(try KnowledgeJSON.decode(
                    KnowledgeChunk.self,
                    from: Data(rawLine)))
            } catch {
                recordError("chunk_decode", "chunk-line-\(offset + 1)", "Chunk line is invalid JSON.")
            }
        }
        return chunks
    }

    private func validateChunks(
        _ chunks: [KnowledgeChunk],
        concepts: [String: OKFConcept],
        checksums: KnowledgeChecksums,
        snapshotRoot: URL,
        rootIdentity: WorkspaceRootIdentity,
        policy: KnowledgeValidationPolicy,
        recordError: (String, String, String) -> Void
    ) {
        var IDs = Set<String>()
        for chunk in chunks {
            guard chunk.schema == KnowledgeContract.chunkSchema,
                  IDs.insert(chunk.chunkID).inserted,
                  KnowledgeDigest.sha256(chunk.text) == chunk.textSha256,
                  !chunk.sourceIDs.isEmpty,
                  chunk.sourceIDs.allSatisfy(
                      KnowledgeSourceIdentity.isPortable),
                  Set(chunk.sourceIDs).count == chunk.sourceIDs.count else {
                recordError("chunk_identity", chunk.chunkID, "Chunk identity, text hash, or source IDs are invalid.")
                continue
            }
            switch chunk.evidenceClass {
            case .exactConceptSlice:
                guard let conceptID = chunk.conceptID,
                      let revision = chunk.conceptRevision,
                      let locator = chunk.conceptLocator,
                      chunk.supportingConcepts == nil,
                      let concept = concepts[conceptID],
                      concept.revision == revision else {
                    recordError("chunk_exact_provenance", chunk.chunkID, "Exact chunk concept binding is invalid.")
                    continue
                }
                do {
                    if try Self.slice(concept.normalizedText, locator: locator) != chunk.text {
                        recordError("chunk_exact_slice", chunk.chunkID, "Exact chunk bytes do not match the concept locator.")
                    }
                } catch {
                    recordError("chunk_exact_slice", chunk.chunkID, "Exact chunk locator is invalid.")
                }
                do {
                    let attributed = try OKFReader.attributedSourceIDs(
                        in: chunk.text,
                        declaredSourceIDs: concept.sources.compactMap(\.id))
                    if chunk.sourceIDs != attributed {
                        recordError(
                            "chunk_source",
                            chunk.chunkID,
                            "Exact chunk source IDs do not match deterministic concept attribution.")
                    }
                } catch {
                    recordError(
                        "chunk_source",
                        chunk.chunkID,
                        "Exact chunk source attribution could not be parsed deterministically.")
                }
            case .generatedDerivative:
                guard policy.allowGeneratedDerivatives,
                      chunk.conceptLocator == nil,
                      let supports = chunk.supportingConcepts,
                      !supports.isEmpty else {
                    recordError("chunk_derivative_provenance", chunk.chunkID, "Generated derivative provenance is incomplete.")
                    continue
                }
                var supportingSourceIDs = Set<String>()
                for support in supports {
                    guard let concept = concepts[support.conceptID],
                          concept.revision == support.conceptRevision else {
                        recordError("chunk_derivative_support", chunk.chunkID, "Generated derivative support is missing or changed.")
                        continue
                    }
                    supportingSourceIDs.formUnion(
                        concept.sources.compactMap(\.id))
                    do {
                        _ = try Self.slice(concept.normalizedText, locator: support.conceptLocator)
                    } catch {
                        recordError("chunk_derivative_support", chunk.chunkID, "Generated derivative support locator is invalid.")
                    }
                }
                if !Set(chunk.sourceIDs).isSubset(of: supportingSourceIDs) {
                    recordError(
                        "chunk_source",
                        chunk.chunkID,
                        "Generated chunk source ID is missing from its supporting concepts.")
                }
            }
            do {
                let sourceConcepts: [OKFConcept]
                switch chunk.evidenceClass {
                case .exactConceptSlice:
                    sourceConcepts = chunk.conceptID.flatMap { concepts[$0] }.map { [$0] } ?? []
                case .generatedDerivative:
                    sourceConcepts = (chunk.supportingConcepts ?? []).compactMap {
                        concepts[$0.conceptID]
                    }
                }
                try validateSourceLocators(
                    chunk.sourceLocators,
                    allowedSourceIDs: Set(chunk.sourceIDs),
                    concepts: sourceConcepts,
                    checksums: checksums,
                    snapshotRoot: snapshotRoot,
                    rootIdentity: rootIdentity)
            } catch let domain as KnowledgeDomainError {
                recordError("source_locator", chunk.chunkID, domain.failure.message)
            } catch {
                recordError("source_locator", chunk.chunkID, "Source locator is invalid.")
            }
        }
    }

    private func validateDense(
        _ profile: KnowledgeEmbeddingIndexProfile,
        denseFile: KnowledgeDenseIndexFile,
        denseData: Data,
        chunks: [KnowledgeChunk],
        recordError: (String, String, String) -> Void
    ) {
        if profile.indexDigest != KnowledgeDigest.sha256(denseData)
            || profile.vectorCount != denseFile.vectors.count
            || profile.model.dimensions != denseFile.dimensions
            || profile.chunkManifestDigest.isEmpty {
            recordError("dense_integrity", profile.id, "Dense index count, dimension, or digest is inconsistent.")
        }
        let chunkIDs = Set(chunks.map(\.chunkID))
        let vectorIDs = Set(denseFile.vectors.map(\.chunkID))
        if chunkIDs != vectorIDs {
            recordError("dense_completeness", profile.id, "Dense index has missing or orphan vector keys.")
        }
        do {
            if try Self.denseComponentRevision(profile) != profile.componentRevision {
                recordError("dense_component_revision", profile.id, "Dense component revision is inconsistent.")
            }
        } catch {
            recordError("dense_component_revision", profile.id, "Dense component revision could not be computed.")
        }
        if profile.componentRevision != profileForSelectedDenseRevision(profile) {
            // This helper keeps the diagnostic branch explicit while the exact
            // selected reference is validated in retrieval snapshot checks.
        }
    }

    private func profileForSelectedDenseRevision(
        _ profile: KnowledgeEmbeddingIndexProfile
    ) -> String {
        profile.componentRevision
    }

    private func validateLexical(
        _ profile: KnowledgeLexicalIndexProfile,
        lexicalFile: KnowledgeLexicalIndexFile,
        lexicalData: Data,
        chunks: [KnowledgeChunk],
        recordError: (String, String, String) -> Void
    ) {
        if profile.indexDigest != KnowledgeDigest.sha256(lexicalData)
            || profile.documentCount != lexicalFile.documents.count
            || profile.tokenizer != lexicalFile.tokenizer {
            recordError("lexical_integrity", profile.id, "Lexical index count, tokenizer, or digest is inconsistent.")
        }
        if Set(chunks.map(\.chunkID)) != Set(lexicalFile.documents.map(\.chunkID)) {
            recordError("lexical_completeness", profile.id, "Lexical index has missing or orphan document keys.")
        }
        do {
            if try Self.lexicalComponentRevision(profile) != profile.componentRevision {
                recordError("lexical_component_revision", profile.id, "Lexical component revision is inconsistent.")
            }
        } catch {
            recordError("lexical_component_revision", profile.id, "Lexical component revision could not be computed.")
        }
    }

    private func validateSourceLocators(
        _ locators: [KnowledgeSourceLocator]?,
        allowedSourceIDs: Set<String>,
        concepts: [OKFConcept],
        checksums: KnowledgeChecksums,
        snapshotRoot: URL,
        rootIdentity: WorkspaceRootIdentity
    ) throws {
        guard let locators else { return }
        guard Set(locators).count == locators.count else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Source locator collection contains a duplicate entry.")
        }
        var inventory: [String: KnowledgeChecksumEntry] = [:]
        for entry in checksums.files {
            guard inventory.updateValue(entry, forKey: entry.path) == nil else {
                throw KnowledgeDomainError(
                    .integrityFailed,
                    "Source inventory contains a duplicate path.")
            }
        }
        for locator in locators {
            guard locator.schema == KnowledgeHostIdentity.schema(
                    "source-locator/1"),
                  KnowledgeSourceIdentity.isPortable(locator.sourceID),
                  allowedSourceIDs.contains(locator.sourceID),
                  KnowledgeDigest.isValid(locator.sourceRevision),
                  !locator.adapterIdentity.isEmpty,
                  !locator.adapterVersion.isEmpty,
                  backendRegistry.sourceLocators.contains(
                    locator.adapterIdentity + "@" + locator.adapterVersion) else {
                throw KnowledgeDomainError(.integrityFailed, "Source locator cannot be replayed by an exact registered adapter.")
            }
            let resourcePaths = Set(concepts.compactMap { concept -> String? in
                guard let source = concept.sources.first(where: {
                    $0.id == locator.sourceID
                }) else {
                    return nil
                }
                return Self.localSourcePath(
                    source.resource,
                    relativeTo: concept.relativePath)
            })
            guard resourcePaths.count == 1,
                  let resourcePath = resourcePaths.first,
                  let entry = inventory[resourcePath],
                  entry.sha256 == locator.sourceRevision else {
                throw KnowledgeDomainError(
                    .integrityFailed,
                    "Source locator is not bound to one immutable source inventory entry.")
            }
            let sourceBytes = try fileSystem.readFile(
                root: snapshotRoot,
                relativePath: resourcePath,
                maximumBytes: entry.size,
                expectedRootIdentity: rootIdentity)
            guard sourceBytes.count == entry.size,
                  KnowledgeDigest.sha256(sourceBytes) == entry.sha256 else {
                throw KnowledgeDomainError(
                    .integrityFailed,
                    "Source locator bytes no longer match the immutable source inventory.")
            }
            _ = try backendRegistry.sourceLocatorAdapters.replay(
                locator,
                in: sourceBytes)
        }
    }

    private static func localSourcePath(
        _ resource: String,
        relativeTo conceptPath: String
    ) -> String? {
        guard !resource.isEmpty,
              resource.range(
                of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
                options: .regularExpression) == nil else { return nil }
        return normalizedBundlePath(
            resource,
            relativeTo: conceptPath)
    }

    private func validateSourceReferences(
        _ concept: OKFConcept,
        knownPaths: Set<String>,
        recordError: (String, String, String) -> Void
    ) {
        for source in concept.sources {
            let resource = source.resource
            if resource.range(
                of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
                options: .regularExpression) != nil { continue }
            guard let normalized = Self.normalizedBundlePath(
                resource,
                relativeTo: concept.relativePath),
                  knownPaths.contains(normalized) else {
                recordError("grounding_source_missing", concept.conceptID, "A grounding-required bundle source is missing.")
                continue
            }
        }
    }

    private func validateOrdinaryLinks(
        _ concept: OKFConcept,
        knownPaths: Set<String>,
        warning: (String, String, String) -> Void
    ) {
        guard let expression = try? NSRegularExpression(
            pattern: #"\[[^\]]*\]\(([^)]+)\)"#) else { return }
        let range = NSRange(
            concept.normalizedText.startIndex..<concept.normalizedText.endIndex,
            in: concept.normalizedText)
        for match in expression.matches(in: concept.normalizedText, range: range) {
            guard let targetRange = Range(match.range(at: 1), in: concept.normalizedText) else {
                continue
            }
            var target = String(concept.normalizedText[targetRange])
            if let fragment = target.firstIndex(of: "#") {
                target = String(target[..<fragment])
            }
            guard !target.isEmpty,
                  !target.contains("://"),
                  !target.hasPrefix("#") else { continue }
            guard let normalized = Self.normalizedBundlePath(
                target,
                relativeTo: concept.relativePath),
                  knownPaths.contains(normalized) else {
                warning(
                    "ordinary_link_missing",
                    concept.conceptID,
                    "A non-grounding Markdown link does not resolve inside this snapshot.")
                continue
            }
        }
    }

    /// Resolves a bundle-local reference without ever asking Foundation to
    /// reinterpret a relative string against the process working directory.
    private static func normalizedBundlePath(
        _ reference: String,
        relativeTo ownerPath: String
    ) -> String? {
        guard !reference.isEmpty,
              !reference.contains("\\"),
              !reference.contains("\0") else {
            return nil
        }
        var components = reference.hasPrefix("/")
            ? []
            : ownerPath
                .split(separator: "/", omittingEmptySubsequences: true)
                .dropLast()
                .map(String.init)
        for rawComponent in reference.split(
            separator: "/",
            omittingEmptySubsequences: false) {
            let component = String(rawComponent)
            if component.isEmpty || component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        let normalized = components.joined(separator: "/")
        return normalized.isEmpty ? nil : normalized
    }

    private static func slice(
        _ text: String,
        locator: KnowledgeConceptLocator
    ) throws -> String {
        guard locator.kind == "utf8-byte-range",
              locator.start >= 0,
              locator.end > locator.start else {
            throw KnowledgeDomainError(.integrityFailed, "Concept locator shape is invalid.")
        }
        let bytes = Array(text.utf8)
        guard locator.end <= bytes.count,
              String(bytes: bytes[locator.start..<locator.end], encoding: .utf8) != nil else {
            throw KnowledgeDomainError(.integrityFailed, "Concept locator is outside a UTF-8 boundary.")
        }
        return String(decoding: bytes[locator.start..<locator.end], as: UTF8.self)
    }
}
