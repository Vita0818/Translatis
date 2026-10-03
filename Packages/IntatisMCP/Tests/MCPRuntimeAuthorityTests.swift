import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisMCP

final class MCPRuntimeAuthorityTests: XCTestCase {
    func testReadyOpenConnectionIsReusedOnlyWithExactIdentity() async throws {
        let session = SessionID(rawValue: "sess_reuse")
        let agent = AgentID(rawValue: "agent_reuse")
        let identity = makeIdentity(
            session: session,
            agent: agent,
            serverID: "server_reuse")
        let factory = TestMCPClientFactory()
        let consentSource = TestConsentSource(
            consents: [makeConsent(for: identity)])
        let audit = TestAuditSink()
        let runtime = makeRuntime(
            session: session,
            factory: factory,
            consentSource: consentSource,
            audit: audit)

        let first = try await runtime.activate(
            makePlan(
                session: session,
                agent: agent,
                reason: .send,
                requirements: [makeRequirement(identity)]))
        let second = try await runtime.activate(
            makePlan(
                session: session,
                agent: agent,
                reason: .resume,
                requirements: [makeRequirement(identity)]))

        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(first.connections.count, 1)
        XCTAssertEqual(second.connections.count, 1)
        XCTAssertEqual(
            first.connections[0].bindingIdentity.connectionGeneration,
            second.connections[0].bindingIdentity.connectionGeneration)
        XCTAssertNotEqual(first.snapshotID, second.snapshotID)
        XCTAssertNotEqual(first.bindingID, second.bindingID)
        try await first.connections[0].route.revalidate()
        try await second.connections[0].route.revalidate()

        let auditState = await audit.snapshot()
        XCTAssertEqual(auditState.requests.count, 2)
        XCTAssertEqual(
            auditState.settlements.map(\.status),
            [.succeeded, .succeeded])
        _ = await runtime.shutdownAndDrain(reason: "test complete")
    }

    func testReuseEvaluationChecksEveryCodexIdentityFieldAndState()
        async throws {
        let session = SessionID(rawValue: "sess_predicate")
        let agent = AgentID(rawValue: "agent_predicate")
        let base = makeIdentity(
            session: session,
            agent: agent,
            serverID: "server_predicate",
            transport: .streamableHTTP,
            account: "account_a",
            environment: "environment_a",
            launchArtifact: nil)
        let factory = TestMCPClientFactory()
        let pool = MCPConnectionPool(sessionID: session)
        let first = try await pool.acquire(
            identity: base,
            revocationGeneration:
                MCPRevocationGeneration(rawValue: "revoke_1"),
            factory: factory)
        _ = try await first.connection.startup()
        try await pool.confirmCurrentReady(first)

        let cases: [(MCPConnectionReuseIdentity, MCPConnectionReuseMismatch)] = [
            (
                makeIdentity(
                    session: session,
                    agent: agent,
                    serverID: "different_server",
                    transport: .streamableHTTP,
                    account: "account_a",
                    environment: "environment_a",
                    launchArtifact: nil),
                .serverIdentity
            ),
            (
                makeIdentity(
                    session: session,
                    agent: agent,
                    serverID: "server_predicate",
                    serverRevision: "revision_2",
                    transport: .streamableHTTP,
                    account: "account_a",
                    environment: "environment_a",
                    launchArtifact: nil),
                .serverConfigurationRevision
            ),
            (
                copyIdentity(base, transport: .stdio),
                .transport
            ),
            (
                copyIdentity(
                    base,
                    transportConfigurationFingerprint:
                        "transport_configuration_b"),
                .transportConfiguration
            ),
            (
                copyIdentity(
                    base,
                    authority: makeAuthority(
                        session: session,
                        agent: agent,
                        server: base.server,
                        transport: .streamableHTTP,
                        account: "account_a",
                        environment: "environment_a",
                        launchArtifact: nil,
                        workspace: "workspace_b",
                        networkRevision: "network_b")),
                .authority
            ),
            (
                copyIdentity(
                    base,
                    oauthAccountReference:
                        MCPAccountReference(rawValue: "account_b")),
                .oauthAccount
            ),
            (
                copyIdentity(
                    base,
                    environmentReference:
                        MCPEnvironmentReference(rawValue: "environment_b")),
                .environment
            ),
            (
                copyIdentity(base, launchArtifactFingerprint: "launch_b"),
                .launchArtifact
            ),
            (
                copyIdentity(base, runtimeIdentityFingerprint: "runtime_b"),
                .runtimeIdentity
            ),
        ]

        for (candidate, expectedMismatch) in cases {
            let evaluation = await first.connection.reuseEvaluation(
                requested: candidate)
            XCTAssertFalse(evaluation.canReuse)
            XCTAssertTrue(
                evaluation.mismatches.contains(expectedMismatch),
                "expected \(expectedMismatch) in \(evaluation.mismatches)")
        }

        guard let firstClient = factory.client(first.generation) else {
            return XCTFail("missing fake client")
        }
        await firstClient.forceClosed()
        let closedEvaluation = await first.connection.reuseEvaluation(
            requested: base)
        XCTAssertTrue(
            closedEvaluation.mismatches.contains(.clientClosed))

        let replacement = try await pool.acquire(
            identity: base,
            revocationGeneration:
                MCPRevocationGeneration(rawValue: "revoke_1"),
            factory: factory)
        XCTAssertFalse(replacement.reused)
        XCTAssertNotEqual(replacement.generation, first.generation)
        XCTAssertTrue(
            replacement.replacementReasons.contains(.clientClosed))

        let secondPool = MCPConnectionPool(sessionID: session)
        let allocated = try await secondPool.acquire(
            identity: base,
            revocationGeneration:
                MCPRevocationGeneration(rawValue: "revoke_1"),
            factory: factory)
        let allocatedReplacement = try await secondPool.acquire(
            identity: base,
            revocationGeneration:
                MCPRevocationGeneration(rawValue: "revoke_1"),
            factory: factory)
        XCTAssertNotEqual(
            allocated.generation,
            allocatedReplacement.generation)
        XCTAssertTrue(
            allocatedReplacement.replacementReasons
                .contains(.startupIncomplete))

        _ = await pool.shutdownAndDrain(reason: "test complete")
        _ = await secondPool.shutdownAndDrain(reason: "test complete")
    }

    func testDifferentAgentWorkspaceNetworkAndCredentialAuthoritiesNeverShare()
        async throws {
        let session = SessionID(rawValue: "sess_isolation")
        let agentA = AgentID(rawValue: "agent_a")
        let agentB = AgentID(rawValue: "agent_b")
        let identityA = makeIdentity(
            session: session,
            agent: agentA,
            serverID: "server_shared_alias",
            transport: .streamableHTTP,
            account: "account_a",
            environment: "environment_a",
            launchArtifact: nil,
            workspace: "workspace_a",
            networkRevision: "network_a")
        let identityB = makeIdentity(
            session: session,
            agent: agentB,
            serverID: "server_shared_alias",
            transport: .streamableHTTP,
            account: "account_b",
            environment: "environment_b",
            launchArtifact: nil,
            workspace: "workspace_b",
            networkRevision: "network_b")
        let factory = TestMCPClientFactory()
        let runtime = makeRuntime(
            session: session,
            factory: factory,
            consentSource: TestConsentSource(
                consents: [
                    makeConsent(for: identityA),
                    makeConsent(for: identityB),
                ]),
            audit: TestAuditSink())

        let first = try await runtime.activate(
            makePlan(
                session: session,
                agent: agentA,
                reason: .send,
                requirements: [makeRequirement(identityA)]))
        let second = try await runtime.activate(
            makePlan(
                session: session,
                agent: agentB,
                reason: .send,
                requirements: [makeRequirement(identityB)]))

        XCTAssertEqual(factory.creationCount, 2)
        XCTAssertNotEqual(
            first.connections[0].bindingIdentity.connectionGeneration,
            second.connections[0].bindingIdentity.connectionGeneration)
        try await first.connections[0].route.revalidate()
        try await second.connections[0].route.revalidate()

        _ = await runtime.shutdownAndDrain(reason: "test complete")
    }

