import XCTest
import IntatisCore
@testable import IntatisProtocol

final class PermissionReviewProtocolTests: XCTestCase {
    func testLegacyPermissionRequestWithoutContextStillDecodes() throws {
        let data = Data(#"""
        {
          "requestId":"req_legacy",
          "agent":"main",
          "tool":"write_file",
          "args":"{}",
          "risk":"medium",
          "reason":"write to workspace"
        }
        """#.utf8)

        let payload = try JSONDecoder().decode(PermissionRequestPayload.self, from: data)

        XCTAssertEqual(payload.requestId, RequestID(rawValue: "req_legacy"))
        XCTAssertNil(payload.context)
    }

    func testLegacyPermissionResolvedWithoutIntentStillDecodes() throws {
        let data = Data(#"{"tool":"write_file","decision":"deny","risk":"medium","reason":"legacy"}"#.utf8)

        let payload = try JSONDecoder().decode(PermissionResolvedPayload.self, from: data)

        XCTAssertEqual(payload.tool, "write_file")
        XCTAssertEqual(payload.decision, .deny)
        XCTAssertNil(payload.intent)
        XCTAssertNil(payload.authorization)
        XCTAssertNil(payload.source)
        XCTAssertNil(payload.reviewTaskID)
        XCTAssertNil(payload.reviewStatus)
        XCTAssertNil(payload.failureKind)
    }

    func testPartialPermissionRequestContextUsesAdditiveDefaults() throws {
        let data = Data(#"{"taskID":"task_partial","gate":{"decision":"ask","risk":"medium","reason":"write"}}"#.utf8)

        let context = try JSONDecoder().decode(PermissionRequestContext.self, from: data)

        XCTAssertEqual(context.taskID, TaskID(rawValue: "task_partial"))
        XCTAssertEqual(context.touchedPaths, [])
        XCTAssertNil(context.sideEffect)
        XCTAssertNil(context.intent)
        XCTAssertNil(context.authorization)
        XCTAssertNil(context.executionID)
        XCTAssertNil(context.reviewInvocationEvidence)
        XCTAssertNil(context.causalContext?.authorizationContext)
    }

    func testPermissionRequestContextRoundTripsOnlyInvocationEvidenceMetadata()
        throws {
        let metadata = PermissionReviewInvocationEvidenceMetadata(
            sourceGenerationID: "provider-generation_test",
            toolSnapshotID: "snapshot_test",
            modelAuthorizationContextDigest: String(repeating: "a", count: 64))
        let context = PermissionRequestContext(
            reviewInvocationEvidence: metadata)

        let data = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(
            PermissionRequestContext.self,
            from: data)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(decoded.reviewInvocationEvidence, metadata)
        XCTAssertFalse(json.contains("canonicalBusinessArguments"))
        XCTAssertFalse(json.contains("modelAuthorizationContextJSON"))
    }

    func testLegacyReviewTaskAndSettlementWithoutAuthorizationStillDecode() throws {
        let taskJSON = Data(#"""
        {
          "id":"review_legacy",
          "sessionID":"session_legacy",
          "requestID":"request_legacy",
          "reviewerAgent":"permission-reviewer",
          "tool":"write_file",
          "normalizedArgs":"{}",
          "touchedPaths":[],
          "risksNetwork":false,
          "gate":{"decision":"pass","risk":"medium","reason":"write"},
          "causalContext":{"taskLineage":[],"relatedAgents":[],"eventSequenceNumbers":[]},
          "createdAt":0,
          "deadline":1
        }
        """#.utf8)
        let settledJSON = Data(#"""
        {
          "reviewTaskID":"review_legacy",
          "requestID":"request_legacy",
          "reviewerAgent":"permission-reviewer",
          "reviewerModel":"reviewer-model",
          "tool":"write_file",
          "decision":"deny",
          "risk":"medium",
          "status":"denied",
          "reason":"legacy reason",
          "durationMillis":12,
          "settledAt":1
        }
        """#.utf8)

        let task = try JSONDecoder().decode(PermissionReviewTask.self, from: taskJSON)
        let settled = try JSONDecoder().decode(PermissionReviewSettledPayload.self, from: settledJSON)

        XCTAssertEqual(task.id.rawValue, "review_legacy")
        XCTAssertNil(task.authorization)
        XCTAssertNil(task.causalContext.authorizationContext)
        XCTAssertEqual(settled.reason, "legacy reason")
        XCTAssertNil(settled.authorization)
        XCTAssertNil(settled.failureKind)
    }

    func testLegacyProviderStillStoppingFailureKindRemainsDecodable() throws {
        let data = Data(#""provider_still_stopping""#.utf8)

        let failureKind = try JSONDecoder().decode(
            PermissionApprovalFailureKind.self,
            from: data)

        XCTAssertEqual(failureKind, .providerStillStopping)
    }

    func testLegacyMalformedVerdictAndTypedReviewerDiagnosticsRemainCodable() throws {
        let kinds: [PermissionApprovalFailureKind] = [
            .malformedVerdict,
            .reviewerIncompleteResponse,
            .reviewerNonSuccessFinish,
            .reviewerVerdictMissingMarker,
            .reviewerVerdictMultipleMarkers,
            .reviewerVerdictNotFinal,
            .reviewerVerdictMissingReason,
            .reviewerVerdictStructuredOutput,
        ]

        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(
                try JSONDecoder().decode(PermissionApprovalFailureKind.self, from: data),
                kind)
        }
        XCTAssertEqual(
            try JSONDecoder().decode(
                PermissionApprovalFailureKind.self,
                from: Data(#""malformed_verdict""#.utf8)),
            .malformedVerdict)
    }

    func testAuthorizationContextRoundTripsWithoutModelSuppliedBindingFields() throws {
        let causal = PermissionReviewCausalContext(
            userGoal: "Update the report",
            taskLineage: [TaskID(rawValue: "task_report")],
            authorizationContext: PermissionAuthorizationContext(
                report: PermissionAuthorizationReport(
                    authorizationGoal: "Finish the user-requested report revision.",
                    currentProgress: "The source report has been read and the target section is located.",
                    latestInstructionInterpretation: "Continue means apply the already agreed revision.",
                    currentActionJustification: "Writing the bounded patch is the next required step.",
                    scopeAssessment: "The patch remains inside the named report."),
                supportingUserEventSequences: [3, 8, 11]))

        let data = try JSONEncoder().encode(causal)
        let decoded = try JSONDecoder().decode(
            PermissionReviewCausalContext.self,
            from: data)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let authorization = try XCTUnwrap(
            object["authorizationContext"] as? [String: Any])

        XCTAssertEqual(decoded, causal)
        XCTAssertEqual(
            decoded.authorizationContext?.supportingUserEventSequences,
            [3, 8, 11])
        XCTAssertEqual(Set(authorization.keys), Set([
            "report",
            "supportingUserEventSequences",
        ]))
        XCTAssertNil(authorization["reportAuthor"])
        XCTAssertNil(authorization["latestUserInstruction"])
        XCTAssertNil(authorization["bindingDigest"])
    }

    func testResolvedToolAuthorizationRoundTripsAllPinnedFacts() throws {
        let intent = PermissionIntent(
            action: "filesystem.patch",
            resources: [PermissionResource(
                kind: .workspacePath,
                value: "Sources/App.swift",
                access: .readWrite)],
            metadata: ["operation": .string("apply_unified_diff")],
            dataEffects: [.mutate],
            risks: [.workspaceMutation],
            replayPolicy: .doNotReplay)
        let gate = PermissionReviewGateSnapshot(
            decision: .ask,
            risk: .medium,
            reason: "workspace mutation requires review",
            policyVersion: "intatis.deterministic-policy.v1")
        let authorization = ResolvedToolAuthorization(
            authorizationID: "authorization-roundtrip",
            registryVersion: "intatis.cowork.v1",
            concreteToolID: "intatis.cowork.v1/apply_patch",
            descriptorFingerprint: String(repeating: "a", count: 64),
            toolName: "apply_patch",
            canonicalAction: intent.action,
            canonicalPermission: "filesystem.edit",
            actionPreview: PermissionActionPreview(
                kind: "filesystem.patch",
                fields: [
                    "path": "Sources/App.swift",
                    "summary": "Apply a bounded source patch",
                ]),
            requiredCapabilities: [.applyPatch],
            membership: .granted,
            capabilityLeaseID: CapabilityLeaseID(rawValue: "capability-roundtrip"),
            capabilityTaskID: TaskID(rawValue: "task-roundtrip"),
            workspaceLeaseID: WorkspaceLeaseID(rawValue: "workspace-lease-roundtrip"),
            workspaceAccess: .readWrite,
            workspaceRootIdentity: WorkspaceRootIdentity(
                canonicalPath: "/tmp/workspace",
                deviceID: 10,
                fileID: 20),
            invocation: ToolAuthorizationInvocationContext(
                sessionID: SessionID(rawValue: "session-roundtrip"),
                agent: AgentID(rawValue: "main"),
                taskID: TaskID(rawValue: "task-roundtrip"),
                rootTaskID: TaskID(rawValue: "root-roundtrip"),
                parentTaskID: TaskID(rawValue: "parent-roundtrip"),
                attempt: 2,
                toolCallID: "call-roundtrip",
                taskObjective: "Patch the selected source file"),
            normalizedArgumentsDigest: String(repeating: "b", count: 64),
            normalizedArgumentsCharacterCount: 128,
            intent: intent,
            sideEffect: .write,
            risksNetwork: false,
            replayPolicy: .doNotReplay,
            deterministicGate: gate,
            capabilityLeaseFingerprint: String(repeating: "c", count: 64),
            workspaceID: WorkspaceID(rawValue: "workspace-roundtrip"),
            workspaceTaskID: TaskID(rawValue: "task-roundtrip"),
            workspaceRootPath: "/tmp/workspace",
            workspaceLeaseFingerprint: String(repeating: "d", count: 64))

        let data = try JSONEncoder().encode(authorization)
        let decoded = try JSONDecoder().decode(ResolvedToolAuthorization.self, from: data)

        XCTAssertEqual(decoded, authorization)
        XCTAssertEqual(decoded.canonicalPermission, "filesystem.edit")
        XCTAssertEqual(decoded.actionPreview?.kind, "filesystem.patch")
        XCTAssertEqual(decoded.actionPreview?.fields["path"], "Sources/App.swift")

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(legacyObject.removeValue(forKey: "canonicalPermission"))
        XCTAssertNotNil(legacyObject.removeValue(forKey: "actionPreview"))
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try JSONDecoder().decode(
            ResolvedToolAuthorization.self,
            from: legacyData)

        XCTAssertNil(legacyDecoded.canonicalPermission)
        XCTAssertNil(legacyDecoded.actionPreview)
        XCTAssertEqual(legacyDecoded.authorizationID, authorization.authorizationID)
        XCTAssertEqual(legacyDecoded.intent, authorization.intent)
    }

    func testPermissionActionPreviewDecodeResanitizesForgedSecretValues() throws {
        let secret = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let data = Data(#"""
        {
          "kind":"network.fetch",
          "fields":{
            "authorization":"Authorization: Bearer \#(secret)",
            "url":"https://example.test/resource?access_token=\#(secret)"
          },
          "redacted":false,
          "truncated":false
        }
        """#.utf8)

        let preview = try JSONDecoder().decode(PermissionActionPreview.self, from: data)
        let reencoded = try JSONEncoder().encode(preview)
        let reencodedText = try XCTUnwrap(String(data: reencoded, encoding: .utf8))

        XCTAssertTrue(preview.redacted)
        XCTAssertFalse(preview.truncated)
        XCTAssertFalse(preview.fields.values.joined().contains(secret))
        XCTAssertFalse(reencodedText.contains(secret))
        XCTAssertTrue(preview.fields["authorization"]?.contains("[REDACTED]") == true)
        XCTAssertTrue(preview.fields["url"]?.contains("[REDACTED]") == true)
    }

    func testDiagnosticSanitizerRedactsCompleteURLsWithoutChangingOrdinaryURLText() {
        let diagnostic =
            "upstream https://[fd00::24]:8443/private/v1/chat/completions failed with HTTP 502"

        let ordinary = PermissionReviewTextSanitizer.sanitize(
            diagnostic,
            maxCharacters: 1_024)
        let scrubbed = PermissionReviewTextSanitizer.sanitizeDiagnostic(
            diagnostic,
            maxCharacters: 1_024)

        XCTAssertEqual(ordinary.text, diagnostic)
        XCTAssertFalse(ordinary.redacted)
        XCTAssertEqual(
            scrubbed.text,
            "upstream [REDACTED_URL] failed with HTTP 502")
        XCTAssertTrue(scrubbed.redacted)
        XCTAssertFalse(scrubbed.text.contains("fd00"))
        XCTAssertFalse(scrubbed.text.contains("/private/v1"))
    }

    func testPermissionActionPreviewDecodeEnforcesFieldAndCharacterBounds() throws {
        let longKind = String(repeating: "k", count: 100)
        let longValue = String(repeating: "v", count: 1_000)
        let object: [String: Any] = [
            "kind": longKind,
            "fields": [
                "a_long": longValue,
                "b": "b",
                "c": "c",
                "d": "d",
                "e": "e",
                "f": "f",
                "g": "g",
                "h": "h",
                "z_omitted": "z",
            ],
            "redacted": false,
            "truncated": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)

        let preview = try JSONDecoder().decode(PermissionActionPreview.self, from: data)

        XCTAssertTrue(preview.truncated)
        XCTAssertFalse(preview.redacted)
        XCTAssertEqual(preview.kind, String(longKind.prefix(80)) + "...")
        XCTAssertEqual(preview.fields.count, 8)
        XCTAssertNil(preview.fields["z_omitted"])
        XCTAssertEqual(preview.fields["a_long"], String(longValue.prefix(800)) + "...")
    }

    func testReviewRequestedAndSettledEventsRoundTrip() throws {
        let reviewer = AgentID(rawValue: "permission-reviewer")
        let requestID = RequestID(rawValue: "req_roundtrip")
        let reviewID = PermissionReviewTaskID(rawValue: "review_roundtrip")
        let intent = PermissionIntent(
            action: "filesystem.write",
            resources: [PermissionResource(
                kind: .workspacePath,
                value: "Sources/App.swift",
                access: .readWrite)],
            metadata: ["operation": .string("overwrite")],
            dataEffects: [.mutate],
            risks: [.workspaceMutation],
            replayPolicy: .doNotReplay)
        let task = PermissionReviewTask(
            id: reviewID,
            sessionID: SessionID(rawValue: "sess_roundtrip"),
            requestID: requestID,
            requestingAgent: AgentID(rawValue: "main"),
            reviewerAgent: reviewer,
            taskID: TaskID(rawValue: "task_roundtrip"),
            rootTaskID: TaskID(rawValue: "task_root"),
            attempt: 3,
            toolCallID: "call_roundtrip",
            tool: "write_file",
            normalizedArgs: "{}",
            touchedPaths: ["Sources/App.swift"],
            risksNetwork: false,
            sideEffect: .write,
            intent: intent,
            gate: .init(decision: .ask, risk: .medium, reason: "write to workspace"),
            causalContext: .init(eventSequenceNumbers: [1, 2]),
            executionID: "exec_roundtrip",
            replayPolicy: "requires_reconciliation",
            createdAt: Date(timeIntervalSince1970: 10),
            deadline: Date(timeIntervalSince1970: 20))
        let settled = PermissionReviewSettledPayload(
            reviewTaskID: reviewID,
            requestID: requestID,
            requestingAgent: AgentID(rawValue: "main"),
            reviewerAgent: reviewer,
            reviewerModel: ModelID(rawValue: "reviewer-model"),
            tool: "write_file",
            decision: .allow,
            risk: .medium,
            status: .allowed,
            reason: "within task scope",
            usage: .init(promptTokens: 8, completionTokens: 2, totalTokens: 10),
            cumulativeTokens: 10,
            durationMillis: 15,
            settledAt: Date(timeIntervalSince1970: 11))
        let envelopes = [
            Envelope(seq: 1, ts: Date(timeIntervalSince1970: 100), session: task.sessionID,
                     event: .permissionReviewRequested(.init(task: task))),
            Envelope(seq: 2, ts: Date(timeIntervalSince1970: 101), session: task.sessionID,
                     event: .permissionReviewSettled(settled)),
        ]
        let encoder = Envelope.makeEncoder()
        let decoder = Envelope.makeDecoder()

        let decoded = try envelopes.map { try decoder.decode(Envelope.self, from: encoder.encode($0)) }

        XCTAssertEqual(decoded, envelopes)
        XCTAssertEqual(decoded.map(\.event.type), [.permissionReviewRequested, .permissionReviewSettled])
    }
}
