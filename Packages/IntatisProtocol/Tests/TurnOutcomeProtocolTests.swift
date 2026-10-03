import XCTest
import IntatisCore
@testable import IntatisProtocol

final class TurnOutcomeProtocolTests: XCTestCase {
    private let sessionID = SessionID(rawValue: "sess_phase_c")
    private let turnID = TurnID(rawValue: "turn_one")

    func testTypedToolResultRoundTripsAllCorrelationAndOutcomeFields() throws {
        let payload = ToolResultPayload(
            toolCallId: "call_one",
            observation: "User declined this call.",
            truncated: false,
            outcome: .denied,
            failureSource: .userDenied,
            turnID: turnID,
            permissionRequestID: RequestID(rawValue: "req_one"))

        let envelope = Envelope(
            seq: 1,
            ts: Date(timeIntervalSince1970: 1),
            session: sessionID,
            event: .toolResult(payload))
        let data = try Envelope.makeEncoder().encode(envelope)

        XCTAssertEqual(
            try Envelope.makeDecoder().decode(Envelope.self, from: data),
            envelope)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedPayload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(encodedPayload["outcome"] as? String, "denied")
        XCTAssertEqual(encodedPayload["failureSource"] as? String, "user_denied")
        XCTAssertEqual(encodedPayload["turnID"] as? String, "turn_one")
        XCTAssertEqual(encodedPayload["permissionRequestID"] as? String, "req_one")
    }

