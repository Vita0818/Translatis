import XCTest
import IntatisCore
@testable import IntatisProtocol

final class MCPProtocolTests: XCTestCase {
    private let server = MCPServerReference(
        serverID: MCPServerID(rawValue: "mcpserver_fixture"),
        serverRevision: MCPServerRevision(rawValue: "mcprev_fixture"))
    private let attachmentID = MCPAttachmentID(rawValue: "mcpattach_fixture")
    private let generation = MCPConnectionGeneration(rawValue: "mcpcnx_fixture")
    private let rawCatalogRevision = MCPRawCatalogRevision(rawValue: "mcpraw_fixture")
    private let agentCatalogRevision = MCPAgentCatalogViewRevision(rawValue: "mcpview_fixture")
    private let bindingID = MCPBindingID(rawValue: "mcpbind_fixture")
    private let revocation = MCPRevocationGeneration(rawValue: "mcprevocation_3")
    private let environment = MCPEnvironmentReference(rawValue: "local-default")
    private let agent = AgentID(rawValue: "worker")

    private func filter(_ suffix: String = "1") -> MCPCatalogFilter {
        MCPCatalogFilter(
            revision: MCPPolicyRevision(rawValue: "filter_\(suffix)"),
            tools: MCPNameFilter(allowList: ["read", "write"], denyList: ["danger"]),
            resources: MCPNameFilter(denyList: ["private://fixture"]),
            prompts: MCPNameFilter(allowList: ["review"]),
            completions: MCPNameFilter(allowList: ["review.argument"]))
    }

    private func policy(_ suffix: String = "1") -> MCPAttachmentPolicy {
        MCPAttachmentPolicy(
            revision: MCPPolicyRevision(rawValue: "attach_policy_\(suffix)"),
            required: true,
            approvalMode: .writes,
            parallelCalls: true,
            filter: filter(suffix))
    }

    private func attachment() -> MCPServerAttachment {
        MCPServerAttachment(
            attachmentID: attachmentID,
            server: server,
            policy: policy(),
            source: .projectConfiguration,
            sourceFingerprint: "source-sha256")
    }

    private func grant() -> MCPGrant {
        MCPGrant(
            grantID: MCPGrantID(rawValue: "mcpgrant_fixture"),
            attachmentID: attachmentID,
            server: server,
            agentID: agent,
            capabilityLeaseID:
                CapabilityLeaseID(rawValue: "clease-mcp"),
            taskID: TaskID(rawValue: "task-mcp"),
            capabilities: [.resources, .tools, .sampling, .elicitation, .tasks],
            filter: filter(),
            approvalModeCeiling: .writes,
            authorityFingerprint: "authority-sha256",
            grantFingerprint: "grant-sha256",
            revocationGeneration: revocation)
    }

    private func provenance() -> MCPContentProvenance {
        MCPContentProvenance(
            sourceKind: .tool,
            server: server,
            connectionGeneration: generation,
            rawCatalogRevision: rawCatalogRevision,
            agentCatalogViewRevision: agentCatalogRevision,
            bindingID: bindingID,
            protocolProfile: .standardExtended,
            negotiatedProtocolVersion: MCPNegotiatedProtocolVersion(.v2025_11_25),
            remoteName: "read",
            resourceURI: "fixture://document",
            schemaHash: "schema-sha256",
            accountReference: MCPAccountReference(rawValue: "account-fixture"),
            environmentReference: environment)
    }

