import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisConversation

final class PermissionSettlementTransactionTests: XCTestCase {
    private func makeLogPair(
        session: String = "permission-settlement"
    ) throws -> (EventLog, EventLog, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-permission-settlement-\(UUID().uuidString)",
                                    isDirectory: true)
        let fileURL = directory.appendingPathComponent("events.jsonl")
        let sessionID = SessionID(rawValue: session)
        return (
            try EventLog(session: sessionID, fileURL: fileURL),
            try EventLog(session: sessionID, fileURL: fileURL),
            directory)
    }

    private func request(_ id: String = "req_1") -> PermissionRequestPayload {
        PermissionRequestPayload(
            requestId: RequestID(rawValue: id),
            agent: AgentID(rawValue: "main"),
            tool: "write_file",
            args: "{}",
            risk: .medium,
            reason: "write requires approval")
    }

    private func resolution(
        _ decision: PermissionDecision,
        id: String = "req_1"
    ) -> PermissionResolvedPayload {
        PermissionResolvedPayload(
            requestId: RequestID(rawValue: id),
            tool: "write_file",
            decision: decision,
            risk: .medium,
            reason: decision == .allow ? "approved" : "declined",
            source: .user)
    }

    func testConcurrentExactSettlementIsIdempotentAcrossEventLogInstances() async throws {
        let (first, second, directory) = try makeLogPair()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await first.append(.permissionRequest(request()))
        let terminal = resolution(.deny)

        async let firstResult = first.settlePermissionRequest(terminal)
        async let secondResult = second.settlePermissionRequest(terminal)
        let (left, right) = try await (firstResult, secondResult)
        let results = [left, right]

        XCTAssertEqual(results.filter(\.didAppend).count, 1)
        XCTAssertEqual(Set(results.map(\.envelope.seq)).count, 1)
        let replayed = try await first.replayChecked()
        XCTAssertEqual(replayed.compactMap { envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = envelope.event else { return nil }
            return payload
        }, [terminal])
    }

    func testConflictingSecondSettlementFailsClosedWithoutAppending() async throws {
        let (first, second, directory) = try makeLogPair()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await first.append(.permissionRequest(request()))
        _ = try await first.settlePermissionRequest(resolution(.deny))

        do {
            _ = try await second.settlePermissionRequest(resolution(.allow))
            XCTFail("a conflicting terminal response must not append")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .conflictingPermissionSettlement)
        }

        let replayed = try await second.replayChecked()
        XCTAssertEqual(replayed.filter {
            if case .permissionResolved = $0.event { return true }
            return false
        }.count, 1)
    }

    func testSettlementRequiresDurablyRegisteredRequest() async throws {
        let (first, _, directory) = try makeLogPair()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await first.settlePermissionRequest(resolution(.deny))
            XCTFail("an orphan response must fail closed")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .permissionRequestNotFound)
        }
        let replayed = try await first.replayChecked()
        XCTAssertTrue(replayed.isEmpty)
    }

    func testSettlementRejectsMismatchedCallIdentityAndActionDecision() async throws {
        let (first, _, directory) = try makeLogPair()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turnID = TurnID(rawValue: "turn_exact")
        var registered = request()
        registered.context = PermissionRequestContext(
            turnID: turnID,
            toolCallID: "call_exact")
        _ = try await first.registerPermissionRequest(registered)

        var wrongCall = resolution(.deny)
        wrongCall.turnID = turnID
        wrongCall.toolCallID = "call_other"
        do {
            _ = try await first.settlePermissionRequest(wrongCall)
            XCTFail("mismatched call identity must fail closed")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .conflictingPermissionSettlement)
        }

        var inconsistent = resolution(.deny)
        inconsistent.turnID = turnID
        inconsistent.toolCallID = "call_exact"
        inconsistent.action = .approve
        do {
            _ = try await first.settlePermissionRequest(inconsistent)
            XCTFail("approve action cannot settle a deny decision")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .conflictingPermissionSettlement)
        }

        let replayed = try await first.replayChecked()
        XCTAssertEqual(replayed.filter { envelope in
            if case .permissionResolved = envelope.event { return true }
            return false
        }.count, 0)
    }

    func testRequestRegistrationIsFirstWriteAndExactReplayIsIdempotent() async throws {
        let (first, second, directory) = try makeLogPair()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = request()

        async let left = first.registerPermissionRequest(payload)
        async let right = second.registerPermissionRequest(payload)
        let (leftResult, rightResult) = try await (left, right)
        let results = [leftResult, rightResult]

        XCTAssertEqual(results.filter(\.didAppend).count, 1)
        let replayed = try await first.replayChecked()
        XCTAssertEqual(replayed.filter {
            if case .permissionRequest = $0.event { return true }
            return false
        }.count, 1)
    }

    func testRequestRegistrationRejectsConflictingPayload() async throws {
        let (first, second, directory) = try makeLogPair()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await first.registerPermissionRequest(request())
        var conflict = request()
        conflict.reason = "different immutable payload"

        do {
            _ = try await second.registerPermissionRequest(conflict)
            XCTFail("a reused RequestID with different payload must fail closed")
        } catch let error as EventLogError {
            XCTAssertEqual(error, .conflictingPermissionRequest)
        }
    }

    func testOrdinaryApproveNeverCreatesRememberedMCPApproval()
        async throws
    {
        let (log, _, directory) = try makeLogPair(
            session: "ordinary-approve")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authorization = mcpAuthorization(
            mode: .auto,
            sideEffect: .readOnly)
        var pending = request()
        pending.tool = authorization.toolName
        pending.context = PermissionRequestContext(
            authorization: authorization)
        _ = try await log.registerPermissionRequest(
            pending)
        _ = try await log.settlePermissionRequest(
            PermissionResolvedPayload(
                requestId: pending.requestId,
                tool: authorization.toolName,
                decision: .allow,
                risk: .low,
                reason: "approve once",
                authorization: authorization,
                source: .user,
                action: .approve))

        let replay = try await log.replayChecked()
        XCTAssertFalse(replay.contains {
            if case .mcpRememberedApprovalGranted =
                    $0.event {
                return true
            }
            return false
        })
    }

    func testExplicitAutoReadOnlyApproveAndRememberCreatesExactApproval()
        async throws
    {
        let (log, _, directory) = try makeLogPair(
            session: "explicit-remember")
        defer { try? FileManager.default.removeItem(at: directory) }
        let authorization = mcpAuthorization(
            mode: .auto,
            sideEffect: .readOnly)
        var pending = request()
        pending.tool = authorization.toolName
        pending.context = PermissionRequestContext(
            authorization: authorization)
        _ = try await log.registerPermissionRequest(
            pending)
        _ = try await log.settlePermissionRequest(
            PermissionResolvedPayload(
                requestId: pending.requestId,
                tool: authorization.toolName,
                decision: .allow,
                risk: .low,
                reason: "explicitly remember",
                authorization: authorization,
                source: .user,
                action: .approveAndRemember))

        let replay = try await log.replayChecked()
        let remembered = replay.compactMap {
            envelope -> MCPRememberedToolApproval? in
            guard case .mcpRememberedApprovalGranted(
                let payload) = envelope.event else {
                return nil
            }
            return payload.approval
        }
        XCTAssertEqual(remembered.count, 1)
        XCTAssertTrue(try XCTUnwrap(remembered.first)
            .exactlyMatches(
                try XCTUnwrap(
                    authorization.mcp)))
    }

    func testRememberActionRejectsNonAutoOrNonReadOnlyAuthority()
        async throws
    {
        for (index, fixture) in [
            (MCPApprovalMode.prompt, SideEffect.readOnly),
            (MCPApprovalMode.auto, SideEffect.destructive),
        ].enumerated() {
            let (log, _, directory) = try makeLogPair(
                session: "invalid-remember-\(index)")
            defer {
                try? FileManager.default.removeItem(
                    at: directory)
            }
            let authorization = mcpAuthorization(
                mode: fixture.0,
                sideEffect: fixture.1)
            var pending = request()
            pending.tool = authorization.toolName
            pending.context = PermissionRequestContext(
                authorization: authorization)
            _ = try await log.registerPermissionRequest(
                pending)
            do {
                _ = try await log
                    .settlePermissionRequest(
                        PermissionResolvedPayload(
                            requestId:
                                pending.requestId,
                            tool:
                                authorization
                                    .toolName,
                            decision: .allow,
                            risk: .medium,
                            reason:
                                "invalid remember",
                            authorization:
                                authorization,
                            source: .user,
                            action:
                                .approveAndRemember))
                XCTFail(
                    "ineligible remember action must fail closed")
            } catch let error as EventLogError {
                XCTAssertEqual(
                    error,
                    .conflictingPermissionSettlement)
            }
            let replay = try await log.replayChecked()
            XCTAssertFalse(replay.contains {
                if case .permissionResolved = $0.event {
                    return true
                }
                return false
            })
        }
    }

    private func mcpAuthorization(
        mode: MCPApprovalMode,
        sideEffect: SideEffect
    ) -> ResolvedToolAuthorization {
        let mcp = MCPToolAuthorizationSnapshot(
            server: MCPServerReference(
                serverID:
                    MCPServerID(
                        rawValue: "server-fixture"),
                serverRevision:
                    MCPServerRevision(
                        rawValue: "revision-fixture")),
            attachmentID:
                MCPAttachmentID(
                    rawValue: "attachment-fixture"),
            grantID:
                MCPGrantID(
                    rawValue: "grant-fixture"),
            grantFingerprint: "grant-fingerprint",
            connectionGeneration:
                MCPConnectionGeneration(
                    rawValue: "generation-fixture"),
            rawCatalogRevision:
                MCPRawCatalogRevision(
                    rawValue: "catalog-fixture"),
            agentCatalogViewRevision:
                MCPAgentCatalogViewRevision(
                    rawValue: "view-fixture"),
            bindingID:
                MCPBindingID(
                    rawValue: "binding-fixture"),
            remoteToolName: "lookup",
            schemaHash: "schema-fingerprint",
            protocolProfile: .codexCompat,
            negotiatedProtocolVersion:
                MCPNegotiatedProtocolVersion(
                    .v2025_06_18),
            effectiveApprovalMode: mode,
            approvalDecision: .askUser,
            approvalPolicySource: .serverDefault,
            environmentReference:
                MCPEnvironmentReference(
                    rawValue: "environment-fixture"),
            authorityFingerprint:
                "authority-fingerprint",
            revocationGeneration:
                MCPRevocationGeneration(
                    rawValue: "revocation-fixture"))
        return ResolvedToolAuthorization(
            authorizationID: "authorization-fixture",
            registryVersion: "registry-fixture",
            concreteToolID: "tool-fixture",
            descriptorFingerprint:
                "descriptor-fingerprint",
            toolName: "mcp__fixture__lookup",
            canonicalAction: "mcp.tool.call",
            requiredCapabilities: [],
            membership: .notRequired,
            capabilityLeaseID: nil,
            capabilityTaskID: nil,
            workspaceLeaseID: nil,
            workspaceAccess: nil,
            workspaceRootIdentity: nil,
            normalizedArgumentsDigest:
                "arguments-fingerprint",
            normalizedArgumentsCharacterCount: 2,
            intent: PermissionIntent(
                action: "mcp.tool.call",
                resources: [],
                replayPolicy:
                    sideEffect == .readOnly
                        ? .safeToReplay
                        : .doNotReplay),
            sideEffect: sideEffect,
            risksNetwork: true,
            replayPolicy:
                sideEffect == .readOnly
                    ? .safeToReplay
                    : .doNotReplay,
            mcp: mcp)
    }
}