    func testRevocationImmediatelyFencesOldGenerationRoute() async throws {
        let session = SessionID(rawValue: "sess_revoke")
        let agent = AgentID(rawValue: "agent_revoke")
        let identity = makeIdentity(
            session: session,
            agent: agent,
            serverID: "server_revoke")
        let runtime = makeRuntime(
            session: session,
            factory: TestMCPClientFactory(),
            consentSource: TestConsentSource(
                consents: [makeConsent(for: identity)]),
            audit: TestAuditSink())
        let snapshot = try await runtime.activate(
            makePlan(
                session: session,
                agent: agent,
                reason: .send,
                requirements: [makeRequirement(identity)]))
        let route = try XCTUnwrap(snapshot.connections.first?.route)
        try await route.revalidate()

        let replacementRevocation =
            MCPRevocationGeneration(rawValue: "revoke_replacement")
        await runtime.revokeAuthority(
            identity.poolKey,
            to: replacementRevocation,
            reason: "test policy tightening")

        do {
            try await route.revalidate()
            XCTFail("revoked route should fail")
        } catch let error as MCPConnectionError {
            XCTAssertEqual(
                error,
                .staleRevocation(
                    expected:
                        MCPRevocationGeneration(rawValue: "revoke_1"),
                    actual: replacementRevocation))
        }
        _ = await runtime.shutdownAndDrain(reason: "test complete")
    }

    func testCatalogRefreshPublishesWholeNewSnapshotWithoutSwappingOldBinding()
        async throws {
        let session = SessionID(rawValue: "sess_catalog")
        let agent = AgentID(rawValue: "agent_catalog")
        let identity = makeIdentity(
            session: session,
            agent: agent,
            serverID: "server_catalog")
        let factory = TestMCPClientFactory()
        let runtime = makeRuntime(
            session: session,
            factory: factory,
            consentSource: TestConsentSource(
                consents: [makeConsent(for: identity)]),
            audit: TestAuditSink())
        let first = try await runtime.activate(
            makePlan(
                session: session,
                agent: agent,
                reason: .send,
                requirements: [makeRequirement(identity)]))
        let firstConnection = try XCTUnwrap(first.connections.first)
        XCTAssertEqual(
            firstConnection.catalog.revision.rawValue,
            initialCatalogRevision(for: identity))

        let stalePublication =
            try await runtime
                .markCatalogStaleAndRepublish(
                    identity: identity,
                    generation:
                        firstConnection
                            .bindingIdentity
                            .connectionGeneration,
                    revocationGeneration:
                        firstConnection
                            .bindingIdentity
                            .revocationGeneration,
                    kinds: [.tools])
        let staleConnection =
            try XCTUnwrap(
                stalePublication
                    .connections.first)
        XCTAssertEqual(
            staleConnection
                .unavailableCatalogKinds,
            [.tools])
        do {
            try await firstConnection.route
                .revalidate()
            XCTFail(
                "listChanged must stale the old tool route immediately")
        } catch let error as MCPConnectionError {
            XCTAssertEqual(
                error,
                .catalogKindStale(.tools))
        }

        let replacement = try makeCatalog(
            revision: "raw_catalog_2",
            fingerprint: "catalog_fingerprint_2",
            toolName: "replacement_tool")
        _ = try await runtime.refreshExisting(
            identity: identity,
            generation:
                firstConnection.bindingIdentity.connectionGeneration,
            revocationGeneration:
                firstConnection.bindingIdentity.revocationGeneration,
            callerFingerprint: "caller_refresh"
        ) {
            replacement
        }

        let latestAfterRefresh =
            await runtime.latestPublishedSnapshot(
                agentID: agent)
        let republished = try XCTUnwrap(
            latestAfterRefresh)
        let republishedConnection =
            try XCTUnwrap(
                republished.connections.first)
        XCTAssertGreaterThan(
            republished.publicationOrdinal,
            first.publicationOrdinal)
        XCTAssertNotEqual(
            republished.bindingID,
            first.bindingID)
        XCTAssertEqual(
            republishedConnection.catalog,
            replacement)
        XCTAssertEqual(
            republishedConnection.bindingIdentity
                .connectionGeneration,
            firstConnection.bindingIdentity
                .connectionGeneration)
        try await republishedConnection.route
            .revalidate()

        // The old value remains immutable and retains the old route rather
        // than silently consulting the current catalog.
        XCTAssertEqual(
            firstConnection.catalog.revision.rawValue,
            initialCatalogRevision(for: identity))
        XCTAssertEqual(
            firstConnection.catalog.items.map(\.remoteName),
            ["initial_tool"])
        do {
            try await firstConnection.route.revalidate()
            XCTFail("old route should be catalog-stale")
        } catch let error as MCPConnectionError {
            XCTAssertEqual(
                error,
                .staleCatalog(
                    expected: firstConnection.catalog.revision,
                    actual: replacement.revision))
        }

        let second = try await runtime.activate(
            makePlan(
                session: session,
                agent: agent,
                reason: .resume,
                requirements: [makeRequirement(identity)]))
        let secondConnection = try XCTUnwrap(second.connections.first)
        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(
            secondConnection.bindingIdentity.connectionGeneration,
            firstConnection.bindingIdentity.connectionGeneration)
        XCTAssertEqual(secondConnection.catalog, replacement)
        try await secondConnection.route.revalidate()
        _ = await runtime.shutdownAndDrain(reason: "test complete")
    }

    func testRefreshDiagnosticUsesExactSessionRedactor()
        async throws {
        let session =
            SessionID(
                rawValue:
                    "sess_refresh_redaction")
        let agent =
            AgentID(
                rawValue:
                    "agent_refresh_redaction")
        let identity = makeIdentity(
            session: session,
            agent: agent,
            serverID:
                "server_refresh_redaction")
        let secret =
            "opaque-refresh-secret"
        let redactor =
            MCPResolvedSecretRedactor()
        redactor.registerMCPSecretRedactionValue(
            secret)
        let audit = TestAuditSink()
        let runtime = MCPRuntime(
            sessionID: session,
            factory:
                TestMCPClientFactory(),
            hardGate: AllowHardGate(),
            consentSource:
                TestConsentSource(
                    consents: [
                        makeConsent(
                            for: identity),
                    ]),
            auditSink: audit,
            outputSanitizer:
                redactor)
        let active = try await runtime.activate(
            makePlan(
                session: session,
                agent: agent,
                reason: .send,
                requirements: [
                    makeRequirement(identity),
                ]))
        let connection =
            try XCTUnwrap(
                active.connections.first)

        do {
            _ = try await runtime
                .refreshExisting(
                    identity: identity,
                    generation:
                        connection
                            .bindingIdentity
                            .connectionGeneration,
                    revocationGeneration:
                        connection
                            .bindingIdentity
                            .revocationGeneration,
                    callerFingerprint:
                        "caller_refresh_redaction"
                ) {
                    throw TestClientError
                        .startup(
                            "server echoed \(secret)")
                }
            XCTFail(
                "injected refresh failure must fail")
        } catch {
            // The caller receives the original typed error; every durable
            // diagnostic must still use the session redactor.
        }
        let auditState =
            await audit.snapshot()
        let refreshSettlement =
            try XCTUnwrap(
                auditState.settlements
                    .last(where: {
                        $0.action == .refresh
                    }))
        let diagnostic =
            try XCTUnwrap(
                refreshSettlement.diagnostic)
        XCTAssertFalse(
            diagnostic.summary
                .contains(secret))
        XCTAssertTrue(
            diagnostic.summary
                .contains("[REDACTED]"))
        _ = await runtime.shutdownAndDrain(
            reason: "test complete")
    }

