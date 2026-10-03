import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
@testable import IntatisCowork

private final class GoalVerifierTestProvider: ToolCallingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let chunks: [AgentChunk]
    private let delayNanoseconds: UInt64
    private let terminalUsageLimit: ProviderUsageLimitError?
    private var capturedRequests: [AgentRequest] = []

    init(chunks: [AgentChunk],
         delayNanoseconds: UInt64 = 0,
         terminalUsageLimit: ProviderUsageLimitError? = nil) {
        self.chunks = chunks
        self.delayNanoseconds = delayNanoseconds
        self.terminalUsageLimit = terminalUsageLimit
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        capturedRequests.append(request)
        lock.unlock()
        let chunks = chunks
        let delay = delayNanoseconds
        let terminalUsageLimit = terminalUsageLimit
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: delay)
                    }
                    for chunk in chunks {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                    }
                    if let terminalUsageLimit {
                        continuation.finish(throwing: terminalUsageLimit)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: CancellationError())
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}

final class GoalVerifierControlPlaneTests: XCTestCase {
    func testCompleteRequiresAndPreservesAuthoritativeEvidence() async throws {
        let fixture = makeFixture(includeValidationEvidence: true)
        let response = completeResponse(reference: "test://swift/goal-verifier")
        let provider = GoalVerifierTestProvider(chunks: [
            .textDelta(response),
            .usage(Usage(promptTokens: 120, completionTokens: 40, totalTokens: 160)),
            .done(finishReason: "stop"),
        ])
        let verifier = GoalVerifierControlPlane(
            provider: provider,
            model: ModelID(rawValue: "selected-model"))

        let result = await verifier.verify(fixture.input)

        XCTAssertEqual(result.audit.verdict, .complete)
        XCTAssertTrue(result.audit.isCompletionProof)
        XCTAssertEqual(result.audit.requirements.count, 2)
        XCTAssertEqual(result.audit.requirements.flatMap(\.evidence).count, 2)
        XCTAssertEqual(result.usage?.totalTokens, 160)
        XCTAssertNil(result.failureKind)
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.model, ModelID(rawValue: "selected-model"))
        XCTAssertTrue(request.tools.isEmpty)
        XCTAssertNil(request.temperature)
        XCTAssertNil(request.maxOutputTokens)
        XCTAssertEqual(request.messages.map(\.role), [.system, .user])
        XCTAssertTrue(request.messages[0].content?.contains("independent GoalVerifier") == true)
        XCTAssertTrue(request.messages[1].content?.contains("GOAL_SNAPSHOT") == true)
    }

    func testFabricatedEvidenceDowngradesCompletionToContinue() async {
        let fixture = makeFixture(includeValidationEvidence: false)
        let provider = GoalVerifierTestProvider(chunks: [
            .textDelta(completeResponse(reference: "invented://evidence")),
            .done(finishReason: "stop"),
        ])
        let verifier = GoalVerifierControlPlane(
            provider: provider,
            model: ModelID(rawValue: "m"))

        let result = await verifier.verify(fixture.input)

        XCTAssertEqual(result.audit.verdict, .continue)
        XCTAssertEqual(result.failureKind, .hostValidation)
        XCTAssertTrue(result.audit.requirements.allSatisfy { $0.status == .unproven })
        XCTAssertTrue(result.audit.requirements.allSatisfy { $0.evidence.isEmpty })
        XCTAssertTrue(result.audit.remainingWork.contains {
            $0.contains("authoritative evidence") || $0.contains("host-side")
        })
    }

    func testMalformedOutputFailsSafeToContinue() async {
        let fixture = makeFixture(includeValidationEvidence: true)
        let provider = GoalVerifierTestProvider(chunks: [
            .textDelta("```json\n{\"verdict\":\"complete\"}\n```"),
            .done(finishReason: "stop"),
        ])
        let verifier = GoalVerifierControlPlane(
            provider: provider,
            model: ModelID(rawValue: "m"))

        let result = await verifier.verify(fixture.input)

        XCTAssertEqual(result.audit.verdict, .continue)
        XCTAssertEqual(result.failureKind, .malformedOutput)
        XCTAssertFalse(result.audit.requirements.isEmpty)
    }

    func testEmptyRequirementsCannotComplete() async {
        let fixture = makeFixture(includeValidationEvidence: true)
        let provider = GoalVerifierTestProvider(chunks: [
            .textDelta(#"{"verdict":"complete","requirements":[],"progress_made":true,"remaining_work":[],"blocker":null}"#),
            .done(finishReason: "stop"),
        ])
        let verifier = GoalVerifierControlPlane(
            provider: provider,
            model: ModelID(rawValue: "m"))

        let result = await verifier.verify(fixture.input)

        XCTAssertEqual(result.audit.verdict, .continue)
        XCTAssertEqual(result.failureKind, .malformedOutput)
        XCTAssertEqual(result.audit.requirements.map(\.id), ["objective", "success_criterion_1"])
    }

    func testToolCallFailsSafeToContinue() async {
        let fixture = makeFixture(includeValidationEvidence: true)
        let provider = GoalVerifierTestProvider(chunks: [
            .toolCalls([ToolCall(id: "call_1", name: "run_shell", arguments: "{}")]),
            .textDelta(completeResponse(reference: "test://swift/goal-verifier")),
            .done(finishReason: "tool_calls"),
        ])
        let verifier = GoalVerifierControlPlane(
            provider: provider,
            model: ModelID(rawValue: "m"))

        let result = await verifier.verify(fixture.input)

        XCTAssertEqual(result.audit.verdict, .continue)
        XCTAssertEqual(result.failureKind, .toolCall)
    }

    func testMissingCompletionMarkerFailsSafeToContinue() async {
        let fixture = makeFixture(includeValidationEvidence: true)
        let provider = GoalVerifierTestProvider(chunks: [
            .textDelta(completeResponse(reference: "test://swift/goal-verifier")),
        ])
        let verifier = GoalVerifierControlPlane(
            provider: provider,
            model: ModelID(rawValue: "m"))

        let result = await verifier.verify(fixture.input)

        XCTAssertEqual(result.audit.verdict, .continue)
        XCTAssertEqual(result.failureKind, .incompleteResponse)
    }

    func testProviderOutputLimitFinishReasonIsDistinctFromUsageLimit() async {
        let fixture = makeFixture(includeValidationEvidence: true)
        let provider = GoalVerifierTestProvider(chunks: [
            .textDelta("{\"verdict\":"),
            .usage(Usage(totalTokens: 512)),
            .done(finishReason: "length"),
        ])
        let verifier = GoalVerifierControlPlane(
            provider: provider,
            model: ModelID(rawValue: "m"))

        let result = await verifier.verify(fixture.input)

        XCTAssertEqual(result.audit.verdict, .continue)
        XCTAssertEqual(result.failureKind, .outputLimit)
        XCTAssertEqual(result.usage?.totalTokens, 512)
    }

    func testProviderMaxTokensFinishReasonRemainsOutputLimit() async {
        let fixture = makeFixture(includeValidationEvidence: true)
        let provider = GoalVerifierTestProvider(chunks: [
            .textDelta("{\"verdict\":"),
            .done(finishReason: "max_tokens"),
        ])
        let verifier = GoalVerifierControlPlane(
            provider: provider,
            model: ModelID(rawValue: "m"))

        let result = await verifier.verify(fixture.input)

        XCTAssertEqual(result.audit.verdict, .continue)
        XCTAssertEqual(result.failureKind, .outputLimit)
    }

    func testExplicitOutputPolicyIsForwardedWithoutAnArbitraryClamp() async throws {
        let fixture = makeFixture(includeValidationEvidence: true)
        let provider = GoalVerifierTestProvider(chunks: [
            .textDelta(completeResponse(reference: "test://swift/goal-verifier")),
            .done(finishReason: "stop"),
        ])
        let verifier = GoalVerifierControlPlane(
            provider: provider,
            model: ModelID(rawValue: "m"),
            policy: GoalVerifierPolicy(
                maxOutputCharacters: 200_000,
                maxOutputTokens: 20_000))

        _ = await verifier.verify(fixture.input)

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertNil(request.temperature)
        XCTAssertEqual(request.maxOutputTokens, 20_000)
        XCTAssertEqual(
            GoalVerifierPolicy(maxOutputCharacters: 200_000)
                .maxOutputCharacters,
            200_000)
    }

    func testProviderHardUsageLimitIsDistinctFromOutputLimit() async {
        let fixture = makeFixture(includeValidationEvidence: true)
        let provider = GoalVerifierTestProvider(
            chunks: [.usage(Usage(promptTokens: 80, totalTokens: 80))],
            terminalUsageLimit: ProviderUsageLimitError(
                signal: "billing_hard_limit_reached",
                providerMessage: "Account billing hard limit reached."))
        let verifier = GoalVerifierControlPlane(
            provider: provider,
            model: ModelID(rawValue: "m"))

        let result = await verifier.verify(fixture.input)

        XCTAssertEqual(result.audit.verdict, .continue)
        XCTAssertEqual(result.failureKind, .usageLimit)
        XCTAssertEqual(result.usage?.totalTokens, 80)
        XCTAssertTrue(result.reason?.contains("account usage limit") == true)
    }

    func testTimeoutReturnsWithoutWaitingForSlowProviderAndQuarantinesVerifier() async {
        let fixture = makeFixture(includeValidationEvidence: true)
        let provider = GoalVerifierTestProvider(
            chunks: [
                .textDelta(completeResponse(reference: "test://swift/goal-verifier")),
                .done(finishReason: "stop"),
            ],
            delayNanoseconds: 2_000_000_000)
        let verifier = GoalVerifierControlPlane(
            provider: provider,
            model: ModelID(rawValue: "m"),
            policy: GoalVerifierPolicy(timeoutSeconds: 0.02))

        let started = Date()
        let first = await verifier.verify(fixture.input)
        let elapsed = Date().timeIntervalSince(started)
        let second = await verifier.verify(fixture.input)

        XCTAssertLessThan(elapsed, 1)
        XCTAssertEqual(first.audit.verdict, .continue)
        XCTAssertEqual(first.failureKind, .timeout)
        XCTAssertEqual(second.failureKind, .previousCallStillStopping)
        guard case .degraded = await verifier.health() else {
            return XCTFail("expected degraded verifier health")
        }
    }

    func testCallerCancellationFailsSafeToContinue() async {
        let fixture = makeFixture(includeValidationEvidence: true)
        let provider = GoalVerifierTestProvider(
            chunks: [.done(finishReason: "stop")],
            delayNanoseconds: 2_000_000_000)
        let verifier = GoalVerifierControlPlane(
            provider: provider,
            model: ModelID(rawValue: "m"),
            policy: GoalVerifierPolicy(timeoutSeconds: 10))
        let operation = Task { await verifier.verify(fixture.input) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        operation.cancel()

        let result = await operation.value

        XCTAssertEqual(result.audit.verdict, .continue)
        XCTAssertEqual(result.failureKind, .cancelled)
    }

    private struct Fixture {
        var input: GoalVerificationInput
    }

    private func makeFixture(includeValidationEvidence: Bool) -> Fixture {
        let session = SessionID(rawValue: "goal-verifier-session")
        let goalID = GoalID(rawValue: "goal-verifier")
        let runID = ContinuationRunID(rawValue: "run-verifier")
        let evidence = TaskEvidence(
            kind: "test",
            reference: "test://swift/goal-verifier",
            summary: "Focused Goal verifier tests passed.")
        let goal = Goal(
            id: goalID,
            sessionID: session,
            objective: "Build Goal verification",
            successCriteria: ["Focused verification tests pass"])
        let run = ContinuationRun(
            id: runID,
            sessionID: session,
            goalID: goalID,
            ordinal: 1,
            status: .checkpointed)
        return Fixture(input: GoalVerificationInput(
            goal: goal,
            run: run,
            runHistory: ["Run 1 implemented the verifier."],
            validationEvidence: includeValidationEvidence ? [evidence] : []))
    }

    private func completeResponse(reference: String) -> String {
        """
        {"verdict":"complete","requirements":[{"id":"objective","text":"Build Goal verification","status":"proven","evidence":[{"kind":"test","reference":"\(reference)","summary":"Implementation is covered."}],"gap":null},{"id":"success_criterion_1","text":"Focused verification tests pass","status":"proven","evidence":[{"kind":"test","reference":"\(reference)","summary":"Tests passed."}],"gap":null}],"progress_made":true,"remaining_work":[],"blocker":null}
        """
    }
}
