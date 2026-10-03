import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
@testable import IntatisAgentKernel

private enum CompactorProviderStep {
    case chunks([AgentChunk])
    case contextWindowExceeded
    case cancelled
}

private final class CompactorScriptedProvider:
    ToolCallingProvider, @unchecked Sendable
{
    private let lock = NSLock()
    private var steps: [CompactorProviderStep]
    private var requestStorage: [AgentRequest] = []

    init(_ steps: [CompactorProviderStep]) {
        self.steps = steps
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    func stream(
        _ request: AgentRequest
    ) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        requestStorage.append(request)
        let step = steps.isEmpty
            ? .chunks([
                .textDelta("fallback summary"),
                .done(finishReason: "stop"),
            ])
            : steps.removeFirst()
        lock.unlock()

        return AsyncThrowingStream { continuation in
            switch step {
            case .chunks(let chunks):
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            case .contextWindowExceeded:
                continuation.finish(throwing:
                    ProviderContextWindowExceededError(
                        signal: "context_length_exceeded",
                        providerMessage: "input is too large",
                        statusCode: 400,
                        operation: "test compaction"))
            case .cancelled:
                continuation.finish(throwing: CancellationError())
            }
        }
    }
}

final class AgentModelHistoryCompactorTests: XCTestCase {
    private let model = ModelID(rawValue: "test-compaction-model")