    func testRequiredFailureAggregatesFrozenViewAndProviderDispatchIsZero()
        async throws {
        let session = SessionID(rawValue: "sess_required")
        let agent = AgentID(rawValue: "agent_required")
        let definitionRequired = makeIdentity(
            session: session,
            agent: agent,
            serverID: "required_definition")
        let attachmentRequired = makeIdentity(
            session: session,
            agent: agent,
            serverID: "required_attachment")
        let optionalHealthy = makeIdentity(
            session: session,
            agent: agent,
            serverID: "optional_healthy")
        let factory = TestMCPClientFactory { identity, _ in
            if identity.server.serverID.rawValue.hasPrefix("required_") {
                return .failure("required startup failure")
            }
            return .success(
                try! makeInitialCatalog(for: identity),
                .init(.v2025_06_18),
                nil)
        }
        let identities = [
            definitionRequired,
            attachmentRequired,
            optionalHealthy,
        ]
        let runtime = makeRuntime(
            session: session,
            factory: factory,
            consentSource: TestConsentSource(
                consents: identities.map { makeConsent(for: $0) }),
            audit: TestAuditSink())
        let dispatchCounter = AsyncCounter()
        let plan = makePlan(
            session: session,
            agent: agent,
            reason: .send,
            requirements: [
                makeRequirement(
                    definitionRequired,
                    definitionRequired: true,
                    attachmentRequired: false),
                makeRequirement(
                    attachmentRequired,
                    definitionRequired: false,
                    attachmentRequired: true),
                makeRequirement(
                    optionalHealthy,
                    definitionRequired: false,
                    attachmentRequired: false),
            ])

        do {
            _ = try await runtime.withPreparedProviderDispatch(plan) {
                snapshot in
                await dispatchCounter.increment()
                return snapshot.connections.count
            }
            XCTFail("required startup failure should stop invocation")
        } catch let failure as MCPRequiredStartupFailure {
            XCTAssertEqual(failure.failures.count, 2)
            XCTAssertTrue(failure.failures.allSatisfy(\.required))
            XCTAssertEqual(failure.cliExitCode, 1)
            XCTAssertTrue(failure.providerDispatchMustRemainZero)
        }

        let dispatchCount = await dispatchCounter.value
        let latestSnapshot = await runtime.latestPublishedSnapshot()
        XCTAssertEqual(dispatchCount, 0)
        XCTAssertNil(latestSnapshot)
        _ = await runtime.shutdownAndDrain(reason: "test complete")
    }

    func testOptionalFailureIsDegradedButHealthyServerDispatches()
        async throws {
        let session = SessionID(rawValue: "sess_optional")
        let agent = AgentID(rawValue: "agent_optional")
        let requiredHealthy = makeIdentity(
            session: session,
            agent: agent,
            serverID: "required_healthy")
        let optionalFailure = makeIdentity(
            session: session,
            agent: agent,
            serverID: "optional_failure")
        let factory = TestMCPClientFactory { identity, _ in
            if identity.server.serverID.rawValue == "optional_failure" {
                return .failure("optional startup failure")
            }
            return .success(
                try! makeInitialCatalog(for: identity),
                .init(.v2025_06_18),
                nil)
        }
        let runtime = makeRuntime(
            session: session,
            factory: factory,
            consentSource: TestConsentSource(
                consents: [
                    makeConsent(for: requiredHealthy),
                    makeConsent(for: optionalFailure),
                ]),
            audit: TestAuditSink())
        let dispatchCounter = AsyncCounter()
        let result = try await runtime.withPreparedProviderDispatch(
            makePlan(
                session: session,
                agent: agent,
                reason: .send,
                requirements: [
                    makeRequirement(
                        requiredHealthy,
                        definitionRequired: true),
                    makeRequirement(optionalFailure),
                ])
        ) { snapshot in
            await dispatchCounter.increment()
            XCTAssertEqual(snapshot.connections.count, 1)
            XCTAssertEqual(snapshot.optionalFailures.count, 1)
            XCTAssertFalse(snapshot.optionalFailures[0].required)
            return snapshot.connections[0].reuseIdentity.server.serverID
        }

        XCTAssertEqual(result.rawValue, "required_healthy")
        let dispatchCount = await dispatchCounter.value
        XCTAssertEqual(dispatchCount, 1)
        _ = await runtime.shutdownAndDrain(reason: "test complete")
    }

    func testFrozenServerStartupRunsConcurrently() async throws {
        let session = SessionID(rawValue: "sess_parallel")
        let agent = AgentID(rawValue: "agent_parallel")
        let identities = (0..<4).map {
            makeIdentity(
                session: session,
                agent: agent,
                serverID: "parallel_\($0)")
        }
        let probe = StartupConcurrencyProbe()
        let factory = TestMCPClientFactory { identity, _ in
            .success(
                try! makeInitialCatalog(for: identity),
                .init(.v2025_06_18),
                probe)
        }
        let runtime = makeRuntime(
            session: session,
            factory: factory,
            consentSource: TestConsentSource(
                consents: identities.map { makeConsent(for: $0) }),
            audit: TestAuditSink())

        let snapshot = try await runtime.activate(
            makePlan(
                session: session,
                agent: agent,
                reason: .explicitConnect,
                requirements: identities.map { makeRequirement($0) }))
        XCTAssertEqual(snapshot.connections.count, identities.count)
        let maximumConcurrent = await probe.maximumConcurrent
        XCTAssertGreaterThanOrEqual(maximumConcurrent, 2)
        _ = await runtime.shutdownAndDrain(reason: "test complete")
    }

    func testColdRestoreAttachRetryTestLoginAndRefreshNeverConnect()
        async throws {
        let session = SessionID(rawValue: "sess_cold")
        let agent = AgentID(rawValue: "agent_cold")
        let identity = makeIdentity(
            session: session,
            agent: agent,
            serverID: "server_cold")
        let factory = TestMCPClientFactory()
        let runtime = makeRuntime(
            session: session,
            factory: factory,
            consentSource: TestConsentSource(
                consents: [makeConsent(for: identity)]),
            audit: TestAuditSink())

        try await runtime.reconcileColdRestore(
            MCPColdRestoreState(
                sessionID: session,
                records: [
                    MCPColdRestoreRecord(
                        server: identity.server,
                        attachmentID:
                            identity.authority.attachmentID,
                        historicalStatus: .interrupted,
                        lastGeneration:
                            MCPConnectionGeneration(
                                rawValue: "historical_generation"),
                        lastRawCatalogRevision:
                            MCPRawCatalogRevision(
                                rawValue: "historical_catalog")),
                ]))
        let restoredRecordCount =
            await runtime.restoredHistoricalState()?.records.count
        XCTAssertEqual(restoredRecordCount, 1)

        let forbidden: [MCPRuntimeActivationReason] = [
            .coldRestore, .restore, .attach, .retry, .test,
            .authenticate, .refresh,
        ]
        for reason in forbidden {
            do {
                _ = try await runtime.activate(
                    makePlan(
                        session: session,
                        agent: agent,
                        reason: reason,
                        requirements: [makeRequirement(identity)]))
                XCTFail("\(reason) must not connect")
            } catch let error as MCPRuntimeError {
                XCTAssertEqual(
                    error,
                    .activationDoesNotCreateConnection(reason))
            }
        }
        XCTAssertEqual(factory.creationCount, 0)
        _ = await runtime.shutdownAndDrain(reason: "test complete")
    }

