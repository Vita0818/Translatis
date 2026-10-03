import Foundation
import IntatisCore
import IntatisPermission
import IntatisProtocol
import IntatisProviders

public enum AgentModelHistoryCompactionError:
    Error, Equatable, Sendable, LocalizedError
{
    case responseEndedWithoutCompletionMarker
    case responseRequestedToolCalls
    case incompleteFinishReason(String)
    case emptySummary
    case invalidContextualReplacement
    case summaryContainsSecret
    case summaryOutputLimitExceeded(estimated: Int, limit: Int)
    case replacementBudgetUnavailable(limit: Int)
    case replacementExceedsUsableContext(estimated: Int, limit: Int)
    case windowNumberExhausted

    public var errorDescription: String? {
        switch self {
        case .responseEndedWithoutCompletionMarker:
            return "The history compaction response ended without a completion marker."
        case .responseRequestedToolCalls:
            return "The history compaction response unexpectedly requested tools."
        case .incompleteFinishReason(let reason):
            return "The history compaction response was incomplete: \(reason)."
        case .emptySummary:
            return "The history compaction response did not contain a summary."
        case .invalidContextualReplacement:
            return "The current turn context cannot be represented in a model-history replacement."
        case .summaryContainsSecret:
            return "The history compaction response contained secret-like material and was rejected."
        case .summaryOutputLimitExceeded(let estimated, let limit):
            return "The history compaction response exceeded its output ceiling (estimated \(estimated), limit \(limit) tokens)."
        case .replacementBudgetUnavailable(let limit):
            return "The model's usable context window leaves no room for a history-compaction summary (limit \(limit) tokens)."
        case .replacementExceedsUsableContext(let estimated, let limit):
            return "The compacted model history still exceeds the usable context window (estimated \(estimated), limit \(limit) tokens)."
        case .windowNumberExhausted:
            return "The model-history compaction window number is exhausted."
        }
    }
}

/// One genuine user turn retained independently from the model-generated
/// continuation summary. Context bundles, external data, explicit Skill
/// bodies, and older compaction summaries must never be represented by this
/// type.
public struct AgentModelHistoryRealUserMessage: Equatable, Sendable {
    public var content: String
    public var submissionID: SubmissionID?
    public var attachmentIDs: [ArtifactID]?
    public var imageReferences: [ModelHistoryImageReference]?
    public var contentTruncated: Bool

    public init(
        content: String,
        submissionID: SubmissionID? = nil,
        attachmentIDs: [ArtifactID]? = nil,
        imageReferences: [ModelHistoryImageReference]? = nil,
        contentTruncated: Bool = false
    ) {
        self.content = content
        self.submissionID = submissionID
        self.attachmentIDs = attachmentIDs
        self.imageReferences = imageReferences
        self.contentTruncated = contentTruncated
    }
}

public struct AgentModelHistoryCompactionResult: Equatable, Sendable {
    public var message: String
    public var replacementHistory: [ModelHistoryReplacementItem]
    public var providerHistory: [AgentMessage]
    public var checkpointSchemaVersion: Int
    public var usage: Usage?

    public init(
        message: String,
        replacementHistory: [ModelHistoryReplacementItem],
        providerHistory: [AgentMessage],
        checkpointSchemaVersion: Int =
            ModelHistoryCompactedPayload.currentSchemaVersion,
        usage: Usage?
    ) {
        self.message = message
        self.replacementHistory = replacementHistory
        self.providerHistory = providerHistory
        self.checkpointSchemaVersion = checkpointSchemaVersion
        self.usage = usage
    }
}

/// Produces a Codex-style full replacement history. The original durable
/// events remain audit history; callers install this replacement only after a
/// typed checkpoint has committed successfully.
public struct AgentModelHistoryCompactor: Sendable {
    public static let retainedRealUserTokenBudget = 20_000
    static let retainedRealUserTruncationMarker =
        "[Earlier part of this user message omitted]\n"

    private let provider: ToolCallingProvider
    private let model: ModelID
    private let reasoningEffort: ReasoningEffort?
    private let includeUsage: Bool
    private let tokenBudgetMeter: AgentTokenBudgetMeter?

