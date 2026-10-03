import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class PermissionProjectionTests: XCTestCase {
    private let session = SessionID(rawValue: "perm")

    private func env(_ seq: Int, _ event: Event) -> Envelope {
        Envelope(seq: seq, ts: Date(timeIntervalSince1970: Double(seq)), session: session, event: event)
    }

    private func request(_ id: String = "req_1",
                         approvalMode: PermissionApprovalMode? = nil) -> PermissionRequestPayload {
        PermissionRequestPayload(requestId: RequestID(rawValue: id),
                                 agent: AgentID(rawValue: "A"),
                                 tool: "write_file",
                                 args: #"{"path":"a.txt"}"#,
                                 risk: .medium,
                                 reason: "write to workspace",
                                 approvalMode: approvalMode)
    }

    private func authorization() -> ResolvedToolAuthorization {
        let intent = PermissionIntent(
            action: "filesystem.write",
            resources: [PermissionResource(kind: .workspacePath, value: "a.txt", access: .readWrite)],
            dataEffects: [.mutate],
            risks: [.workspaceMutation],
            replayPolicy: .doNotReplay)
        return ResolvedToolAuthorization(
            authorizationID: "authorization_projection",
            registryVersion: "test.v1",
            concreteToolID: "test.v1/write_file",
            descriptorFingerprint: "descriptor",
            toolName: "write_file",
            canonicalAction: intent.action,
            requiredCapabilities: [],
            membership: .notRequired,
            capabilityLeaseID: nil,
            capabilityTaskID: nil,
            workspaceLeaseID: nil,
            workspaceAccess: nil,
            workspaceRootIdentity: nil,
            normalizedArgumentsDigest: "arguments",
            normalizedArgumentsCharacterCount: 16,
            intent: intent,
            sideEffect: .write,
            risksNetwork: false,
            replayPolicy: .doNotReplay)
    }

    private func reviewRequested(_ requestID: String) -> PermissionReviewRequestedPayload {
        PermissionReviewRequestedPayload(task: PermissionReviewTask(
            id: PermissionReviewTaskID(rawValue: "review_\(requestID)"),
            sessionID: session,
            requestID: RequestID(rawValue: requestID),
            requestingAgent: AgentID(rawValue: "A"),
            reviewerAgent: AgentID(rawValue: "permission-reviewer"),
            tool: "write_file",
            normalizedArgs: #"{"path":"a.txt"}"#,
            gate: PermissionReviewGateSnapshot(
                decision: .ask,
                risk: .medium,
                reason: "automatic review required"),
            deadline: Date(timeIntervalSince1970: 60)))
    }

    func testUnresolvedPermissionRequestAppearsPending() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request()))
        ])

        XCTAssertEqual(projection.pending.count, 1)
        XCTAssertEqual(projection.latest?.request.requestId, RequestID(rawValue: "req_1"))
        XCTAssertEqual(projection.latest?.state, .livePending)
        XCTAssertEqual(projection.latest?.state.isActionable, true)
    }

    func testExactDuplicateRequestIsIdempotentAndDoesNotChangeFIFOOrder() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request("req_1"))),
            env(1, .permissionRequest(request("req_2"))),
            env(2, .permissionRequest(request("req_1"))),
        ])

        XCTAssertEqual(projection.pending.map(\.id), [
            RequestID(rawValue: "req_1"),
            RequestID(rawValue: "req_2"),
        ])
        XCTAssertEqual(projection.pending.first?.requestedSeq, 0)
        XCTAssertEqual(projection.latest?.id, RequestID(rawValue: "req_1"))
    }

    func testConflictingDuplicateRequestRetainsFirstPayloadAndFailsClosed() {
        var conflicting = request("req_1")
        conflicting.tool = "network_request"
        conflicting.args = #"{"url":"https://example.invalid"}"#

        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request("req_1"))),
            env(1, .permissionRequest(conflicting)),
        ])

        XCTAssertEqual(projection.pending.count, 1)
        XCTAssertEqual(projection.latest?.request.tool, "write_file")
        XCTAssertEqual(projection.latest?.requestedSeq, 0)
        XCTAssertEqual(projection.latest?.state, .expired)
        XCTAssertEqual(projection.latest?.hasIdentityConflict, true)
        XCTAssertFalse(projection.latest?.state.isActionable == true)
    }

    func testAutomaticReviewMakesGenericRequestNonActionable() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request("req_auto"))),
            env(1, .permissionReviewRequested(reviewRequested("req_auto"))),
        ])

        XCTAssertEqual(projection.latest?.id, RequestID(rawValue: "req_auto"))
        XCTAssertEqual(projection.latest?.state, .resolving)
        XCTAssertFalse(projection.latest?.state.isActionable == true)
    }

    func testAutomaticApprovalModeIsNonActionableBeforeReviewLifecycleStarts() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request(
                "req_auto",
                approvalMode: .automaticReviewer))),
        ])

        XCTAssertEqual(projection.latest?.id, RequestID(rawValue: "req_auto"))
        XCTAssertEqual(projection.latest?.state, .resolving)
        XCTAssertFalse(projection.latest?.state.isActionable == true)
    }

    func testLegacyNilAndExplicitManualDuplicateAreEquivalent() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request("req_manual"))),
            env(1, .permissionRequest(request(
                "req_manual",
                approvalMode: .manual))),
        ])

        XCTAssertEqual(projection.pending.count, 1)
        XCTAssertEqual(projection.latest?.requestedSeq, 0)
        XCTAssertEqual(projection.latest?.state, .livePending)
        XCTAssertEqual(projection.latest?.hasIdentityConflict, false)
        XCTAssertEqual(projection.latest?.state.isActionable, true)
    }

    func testAutomaticReviewSeenBeforeGenericRequestStillFailsClosed() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionReviewRequested(reviewRequested("req_auto"))),
            env(1, .permissionRequest(request("req_auto"))),
        ])

        XCTAssertEqual(projection.latest?.state, .resolving)
        XCTAssertFalse(projection.latest?.state.isActionable == true)
    }

    func testPermissionResolvedRemovesPending() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request())),
            env(1, .permissionResolved(.init(requestId: RequestID(rawValue: "req_1"),
                                             tool: "write_file",
                                             decision: .deny,
                                             risk: .medium,
                                             reason: "user denied")))
        ])

        XCTAssertTrue(projection.pending.isEmpty)
    }

    func testPermissionResolvedRetainsLatestNoticeWithStableID() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request())),
            env(1, .permissionResolved(.init(requestId: RequestID(rawValue: "req_1"),
                                             tool: "write_file",
                                             decision: .allow,
                                             risk: .medium,
                                             reason: "user approved",
                                             source: .automaticReviewer,
                                             reviewTaskID: PermissionReviewTaskID(rawValue: "review_1"),
                                             reviewStatus: .allowed)))
        ])
        let replayed = PermissionProjection.build(from: [
            env(0, .permissionRequest(request())),
            env(1, .permissionResolved(.init(requestId: RequestID(rawValue: "req_1"),
                                             tool: "write_file",
                                             decision: .allow,
                                             risk: .medium,
                                             reason: "user approved",
                                             source: .automaticReviewer,
                                             reviewTaskID: PermissionReviewTaskID(rawValue: "review_1"),
                                             reviewStatus: .allowed)))
        ])

        XCTAssertEqual(projection.latestResolved?.id, "permission:req_1:resolved")
        XCTAssertEqual(projection.latestResolved?.decision, .allow)
        XCTAssertEqual(projection.latestResolved?.source, .automaticReviewer)
        XCTAssertEqual(
            projection.latestResolved?.reviewTaskID,
            PermissionReviewTaskID(rawValue: "review_1"))
        XCTAssertEqual(projection.latestResolved?.reviewStatus, .allowed)
        XCTAssertEqual(projection.latestResolved, replayed.latestResolved)
    }

    func testFirstTerminalResolutionWinsAgainstLateAndConflictingDuplicates() {
        let requestID = RequestID(rawValue: "req_1")
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request())),
            env(1, .permissionResolved(.init(
                requestId: requestID,
                tool: "write_file",
                decision: .allow,
                risk: .medium,
                reason: "first terminal"))),
            env(2, .permissionResolved(.init(
                requestId: requestID,
                tool: "write_file",
                decision: .deny,
                risk: .high,
                reason: "late conflicting terminal"))),
        ])

        XCTAssertTrue(projection.pending.isEmpty)
        XCTAssertEqual(projection.resolved.count, 1)
        XCTAssertEqual(projection.latestResolved?.decision, .allow)
        XCTAssertEqual(projection.latestResolved?.reason, "first terminal")
        XCTAssertEqual(projection.latestResolved?.resolvedSeq, 1)
    }

    func testTerminalResolutionPreventsLateRequestFromReopeningIdentity() {
        let requestID = RequestID(rawValue: "req_1")
        let projection = PermissionProjection.build(from: [
            env(0, .permissionResolved(.init(
                requestId: requestID,
                tool: "write_file",
                decision: .deny,
                risk: .medium,
                reason: "already terminal"))),
            env(1, .permissionRequest(request())),
        ])

        XCTAssertTrue(projection.pending.isEmpty)
        XCTAssertEqual(projection.resolved.count, 1)
    }

    func testResolvingMiddleRequestPreservesRemainingFIFOOrder() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request("req_1"))),
            env(1, .permissionRequest(request("req_2"))),
            env(2, .permissionRequest(request("req_3"))),
            env(3, .permissionResolved(.init(
                requestId: RequestID(rawValue: "req_2"),
                tool: "write_file",
                decision: .deny,
                risk: .medium,
                reason: "remote decline"))),
        ])

        XCTAssertEqual(projection.pending.map(\.id), [
            RequestID(rawValue: "req_1"),
            RequestID(rawValue: "req_3"),
        ])
        XCTAssertEqual(projection.latest?.id, RequestID(rawValue: "req_1"))
    }

    func testPermissionFailureClassificationAndAuthorizationReachProjection() {
        let authorization = authorization()
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request())),
            env(1, .permissionResolved(.init(
                requestId: RequestID(rawValue: "req_1"),
                tool: "write_file",
                decision: .deny,
                risk: .high,
                reason: "review provider failed",
                authorization: authorization,
                source: .automaticReviewerFailure,
                reviewTaskID: PermissionReviewTaskID(rawValue: "review_failure"),
                reviewStatus: .failed,
                failureKind: .providerFailure))),
        ])

        XCTAssertEqual(projection.latestResolved?.risk, .high)
        XCTAssertEqual(projection.latestResolved?.reason, "review provider failed")
        XCTAssertEqual(projection.latestResolved?.authorization, authorization)
        XCTAssertEqual(projection.latestResolved?.source, .automaticReviewerFailure)
        XCTAssertEqual(projection.latestResolved?.reviewStatus, .failed)
        XCTAssertEqual(projection.latestResolved?.failureKind, .providerFailure)
    }

    func testReplayAfterReloadPreservesPendingPermissionState() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-perm-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try EventLog(session: session, fileURL: url)
        try await log.append(.permissionRequest(request()))

        let reloaded = try EventLog(session: session, fileURL: url)
        let projection = PermissionProjection.build(from: await reloaded.replay())

        XCTAssertEqual(projection.pending.count, 1)
        XCTAssertEqual(projection.latest?.request.tool, "write_file")
    }

    func testExpiredPermissionCanBeShownAsNeedsRerun() {
        let projection = PermissionProjection.build(from: [
            env(0, .permissionRequest(request()))
        ], markNeedsRerun: true)

        XCTAssertEqual(projection.latest?.state, .needsRerun)
        XCTAssertEqual(projection.latest?.state.isActionable, false)
        XCTAssertFalse(projection.latest?.request.reason.contains("needs rerun") == true)
    }

    func testResolvingAndExpiredPermissionsAreNotActionable() {
        XCTAssertFalse(PendingPermissionState.resolving.isActionable)
        XCTAssertFalse(PendingPermissionState.approved.isActionable)
        XCTAssertFalse(PendingPermissionState.rejected.isActionable)
        XCTAssertFalse(PendingPermissionState.expired.isActionable)
        XCTAssertFalse(PendingPermissionState.needsRerun.isActionable)
    }
}