    func testOnlySendResumeAndExplicitConnectActivateSessionConnections()
        async throws {
        let session = SessionID(rawValue: "sess_activation")
        let agent = AgentID(rawValue: "agent_activation")
        let identities = [
            makeIdentity(
                session: session,
                agent: agent,
                serverID: "send_server"),
            makeIdentity(
                session: session,
                agent: agent,
                serverID: "resume_server"),
            makeIdentity(
                session: session,
                agent: agent,
                serverID: "connect_server"),
        ]
        let factory = TestMCPClientFactory()
        let runtime = makeRuntime(
            session: session,
            factory: factory,
            consentSource: TestConsentSource(
                consents: identities.map { makeConsent(for: $0) }),
            audit: TestAuditSink())

        for (reason, identity) in zip(
            [
                MCPRuntimeActivationReason.send,
                .resume,
                .explicitConnect,
            ],
            identities
        ) {
            let snapshot = try await runtime.activate(
                makePlan(
                    session: session,
                    agent: agent,
                    reason: reason,
                    requirements: [makeRequirement(identity)]))
            XCTAssertEqual(snapshot.connections.count, 1)
        }
        XCTAssertEqual(factory.creationCount, 3)

        let before = factory.creationCount
        do {
            _ = try await runtime.withPreparedProviderDispatch(
                makePlan(
                    session: session,
                    agent: agent,
                    reason: .explicitConnect,
                    requirements: [makeRequirement(identities[2])])
            ) { _ in
                XCTFail("Connect must not dispatch provider")
                return ()
            }
            XCTFail("Connect must not dispatch provider")
        } catch let error as MCPRuntimeError {
            XCTAssertEqual(
                error,
                .activationDoesNotPermitProviderDispatch(
                    .explicitConnect))
        }
        XCTAssertEqual(factory.creationCount, before)
        _ = await runtime.shutdownAndDrain(reason: "test complete")
    }

    func testMissingOrMismatchedExactConsentFailsBeforeFactory()
        async throws {
        let session = SessionID(rawValue: "sess_consent")
        let agent = AgentID(rawValue: "agent_consent")
        let identity = makeIdentity(
            session: session,
            agent: agent,
            serverID: "server_consent")
        let factory = TestMCPClientFactory()
        let audit = TestAuditSink()
        let runtime = makeRuntime(
            session: session,
            factory: factory,
            consentSource: MismatchedConsentSource(
                consent: makeConsent(
                    for: copyIdentity(
                        identity,
                        environmentReference:
                            MCPEnvironmentReference(
                                rawValue: "other_environment")))),
            audit: audit)

        do {
            _ = try await runtime.activate(
                makePlan(
                    session: session,
                    agent: agent,
                    reason: .send,
                    requirements: [
                        makeRequirement(
                            identity,
                            definitionRequired: true),
                    ]))
            XCTFail("mismatched consent should fail")
        } catch let failure as MCPRequiredStartupFailure {
            XCTAssertEqual(failure.failures.count, 1)
            XCTAssertEqual(
                failure.failures[0].code,
                "control_plane_admission_failed")
        }
        XCTAssertEqual(factory.creationCount, 0)
        let auditState = await audit.snapshot()
        XCTAssertEqual(auditState.requests.count, 1)
        XCTAssertEqual(auditState.settlements.count, 1)
        XCTAssertEqual(auditState.settlements[0].status, .denied)
        _ = await runtime.shutdownAndDrain(reason: "test complete")
    }

    func testHardGateDenialFailsBeforeConsentAndFactory() async throws {
        let session = SessionID(rawValue: "sess_hard_gate")
        let agent = AgentID(rawValue: "agent_hard_gate")
        let identity = makeIdentity(
            session: session,
            agent: agent,
            serverID: "server_hard_gate")
        let factory = TestMCPClientFactory()
        let audit = TestAuditSink()
        let runtime = MCPRuntime(
            sessionID: session,
            factory: factory,
            hardGate: DenyHardGate(),
            consentSource: TestConsentSource(
                consents: [makeConsent(for: identity)]),
            auditSink: audit)

        do {
            _ = try await runtime.activate(
                makePlan(
                    session: session,
                    agent: agent,
                    reason: .send,
                    requirements: [
                        makeRequirement(
                            identity,
                            definitionRequired: true),
                    ]))
            XCTFail("hard gate should fail")
        } catch is MCPRequiredStartupFailure {
            // Expected aggregate required terminal.
        }
        XCTAssertEqual(factory.creationCount, 0)
        let auditState = await audit.snapshot()
        XCTAssertEqual(auditState.settlements.map(\.status), [.denied])
        _ = await runtime.shutdownAndDrain(reason: "test complete")
    }

    func testAdmissionSettlementFailureRetiresStartedGeneration()
        async throws {
        let session = SessionID(rawValue: "sess_audit_fail")
        let agent = AgentID(rawValue: "agent_audit_fail")
        let identity = makeIdentity(
            session: session,
            agent: agent,
            serverID: "server_audit_fail")
        let factory = TestMCPClientFactory()
        let audit = TestAuditSink(failAllSettlements: true)
        let runtime = makeRuntime(
            session: session,
            factory: factory,
            consentSource: TestConsentSource(
                consents: [makeConsent(for: identity)]),
            audit: audit)

        do {
            _ = try await runtime.activate(
                makePlan(
                    session: session,
                    agent: agent,
                    reason: .send,
                    requirements: [
                        makeRequirement(
                            identity,
                            definitionRequired: true),
                    ]))
            XCTFail("durable settlement failure must fail closed")
        } catch is MCPRequiredStartupFailure {
            // Expected.
        }
        XCTAssertEqual(factory.creationCount, 1)
        let clients = factory.allClients
        XCTAssertEqual(clients.count, 1)
        let clientOpen = await clients[0].isOpen()
        XCTAssertFalse(clientOpen)
        _ = await runtime.shutdownAndDrain(reason: "test complete")
    }