    func testTurnOutcomeRoundTripsThroughStableEnvelopeTag() throws {
        let payload = TurnOutcomePayload(
            turnID: turnID,
            outcome: .interrupted,
            failureSource: .userCancelled,
            reason: "Turn cancelled by user",
            submissionID: SubmissionID(rawValue: "sub_one"),
            taskID: TaskID(rawValue: "task_one"),
            agentID: AgentID(rawValue: "main"))
        let envelope = Envelope(
            seq: 2,
            ts: Date(timeIntervalSince1970: 2),
            session: sessionID,
            event: .turnOutcome(payload))
        let data = try Envelope.makeEncoder().encode(envelope)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "turn_outcome")
        XCTAssertEqual(
            try Envelope.makeDecoder().decode(Envelope.self, from: data),
            envelope)
    }

    func testEveryFailureSourceHasStableWireValue() throws {
        let expected: [(ExecutionFailureSource, String)] = [
            (.userDenied, "user_denied"),
            (.userCancelled, "user_cancelled"),
            (.turnCancelled, "turn_cancelled"),
            (.policyDenied, "policy_denied"),
            (.reviewerTimedOut, "reviewer_timed_out"),
            (.reviewerFailed, "reviewer_failed"),
            (.sandboxDenied, "sandbox_denied"),
            (.runtimeFailed, "runtime_failed"),
        ]

        for (source, rawValue) in expected {
            let data = try JSONEncoder().encode(source)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(ExecutionFailureSource.self, from: data), source)
        }
    }

    func testLegacyToolResultDecodesWithTypedFieldsAbsent() throws {
        let json = #"{"seq":1,"ts":"2026-07-20T00:00:00Z","session":"sess_legacy","v":1,"type":"tool_result","payload":{"toolCallId":"call_legacy","observation":"ok"}}"#

        let envelope = try Envelope.makeDecoder().decode(Envelope.self, from: Data(json.utf8))
        guard case .toolResult(let payload) = envelope.event else {
            return XCTFail("expected tool_result")
        }

        XCTAssertEqual(payload.toolCallId, "call_legacy")
        XCTAssertEqual(payload.observation, "ok")
        XCTAssertNil(payload.outcome)
        XCTAssertNil(payload.failureSource)
        XCTAssertNil(payload.turnID)
        XCTAssertNil(payload.permissionRequestID)
    }

    func testLegacyPermissionPayloadsDecodeWithoutFailureSource() throws {
        let request = #"{"requestId":"req_legacy","tool":"write_file","args":"{}","risk":"high","reason":"review"}"#
        let resolution = #"{"requestId":"req_legacy","tool":"write_file","decision":"deny","risk":"high","reason":"denied","source":"user"}"#
        let approval = #"{"decision":"deny","reason":"denied","source":"user"}"#

        let permissionRequest = try JSONDecoder().decode(
            PermissionRequestPayload.self,
            from: Data(request.utf8))
        let resolved = try JSONDecoder().decode(
            PermissionResolvedPayload.self,
            from: Data(resolution.utf8))
        let responderResolution = try JSONDecoder().decode(
            PermissionApprovalResolution.self,
            from: Data(approval.utf8))

        XCTAssertNil(permissionRequest.approvalMode)
        XCTAssertEqual(permissionRequest.effectiveApprovalMode, .manual)
        XCTAssertNil(resolved.failureSource)
        XCTAssertNil(resolved.action)
        XCTAssertNil(resolved.turnID)
        XCTAssertNil(resolved.toolCallID)
        XCTAssertNil(responderResolution.failureSource)
        XCTAssertNil(responderResolution.action)
        XCTAssertEqual(responderResolution.effectiveAction, .decline)
    }

    func testExplicitPermissionResponseActionsRoundTripAndLegacyActionIsDerived() throws {
        let rememberResolution =
            PermissionApprovalResolution(
                decision: .allow,
                action: .approveAndRemember,
                reason: "Approve and remember",
                source: .user)
        XCTAssertEqual(
            try JSONDecoder().decode(
                PermissionApprovalResolution.self,
                from: JSONEncoder().encode(
                    rememberResolution)),
            rememberResolution)
        XCTAssertEqual(
            rememberResolution.effectiveAction,
            .approveAndRemember)

        let cancelResolution = PermissionApprovalResolution(
            decision: .deny,
            action: .cancelTurn,
            reason: "Cancel this turn",
            source: .user,
            failureSource: .userCancelled)
        let resolutionData = try JSONEncoder().encode(cancelResolution)
        let decodedResolution = try JSONDecoder().decode(
            PermissionApprovalResolution.self,
            from: resolutionData)
        XCTAssertEqual(decodedResolution, cancelResolution)
        XCTAssertEqual(decodedResolution.effectiveAction, .cancelTurn)

        let durable = PermissionResolvedPayload(
            requestId: RequestID(rawValue: "req_cancel"),
            turnID: turnID,
            toolCallID: "call_cancel",
            tool: "write_file",
            decision: .deny,
            risk: .medium,
            reason: "Cancel this turn",
            source: .user,
            failureSource: .userCancelled,
            action: .cancelTurn)
        XCTAssertEqual(
            try JSONDecoder().decode(
                PermissionResolvedPayload.self,
                from: JSONEncoder().encode(durable)),
            durable)

        let command = Command.permissionRespond(PermissionRespondParams(
            session: sessionID,
            requestId: RequestID(rawValue: "req_cancel"),
            decision: .deny,
            action: .cancelTurn))
        let commandData = try JSONEncoder().encode(command)
        XCTAssertEqual(try JSONDecoder().decode(Command.self, from: commandData), command)

        let legacy = #"{"session":"sess_phase_c","requestId":"req_legacy","decision":"allow"}"#
        let legacyParams = try JSONDecoder().decode(
            PermissionRespondParams.self,
            from: Data(legacy.utf8))
        XCTAssertNil(legacyParams.action)
        XCTAssertEqual(legacyParams.effectiveAction, .approve)
    }

    func testAutomaticReviewerModeRoundTripsWithoutChangingLegacyDefault() throws {
        let payload = PermissionRequestPayload(
            requestId: RequestID(rawValue: "req_automatic"),
            agent: AgentID(rawValue: "main"),
            tool: "write_file",
            args: "{}",
            risk: .medium,
            reason: "Review write",
            approvalMode: .automaticReviewer)

        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["approvalMode"] as? String, "automatic_reviewer")

        let decoded = try JSONDecoder().decode(PermissionRequestPayload.self, from: data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.effectiveApprovalMode, .automaticReviewer)
    }
}