    public init(
        provider: ToolCallingProvider,
        model: ModelID,
        reasoningEffort: ReasoningEffort? = nil,
        includeUsage: Bool = false,
        tokenBudgetMeter: AgentTokenBudgetMeter? = nil
    ) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.includeUsage = includeUsage
        self.tokenBudgetMeter = tokenBudgetMeter
    }

    public func compact(
        history: [AgentMessage],
        realUserMessages: [AgentModelHistoryRealUserMessage],
        mediaAwareCheckpointRequired: Bool = false,
        maximumReplacementInputTokens: Int? = nil
    ) async throws -> AgentModelHistoryCompactionResult {
        try await compactOnce(
            history: history,
            realUserMessages: realUserMessages,
            mediaAwareCheckpointRequired:
                mediaAwareCheckpointRequired,
            maximumReplacementInputTokens:
                maximumReplacementInputTokens)
    }

    private func compactOnce(
        history: [AgentMessage],
        realUserMessages: [AgentModelHistoryRealUserMessage],
        mediaAwareCheckpointRequired: Bool,
        maximumReplacementInputTokens: Int?
    ) async throws -> AgentModelHistoryCompactionResult {
        try Task.checkCancellation()
        let summaryOutputLimit = try Self.summaryOutputTokenLimit(
            maximumReplacementInputTokens:
                maximumReplacementInputTokens)
        var request = AgentRequest(
            model: model,
            messages: history + [.user(Self.compactionPrompt)],
            tools: [],
            reasoningEffort: reasoningEffort,
            includeUsage: includeUsage,
            parallelToolCalls: false)
        let estimatedInput = AgentTokenEstimator.approximateInputTokens(
            messages: request.messages)
        var reservation: AgentTokenBudgetReservation?
        if let tokenBudgetMeter {
            reservation = try await tokenBudgetMeter.reserve(
                estimatedInputTokens: estimatedInput)
        }
        request.maxOutputTokens = [
            reservation?.maxOutputTokens,
            summaryOutputLimit,
        ].compactMap { $0 }.min()
        let effectiveSummaryOutputLimit = request.maxOutputTokens
        // A real replacement-window or explicit Goal token budget is a
        // correctness constraint, so mirror that provider request on the host
        // in case a provider ignores it. With neither constraint, do not
        // invent a summary-output ceiling.
        let maximumSummaryUTF8Bytes = effectiveSummaryOutputLimit.map {
            let (bytes, overflow) = $0.multipliedReportingOverflow(by: 4)
            return overflow ? Int.max : bytes
        }

        var summary = ""
        var summaryUTF8Bytes = 0
        var responseUsage: Usage?
        var completed = false
        var finishReason: String?
        var receivedToolCalls = false

        do {
            for try await chunk in provider.stream(request) {
                try Task.checkCancellation()
                switch chunk {
                case .textDelta(let text):
                    let incomingBytes = text.utf8.count
                    if let maximumSummaryUTF8Bytes,
                       incomingBytes
                        > maximumSummaryUTF8Bytes
                            - summaryUTF8Bytes {
                        throw AgentModelHistoryCompactionError
                            .summaryOutputLimitExceeded(
                                estimated:
                                    effectiveSummaryOutputLimit == Int.max
                                        ? Int.max
                                        : (effectiveSummaryOutputLimit ?? 0) + 1,
                                limit:
                                    effectiveSummaryOutputLimit ?? 0)
                    }
                    summary += text
                    summaryUTF8Bytes += incomingBytes
                    if let effectiveSummaryOutputLimit {
                        let estimatedSummaryTokens =
                            AgentTokenEstimator.approximateTokens(
                                in: summary)
                        guard estimatedSummaryTokens
                            <= effectiveSummaryOutputLimit else {
                            throw AgentModelHistoryCompactionError
                                .summaryOutputLimitExceeded(
                                    estimated:
                                        estimatedSummaryTokens,
                                    limit:
                                        effectiveSummaryOutputLimit)
                        }
                    }
                case .toolCalls(let calls):
                    if !calls.isEmpty {
                        receivedToolCalls = true
                    }
                case .usage(let usage):
                    responseUsage = Usage.merging(
                        responseUsage,
                        with: usage)
                case .done(let reason):
                    completed = true
                    finishReason = reason ?? finishReason
                }
            }
            try Task.checkCancellation()
            let estimatedTotal = Self.estimatedTotalTokens(
                request: request,
                summary: summary)
            let reportedTotal = Self.reportedTotalTokens(responseUsage)
            if let activeReservation = reservation,
               let tokenBudgetMeter {
                reservation = nil
                try await tokenBudgetMeter.settle(
                    activeReservation,
                    reportedTokens: reportedTotal,
                    estimatedTokens: estimatedTotal)
            }
        } catch {
            if let activeReservation = reservation,
               let tokenBudgetMeter {
                reservation = nil
                let estimatedTotal = Self.estimatedTotalTokens(
                    request: request,
                    summary: summary)
                _ = try? await tokenBudgetMeter.settle(
                    activeReservation,
                    reportedTokens: Self.reportedTotalTokens(responseUsage),
                    estimatedTokens: estimatedTotal)
            }
            throw error
        }

        guard completed else {
            throw AgentModelHistoryCompactionError
                .responseEndedWithoutCompletionMarker
        }
        guard !receivedToolCalls else {
            throw AgentModelHistoryCompactionError.responseRequestedToolCalls
        }
        if let finishReason,
           !Self.isSuccessfulFinishReason(finishReason) {
            throw AgentModelHistoryCompactionError
                .incompleteFinishReason(finishReason)
        }

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentModelHistoryCompactionError.emptySummary
        }
        guard !SecretScanner.containsSecret(trimmed) else {
            throw AgentModelHistoryCompactionError.summaryContainsSecret
        }
        let continuationMessage =
            Self.continuationSummaryPrefix + trimmed
        let retainedUsers = try Self.retainedRealUsersFittingReplacement(
            from: realUserMessages,
            summary: continuationMessage,
            maximumReplacementInputTokens:
                maximumReplacementInputTokens)
        var replacement = retainedUsers.map { user in
            ModelHistoryReplacementItem(
                itemID: "model-history-compacted-user:\(UUID().uuidString.lowercased())",
                sourceSubmissionID: user.submissionID,
                kind: .message,
                role: .user,
                messageClassification: .realUser,
                content: user.content,
                contentTruncated:
                    user.contentTruncated ? true : nil)
        }
        replacement.append(ModelHistoryReplacementItem(
            itemID: "model-history-compaction-summary:\(UUID().uuidString.lowercased())",
            kind: .message,
            role: .user,
            messageClassification: .compactionSummary,
            content: continuationMessage))

        return AgentModelHistoryCompactionResult(
            message: continuationMessage,
            replacementHistory: replacement,
            providerHistory:
                retainedUsers.map { .user($0.content) }
                + [.user(continuationMessage)],
            checkpointSchemaVersion:
                mediaAwareCheckpointRequired
                    || history.contains(where: { !$0.images.isEmpty })
                    || realUserMessages.contains(where: {
                        $0.imageReferences?.isEmpty == false
                    })
                    ? ModelHistoryCompactedPayload.mediaSchemaVersion
                    : ModelHistoryCompactedPayload.currentSchemaVersion,
            usage: responseUsage
                ?? Usage(totalTokens: Self.estimatedTotalTokens(
                    request: request,
                    summary: summary)))
    }

    private static let compactionPrompt = """
    Create a concise continuation brief for another model that will resume this work. Preserve the user's goals, binding constraints, concrete decisions, completed work, relevant file or symbol names, validation evidence, unresolved failures, and the exact next actions. Distinguish facts from uncertainty. Never retain or output secrets, credentials, authentication material, or unrelated large tool output. Do not call tools and do not address the user; return only the continuation brief.
    """

    private static let continuationSummaryPrefix = """
    Continuation summary from the earlier model history:

    """

    private static func summaryOutputTokenLimit(
        maximumReplacementInputTokens: Int?
    ) throws -> Int? {
        guard let maximumReplacementInputTokens else {
            return nil
        }
        let fixedSummaryTokens = AgentTokenEstimator
            .approximateInputTokens(messages: [
                .user(continuationSummaryPrefix),
            ])
        let available =
            maximumReplacementInputTokens - fixedSummaryTokens
        guard available > 0 else {
            throw AgentModelHistoryCompactionError
                .replacementBudgetUnavailable(
                    limit: maximumReplacementInputTokens)
        }
        return available
    }

    private static func retainedRealUsersFittingReplacement(
        from messages: [AgentModelHistoryRealUserMessage],
        summary: String,
        maximumReplacementInputTokens: Int?
    ) throws -> [AgentModelHistoryRealUserMessage] {
        guard let maximumReplacementInputTokens else {
            return retainedRealUsers(
                from: messages,
                tokenBudget: retainedRealUserTokenBudget)
        }

        let summaryHistory: [AgentMessage] = [.user(summary)]
        let summaryTokens = AgentTokenEstimator.approximateInputTokens(
            messages: summaryHistory)
        guard summaryTokens <= maximumReplacementInputTokens else {
            throw AgentModelHistoryCompactionError
                .replacementExceedsUsableContext(
                    estimated: summaryTokens,
                    limit: maximumReplacementInputTokens)
        }

        let upperBudget = min(
            retainedRealUserTokenBudget,
            max(0, maximumReplacementInputTokens - summaryTokens))
        func candidate(
            tokenBudget: Int
        ) -> (
            users: [AgentModelHistoryRealUserMessage],
            estimated: Int
        ) {
            let users = retainedRealUsers(
                from: messages,
                tokenBudget: tokenBudget)
            let history =
                users.map { AgentMessage.user($0.content) }
                + summaryHistory
            return (
                users,
                AgentTokenEstimator.approximateInputTokens(
                    messages: history))
        }

        let upper = candidate(tokenBudget: upperBudget)
        if upper.estimated <= maximumReplacementInputTokens {
            return upper.users
        }

        var low = 0
        var high = upperBudget
        var best = candidate(tokenBudget: 0)
        guard best.estimated <= maximumReplacementInputTokens else {
            throw AgentModelHistoryCompactionError
                .replacementExceedsUsableContext(
                    estimated: best.estimated,
                    limit: maximumReplacementInputTokens)
        }
        while low <= high {
            let midpoint = low + (high - low) / 2
            let current = candidate(tokenBudget: midpoint)
            if current.estimated <= maximumReplacementInputTokens {
                best = current
                low = midpoint + 1
            } else {
                high = midpoint - 1
            }
        }
        return best.users
    }

    private static func retainedRealUsers(
        from messages: [AgentModelHistoryRealUserMessage],
        tokenBudget: Int
    ) -> [AgentModelHistoryRealUserMessage] {
        var remaining = max(0, tokenBudget)
        var newestFirst: [AgentModelHistoryRealUserMessage] = []

        for message in messages.reversed() {
            guard remaining > 0 else { break }
            let tokens = AgentTokenEstimator.approximateTokens(
                in: message.content)
            if tokens <= remaining {
                newestFirst.append(message)
                remaining -= tokens
                continue
            }

            let marker = retainedRealUserTruncationMarker
            let markerTokens = AgentTokenEstimator.approximateTokens(in: marker)
            let suffixBudget = max(0, remaining - markerTokens)
            let suffix = AgentTokenEstimator.newestSuffix(
                of: message.content,
                fittingTokenBudget: suffixBudget)
            if !suffix.isEmpty {
                var boundary = message
                boundary.content = marker + suffix
                boundary.contentTruncated = true
                newestFirst.append(boundary)
            }
            break
        }
        return newestFirst.reversed()
    }

    private static func reportedTotalTokens(_ usage: Usage?) -> Int? {
        guard let usage else { return nil }
        if let total = usage.totalTokens {
            return total
        }
        let summed = (usage.promptTokens ?? 0)
            + (usage.completionTokens ?? 0)
        return summed > 0 ? summed : nil
    }

    private static func estimatedTotalTokens(
        request: AgentRequest,
        summary: String
    ) -> Int {
        AgentTokenEstimator.approximateTotalTokens(
            request: request,
            assistantText: summary,
            toolCalls: [])
    }

    private static func isSuccessfulFinishReason(_ reason: String) -> Bool {
        switch reason.lowercased() {
        case "stop", "end_turn", "completed", "complete":
            return true
        default:
            return false
        }
    }
}