    func testExactSessionShutdownDrainsOnlyThatRuntime() async throws {
        let sessionA = SessionID(rawValue: "sess_shutdown_a")
        let sessionB = SessionID(rawValue: "sess_shutdown_b")
        let agent = AgentID(rawValue: "agent_shutdown")
        let identityA = makeIdentity(
            session: sessionA,
            agent: agent,
            serverID: "server_shutdown")
        let identityB = makeIdentity(
            session: sessionB,
            agent: agent,
            serverID: "server_shutdown")
        let factoryA = TestMCPClientFactory()
        let factoryB = TestMCPClientFactory()
        let runtimeA = makeRuntime(
            session: sessionA,
            factory: factoryA,
            consentSource: TestConsentSource(
                consents: [makeConsent(for: identityA)]),
            audit: TestAuditSink())
        let runtimeB = makeRuntime(
            session: sessionB,
            factory: factoryB,
            consentSource: TestConsentSource(
                consents: [makeConsent(for: identityB)]),
            audit: TestAuditSink())

        let snapshotA = try await runtimeA.activate(
            makePlan(
                session: sessionA,
                agent: agent,
                reason: .send,
                requirements: [makeRequirement(identityA)]))
        let snapshotB = try await runtimeB.activate(
            makePlan(
                session: sessionB,
                agent: agent,
                reason: .send,
                requirements: [makeRequirement(identityB)]))
        let reportA = await runtimeA.shutdownAndDrain(
            reason: "delete exact session A")
        XCTAssertTrue(reportA.fullyDrained)
        XCTAssertEqual(reportA.sessionID, sessionA)
        let clientAOpen = await factoryA.allClients[0].isOpen()
        let clientBOpen = await factoryB.allClients[0].isOpen()
        XCTAssertFalse(clientAOpen)
        XCTAssertTrue(clientBOpen)
        try await snapshotB.connections[0].route.revalidate()

        do {
            _ = try await runtimeA.activate(
                makePlan(
                    session: sessionA,
                    agent: agent,
                    reason: .send,
                    requirements: [makeRequirement(identityA)]))
            XCTFail("stopped runtime must reject new admission")
        } catch let error as MCPRuntimeError {
            XCTAssertEqual(error, .stopped)
        }

        do {
            try await snapshotA.connections[0].route.revalidate()
            XCTFail("session A route should be closed")
        } catch {
            // Any exact close fence is sufficient; it must not reroute to B.
        }
        _ = await runtimeB.shutdownAndDrain(reason: "test complete")
    }

    func testDuplicateFrozenRequirementFailsBeforeFactory() async throws {
        let session = SessionID(rawValue: "sess_duplicate")
        let agent = AgentID(rawValue: "agent_duplicate")
        let identity = makeIdentity(
            session: session,
            agent: agent,
            serverID: "server_duplicate")
        let factory = TestMCPClientFactory()
        let runtime = makeRuntime(
            session: session,
            factory: factory,
            consentSource: TestConsentSource(
                consents: [makeConsent(for: identity)]),
            audit: TestAuditSink())
        let requirement = makeRequirement(identity)

        do {
            _ = try await runtime.activate(
                makePlan(
                    session: session,
                    agent: agent,
                    reason: .send,
                    requirements: [requirement, requirement]))
            XCTFail("duplicate frozen server should fail")
        } catch let error as MCPRuntimeError {
            XCTAssertEqual(
                error,
                .duplicateFrozenServer(
                    server: identity.server,
                    attachmentID:
                        identity.authority.attachmentID))
        }
        XCTAssertEqual(factory.creationCount, 0)
        _ = await runtime.shutdownAndDrain(reason: "test complete")
    }
}

// MARK: - Test identities

private func makeIdentity(
    session: SessionID,
    agent: AgentID,
    serverID: String,
    serverRevision: String = "revision_1",
    transport: MCPTransportKind = .stdio,
    account: String? = nil,
    environment: String = "environment_1",
    launchArtifact: String? = "launch_1",
    workspace: String = "workspace_1",
    networkRevision: String = "network_1"
) -> MCPConnectionReuseIdentity {
    let server = MCPServerReference(
        serverID: MCPServerID(rawValue: serverID),
        serverRevision:
            MCPServerRevision(rawValue: serverRevision))
    let normalizedLaunch =
        transport == .stdio ? launchArtifact : nil
    let authority = makeAuthority(
        session: session,
        agent: agent,
        server: server,
        transport: transport,
        account: account,
        environment: environment,
        launchArtifact: normalizedLaunch,
        workspace: workspace,
        networkRevision: networkRevision)
    return MCPConnectionReuseIdentity(
        server: server,
        transport: transport,
        transportConfigurationFingerprint:
            "transport_\(serverID)_\(serverRevision)_\(transport.rawValue)",
        authority: authority,
        oauthAccountReference: account.map {
            MCPAccountReference(rawValue: $0)
        },
        environmentReference:
            MCPEnvironmentReference(rawValue: environment),
        launchArtifactFingerprint: normalizedLaunch,
        runtimeIdentityFingerprint:
            "runtime_\(transport.rawValue)_\(workspace)")
}

private func makeAuthority(
    session: SessionID,
    agent: AgentID,
    server: MCPServerReference,
    transport: MCPTransportKind,
    account: String?,
    environment: String,
    launchArtifact: String?,
    workspace: String,
    networkRevision: String
) -> MCPConnectionAuthority {
    let accountReference = account.map {
        MCPAccountReference(rawValue: $0)
    }
    return MCPConnectionAuthority(
        server: server,
        transport: transport,
        protocolProfile: .codexCompat,
        sessionID: session,
        agentID: agent,
        attachmentID:
            MCPAttachmentID(
                rawValue: "attachment_\(agent.rawValue)_\(server.serverID.rawValue)"),
        capabilityLeaseID:
            CapabilityLeaseID(
                rawValue: "capability_\(agent.rawValue)"),
        capabilityTaskID: nil,
        workspaceLeaseID:
            WorkspaceLeaseID(rawValue: workspace),
        workspaceRootIdentityFingerprint:
            "root_\(workspace)",
        workspaceLeasePolicyFingerprint:
            String(repeating: "a", count: 64),
        attachmentPolicyRevision:
            MCPPolicyRevision(rawValue: "attachment_policy_1"),
        accountReference: accountReference,
        environmentReference:
            MCPEnvironmentReference(rawValue: environment),
        launchArtifactFingerprint: launchArtifact,
        rootsPolicyRevision:
            MCPPolicyRevision(rawValue: "roots_\(workspace)"),
        networkPolicyRevision:
            MCPPolicyRevision(rawValue: networkRevision),
        sandboxProfileRevision:
            MCPPolicyRevision(rawValue: "sandbox_1"),
        sandboxPolicyFingerprint:
            String(repeating: "b", count: 64),
        hostPlatform: "test-host",
        fingerprint:
            [
                server.serverID.rawValue,
                server.serverRevision.rawValue,
                transport.rawValue,
                session.rawValue,
                agent.rawValue,
                workspace,
                networkRevision,
                account ?? "no-account",
                environment,
                launchArtifact ?? "no-launch",
            ].joined(separator: "|"))
}

private func copyIdentity(
    _ identity: MCPConnectionReuseIdentity,
    transport: MCPTransportKind? = nil,
    transportConfigurationFingerprint: String? = nil,
    authority: MCPConnectionAuthority? = nil,
    oauthAccountReference: MCPAccountReference?? = nil,
    environmentReference: MCPEnvironmentReference? = nil,
    launchArtifactFingerprint: String?? = nil,
    runtimeIdentityFingerprint: String? = nil
) -> MCPConnectionReuseIdentity {
    MCPConnectionReuseIdentity(
        server: identity.server,
        transport: transport ?? identity.transport,
        transportConfigurationFingerprint:
            transportConfigurationFingerprint
                ?? identity.transportConfigurationFingerprint,
        authority: authority ?? identity.authority,
        oauthAccountReference:
            oauthAccountReference ?? identity.oauthAccountReference,
        environmentReference:
            environmentReference ?? identity.environmentReference,
        launchArtifactFingerprint:
            launchArtifactFingerprint
                ?? identity.launchArtifactFingerprint,
        runtimeIdentityFingerprint:
            runtimeIdentityFingerprint
                ?? identity.runtimeIdentityFingerprint)
}

private func makeConsent(
    for identity: MCPConnectionReuseIdentity
) -> MCPConsent {
    let requirement = MCPConsentRequirement(identity: identity)
    return MCPConsent(
        consentID:
            MCPConsentID(
                rawValue:
                    "consent_\(identity.authority.fingerprint.hashValue)"),
        kind: requirement.kind,
        server: requirement.server,
        attachmentID: requirement.attachmentID,
        authorityFingerprint: requirement.authorityFingerprint,
        launchArtifactFingerprint:
            requirement.launchArtifactFingerprint,
        accountReference: requirement.accountReference,
        environmentReference: requirement.environmentReference,
        policyRevision: requirement.policyRevision)
}