    func testOnlyRealUsersEnterReplacementWhileAllHistoryParticipatesInSummary()
        async throws
    {
        let call = ToolCall(
            id: "tool-call-1",
            name: "activate_skill",
            arguments: #"{"name":"large-skill"}"#)
        let history: [AgentMessage] = [
            .developer("contextual skill body"),
            .user("the genuine user request"),
            .assistant(toolCalls: [call], content: "checking the skill"),
            .tool(id: call.id, content: "large historical skill instructions"),
        ]
        let submissionID = SubmissionID(rawValue: "submission-real-user")
        let attachmentID = ArtifactID(rawValue: "artifact-real-user")
        let provider = CompactorScriptedProvider([.chunks([
            .textDelta("Preserve the requested implementation and its constraints."),
            .done(finishReason: "stop"),
        ])])

        let result = try await makeCompactor(provider).compact(
            history: history,
            realUserMessages: [
                AgentModelHistoryRealUserMessage(
                    content: "the genuine user request",
                    submissionID: submissionID,
                    attachmentIDs: [attachmentID]),
            ])

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(Array(request.messages.dropLast()), history)
        XCTAssertEqual(request.messages.last?.role, .user)
        XCTAssertFalse(request.messages.last?.content?.isEmpty ?? true)
        XCTAssertEqual(request.tools, [])
        XCTAssertEqual(request.parallelToolCalls, false)

        XCTAssertEqual(result.replacementHistory.count, 2)
        let retainedUser = result.replacementHistory[0]
        XCTAssertEqual(retainedUser.kind, .message)
        XCTAssertEqual(retainedUser.role, .user)
        XCTAssertEqual(retainedUser.messageClassification, .realUser)
        XCTAssertEqual(retainedUser.content, "the genuine user request")
        XCTAssertEqual(retainedUser.sourceSubmissionID, submissionID)
        XCTAssertNil(retainedUser.attachmentIDs)
        XCTAssertNil(retainedUser.imageReferences)
        XCTAssertNil(retainedUser.contentTruncated)

        let summary = try XCTUnwrap(result.replacementHistory.last)
        XCTAssertEqual(summary.kind, .message)
        XCTAssertEqual(summary.role, .user)
        XCTAssertEqual(summary.messageClassification, .compactionSummary)
        XCTAssertEqual(summary.content, result.message)
        XCTAssertTrue(
            result.message.contains(
                "Preserve the requested implementation and its constraints."))

        XCTAssertEqual(
            result.replacementHistory.compactMap(\.content),
            ["the genuine user request", result.message])
        XCTAssertFalse(
            result.replacementHistory.compactMap(\.content)
                .contains("contextual skill body"))
        XCTAssertFalse(
            result.replacementHistory.compactMap(\.content)
                .contains("large historical skill instructions"))
        XCTAssertEqual(
            result.providerHistory,
            [.user("the genuine user request"), .user(result.message)])
    }

    func testCompactionSummarizesActiveImageButReplacementDropsOldMedia()
        async throws
    {
        let image = ImageAttachment(
            url: "data:image/png;base64,QUJD")
        let reference = ModelHistoryImageReference(
            artifactID: ArtifactID(rawValue: "artifact-active-image"),
            mimeType: "image/png",
            byteCount: 3,
            sha256: String(repeating: "c", count: 64))
        let provider = CompactorScriptedProvider([.chunks([
            .textDelta("The image was inspected and its relevant result was preserved."),
            .done(finishReason: "stop"),
        ])])

        let result = try await makeCompactor(provider).compact(
            history: [.user("inspect", images: [image])],
            realUserMessages: [
                AgentModelHistoryRealUserMessage(
                    content: "inspect",
                    submissionID: SubmissionID(rawValue: "sub-active-image"),
                    attachmentIDs: [reference.artifactID],
                    imageReferences: [reference]),
            ])

        XCTAssertEqual(
            provider.requests.first?.messages.first?.images,
            [image])
        XCTAssertEqual(
            result.checkpointSchemaVersion,
            ModelHistoryCompactedPayload.mediaSchemaVersion)
        XCTAssertTrue(result.replacementHistory.allSatisfy {
            $0.attachmentIDs == nil && $0.imageReferences == nil
        })

        let checkpoint = ModelHistoryCompactedPayload(
            schemaVersion: result.checkpointSchemaVersion,
            agent: AgentID(rawValue: "main"),
            message: result.message,
            replacementHistory: result.replacementHistory,
            windowNumber: 1,
            firstWindowID: "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d111",
            previousWindowID: "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d111",
            windowID: "018f47a0-7b1c-7cc0-8e5f-7f0a3c91d222")
        let projection = try AgentModelHistoryProjector()
            .projectReplacementState(checkpoint)
        XCTAssertEqual(projection.messages.count, projection.imageBindings.count)
        XCTAssertTrue(projection.imageBindings.allSatisfy { $0 == nil })

        let inheritedProvider = CompactorScriptedProvider([.chunks([
            .textDelta("new text-only summary"),
            .done(finishReason: "stop"),
        ])])
        let inherited = try await makeCompactor(inheritedProvider).compact(
            history: [.user("new text-only turn")],
            realUserMessages: [],
            mediaAwareCheckpointRequired: true)
        XCTAssertEqual(
            inherited.checkpointSchemaVersion,
            ModelHistoryCompactedPayload.mediaSchemaVersion)
    }

    func testTokenEstimatorChargesFixedCostPerImage() {
        let plain = AgentTokenEstimator.approximateInputTokens(
            messages: [.user("inspect")])
        let withTwoImages = AgentTokenEstimator.approximateInputTokens(
            messages: [.user(
                "inspect",
                images: [
                    ImageAttachment(url: "data:image/png;base64,QQ=="),
                    ImageAttachment(url: "data:image/jpeg;base64,Qg=="),
                ])])

        XCTAssertEqual(
            withTwoImages - plain,
            2 * AgentTokenEstimator.imageTokenCost)
    }

    func testRetainsNewestRealUsersWithinTwentyThousandTokensAndTruncatesUTF8Boundary()
        async throws
    {
        let newest = String(repeating: "n", count: 79_600)
        let boundary = "discard-this-prefix:"
            + String(repeating: "汉🙂", count: 500)
        let dropped = "this oldest message must be omitted"
        let provider = CompactorScriptedProvider([.chunks([
            .textDelta("unicode-safe continuation"),
            .done(finishReason: "stop"),
        ])])

        let result = try await makeCompactor(provider).compact(
            history: [
                .user(dropped),
                .user(boundary),
                .user(newest),
            ],
            realUserMessages: [
                AgentModelHistoryRealUserMessage(
                    content: dropped,
                    submissionID: SubmissionID(rawValue: "submission-dropped")),
                AgentModelHistoryRealUserMessage(
                    content: boundary,
                    submissionID: SubmissionID(rawValue: "submission-boundary")),
                AgentModelHistoryRealUserMessage(
                    content: newest,
                    submissionID: SubmissionID(rawValue: "submission-newest")),
            ])

        XCTAssertEqual(result.replacementHistory.count, 3)
        let truncated = result.replacementHistory[0]
        let retainedNewest = result.replacementHistory[1]
        let summary = result.replacementHistory[2]

        XCTAssertEqual(
            truncated.sourceSubmissionID,
            SubmissionID(rawValue: "submission-boundary"))
        XCTAssertEqual(truncated.contentTruncated, true)
        let marker =
            AgentModelHistoryCompactor.retainedRealUserTruncationMarker
        let truncatedContent = try XCTUnwrap(truncated.content)
        XCTAssertTrue(truncatedContent.hasPrefix(marker))
        let suffix = String(truncatedContent.dropFirst(marker.count))
        XCTAssertFalse(suffix.isEmpty)
        XCTAssertTrue(boundary.hasSuffix(suffix))
        XCTAssertFalse(suffix.contains("\u{FFFD}"))

        let newestTokens = approximateTokens(newest)
        let markerTokens = approximateTokens(marker)
        let maximumSuffixBytes =
            (AgentModelHistoryCompactor.retainedRealUserTokenBudget
                - newestTokens - markerTokens) * 4
        XCTAssertLessThanOrEqual(suffix.utf8.count, maximumSuffixBytes)
        // This fixture deliberately puts the byte cut inside a multi-byte
        // scalar. A safe cut advances to the next scalar boundary.
        XCTAssertLessThan(suffix.utf8.count, maximumSuffixBytes)

        XCTAssertEqual(
            retainedNewest.sourceSubmissionID,
            SubmissionID(rawValue: "submission-newest"))
        XCTAssertEqual(retainedNewest.content, newest)
        XCTAssertNil(retainedNewest.contentTruncated)
        XCTAssertFalse(
            result.replacementHistory.compactMap(\.content).contains(dropped))
        XCTAssertEqual(summary.messageClassification, .compactionSummary)
        XCTAssertEqual(summary.content, result.message)
    }

    func testMalformedOrIncompleteResponsesFailWithTypedErrors() async throws {
        let toolCall = ToolCall(
            id: "unexpected-call",
            name: "unexpected_tool",
            arguments: "{}")
        let fixtures:
            [(String, [AgentChunk], AgentModelHistoryCompactionError)] = [
                (
                    "missing done",
                    [.textDelta("partial")],
                    .responseEndedWithoutCompletionMarker
                ),
                (
                    "tool call",
                    [
                        .toolCalls([toolCall]),
                        .done(finishReason: "stop"),
                    ],
                    .responseRequestedToolCalls
                ),
                (
                    "length",
                    [
                        .textDelta("truncated"),
                        .done(finishReason: "length"),
                    ],
                    .incompleteFinishReason("length")
                ),
                (
                    "empty",
                    [
                        .textDelta(" \n\t "),
                        .done(finishReason: "stop"),
                    ],
                    .emptySummary
                ),
            ]

        for (label, chunks, expected) in fixtures {
            let provider = CompactorScriptedProvider([.chunks(chunks)])
            do {
                _ = try await makeCompactor(provider).compact(
                    history: [.user("history")],
                    realUserMessages: [
                        AgentModelHistoryRealUserMessage(content: "history"),
                    ])
                XCTFail("\(label) should fail closed")
            } catch let error as AgentModelHistoryCompactionError {
                XCTAssertEqual(error, expected, label)
            } catch {
                XCTFail("\(label) returned unexpected error: \(error)")
            }
        }
    }

    func testSecretBearingSummaryFailsBeforeReplacement() async throws {
        let provider = CompactorScriptedProvider([.chunks([
            .textDelta("continuation accidentally retained ghp_example123456"),
            .done(finishReason: "stop"),
        ])])

        do {
            _ = try await makeCompactor(provider).compact(
                history: [.user("history")],
                realUserMessages: [
                    AgentModelHistoryRealUserMessage(content: "history"),
                ])
            XCTFail("secret-like summary material must fail closed")
        } catch let error as AgentModelHistoryCompactionError {
            XCTAssertEqual(error, .summaryContainsSecret)
            XCTAssertFalse(
                error.localizedDescription.contains("ghp_"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCancellationRemainsCancellationError() async throws {
        let provider = CompactorScriptedProvider([.cancelled])

        do {
            _ = try await makeCompactor(provider).compact(
                history: [.user("history")],
                realUserMessages: [
                    AgentModelHistoryRealUserMessage(content: "history"),
                ])
            XCTFail("Cancellation must not be translated into a compaction error.")
        } catch is CancellationError {
            // Expected typed cancellation.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    func testContextOverflowFailsWithoutClippingUnsummarizedHistory()
        async throws
    {
        let history: [AgentMessage] = [
            .system("trusted system"),
            .assistant(toolCalls: [ToolCall(
                id: "call-that-must-remain",
                name: "read_tool",
                arguments: "{}")]),
            .tool(
                id: "call-that-must-remain",
                content: "evidence that must be summarized"),
            .user("latest request"),
        ]
        let provider = CompactorScriptedProvider([
            .contextWindowExceeded,
            .chunks([
                .textDelta("must never summarize a clipped window"),
                .done(finishReason: "stop"),
            ]),
        ])

        do {
            _ = try await makeCompactor(provider).compact(
                history: history,
                realUserMessages: [
                    AgentModelHistoryRealUserMessage(
                        content: "latest request"),
                ])
            XCTFail("compaction must fail instead of hiding unsummarized history")
        } catch let error as ProviderContextWindowExceededError {
            XCTAssertEqual(error.signal, "context_length_exceeded")
            XCTAssertEqual(error.statusCode, 400)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(
            Array(try XCTUnwrap(provider.requests.first).messages.dropLast()),
            history)
    }

    func testReplacementFitsExplicitUsableWindowAndBoundsSummaryOutput()
        async throws
    {
        let provider = CompactorScriptedProvider([.chunks([
            .textDelta(String(repeating: "summary-", count: 40)),
            .done(finishReason: "stop"),
        ])])
        let usableLimit = 180

        let result = try await makeCompactor(provider).compact(
            history: [
                .user(String(repeating: "old-history-", count: 500)),
            ],
            realUserMessages: [
                AgentModelHistoryRealUserMessage(
                    content: String(
                        repeating: "retained-user-",
                        count: 500),
                    submissionID:
                        SubmissionID(rawValue: "bounded-user")),
            ],
            maximumReplacementInputTokens: usableLimit)

        XCTAssertLessThanOrEqual(
            AgentTokenEstimator.approximateInputTokens(
                messages: result.providerHistory),
            usableLimit)
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertNotNil(request.maxOutputTokens)
        XCTAssertLessThanOrEqual(
            request.maxOutputTokens ?? .max,
            usableLimit)
        XCTAssertLessThan(
            result.replacementHistory
                .first(where: {
                    $0.messageClassification == .realUser
                })?
                .content?
                .utf8.count
                ?? 0,
            String(repeating: "retained-user-", count: 500)
                .utf8.count)
    }

    func testProviderIgnoringDerivedReplacementWindowCeilingFailsClosed()
        async throws
    {
        let provider = CompactorScriptedProvider([.chunks([
            .textDelta(String(
                repeating: "oversized-summary-",
                count: 1_200)),
            .done(finishReason: "stop"),
        ])])

        do {
            _ = try await makeCompactor(provider).compact(
                history: [.user("history")],
                realUserMessages: [],
                maximumReplacementInputTokens: 100)
            XCTFail("an oversized provider response must fail closed")
        } catch let error as AgentModelHistoryCompactionError {
            guard case .summaryOutputLimitExceeded(
                let estimated,
                let limit) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertGreaterThan(estimated, limit)
            XCTAssertLessThan(limit, 100)
        }
    }

    func testUnconstrainedCompactionDoesNotInventProviderOutputCeiling()
        async throws
    {
        let provider = CompactorScriptedProvider([.chunks([
            .textDelta("unconstrained summary"),
            .done(finishReason: "stop"),
        ])])

        _ = try await makeCompactor(provider).compact(
            history: [.user("history")],
            realUserMessages: [])

        XCTAssertNil(try XCTUnwrap(provider.requests.first).maxOutputTokens)
    }

    func testReportedUsageSettlesSharedTokenBudgetAndSetsOutputCeiling()
        async throws
    {
        let meter = AgentTokenBudgetMeter(
            limit: 10_000,
            preferredOutputTokensPerRequest: 512)
        let provider = CompactorScriptedProvider([.chunks([
            .textDelta("budgeted summary"),
            .usage(Usage(
                promptTokens: 13,
                completionTokens: 4,
                totalTokens: 17)),
            .done(finishReason: "stop"),
        ])])
        let compactor = AgentModelHistoryCompactor(
            provider: provider,
            model: model,
            includeUsage: true,
            tokenBudgetMeter: meter)

        let result = try await compactor.compact(
            history: [.user("history for budget accounting")],
            realUserMessages: [
                AgentModelHistoryRealUserMessage(
                    content: "history for budget accounting"),
            ])

        XCTAssertEqual(result.usage?.promptTokens, 13)
        XCTAssertEqual(result.usage?.completionTokens, 4)
        XCTAssertEqual(result.usage?.totalTokens, 17)
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertTrue(request.includeUsage)
        XCTAssertNotNil(request.maxOutputTokens)
        XCTAssertLessThanOrEqual(request.maxOutputTokens ?? .max, 512)

        let snapshot = await meter.snapshot()
        XCTAssertEqual(snapshot.limit, 10_000)
        XCTAssertEqual(snapshot.consumed, 17)
        XCTAssertEqual(snapshot.reserved, 0)
        XCTAssertEqual(snapshot.remaining, 9_983)
    }

    private func makeCompactor(
        _ provider: ToolCallingProvider
    ) -> AgentModelHistoryCompactor {
        AgentModelHistoryCompactor(
            provider: provider,
            model: model)
    }

    private func approximateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, (text.utf8.count + 3) / 4)
    }
}
