import Foundation

/// Host-owned retrieval policy. None of these fields are accepted from model
/// arguments, so a caller cannot widen trust, freshness, corpus, or memory
/// limits through `search_knowledge`.
public struct KnowledgeSearchPolicy: Equatable, Sendable {
    public var denseCandidateLimit: Int
    public var lexicalCandidateLimit: Int
    public var rrfConstant: Int
    public var minimumDenseSimilarity: Double
    public var maximumCorpusChunks: Int
    public var maximumEvidencePerConcept: Int
    public var maximumEvidencePerSource: Int
    public var allowedStatuses: Set<String>
    public var allowedTrustTiers: Set<String>
    public var allowedConceptIDs: Set<String>?
    public var allowedSourceIDs: Set<String>?
    public var includeStale: Bool
    public var evaluationDate: String
    public var maximumDurationMilliseconds: Int
    public var resultBudget: KnowledgeResultBudget

    public init(denseCandidateLimit: Int = 40,
                lexicalCandidateLimit: Int = 40,
                rrfConstant: Int = 60,
                minimumDenseSimilarity: Double = 0.15,
                maximumCorpusChunks: Int = 100_000,
                maximumEvidencePerConcept: Int = 2,
                maximumEvidencePerSource: Int = 2,
                allowedStatuses: Set<String> = ["stable"],
                allowedTrustTiers: Set<String> = [
                    "human-reviewed", "machine-confirmed", "unverified",
                ],
                allowedConceptIDs: Set<String>? = nil,
                allowedSourceIDs: Set<String>? = nil,
                includeStale: Bool = false,
                evaluationDate: String,
                maximumDurationMilliseconds: Int = 15_000,
                resultBudget: KnowledgeResultBudget = KnowledgeResultBudget()) {
        self.denseCandidateLimit = denseCandidateLimit
        self.lexicalCandidateLimit = lexicalCandidateLimit
        self.rrfConstant = rrfConstant
        self.minimumDenseSimilarity = minimumDenseSimilarity
        self.maximumCorpusChunks = maximumCorpusChunks
        self.maximumEvidencePerConcept = maximumEvidencePerConcept
        self.maximumEvidencePerSource = maximumEvidencePerSource
        self.allowedStatuses = allowedStatuses
        self.allowedTrustTiers = allowedTrustTiers
        self.allowedConceptIDs = allowedConceptIDs
        self.allowedSourceIDs = allowedSourceIDs
        self.includeStale = includeStale
        self.evaluationDate = evaluationDate
        self.maximumDurationMilliseconds = maximumDurationMilliseconds
        self.resultBudget = resultBudget
    }

    fileprivate func validate() throws {
        guard denseCandidateLimit > 0,
              lexicalCandidateLimit >= 0,
              rrfConstant > 0,
              minimumDenseSimilarity.isFinite,
              minimumDenseSimilarity >= -1,
              minimumDenseSimilarity <= 1,
              maximumCorpusChunks > 0,
              maximumEvidencePerConcept > 0,
              maximumEvidencePerSource > 0,
              !allowedStatuses.isEmpty,
              allowedStatuses.isSubset(of: ["draft", "stable", "deprecated"]),
              !allowedTrustTiers.isEmpty,
              allowedTrustTiers.isSubset(of: [
                  "human-reviewed", "machine-confirmed", "unverified",
              ]),
              maximumDurationMilliseconds > 0,
              resultBudget.maximumEvidenceCount > 0,
              resultBudget.maximumEvidenceCount <= 20,
              resultBudget.maximumEvidenceCharacters > 0,
              resultBudget.maximumEvidenceCharacters <= 4_096,
              resultBudget.maximumEvidenceBytes > 0,
              resultBudget.maximumEvidenceBytes <= 16 * 1_024,
              resultBudget.maximumAggregateEvidenceBytes > 0,
              resultBudget.maximumSerializedBytes > 0,
              resultBudget.maximumEstimatedTokens > 0,
              resultBudget.maximumCandidates > 0,
              denseCandidateLimit + lexicalCandidateLimit
                  <= resultBudget.maximumCandidates else {
            throw KnowledgeDomainError(
                .searchBudgetExceeded,
                "The host retrieval policy contains an invalid or unsafe bound.")
        }
    }
}