private func makeRequirement(
    _ identity: MCPConnectionReuseIdentity,
    definitionRequired: Bool = false,
    attachmentRequired: Bool = false
) -> MCPInvocationServerRequirement {
    MCPInvocationServerRequirement(
        identity: identity,
        agentCatalogViewRevision:
            MCPAgentCatalogViewRevision(
                rawValue:
                    "view_\(identity.server.serverID.rawValue)"),
        revocationGeneration:
            MCPRevocationGeneration(rawValue: "revoke_1"),
        serverDefinitionRequired: definitionRequired,
        attachmentRequired: attachmentRequired,
        callerFingerprint:
            "caller_\(identity.authority.agentID.rawValue)")
}

private func makePlan(
    session: SessionID,
    agent: AgentID,
    reason: MCPRuntimeActivationReason,
    requirements: [MCPInvocationServerRequirement]
) -> MCPInvocationPlan {
    MCPInvocationPlan(
        sessionID: session,
        agentID: agent,
        activationReason: reason,
        servers: requirements)
}

private func makeCatalog(
    revision: String,
    fingerprint: String,
    toolName: String
) throws -> MCPCompleteCatalogSnapshot {
    try MCPCompleteCatalogSnapshot(
        revision: MCPRawCatalogRevision(rawValue: revision),
        catalogFingerprint: fingerprint,
        items: [
            MCPPublishedCatalogItem(
                kind: .tool,
                remoteName: toolName,
                identityFingerprint:
                    "item_\(fingerprint)_\(toolName)",
                schemaHash: "schema_\(toolName)"),
        ])
}

private func initialCatalogRevision(
    for identity: MCPConnectionReuseIdentity
) -> String {
    "raw_\(identity.server.serverID.rawValue)_\(identity.server.serverRevision.rawValue)"
}

private func makeInitialCatalog(
    for identity: MCPConnectionReuseIdentity
) throws -> MCPCompleteCatalogSnapshot {
    try makeCatalog(
        revision: initialCatalogRevision(for: identity),
        fingerprint:
            "catalog_\(identity.server.serverID.rawValue)_\(identity.server.serverRevision.rawValue)",
        toolName: "initial_tool")
}

private func makeRuntime(
    session: SessionID,
    factory: TestMCPClientFactory,
    consentSource: any MCPExactConsentSource,
    audit: TestAuditSink
) -> MCPRuntime {
    MCPRuntime(
        sessionID: session,
        factory: factory,
        hardGate: AllowHardGate(),
        consentSource: consentSource,
        auditSink: audit)
}

// MARK: - Test seams

private struct AllowHardGate: MCPControlPlaneHardGate {
    func evaluate(
        _: MCPControlPlaneAdmissionRequest
    ) async -> MCPControlPlaneHardGateDecision {
        .allow
    }
}

private struct DenyHardGate: MCPControlPlaneHardGate {
    func evaluate(
        _: MCPControlPlaneAdmissionRequest
    ) async -> MCPControlPlaneHardGateDecision {
        .deny(
            MCPDiagnosticSummary(
                code: "test_hard_deny",
                summary: "test hard gate denial"))
    }
}

private actor TestConsentSource: MCPExactConsentSource {
    private let consents: [MCPConsent]

    init(consents: [MCPConsent]) {
        self.consents = consents
    }

    func consent(
        matching requirement: MCPConsentRequirement
    ) async throws -> MCPConsent? {
        consents.first(where: requirement.exactlyMatches)
    }
}

private actor MismatchedConsentSource: MCPExactConsentSource {
    let storedConsent: MCPConsent

    init(consent: MCPConsent) {
        storedConsent = consent
    }

    func consent(
        matching _: MCPConsentRequirement
    ) async throws -> MCPConsent? {
        storedConsent
    }
}

private struct TestAuditSnapshot: Sendable {
    let requests: [MCPControlPlaneAdmissionRequest]
    let settlements: [MCPControlPlaneAdmissionSettlement]
}

private enum TestAuditError: Error, LocalizedError {
    case settlementFailed

    var errorDescription: String? {
        "injected audit settlement failure"
    }
}

private actor TestAuditSink: MCPControlPlaneAuditSink {
    private var requests: [MCPControlPlaneAdmissionRequest] = []
    private var settlements:
        [MCPControlPlaneAdmissionSettlement] = []
    private let failAllSettlements: Bool

    init(failAllSettlements: Bool = false) {
        self.failAllSettlements = failAllSettlements
    }

    func register(
        _ request: MCPControlPlaneAdmissionRequest
    ) async throws {
        requests.append(request)
    }

    func settle(
        _ settlement: MCPControlPlaneAdmissionSettlement
    ) async throws {
        guard !failAllSettlements else {
            throw TestAuditError.settlementFailed
        }
        settlements.append(settlement)
    }

    func snapshot() -> TestAuditSnapshot {
        TestAuditSnapshot(
            requests: requests,
            settlements: settlements)
    }
}

private enum TestClientBehavior: Sendable {
    case success(
        MCPCompleteCatalogSnapshot,
        MCPNegotiatedProtocolVersion,
        StartupConcurrencyProbe?
    )
    case failure(String)
}

private enum TestClientError: Error, LocalizedError {
    case startup(String)

    var errorDescription: String? {
        switch self {
        case .startup(let message):
            return message
        }
    }
}

private actor StartupConcurrencyProbe {
    private var active = 0
    private(set) var maximumConcurrent = 0

    func exercise() async {
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        try? await ContinuousClock().sleep(for: .milliseconds(40))
        active -= 1
    }
}

private actor TestMCPClient: MCPConnectionClient {
    let generation: MCPConnectionGeneration
    let behavior: TestClientBehavior
    private var open = false

    init(
        generation: MCPConnectionGeneration,
        behavior: TestClientBehavior
    ) {
        self.generation = generation
        self.behavior = behavior
    }

    func startup(
        profile _: MCPProtocolProfile,
        maximumProtocolVersion _: MCPProtocolVersion
    ) async throws -> MCPConnectionStartupResult {
        switch behavior {
        case .failure(let message):
            throw TestClientError.startup(message)
        case .success(
            let catalog,
            let negotiatedProtocolVersion,
            let probe
        ):
            if let probe {
                await probe.exercise()
            }
            open = true
            return MCPConnectionStartupResult(
                negotiatedProtocolVersion:
                    negotiatedProtocolVersion,
                catalog: catalog)
        }
    }

    func isOpen() async -> Bool {
        open
    }

    func shutdownAndDrain(reason _: String) async {
        open = false
    }

    func forceClosed() {
        open = false
    }
}

private final class TestMCPClientFactory:
    MCPConnectionClientFactory, @unchecked Sendable {
    typealias BehaviorFactory = @Sendable (
        MCPConnectionReuseIdentity,
        MCPConnectionGeneration
    ) -> TestClientBehavior

    private let lock = NSLock()
    private var clients:
        [MCPConnectionGeneration: TestMCPClient] = [:]
    private let behaviorFactory: BehaviorFactory

    init(
        behaviorFactory: @escaping BehaviorFactory = {
            identity, _ in
            .success(
                try! makeInitialCatalog(for: identity),
                .init(.v2025_06_18),
                nil)
        }
    ) {
        self.behaviorFactory = behaviorFactory
    }

    func makeClient(
        identity: MCPConnectionReuseIdentity,
        generation: MCPConnectionGeneration
    ) throws -> any MCPConnectionClient {
        let client = TestMCPClient(
            generation: generation,
            behavior: behaviorFactory(identity, generation))
        lock.lock()
        clients[generation] = client
        lock.unlock()
        return client
    }

    var creationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count
    }

    var allClients: [TestMCPClient] {
        lock.lock()
        defer { lock.unlock() }
        return clients.keys.sorted {
            $0.rawValue < $1.rawValue
        }.compactMap { clients[$0] }
    }

    func client(
        _ generation: MCPConnectionGeneration
    ) -> TestMCPClient? {
        lock.lock()
        defer { lock.unlock() }
        return clients[generation]
    }
}

