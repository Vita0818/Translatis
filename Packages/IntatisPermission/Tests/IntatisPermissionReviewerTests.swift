import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
@testable import IntatisPermission

private struct CannedChat: ChatProvider {
    let text: String
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { c in c.yield(.delta(text)); c.yield(.done); c.finish() }
    }
}

private final class CapturingCannedChat: ChatProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [ChatRequest] = []

    var requests: [ChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        captured.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.delta("The bounded write matches the user's request.\nALLOW"))
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

private func reviewCtx(profile: PermissionProfile = .reviewed) -> PermissionContext {
    PermissionContext(workspaceRoot: URL(fileURLWithPath: "/ws"), profile: profile,
                      allowsShell: true, userGoal: "edit a file", agent: AgentID(rawValue: "Coder"))
}

private func writeCall() -> ToolCallContext {
    ToolCallContext(toolName: "write_file", sideEffect: .write, touchedPaths: ["a.swift"],
                    risksNetwork: false, rawArgs: #"{"path":"a.swift","content":"x"}"#)
}

final class IntatisPermissionReviewerTests: XCTestCase {

    func testTextVerdictParserAcceptsReasonAndCaseInsensitiveASCIIMarker() throws {
        let parsed = try XCTUnwrap(PermissionReviewTextVerdictParser.parse(
            "The requested write is scoped to the selected workspace.\naLlOw\n\n"))

        XCTAssertEqual(parsed.decision, .allow)
        XCTAssertEqual(parsed.reason, "The requested write is scoped to the selected workspace.")
    }

    func testTextVerdictParserAcceptsDeny() throws {
        let parsed = try XCTUnwrap(PermissionReviewTextVerdictParser.parse(
            "The action is unrelated to the user's request.\nDENY"))

        XCTAssertEqual(parsed.decision, .deny)
        XCTAssertEqual(parsed.reason, "The action is unrelated to the user's request.")
    }

    func testTextVerdictParserAcceptsLongReasonsWithoutChangingDecision() throws {
        for length in [241, 500, 1_000] {
            let reason = String(repeating: "x", count: length)
            for (marker, expectedDecision) in [
                ("ALLOW", PermissionDecision.allow),
                ("DENY", PermissionDecision.deny),
            ] {
                let parsed = try XCTUnwrap(
                    PermissionReviewTextVerdictParser.parse("\(reason)\n\(marker)"))
                XCTAssertEqual(parsed.decision, expectedDecision)
                XCTAssertEqual(parsed.reason, reason)
            }
        }
    }

    func testTextVerdictParserReturnsSecretFreeStructuralDiagnostics() {
        let cases: [(String, PermissionReviewTextVerdictParseFailure)] = [
            ("reason without a verdict", .missingVerdictMarker),
            ("reason\nALLOW\nDENY", .multipleVerdictMarkers),
            ("reason\nALLOW\ntrailing text", .verdictMarkerNotFinal),
            ("ALLOW", .missingReason),
            (#"{"reason":"structured","decision":"allow"}"#, .structuredOutput),
            ("```text\nreason\nALLOW\n```", .structuredOutput),
        ]

        for (output, expected) in cases {
            XCTAssertEqual(
                PermissionReviewTextVerdictParser.parseResult(output),
                .failure(expected),
                output)
        }
    }

    func testTextVerdictParserRejectsMalformedOutputs() {
        let malformed = [
            "",
            "ALLOW",
            "A reason without a verdict",
            "ALLOW\nA reason after the marker",
            "reason\nALLOW\nDENY",
            "reason\nALLOW.",
            "reason\n ALLOW",
            "reason\n\u{0410}LLOW", // Cyrillic A, not ASCII A.
            #"{"reason":"ok","decision":"allow"}"# + "\nALLOW",
            #"Sure: {"reason":"ok","decision":"allow"}"# + "\nALLOW",
            "```text\nreason\n```\nALLOW",
            "reason with an inline ``` fence\nALLOW",
        ]

        for output in malformed {
            XCTAssertNil(PermissionReviewTextVerdictParser.parse(output), output)
        }
    }

    func testReviewerDoesNotInventSamplingParameters() async throws {
        let provider = CapturingCannedChat()
        let reviewer = ModelPermissionReviewer(
            provider: provider,
            model: ModelID(rawValue: "rev"))

        _ = await reviewer.review(
            writeCall(),
            reviewCtx(),
            gateReason: "write",
            risk: .low)

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertNil(request.temperature)
        let prompt = request.messages.map(\.content).joined(separator: "\n")
        XCTAssertFalse(prompt.contains(#""decision""#))
        XCTAssertTrue(prompt.contains("Do not return JSON"))
        XCTAssertTrue(prompt.contains("final nonempty line"))
        XCTAssertTrue(prompt.contains("ALLOW"))
        XCTAssertTrue(prompt.contains("DENY"))
        XCTAssertTrue(prompt.contains("This length is guidance only"))
        XCTAssertEqual(
            prompt.components(
                separatedBy: PermissionReviewTextVerdictParser.modelOutputContract).count - 1,
            2)
    }

    func testReviewerAcceptsLongReasonButReturnsOnlyBoundedSummary() async {
        let reason = String(repeating: "x", count: 1_000)
        let reviewer = ModelPermissionReviewer(
            provider: CannedChat(text: "\(reason)\nALLOW"),
            model: ModelID(rawValue: "rev"))

        let outcome = await reviewer.review(
            writeCall(),
            reviewCtx(),
            gateReason: "write",
            risk: .low)

        XCTAssertEqual(outcome.decision, .allow)
        XCTAssertTrue(outcome.reason.hasPrefix(String(repeating: "x", count: 240)))
        XCTAssertEqual(outcome.reason.count, 243)
        XCTAssertTrue(outcome.reason.hasSuffix("..."))
    }

    func testReviewerScansCompleteLongReasonForSensitiveMaterialBeforeBounding() async {
        let secret = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let reason = String(repeating: "x", count: 300) + " " + secret
        let reviewer = ModelPermissionReviewer(
            provider: CannedChat(text: "\(reason)\nALLOW"),
            model: ModelID(rawValue: "rev"))

        let outcome = await reviewer.review(
            writeCall(),
            reviewCtx(),
            gateReason: "write",
            risk: .low)

        XCTAssertEqual(outcome.decision, .askUser)
        XCTAssertFalse(outcome.reason.contains(secret))
    }

    func testReviewerParsesAllow() async {
        let r = ModelPermissionReviewer(
            provider: CannedChat(text: "The write is scoped and requested.\nALLOW"),
            model: ModelID(rawValue: "rev"))
        let out = await r.review(writeCall(), reviewCtx(), gateReason: "write", risk: .low)
        XCTAssertEqual(out.decision, .allow)
        XCTAssertEqual(out.reason, "The write is scoped and requested.")
        XCTAssertEqual(out.risk, .low)
    }

    func testReviewerParsesDenyAndKeepsHostRisk() async {
        let r = ModelPermissionReviewer(
            provider: CannedChat(text: "The action is unrelated to the user's request.\nDENY"),
            model: ModelID(rawValue: "rev"))
        let out = await r.review(writeCall(), reviewCtx(), gateReason: "write", risk: .medium)
        XCTAssertEqual(out.decision, .deny)
        XCTAssertEqual(out.reason, "The action is unrelated to the user's request.")
        XCTAssertEqual(out.risk, .medium)
    }

    func testReviewerUnparseableAsksUser() async {
        let r = ModelPermissionReviewer(
            provider: CannedChat(text: "A reason without a final verdict"),
            model: ModelID(rawValue: "rev"))
        let out = await r.review(writeCall(), reviewCtx(), gateReason: "write", risk: .medium)
        XCTAssertEqual(out.decision, .askUser)
        XCTAssertEqual(out.risk, .medium)
    }

    func testReviewerRejectsLegacyJSON() async {
        let r = ModelPermissionReviewer(
            provider: CannedChat(text: #"{"decision":"allow","risk":"low","reason":"ok"}"#),
            model: ModelID(rawValue: "rev"))
        let out = await r.review(writeCall(), reviewCtx(), gateReason: "write", risk: .high)
        XCTAssertEqual(out.decision, .askUser)
        XCTAssertEqual(out.risk, .high)
    }

    func testEngineWriteUsesConfiguredModelReviewer() async {
        let reviewer = ModelPermissionReviewer(
            provider: CannedChat(text: "The write is necessary and bounded.\nALLOW"),
            model: ModelID(rawValue: "rev"))
        let engine = PermissionEngine(reviewer: reviewer)
        let decision = await engine.decideDetailed(
            writeCall(),
            reviewCtx(profile: .reviewed))
        XCTAssertEqual(decision.outcome.decision, .allow)
        XCTAssertEqual(decision.outcome.reason, "The write is necessary and bounded.")
        XCTAssertTrue(decision.reviewerConsulted)
    }

    func testHardDenyNeverReachesReviewer() async {
        // The reviewer would say allow, but a sensitive read is a hard deny at the
        // gate — it returns `deny`, never `pass`, so the reviewer is not consulted.
        let reviewer = ModelPermissionReviewer(provider: CannedChat(text: "Looks safe.\nALLOW"),
                                               model: ModelID(rawValue: "rev"))
        let engine = PermissionEngine(reviewer: reviewer)
        let sensitive = ToolCallContext(toolName: "read_file", sideEffect: .readOnly,
                                        touchedPaths: [".env"], risksNetwork: false, rawArgs: "{}")
        let decision = await engine.decideDetailed(
            sensitive,
            reviewCtx())
        XCTAssertEqual(decision.outcome.decision, .deny)
        XCTAssertFalse(decision.reviewerConsulted)
    }
}