    private func mcpAuthorization() -> MCPToolAuthorizationSnapshot {
        MCPToolAuthorizationSnapshot(
            server: server,
            attachmentID: attachmentID,
            grantID: MCPGrantID(rawValue: "mcpgrant_fixture"),
            grantFingerprint: "grant-sha256",
            connectionGeneration: generation,
            rawCatalogRevision: rawCatalogRevision,
            agentCatalogViewRevision: agentCatalogRevision,
            bindingID: bindingID,
            remoteToolName: "read",
            schemaHash: "schema-sha256",
            protocolProfile: .standardExtended,
            negotiatedProtocolVersion: MCPNegotiatedProtocolVersion(.v2025_11_25),
            effectiveApprovalMode: .writes,
            approvalDecision: .askUser,
            approvalPolicySource: .agentGrant,
            accountReference: MCPAccountReference(rawValue: "account-fixture"),
            environmentReference: environment,
            authorityFingerprint: "authority-sha256",
            revocationGeneration: revocation)
    }

    private func authorization(mcp: MCPToolAuthorizationSnapshot? = nil) -> ResolvedToolAuthorization {
        ResolvedToolAuthorization(
            authorizationID: "authorization-fixture",
            registryVersion: "registry-fixture",
            concreteToolID: "tool-fixture",
            descriptorFingerprint: "descriptor-sha256",
            toolName: "mcp__fixture__read",
            canonicalAction: "mcp.tool.call",
            requiredCapabilities: [],
            membership: .notRequired,
            capabilityLeaseID: CapabilityLeaseID(rawValue: "clease-fixture"),
            capabilityTaskID: TaskID(rawValue: "task-fixture"),
            workspaceLeaseID: WorkspaceLeaseID(rawValue: "wlease-fixture"),
            workspaceAccess: .readOnly,
            workspaceRootIdentity: nil,
            invocation: ToolAuthorizationInvocationContext(
                sessionID: SessionID(rawValue: "sess-fixture"),
                agent: agent,
                taskID: TaskID(rawValue: "task-fixture"),
                attempt: 1,
                toolCallID: "call-fixture"),
            normalizedArgumentsDigest: "arguments-sha256",
            normalizedArgumentsCharacterCount: 14,
            intent: PermissionIntent(
                action: "mcp.tool.call",
                resources: [.init(kind: .tool, value: "mcp__fixture__read")],
                dataEffects: [.read],
                replayPolicy: .safeToReplay),
            sideEffect: .readOnly,
            risksNetwork: false,
            replayPolicy: .safeToReplay,
            mcp: mcp)
    }

    private func structuredResult() -> MCPStructuredToolResult {
        MCPStructuredToolResult(
            content: [
                MCPContentBlock(
                    kind: .text,
                    text: "bounded fixture",
                    mimeType: "text/plain",
                    byteCount: 15,
                    sha256: "text-sha256",
                    provenance: provenance()),
                MCPContentBlock(
                    kind: .artifactReference,
                    artifactID: ArtifactID(rawValue: "art-fixture"),
                    mimeType: "image/png",
                    byteCount: 32,
                    sha256: "image-sha256",
                    provenance: provenance()),
            ],
            structuredContent: .object(["ok": .bool(true)]),
            outputSchemaHash: "output-schema-sha256",
            totalByteCount: 47)
    }