private actor AsyncCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private func publicationConfiguration(
    name: String
) throws -> MCPServerConfiguration {
    try MCPServerConfiguration(
        serverID:
            MCPServerID(
                rawValue:
                    "mcpserver_publication"),
        displayName: name,
        approvalPolicy:
            MCPApprovalPolicy(serverDefault: .prompt),
        timeouts: MCPServerTimeouts(),
        filters: MCPServerFilters(),
        transport: .streamableHTTP(
            try MCPHTTPServerConfiguration(
                endpoint:
                    "https://publication.example/mcp")),
        environmentReference:
            MCPEnvironmentReference(
                rawValue: "mcpenv_publication"),
        provenance: MCPConfigurationProvenance(
            sourceKind: .intatisUser,
            sourceLabel: "publication-tests"))
}

private func publicationPrepared(
    name: String,
    catalog: MCPServerCatalog
) throws -> MCPPreparedServerConfiguration {
    try MCPPreparedServerConfiguration.plan(
        alias: "publication",
        staging: MCPConfigurationStaging(
            configuration:
                publicationConfiguration(name: name)),
        catalog: catalog)
}

private func publicationProof(
    _ prepared: MCPPreparedServerConfiguration
) throws -> MCPPreparedConfigurationTestProof {
    try prepared.accept(
        MCPConfigurationTestResult(
            challenge: prepared.staging.challenge,
            terminal: .succeeded,
            testedIdentityFingerprint:
                prepared.staging
                    .expectedTestedIdentityFingerprint,
            sanitizedReasonCode: "ok"))
}

private final class PublicationFactoryProbe:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var factories:
        [UInt64: TestMCPClientFactory] = [:]

    func build(
        _ catalog: MCPServerCatalog
    ) -> any MCPConnectionClientFactory {
        lock.lock()
        defer { lock.unlock() }
        if let existing =
                factories[catalog.generation] {
            return existing
        }
        let factory = TestMCPClientFactory {
            identity, _ in
            .success(
                try! makeCatalog(
                    revision:
                        "raw_global_\(catalog.generation)",
                    fingerprint:
                        "catalog_global_\(catalog.contentDigest)",
                    toolName:
                        "tool_generation_\(catalog.generation)"),
                .init(.v2025_06_18),
                nil)
        }
        factories[catalog.generation] = factory
        return factory
    }

    func creations(generation: UInt64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return factories[generation]?.creationCount ?? 0
    }
}

private actor PublicationConsentRevokerProbe:
    MCPCatalogConsentRevoker
{
    private(set) var revocations:
        [MCPCatalogReferenceRevocation] = []

    func revokeConsents(
        _ revocations:
            [MCPCatalogReferenceRevocation]
    ) {
        self.revocations.append(
            contentsOf: revocations)
    }
}

extension MCPRuntimeAuthorityTests {
    func testCredentialRevocationDrainsRoutesAndRevokesConsent()
        async throws
    {
        let root =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "intatis-credential-revocation-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let store = MCPServerCatalogStore(
            fileURL:
                root.appendingPathComponent(
                    "catalog.json"))
        let prepared = try publicationPrepared(
            name: "Credential Authority",
            catalog: try await store.load())
        let catalog = try await store.savePrepared(
            prepared,
            proof: publicationProof(prepared)).catalog
        let factories = PublicationFactoryProbe()
        let publication =
            try MCPProductionCatalogPublication(
                initialCatalog: catalog,
                buildFactory: {
                    factories.build($0)
                })
        let session =
            SessionID(
                rawValue:
                    "sess_credential_revocation")
        let identity = makeIdentity(
            session: session,
            agent:
                AgentID(
                    rawValue:
                        "agent_credential_revocation"),
            serverID:
                prepared.expectedServerReference
                    .serverID.rawValue,
            serverRevision:
                prepared.expectedServerReference
                    .serverRevision.rawValue,
            transport: .streamableHTTP,
            launchArtifact: nil)
        let owner = MCPSessionRuntimeOwner(
            sessionID: session,
            catalogPublication: publication,
            hardGate: AllowHardGate(),
            consentSource:
                TestConsentSource(
                    consents: [
                        makeConsent(for: identity),
                    ]),
            auditSink: TestAuditSink())
        let revoker =
            PublicationConsentRevokerProbe()
        let registry =
            MCPProcessCatalogRuntimeRegistry()
        await registry.register(
            sessionID: session,
            owner: owner,
            publication: publication,
            consentRevoker: revoker)
        let snapshot = try await owner.activate(
            MCPInvocationPlan(
                sessionID: session,
                agentID:
                    identity.authority.agentID,
                activationReason: .send,
                catalogPublication:
                    MCPCatalogPublicationIdentity(
                        catalog: catalog),
                servers: [
                    makeRequirement(identity),
                ]))
        let route = try XCTUnwrap(
            snapshot.connections.first?.route)
        try await route.revalidate()