/// Immutable, fully in-memory query view of one validated retrieval snapshot.
/// Construction applies host status/trust/freshness policy *before* either
/// dense or lexical ranking, so excluded content cannot influence Top-K.
public struct KnowledgeSnapshotSearchReader: Sendable {
    private struct EligibleChunk: Sendable {
        let chunk: KnowledgeChunk
        let trust: String
        let status: String
        let stale: Bool
        let diversityConcept: String
        let diversitySources: [String]
    }

    public let snapshot: KnowledgeValidatedSnapshot
    public let policy: KnowledgeSearchPolicy

    private let embeddingProvider: any KnowledgeEmbeddingProvider
    private let rerankerProvider: (any KnowledgeRerankerProvider)?
    private let denseIndex: KnowledgeDenseIndex?
    private let lexicalIndex: KnowledgeBM25Index?
    private let retrievalRoute: KnowledgeRetrievalExecutionRoute
    private let eligibleChunks: [String: EligibleChunk]
    private let validator: KnowledgeValidator

    public init(snapshot: KnowledgeValidatedSnapshot,
                embeddingRegistry: KnowledgeEmbeddingRuntimeRegistry,
                rerankerRegistry: KnowledgeRerankerRuntimeRegistry? = nil,
                allowsNetworkRuntime: Bool = false,
                policy: KnowledgeSearchPolicy,
                validator: KnowledgeValidator? = nil) throws {
        try policy.validate()
        guard snapshot.report.semanticVerdict else {
            throw KnowledgeDomainError(
                .indexNotReady,
                retryable: true,
                "The knowledge snapshot is not semantically valid.")
        }
        guard snapshot.evidenceValidationContext.backendRegistry.digest
                == snapshot.backendRegistryDigest else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "The mounted snapshot evidence registry binding is inconsistent.")
        }
        guard snapshot.profile.retrieval.dense == "required" else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "The snapshot contains an unsupported dense retrieval policy.")
        }
        guard let denseProfile = snapshot.profile.embeddingIndexes.first(where: {
            $0.id == snapshot.profile.retrievalSnapshot.dense.id
                && $0.componentRevision
                    == snapshot.profile.retrievalSnapshot.dense.componentRevision
        }) else {
            throw KnowledgeDomainError(
                .embeddingIncompatible,
                "The selected dense component is not present in the profile.")
        }
        let provider = try embeddingRegistry.resolve(denseProfile.model)
        guard allowsNetworkRuntime
                || denseProfile.model.runtimeBindingKind == .local else {
            throw KnowledgeDomainError(
                .accessDenied,
                "A remote embedding route was not included in the authorized execution semantics.")
        }

        let selectedLexicalFile: KnowledgeLexicalIndexFile?
        switch snapshot.profile.retrieval.lexical {
        case "disabled":
            // A retained or otherwise stray lexical artifact is not authority
            // to widen the frozen retrieval route.
            selectedLexicalFile = nil
        case "optional", "required":
            if let selected = snapshot.profile.retrievalSnapshot.lexical {
                guard snapshot.profile.lexicalIndexes.contains(where: {
                    $0.id == selected.id
                        && $0.componentRevision == selected.componentRevision
                }), let lexicalFile = snapshot.lexicalFile else {
                    throw KnowledgeDomainError(
                        .indexNotReady,
                        retryable: true,
                        "The selected lexical retrieval component is unavailable.")
                }
                selectedLexicalFile = lexicalFile
            } else if snapshot.profile.retrieval.lexical == "required" {
                throw KnowledgeDomainError(
                    .indexNotReady,
                    retryable: true,
                    "The snapshot requires an exact lexical retrieval component.")
            } else {
                // Optional means absent is an explicit dense-only route. A
                // lexical file that is not selected by the snapshot is ignored.
                selectedLexicalFile = nil
            }
        default:
            throw KnowledgeDomainError(
                .integrityFailed,
                "The snapshot contains an unsupported lexical retrieval policy.")
        }

        let route: KnowledgeRetrievalExecutionRoute
        switch snapshot.profile.retrieval.fusion {
        case "dense_only":
            route = .denseOnly
        case "rrf":
            route = selectedLexicalFile == nil ? .denseOnly : .hybridRRF
        default:
            throw KnowledgeDomainError(
                .integrityFailed,
                "The snapshot contains an unsupported retrieval fusion route.")
        }
        let reranker: (any KnowledgeRerankerProvider)?
        switch snapshot.profile.retrieval.reranker.mode {
        case .disabled:
            guard snapshot.profile.retrieval.reranker.model == nil else {
                throw KnowledgeDomainError(
                    .rerankUnavailable,
                    "A disabled reranker profile must not bind a model.")
            }
            reranker = nil
        case .optional:
            guard let expected = snapshot.profile.retrieval.reranker.model else {
                reranker = nil
                break
            }
            guard allowsNetworkRuntime || expected.runtimeBindingKind == .local else {
                throw KnowledgeDomainError(
                    .accessDenied,
                    "A remote reranker route was not included in the authorized execution semantics.")
            }
            if let rerankerRegistry {
                reranker = try? rerankerRegistry.resolve(expected)
            } else {
                reranker = nil
            }
        case .required:
            guard let expected = snapshot.profile.retrieval.reranker.model,
                  let rerankerRegistry else {
                throw KnowledgeDomainError(
                    .rerankUnavailable,
                    retryable: true,
                    "The snapshot requires an exact reranker runtime.")
            }
            guard allowsNetworkRuntime || expected.runtimeBindingKind == .local else {
                throw KnowledgeDomainError(
                    .accessDenied,
                    "A remote reranker route was not included in the authorized execution semantics.")
            }
            reranker = try rerankerRegistry.resolve(expected)
        }

        var eligible: [String: EligibleChunk] = [:]
        for chunk in snapshot.chunks.sorted(by: { $0.chunkID < $1.chunkID }) {
            guard let metadata = Self.metadata(
                for: chunk,
                concepts: snapshot.concepts,
                evaluationDate: policy.evaluationDate) else {
                continue
            }
            let conceptAllowed = policy.allowedConceptIDs.map { allowed in
                metadata.conceptIDs.isSubset(of: allowed)
            } ?? true
            let sourcesAllowed = policy.allowedSourceIDs.map { allowed in
                Set(chunk.sourceIDs).isSubset(of: allowed)
            } ?? true
            guard conceptAllowed,
                  sourcesAllowed,
                  policy.allowedStatuses.contains(metadata.status),
                  policy.allowedTrustTiers.contains(metadata.trust),
                  policy.includeStale || !metadata.stale else {
                continue
            }
            guard eligible[chunk.chunkID] == nil else {
                throw KnowledgeDomainError(
                    .integrityFailed,
                    "The query snapshot contains a duplicate eligible chunk identifier.")
            }
            eligible[chunk.chunkID] = EligibleChunk(
                chunk: chunk,
                trust: metadata.trust,
                status: metadata.status,
                stale: metadata.stale,
                diversityConcept: metadata.diversityConcept,
                diversitySources: chunk.sourceIDs.sorted())
        }

        guard eligible.count <= policy.maximumCorpusChunks else {
            throw KnowledgeDomainError(
                .searchBudgetExceeded,
                "The authorized query corpus exceeds the host scan bound.")
        }

        let denseVectors = snapshot.denseFile.vectors.filter {
            eligible[$0.chunkID] != nil
        }
        let dense: KnowledgeDenseIndex?
        if denseVectors.isEmpty {
            dense = nil
        } else {
            dense = try KnowledgeDenseIndex(file: KnowledgeDenseIndexFile(
                dimensions: snapshot.denseFile.dimensions,
                vectors: denseVectors))
        }

        let lexical: KnowledgeBM25Index?
        if route == .hybridRRF, let lexicalFile = selectedLexicalFile {
            let documents = lexicalFile.documents.filter {
                eligible[$0.chunkID] != nil
            }
            lexical = documents.isEmpty
                ? nil
                : try KnowledgeBM25Index(file: KnowledgeLexicalIndexFile(
                    tokenizer: lexicalFile.tokenizer,
                    documents: documents))
        } else {
            lexical = nil
        }

        self.snapshot = snapshot
        self.policy = policy
        embeddingProvider = provider
        rerankerProvider = reranker
        denseIndex = dense
        lexicalIndex = lexical
        retrievalRoute = route
        eligibleChunks = eligible
        let exactValidator = try validator
            ?? snapshot.evidenceValidationContext.makeValidator()
        guard exactValidator.backendRegistry.digest
                == snapshot.backendRegistryDigest else {
            throw KnowledgeDomainError(
                .integrityFailed,
                "Search evidence validation does not match the mounted backend registry.")
        }
        self.validator = exactValidator
    }

    /// Runs deterministic hybrid retrieval against this exact reader snapshot.
    /// `knowledgeBase` is an already-authorized opaque handle, never a path.
    public func search(knowledgeBase: String,
                       query: String,
                       limit: Int = 8) async throws -> KnowledgeSearchResponse {
        let normalizedQuery = OKFReader.normalize(query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidHandle(knowledgeBase),
              !normalizedQuery.isEmpty,
              normalizedQuery.count <= 16_384,
              limit >= 1,
              limit <= min(20, policy.resultBudget.maximumEvidenceCount) else {
            throw KnowledgeDomainError(
                .toolInputInvalid,
                "search_knowledge arguments do not satisfy the frozen input contract.")
        }

        let started = DispatchTime.now().uptimeNanoseconds
        try checkExecutionState(started: started)
        try requireStableSnapshotRoot()

        guard let denseIndex else {
            return KnowledgeSearchResponse.success(
                knowledgeBase: knowledgeBase,
                knowledgeBaseRevision: snapshot.profile.bundle.revision,
                retrievalSnapshot: snapshot.profile.retrievalSnapshot.id,
                retrievalSnapshotRevision: snapshot.profile.retrievalSnapshot.revision,
                rerankApplied: false,
                truncated: false,
                evidence: [])
        }

        let queryVector: [Float]
        do {
            queryVector = try await withDeadline(started: started) {
                try await embeddingProvider.embedQuery(normalizedQuery)
            }
        } catch is CancellationError {
            throw KnowledgeDomainError(
                .searchCancelled,
                "The knowledge search was cancelled.")
        }
        try checkExecutionState(started: started)

        let dense = try denseIndex.search(
            query: queryVector,
            limit: policy.denseCandidateLimit).filter {
                $0.score >= policy.minimumDenseSimilarity
            }
        let lexical: [KnowledgeScoredChunk]
        if retrievalRoute == .hybridRRF,
           policy.lexicalCandidateLimit > 0,
           let lexicalIndex {
            lexical = lexicalIndex.search(
                query: normalizedQuery,
                limit: policy.lexicalCandidateLimit)
        } else {
            lexical = []
        }
        guard dense.count + lexical.count <= policy.resultBudget.maximumCandidates else {
            throw KnowledgeDomainError(
                .searchBudgetExceeded,
                "Candidate generation exceeded the host execution budget.")
        }
        try checkExecutionState(started: started)

        let fused: [KnowledgeScoredChunk]
        switch retrievalRoute {
        case .denseOnly:
            fused = dense
        case .hybridRRF:
            fused = KnowledgeRRF.fuse(
                [dense, lexical].filter { !$0.isEmpty },
                k: policy.rrfConstant,
                limit: min(
                    policy.resultBudget.maximumCandidates,
                    max(
                        policy.denseCandidateLimit,
                        policy.lexicalCandidateLimit)))
        }
        let ordered: [KnowledgeScoredChunk]
        let rerankApplied: Bool
        if let rerankerProvider, !fused.isEmpty {
            let rerankInput = fused.enumerated().compactMap { offset, result in
                eligibleChunks[result.chunkID].map {
                    KnowledgeRerankCandidate(
                        chunkID: result.chunkID,
                        text: $0.chunk.text,
                        retrievalRank: offset + 1,
                        retrievalScore: result.score)
                }
            }
            let reranked: [KnowledgeRerankedCandidate]
            do {
                reranked = try await withDeadline(started: started) {
                    try await rerankerProvider.rerank(
                        query: normalizedQuery,
                        candidates: rerankInput)
                }
            } catch is CancellationError {
                throw KnowledgeDomainError(
                    .searchCancelled,
                    "The knowledge rerank was cancelled.")
            } catch let domain as KnowledgeDomainError
                where domain.failure.code == .searchCancelled
                    || domain.failure.code == .searchTimeout {
                throw domain
            } catch {
                // Once an exact route is selected, execution failure is never
                // silently replaced by the pre-rerank order.
                throw KnowledgeDomainError(
                    .rerankUnavailable,
                    retryable: true,
                    "The exact reranker runtime failed.")
            }
            let expectedIDs = Set(rerankInput.map(\.chunkID))
            let returnedIDs = reranked.map(\.chunkID)
            guard reranked.count == rerankInput.count,
                  Set(returnedIDs).count == returnedIDs.count,
                  Set(returnedIDs) == expectedIDs,
                  reranked.allSatisfy({ $0.score.isFinite }) else {
                throw KnowledgeDomainError(
                    .rerankUnavailable,
                    "The reranker returned an invalid candidate permutation.")
            }
            ordered = reranked.map {
                KnowledgeScoredChunk(chunkID: $0.chunkID, score: $0.score)
            }
            rerankApplied = true
        } else {
            ordered = fused
            rerankApplied = false
        }
        try checkExecutionState(started: started)
        let diversified = diversifiedCandidates(ordered, limit: limit)
        let response = try pack(
            candidates: diversified,
            knowledgeBase: knowledgeBase,
            requestedLimit: limit,
            rerankApplied: rerankApplied)
        try requireStableSnapshotRoot()
        try checkExecutionState(started: started)
        return response
    }

    private func diversifiedCandidates(_ candidates: [KnowledgeScoredChunk],
                                       limit: Int) -> [EligibleChunk] {
        var conceptCounts: [String: Int] = [:]
        var sourceCounts: [String: Int] = [:]
        var textHashes = Set<String>()
        var result: [EligibleChunk] = []
        for candidate in candidates {
            guard let eligible = eligibleChunks[candidate.chunkID],
                  textHashes.insert(eligible.chunk.textSha256).inserted,
                  conceptCounts[eligible.diversityConcept, default: 0]
                    < policy.maximumEvidencePerConcept,
                  eligible.diversitySources.allSatisfy({
                      sourceCounts[$0, default: 0]
                          < policy.maximumEvidencePerSource
                  }) else {
                continue
            }
            result.append(eligible)
            conceptCounts[eligible.diversityConcept, default: 0] += 1
            for source in eligible.diversitySources {
                sourceCounts[source, default: 0] += 1
            }
            if result.count == limit { break }
        }
        return result
    }

    private func pack(candidates: [EligibleChunk],
                      knowledgeBase: String,
                      requestedLimit: Int,
                      rerankApplied: Bool) throws -> KnowledgeSearchResponse {
        var evidence: [KnowledgeSearchEvidence] = []
        var aggregateEvidenceBytes = 0
        var budgetTruncated = false

        for eligible in candidates.prefix(requestedLimit) {
            let next = makeEvidence(
                from: eligible,
                knowledgeBase: knowledgeBase,
                rank: evidence.count + 1)
            let textBytes = Data(next.text.utf8).count
            let perEvidenceFits = next.text.count
                    <= policy.resultBudget.maximumEvidenceCharacters
                && textBytes <= policy.resultBudget.maximumEvidenceBytes
            guard perEvidenceFits else {
                if evidence.isEmpty {
                    throw KnowledgeDomainError(
                        .searchBudgetExceeded,
                        "The highest-ranked evidence cannot fit the safe result budget.")
                }
                budgetTruncated = true
                break
            }

            let proposedAggregate = aggregateEvidenceBytes + textBytes
            let proposed = evidence + [next]
            guard proposedAggregate
                    <= policy.resultBudget.maximumAggregateEvidenceBytes,
                  try responseFitsTransportBudget(
                      evidence: proposed,
                      knowledgeBase: knowledgeBase,
                      truncated: false,
                      rerankApplied: rerankApplied) else {
                if evidence.isEmpty {
                    throw KnowledgeDomainError(
                        .searchBudgetExceeded,
                        "The highest-ranked evidence cannot fit the safe result budget.")
                }
                budgetTruncated = true
                break
            }
            evidence = proposed
            aggregateEvidenceBytes = proposedAggregate
        }

        if budgetTruncated {
            while !evidence.isEmpty,
                  try !responseFitsTransportBudget(
                      evidence: evidence,
                      knowledgeBase: knowledgeBase,
                      truncated: true,
                      rerankApplied: rerankApplied) {
                evidence.removeLast()
            }
            guard !evidence.isEmpty else {
                throw KnowledgeDomainError(
                    .searchBudgetExceeded,
                    "No evidence can fit the safe truncated result envelope.")
            }
        }

        for item in evidence {
            try validator.validateEvidence(item, in: snapshot)
        }
        return KnowledgeSearchResponse.success(
            knowledgeBase: knowledgeBase,
            knowledgeBaseRevision: snapshot.profile.bundle.revision,
            retrievalSnapshot: snapshot.profile.retrievalSnapshot.id,
            retrievalSnapshotRevision: snapshot.profile.retrievalSnapshot.revision,
            rerankApplied: rerankApplied,
            truncated: budgetTruncated,
            evidence: evidence)
    }

    private func responseFitsTransportBudget(
        evidence: [KnowledgeSearchEvidence],
        knowledgeBase: String,
        truncated: Bool,
        rerankApplied: Bool
    ) throws -> Bool {
        let response = KnowledgeSearchResponse.success(
            knowledgeBase: knowledgeBase,
            knowledgeBaseRevision: snapshot.profile.bundle.revision,
            retrievalSnapshot: snapshot.profile.retrievalSnapshot.id,
            retrievalSnapshotRevision: snapshot.profile.retrievalSnapshot.revision,
            rerankApplied: rerankApplied,
            truncated: truncated,
            evidence: evidence)
        let bytes = try KnowledgeJSON.encode(response).count
        let summaryBytes = 128
        let duplicatedTransportBytes = bytes * 2 + summaryBytes
        // UTF-8 bytes are a conservative upper bound for estimated token count.
        return duplicatedTransportBytes
                <= policy.resultBudget.maximumSerializedBytes
            && duplicatedTransportBytes
                <= policy.resultBudget.maximumEstimatedTokens
    }

    private func makeEvidence(from eligible: EligibleChunk,
                              knowledgeBase: String,
                              rank: Int) -> KnowledgeSearchEvidence {
        let chunk = eligible.chunk
        let evidenceDigest = KnowledgeDigest.sha256([
            KnowledgeHostIdentity.schema("evidence-id/1"),
            snapshot.profile.bundle.id,
            snapshot.profile.bundle.revision,
            snapshot.profile.retrievalSnapshot.id,
            snapshot.profile.retrievalSnapshot.revision,
            chunk.chunkID,
            chunk.textSha256,
        ].joined(separator: "\u{1f}"))
        let evidenceID = "ev_" + evidenceDigest.dropFirst("sha256:".count)
        let evidenceURI = [
            "knowledge://\(knowledgeBase)",
            snapshot.profile.retrievalSnapshot.id,
            evidenceID,
        ].joined(separator: "/")
        return KnowledgeSearchEvidence(
            evidenceID: evidenceID,
            rank: rank,
            text: chunk.text,
            textSha256: chunk.textSha256,
            evidenceURI: evidenceURI,
            conceptID: chunk.conceptID,
            conceptRevision: chunk.conceptRevision,
            evidenceClass: chunk.evidenceClass,
            conceptLocator: chunk.conceptLocator,
            supportingConcepts: chunk.supportingConcepts,
            producer: chunk.evidenceClass == .generatedDerivative
                ? chunk.producer
                : nil,
            sourceIDs: chunk.sourceIDs.sorted(),
            sourceLocators: chunk.sourceLocators?.sorted(by: {
                if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
                if $0.kind != $1.kind { return $0.kind < $1.kind }
                return $0.value < $1.value
            }),
            trust: eligible.trust,
            status: eligible.status,
            stale: eligible.stale)
    }

    private func requireStableSnapshotRoot() throws {
        guard snapshot.rootIdentity.matchesCurrentDirectory(
            rootPath: snapshot.root.path) else {
            throw KnowledgeDomainError(
                .revisionChanged,
                retryable: true,
                "The mounted knowledge snapshot identity changed during search.")
        }
    }

    private func checkExecutionState(started: UInt64) throws {
        if Task.isCancelled {
            throw KnowledgeDomainError(
                .searchCancelled,
                "The knowledge search was cancelled.")
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= started ? now - started : UInt64.max
        let maximum = UInt64(policy.maximumDurationMilliseconds)
            * 1_000_000
        guard elapsed <= maximum else {
            throw KnowledgeDomainError(
                .searchTimeout,
                retryable: true,
                "The knowledge search exceeded its bounded duration.")
        }
    }

    /// Races one request-owned provider child against the remaining deadline.
    /// Both children are cancelled and fully joined before this function
    /// returns or throws; no detached or orphaned backend work is retained.
    private func withDeadline<Value: Sendable>(
        started: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try checkExecutionState(started: started)
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= started ? now - started : UInt64.max
        let maximum = UInt64(policy.maximumDurationMilliseconds) * 1_000_000
        guard elapsed < maximum else {
            throw KnowledgeDomainError(
                .searchTimeout,
                retryable: true,
                "The knowledge search exceeded its bounded duration.")
        }
        let remaining = maximum - elapsed
        return try await withThrowingTaskGroup(
            of: KnowledgeDeadlineResult<Value>.self,
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
                        "The knowledge provider race produced no result.")
                }
                group.cancelAll()
                while true {
                    do {
                        guard try await group.next() != nil else { break }
                    } catch {
                        // A cancelled sibling is expected; `next()` consumed it.
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
                        "The knowledge search exceeded its bounded duration.")
                }
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private static func isValidHandle(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9._-]{1,128}$"#,
            options: .regularExpression) != nil
    }

    private static func metadata(
        for chunk: KnowledgeChunk,
        concepts: [String: OKFConcept],
        evaluationDate: String
    ) -> (trust: String, status: String, stale: Bool,
          diversityConcept: String, conceptIDs: Set<String>)? {
        switch chunk.evidenceClass {
        case .exactConceptSlice:
            guard let conceptID = chunk.conceptID,
                  let concept = concepts[conceptID],
                  concept.revision == chunk.conceptRevision else {
                return nil
            }
            return (
                concept.trustTier,
                concept.status,
                isStale(concept.staleAfter, evaluationDate: evaluationDate),
                conceptID,
                [conceptID])
        case .generatedDerivative:
            guard let supports = chunk.supportingConcepts, !supports.isEmpty else {
                return nil
            }
            let resolved = supports.compactMap { support -> OKFConcept? in
                guard let concept = concepts[support.conceptID],
                      concept.revision == support.conceptRevision else {
                    return nil
                }
                return concept
            }
            guard resolved.count == supports.count else { return nil }
            let trust: String
            if resolved.allSatisfy({ $0.trustTier == "human-reviewed" }) {
                trust = "human-reviewed"
            } else if resolved.contains(where: { $0.trustTier == "unverified" }) {
                trust = "unverified"
            } else {
                trust = "machine-confirmed"
            }
            let status: String
            if resolved.contains(where: { $0.status == "deprecated" }) {
                status = "deprecated"
            } else if resolved.contains(where: { $0.status == "draft" }) {
                status = "draft"
            } else {
                status = "stable"
            }
            let stale = resolved.contains {
                isStale($0.staleAfter, evaluationDate: evaluationDate)
            }
            let identity = supports.map(\.conceptID).sorted().joined(separator: "\u{1f}")
            return (
                trust,
                status,
                stale,
                "generated:\(identity)",
                Set(supports.map(\.conceptID)))
        }
    }

    private static func isStale(_ staleAfter: String?,
                                evaluationDate: String) -> Bool {
        guard let staleAfter else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        let stale = OKFReader.parseISODateOnly(staleAfter)
        let evaluation = formatter.date(from: evaluationDate)
            ?? fallback.date(from: evaluationDate)
        guard let stale, let evaluation else {
            // Invalid dates should already have failed validation. Treat an
            // unexpected value as stale rather than widening retrieval.
            return true
        }
        return stale <= evaluation
    }
}

private enum KnowledgeDeadlineResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}

private enum KnowledgeRetrievalExecutionRoute: Sendable {
    case denseOnly
    case hybridRRF
}