    private func roundTrip<T: Codable & Equatable>(
        _ value: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: data), value, file: file, line: line)
    }

    private func roundTripEvent(
        _ event: Event,
        expectedType: String,
        sequence: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let envelope = Envelope(
            seq: sequence,
            ts: Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence)),
            session: SessionID(rawValue: "sess-mcp"),
            event: event)
        let data = try Envelope.makeEncoder().encode(envelope)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, expectedType, file: file, line: line)
        XCTAssertEqual(
            try Envelope.makeDecoder().decode(Envelope.self, from: data),
            envelope,
            file: file,
            line: line)
    }

    func testEightLayerIdentityLaunchArtifactAndAuthorityRoundTrip() throws {
        let executable = MCPLaunchFileIdentity(
            role: .executable,
            canonicalPath: "/Applications/Fixture/bin/server",
            fileType: "regular",
            ownerID: 501,
            mode: 0o755,
            deviceID: 1,
            fileID: 2,
            byteCount: 1024,
            sha256: "artifact-sha256",
            codeSignatureSummary: "team:fixture; notarized:true")
        let launch = LaunchArtifactIdentity(files: [executable], fingerprint: "launch-sha256")
        let authority = MCPConnectionAuthority(
            server: server,
            transport: .stdio,
            protocolProfile: .codexCompat,
            sessionID: SessionID(rawValue: "sess-mcp"),
            agentID: agent,
            attachmentID: attachmentID,
            capabilityLeaseID: CapabilityLeaseID(rawValue: "clease-fixture"),
            capabilityTaskID: nil,
            workspaceLeaseID: WorkspaceLeaseID(rawValue: "wlease-fixture"),
            workspaceRootIdentityFingerprint: "workspace-sha256",
            workspaceLeasePolicyFingerprint:
                String(repeating: "a", count: 64),
            attachmentPolicyRevision: policy().revision,
            environmentReference: environment,
            launchArtifactFingerprint: launch.fingerprint,
            rootsPolicyRevision: MCPPolicyRevision(rawValue: "roots-1"),
            networkPolicyRevision: MCPPolicyRevision(rawValue: "network-1"),
            sandboxProfileRevision: MCPPolicyRevision(rawValue: "sandbox-1"),
            sandboxPolicyFingerprint:
                String(repeating: "b", count: 64),
            hostPlatform: "macos-developer-id",
            fingerprint: "authority-sha256")
        let binding = MCPBindingIdentity(
            protocolProfile: .codexCompat,
            negotiatedProtocolVersion: MCPNegotiatedProtocolVersion(.v2025_06_18),
            server: server,
            connectionGeneration: generation,
            rawCatalogRevision: rawCatalogRevision,
            agentCatalogViewRevision: agentCatalogRevision,
            bindingID: bindingID,
            revocationGeneration: revocation)

        try roundTrip(launch)
        try roundTrip(authority)
        XCTAssertTrue(authority.hasCurrentExecutionAuthority)
        try roundTrip(binding)
        XCTAssertEqual(MCPProtocolProfile.codexCompat.defaultMaximumVersion, .v2025_06_18)
        XCTAssertEqual(MCPProtocolProfile.standardExtended.defaultMaximumVersion, .v2025_11_25)
        XCTAssertEqual(
            String(data: try JSONEncoder().encode(MCPProtocolVersion.v2025_06_18), encoding: .utf8),
            "\"2025-06-18\"")
        XCTAssertEqual(
            String(
                data: try JSONEncoder().encode(
                    MCPNegotiatedProtocolVersion(.v2025_11_25)),
                encoding: .utf8),
            "\"2025-11-25\"")
    }

    func testLegacyConnectionAuthorityDecodesForAuditButIsNotExecutable()
        throws
    {
        let current = MCPConnectionAuthority(
            server: server,
            transport: .streamableHTTP,
            protocolProfile: .standardExtended,
            sessionID: SessionID(rawValue: "sess-legacy"),
            agentID: agent,
            attachmentID: attachmentID,
            capabilityLeaseID:
                CapabilityLeaseID(rawValue: "cap-legacy"),
            capabilityTaskID:
                TaskID(rawValue: "task-legacy"),
            workspaceLeasePolicyFingerprint:
                String(repeating: "a", count: 64),
            attachmentPolicyRevision: policy().revision,
            environmentReference: environment,
            rootsPolicyRevision:
                MCPPolicyRevision(rawValue: "roots-legacy"),
            networkPolicyRevision:
                MCPPolicyRevision(rawValue: "network-legacy"),
            sandboxProfileRevision:
                MCPPolicyRevision(rawValue: "sandbox-legacy"),
            sandboxPolicyFingerprint:
                String(repeating: "b", count: 64),
            hostPlatform: "mac_cli",
            fingerprint: String(repeating: "c", count: 64))
        let encoded = try JSONEncoder().encode(current)
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any])
        legacy.removeValue(forKey: "schemaVersion")
        legacy.removeValue(forKey: "capabilityTaskID")
        legacy.removeValue(
            forKey: "workspaceLeasePolicyFingerprint")
        legacy.removeValue(
            forKey: "sandboxPolicyFingerprint")

        let decoded = try JSONDecoder().decode(
            MCPConnectionAuthority.self,
            from: JSONSerialization.data(
                withJSONObject: legacy))

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertNil(decoded.capabilityTaskID)
        XCTAssertNil(
            decoded.workspaceLeasePolicyFingerprint)
        XCTAssertNil(decoded.sandboxPolicyFingerprint)
        XCTAssertFalse(decoded.hasCurrentExecutionAuthority)
    }

    func testAttachmentGrantConsentAndCapabilityLeaseRoundTrip() throws {
        let consent = MCPConsent(
            consentID: MCPConsentID(rawValue: "mcpconsent-fixture"),
            kind: .launch,
            server: server,
            attachmentID: attachmentID,
            authorityFingerprint: "authority-sha256",
            launchArtifactFingerprint: "launch-sha256",
            environmentReference: environment,
            policyRevision: MCPPolicyRevision(rawValue: "consent-policy-1"))
        let lease = CapabilityLease(
            id: CapabilityLeaseID(rawValue: "clease-mcp"),
            taskID: TaskID(rawValue: "task-mcp"),
            tools: [.readWorkspace],
            communication: .replyOnly,
            delegation: .none,
            mcpGrants: [grant()])

        try roundTrip(attachment())
        try roundTrip(grant())
        try roundTrip(consent)
        try roundTrip(lease)
        XCTAssertTrue(lease.mcpGrants[0].grants(.tools))
        XCTAssertFalse(lease.mcpGrants[0].grants(.completions))
    }

    func testLegacyCapabilityLeaseDefaultsToNoMCPGrants() throws {
        let current = CapabilityLease(
            id: CapabilityLeaseID(rawValue: "clease-legacy"),
            tools: [.readWorkspace],
            communication: .none,
            delegation: .none)
        let encoded = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "mcpGrants")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CapabilityLease.self, from: legacyData)

        XCTAssertTrue(decoded.mcpGrants.isEmpty)
        XCTAssertTrue(CapabilityLease.worker().mcpGrants.isEmpty)
        XCTAssertTrue(CapabilityLease.coordinator().mcpGrants.isEmpty)
    }

    func testGrantExpiryAndLegacyCompletionFilterDefaultsFailClosed() throws {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let expiring = MCPGrant(
            grantID: MCPGrantID(rawValue: "mcpgrant-expiring"),
            attachmentID: attachmentID,
            server: server,
            agentID: agent,
            capabilityLeaseID:
                CapabilityLeaseID(rawValue: "clease-mcp"),
            taskID: TaskID(rawValue: "task-mcp"),
            capabilities: [.tools, .completions],
            filter: filter(),
            approvalModeCeiling: .prompt,
            authorityFingerprint: "authority-sha256",
            grantFingerprint: "grant-sha256",
            revocationGeneration: revocation,
            expiresAt: expiry)
        XCTAssertTrue(
            expiring.isActive(
                at: Date(timeIntervalSince1970: 1_899_999_999)))
        XCTAssertFalse(expiring.isActive(at: expiry))

        let data = try JSONEncoder().encode(expiring)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "expiresAt")
        var legacyFilter = try XCTUnwrap(
            object["filter"] as? [String: Any])
        legacyFilter.removeValue(forKey: "completions")
        object["filter"] = legacyFilter
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            MCPGrant.self,
            from: legacyData)

        XCTAssertNil(decoded.expiresAt)
        XCTAssertTrue(decoded.isActive())
        XCTAssertFalse(
            decoded.filter.completions.allows("any-completion-name"))
    }

    func testStructuredResultAndLegacyToolResultRoundTrip() throws {
        let payload = ToolResultPayload(
            toolCallId: "call-fixture",
            observation: "bounded fixture",
            truncated: false,
            outcome: .succeeded,
            structuredResult: structuredResult(),
            provenance: provenance())
        try roundTrip(payload)

        let legacy = """
        {"toolCallId":"legacy-call","observation":"legacy observation","truncated":false}
        """
        let decoded = try JSONDecoder().decode(ToolResultPayload.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.structuredResult)
        XCTAssertNil(decoded.provenance)
        XCTAssertEqual(decoded.observation, "legacy observation")
    }

    func testAuthorizationSnapshotRoundTripGatePreservationAndLegacyDefault() throws {
        let resolved = authorization(mcp: mcpAuthorization())
        try roundTrip(resolved)

        let gated = resolved.withDeterministicGate(.init(
            decision: .ask,
            risk: .medium,
            reason: "fixture",
            policyVersion: "fixture-v1"))
        XCTAssertEqual(gated.mcp, resolved.mcp)
        XCTAssertEqual(gated.deterministicGate?.decision, .ask)

        let legacyAuthorization = authorization()
        let encoded = try JSONEncoder().encode(legacyAuthorization)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["mcp"])
        XCTAssertNil(try JSONDecoder().decode(ResolvedToolAuthorization.self, from: encoded).mcp)
    }

    func testAllMCPDurableEventFamiliesRoundTripThroughEnvelope() throws {
        let requestID = RequestID(rawValue: "req-mcp")
        let operationID = MCPControlOperationID(rawValue: "mcpop-fixture")
        let remoteTaskID = MCPRemoteServerTaskID(rawValue: "mcpremote-fixture")
        let clientTaskID = MCPClientHostedTaskID(rawValue: "mcpclient-fixture")
        let correlation = MCPEventCorrelation(
            agentID: agent,
            taskID: TaskID(rawValue: "task-fixture"),
            turnID: TurnID(rawValue: "turn-fixture"),
            toolCallID: "call-fixture")
        let fingerprint = MCPPayloadFingerprint(sha256: "payload-sha256", characterCount: 42)
        let diagnostic = MCPDiagnosticSummary(code: "fixture", summary: "bounded diagnostic")
        let events: [(Event, String)] = [
            (.mcpServerAttached(.init(attachment: attachment())), "mcp_server_attached"),
            (.mcpServerDetached(.init(
                attachmentID: attachmentID,
                server: server,
                reason: .user,
                revocationGeneration: revocation)), "mcp_server_detached"),
            (.mcpAttachmentPolicyUpdated(.init(
                attachmentID: attachmentID,
                server: server,
                previousRevision: policy().revision,
                policy: policy("2"),
                revocationGeneration: revocation)), "mcp_attachment_policy_updated"),
            (.mcpConsentGranted(.init(consent: MCPConsent(
                consentID: MCPConsentID(rawValue: "mcpconsent-fixture"),
                kind: .connect,
                server: server,
                attachmentID: attachmentID,
                authorityFingerprint: "authority-sha256",
                environmentReference: environment,
                policyRevision: MCPPolicyRevision(rawValue: "consent-1")))), "mcp_consent_granted"),
            (.mcpConsentRevoked(.init(
                consentID: MCPConsentID(rawValue: "mcpconsent-fixture"),
                kind: .connect,
                server: server,
                attachmentID: attachmentID,
                reason: .credentialChanged,
                revocationGeneration: revocation)), "mcp_consent_revoked"),
            (.mcpControlOperationRequested(.init(
                operationID: operationID,
                kind: .connect,
                server: server,
                attachmentID: attachmentID,
                authorityFingerprint: "authority-sha256",
                correlation: correlation)), "mcp_control_operation_requested"),
            (.mcpControlOperationSettled(.init(
                operationID: operationID,
                kind: .connect,
                server: server,
                attachmentID: attachmentID,
                status: .succeeded,
                connectionGeneration: generation)), "mcp_control_operation_settled"),
            (.mcpGrantGranted(.init(grant: grant())), "mcp_grant_granted"),
            (.mcpGrantRevoked(.init(
                grantID: grant().grantID,
                server: server,
                attachmentID: attachmentID,
                agentID: agent,
                reason: .policyTightened,
                revocationGeneration: revocation)), "mcp_grant_revoked"),
            (.mcpRootsPolicyUpdated(.init(
                revision: MCPPolicyRevision(rawValue: "roots-2"),
                roots: [.init(
                    workspaceID: WorkspaceID(rawValue: "workspace-fixture"),
                    workspaceLeaseID: WorkspaceLeaseID(rawValue: "wlease-fixture"),
                    rootIdentityFingerprint: "workspace-sha256",
                    access: .readOnly)],
                revocationGeneration: revocation)), "mcp_roots_policy_updated"),
            (.mcpNetworkPolicyUpdated(.init(
                revision: MCPPolicyRevision(rawValue: "network-2"),
                access: .allowlisted,
                allowedOriginDigests: ["origin-sha256"],
                proxyPolicy: .system,
                revocationGeneration: revocation)), "mcp_network_policy_updated"),
            (.mcpPromptInserted(.init(
                requestID: requestID,
                promptName: "review",
                arguments: fingerprint,
                insertedMessageID: MessageID(rawValue: "msg-prompt"),
                provenance: provenance(),
                selectedByAgentID: agent)), "mcp_prompt_inserted"),
            (.mcpSamplingRequested(.init(
                requestID: requestID,
                server: server,
                connectionGeneration: generation,
                request: fingerprint,
                maxOutputTokens: 128,
                correlation: correlation)), "mcp_sampling_requested"),
            (.mcpSamplingDecided(.init(
                requestID: requestID,
                decision: .allow,
                source: .user,
                reasonCode: "approved")), "mcp_sampling_decided"),
            (.mcpSamplingSettled(.init(
                requestID: requestID,
                status: .succeeded,
                resultReference: MCPResultReference(rawValue: "mcpresult-sampling"))),
             "mcp_sampling_settled"),
            (.mcpElicitationRequested(.init(
                requestID: requestID,
                server: server,
                connectionGeneration: generation,
                mode: .form,
                request: fingerprint,
                correlation: correlation)), "mcp_elicitation_requested"),
            (.mcpElicitationDecided(.init(
                requestID: requestID,
                decision: .deny,
                source: .deterministicPolicy,
                reasonCode: "policy")), "mcp_elicitation_decided"),
            (.mcpElicitationSettled(.init(
                requestID: requestID,
                status: .denied)), "mcp_elicitation_settled"),
            (.mcpRemoteTaskRequested(.init(
                taskID: remoteTaskID,
                server: server,
                connectionGeneration: generation,
                operation: .toolCall,
                request: fingerprint,
                correlation: correlation)), "mcp_remote_task_requested"),
            (.mcpRemoteTaskMapped(.init(
                taskID: remoteTaskID,
                remoteTaskReference: fingerprint)), "mcp_remote_task_mapped"),
            (.mcpRemoteTaskStateChanged(.init(
                taskID: remoteTaskID,
                state: .working,
                stateRevision: 2)), "mcp_remote_task_state_changed"),
            (.mcpRemoteTaskSettled(.init(
                taskID: remoteTaskID,
                status: .succeeded,
                resultReference: MCPResultReference(rawValue: "mcpresult-remote"))),
             "mcp_remote_task_settled"),
            (.mcpClientTaskRequested(.init(
                taskID: clientTaskID,
                kind: .elicitation,
                server: server,
                connectionGeneration: generation,
                request: fingerprint,
                correlation: correlation)), "mcp_client_task_requested"),
            (.mcpClientTaskStateChanged(.init(
                taskID: clientTaskID,
                state: .inputRequired,
                stateRevision: 3)), "mcp_client_task_state_changed"),
            (.mcpClientTaskSettled(.init(
                taskID: clientTaskID,
                status: .cancelled)), "mcp_client_task_settled"),
            (.mcpConnectionTerminal(.init(
                server: server,
                attachmentID: attachmentID,
                connectionGeneration: generation,
                authorityFingerprint: "authority-sha256",
                status: .ready,
                negotiatedProtocolVersion: MCPNegotiatedProtocolVersion(.v2025_11_25))),
             "mcp_connection_terminal"),
            (.mcpCatalogTerminal(.init(
                server: server,
                connectionGeneration: generation,
                status: .published,
                rawCatalogRevision: rawCatalogRevision,
                catalogHash: "catalog-sha256",
                toolCount: 2,
                resourceCount: 1,
                resourceTemplateCount: 1,
                promptCount: 1)), "mcp_catalog_terminal"),
            (.mcpExecutionUncertain(.init(
                executionID: "execution-fixture",
                authorizationID: "authorization-fixture",
                correlation: correlation,
                authorization: mcpAuthorization(),
                reason: .timeoutAfterDispatch,
                diagnostic: diagnostic)), "mcp_execution_uncertain"),
            (.mcpRequestProgress(.init(
                server: server,
                connectionGeneration: generation,
                authorityFingerprint:
                    "authority-sha256",
                requestIDFingerprint:
                    "request-sha256",
                progressTokenFingerprint:
                    "progress-sha256",
                requestMethod: "tools/call",
                progress: 50,
                total: 100,
                phase: .reported,
                diagnostic:
                    MCPDiagnosticSummary(
                        code: "mcp_progress",
                        summary: "halfway"))),
             "mcp_request_progress"),
        ]

        for (index, entry) in events.enumerated() {
            try roundTripEvent(entry.0, expectedType: entry.1, sequence: index + 1)
        }
    }

    func testDurablePayloadsHaveNoCredentialValueFieldsAndDiagnosticsAreScrubbed() throws {
        let diagnostic = MCPDiagnosticSummary(
            code: "remote",
            summary: "Authorization: Bearer sk-fixture-secret https://private.example/path")
        let event = Event.mcpControlOperationSettled(.init(
            operationID: MCPControlOperationID(rawValue: "mcpop-fixture"),
            kind: .test,
            server: server,
            status: .failed,
            diagnostic: diagnostic))
        let envelope = Envelope(
            seq: 1,
            session: SessionID(rawValue: "sess-mcp"),
            event: event)
        let data = try Envelope.makeEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data)
        let forbiddenKeys: Set<String> = [
            "token",
            "accesstoken",
            "refreshtoken",
            "clientsecret",
            "apikey",
            "password",
            "headers",
            "headervalues",
            "environmentvalues",
            "envvalues",
        ]

        func inspect(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                for (key, nested) in dictionary {
                    XCTAssertFalse(forbiddenKeys.contains(key.lowercased()), "forbidden key \(key)")
                    inspect(nested)
                }
            } else if let array = value as? [Any] {
                array.forEach(inspect)
            } else if let string = value as? String {
                XCTAssertFalse(string.contains("sk-fixture-secret"))
                XCTAssertFalse(string.contains("private.example"))
            }
        }

        inspect(object)
        XCTAssertTrue(diagnostic.redacted)
    }

    func testStructuredToolResultEncodesCompleteDiscriminator() throws {
        let value = structuredResult()
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["resultType"] as? String, "complete")
        XCTAssertEqual(
            try JSONDecoder().decode(MCPStructuredToolResult.self, from: data),
            value)
    }

    func testLegacyStructuredToolResultWithoutDiscriminatorDecodesAsComplete() throws {
        let legacy = #"{"content":[],"isError":false,"truncated":false}"#
        let decoded = try JSONDecoder().decode(
            MCPStructuredToolResult.self,
            from: Data(legacy.utf8))

        XCTAssertEqual(decoded.resultType, .complete)
        XCTAssertEqual(decoded.content, [])
        XCTAssertFalse(decoded.isError)
    }
}