        try await registry
            .revokeCredentialAuthority(
                prepared.expectedServerReference)
        do {
            try await route.revalidate()
            XCTFail("credential-revoked route remained usable")
        } catch {
            // Exact generation was retired before this call can continue.
        }
        let live =
            await owner.liveConnectionSnapshots()
        XCTAssertTrue(live.isEmpty)
        let revoked = await revoker.revocations
        XCTAssertEqual(
            revoked.map(\.reason),
            [.credentialChanged])
        _ = await owner.shutdown(
            reason: "test complete")
        await registry.unregister(
            sessionID: session)
    }

    func testAtomicCatalogPublicationHotReloadAndOldNewIsolation()
        async throws
    {
        let root =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "intatis-publication-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let store = MCPServerCatalogStore(
            fileURL:
                root.appendingPathComponent(
                    "catalog.json"))
        let firstPrepared = try publicationPrepared(
            name: "First",
            catalog: try await store.load())
        let firstReceipt =
            try await store.savePrepared(
                firstPrepared,
                proof:
                    publicationProof(firstPrepared))
        let firstCatalog = firstReceipt.catalog
        let secondPrepared = try publicationPrepared(
            name: "Second",
            catalog: firstCatalog)
        let secondReceipt =
            try await store.savePrepared(
                secondPrepared,
                proof:
                    publicationProof(secondPrepared))
        let secondCatalog = secondReceipt.catalog

        let factories = PublicationFactoryProbe()
        let publication =
            try MCPProductionCatalogPublication(
                initialCatalog: firstCatalog,
                buildFactory: {
                    factories.build($0)
                })
        let session =
            SessionID(
                rawValue:
                    "sess_catalog_publication")
        let agent =
            AgentID(
                rawValue:
                    "agent_catalog_publication")
        let firstIdentity = makeIdentity(
            session: session,
            agent: agent,
            serverID:
                firstPrepared.expectedServerReference
                    .serverID.rawValue,
            serverRevision:
                firstPrepared.expectedServerReference
                    .serverRevision.rawValue,
            transport: .streamableHTTP,
            launchArtifact: nil)
        let secondIdentity = makeIdentity(
            session: session,
            agent: agent,
            serverID:
                secondPrepared.expectedServerReference
                    .serverID.rawValue,
            serverRevision:
                secondPrepared.expectedServerReference
                    .serverRevision.rawValue,
            transport: .streamableHTTP,
            launchArtifact: nil)
        let owner = MCPSessionRuntimeOwner(
            sessionID: session,
            catalogPublication: publication,
            hardGate: AllowHardGate(),
            consentSource: TestConsentSource(
                consents: [
                    makeConsent(for: firstIdentity),
                    makeConsent(for: secondIdentity),
                ]),
            auditSink: TestAuditSink())
        let registry =
            MCPProcessCatalogRuntimeRegistry()
        let revoker =
            PublicationConsentRevokerProbe()
        await registry.register(
            sessionID: session,
            owner: owner,
            publication: publication,
            consentRevoker: revoker)

        let first = try await owner.activate(
            MCPInvocationPlan(
                sessionID: session,
                agentID: agent,
                activationReason: .send,
                catalogPublication:
                    MCPCatalogPublicationIdentity(
                        catalog: firstCatalog),
                servers: [
                    makeRequirement(firstIdentity),
                ]))
        let oldRoute = try XCTUnwrap(
            first.connections.first?.route)
        try await oldRoute.revalidate()
        XCTAssertEqual(
            factories.creations(generation: 1),
            1)

        let report = try await registry.publish(
            secondCatalog)
        XCTAssertEqual(
            report.sessionDiffs[session]?
                .revocations.map(\.reference),
            [firstPrepared.expectedServerReference])
        do {
            try await oldRoute.revalidate()
            XCTFail("old route survived current-revision change")
        } catch {
            // Any retired/stale revocation terminal is fail-closed.
        }
        let recorded =
            await revoker.revocations
        XCTAssertEqual(
            recorded.map(\.reference),
            [firstPrepared.expectedServerReference])

        let second = try await owner.activate(
            MCPInvocationPlan(
                sessionID: session,
                agentID: agent,
                activationReason: .send,
                catalogPublication:
                    MCPCatalogPublicationIdentity(
                        catalog: secondCatalog),
                servers: [
                    makeRequirement(secondIdentity),
                ]))
        XCTAssertEqual(
            second.connections.first?
                .reuseIdentity.server,
            secondPrepared.expectedServerReference)
        XCTAssertEqual(
            factories.creations(generation: 2),
            1)
        let secondRoute = try XCTUnwrap(
            second.connections.first?.route)
        let disabled = try await store.setDisabled(
            serverID:
                secondPrepared.expectedServerReference
                    .serverID,
            disabled: true,
            expectedGeneration:
                secondCatalog.generation)
        _ = try await registry.publish(disabled)
        do {
            try await secondRoute.revalidate()
            XCTFail("disabled revision route remained usable")
        } catch {
            // The route is fenced before another remote call can start.
        }
        let reenabled = try await store.setDisabled(
            serverID:
                secondPrepared.expectedServerReference
                    .serverID,
            disabled: false,
            expectedGeneration:
                disabled.generation)
        _ = try await registry.publish(reenabled)
        let reconnected = try await owner.activate(
            MCPInvocationPlan(
                sessionID: session,
                agentID: agent,
                activationReason: .send,
                catalogPublication:
                    MCPCatalogPublicationIdentity(
                        catalog: reenabled),
                servers: [
                    makeRequirement(secondIdentity),
                ]))
        let tombstoneRoute = try XCTUnwrap(
            reconnected.connections.first?.route)
        let tombstoned = try await store.tombstone(
            secondPrepared.expectedServerReference,
            reason: .userDelete,
            expectedGeneration:
                reenabled.generation)
        _ = try await registry.publish(tombstoned)
        do {
            try await tombstoneRoute.revalidate()
            XCTFail("tombstoned revision route remained usable")
        } catch {
            // The exact tombstoned reference is fenced immediately.
        }
        let live =
            await owner.liveConnectionSnapshots()
        XCTAssertTrue(live.isEmpty)
        _ = await owner.shutdown(
            reason: "test complete")
        await registry.unregister(sessionID: session)
    }

    func testCatalogPublicationRejectsHalfAndRegressedCatalogs()
        async throws
    {
        let root =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "intatis-publication-race-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let store = MCPServerCatalogStore(
            fileURL:
                root.appendingPathComponent(
                    "catalog.json"))
        let first = try publicationPrepared(
            name: "One",
            catalog: try await store.load())
        let catalog1 = try await store.savePrepared(
            first,
            proof: publicationProof(first)).catalog
        let second = try publicationPrepared(
            name: "Two",
            catalog: catalog1)
        let catalog2 = try await store.savePrepared(
            second,
            proof: publicationProof(second)).catalog
        let third = try publicationPrepared(
            name: "Three",
            catalog: catalog2)
        let catalog3 = try await store.savePrepared(
            third,
            proof: publicationProof(third)).catalog
        let probe = PublicationFactoryProbe()
        let publication =
            try MCPProductionCatalogPublication(
                initialCatalog: catalog1,
                buildFactory: { probe.build($0) })

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try? await publication.publish(
                    catalog2)
            }
            group.addTask {
                _ = try? await publication.publish(
                    catalog3)
            }
        }
        let observed =
            try await publication.snapshot()
        XCTAssertEqual(
            observed.publication,
            MCPCatalogPublicationIdentity(
                catalog: observed.catalog))
        XCTAssertTrue(
            observed.catalog == catalog2
                || observed.catalog == catalog3)
        if observed.catalog == catalog2 {
            _ = try await publication.publish(catalog3)
        }
        let final =
            try await publication.snapshot()
        XCTAssertEqual(final.catalog, catalog3)
        do {
            _ = try await publication.publish(catalog1)
            XCTFail("regressed catalog unexpectedly published")
        } catch let error as MCPCatalogPublicationError {
            XCTAssertEqual(
                error,
                .generationRegressed(
                    expectedAtLeast:
                        catalog3.generation,
                    actual:
                        catalog1.generation))
        }
    }

    func testLiveSnapshotsKeepSameServerAcrossAgents()
        async throws
    {
        let session =
            SessionID(rawValue:
                "sess_live_multi_agent")
        let identityA = makeIdentity(
            session: session,
            agent:
                AgentID(rawValue: "agent_live_a"),
            serverID: "server_live_multi")
        let identityB = makeIdentity(
            session: session,
            agent:
                AgentID(rawValue: "agent_live_b"),
            serverID: "server_live_multi")
        let runtime = makeRuntime(
            session: session,
            factory: TestMCPClientFactory(),
            consentSource: TestConsentSource(
                consents: [
                    makeConsent(for: identityA),
                    makeConsent(for: identityB),
                ]),
            audit: TestAuditSink())
        _ = try await runtime.activate(
            makePlan(
                session: session,
                agent:
                    identityA.authority.agentID,
                reason: .send,
                requirements: [
                    makeRequirement(identityA),
                ]))
        _ = try await runtime.activate(
            makePlan(
                session: session,
                agent:
                    identityB.authority.agentID,
                reason: .send,
                requirements: [
                    makeRequirement(identityB),
                ]))
        let live =
            await runtime.liveConnectionSnapshots()
        XCTAssertEqual(live.count, 2)
        XCTAssertEqual(
            Set(live.map {
                $0.reuseIdentity.authority.agentID
            }),
            [
                identityA.authority.agentID,
                identityB.authority.agentID,
            ])
        _ = await runtime.shutdownAndDrain(
            reason: "test complete")
    }
}
