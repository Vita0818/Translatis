import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisMCP
import MCP
@testable import IntatisAgentKernel

private enum MCPRegistryFixtureError: Error {
    case payloadMissing
}

private actor MCPRegistryEventSink: MCPBrokerEventSink {
    func appendMCPBrokerEvent(_: Event) async throws {}
    func appendMCPBrokerEvents(_: [Event]) async throws {}
}

private actor MCPRegistryPayloadStore: MCPBrokerPayloadStore {
    private var values: [MCPResultReference: (String, Data)] = [:]

    func store(
        _ payload: Data,
        scopeFingerprint: String
    ) async throws -> MCPResultReference {
        let reference = MCPResultReference.new()
        values[reference] = (scopeFingerprint, payload)
        return reference
    }

    func resolve(
        _ reference: MCPResultReference,
        scopeFingerprint: String
    ) async throws -> Data {
        guard let value = values[reference],
              value.0 == scopeFingerprint else {
            throw MCPRegistryFixtureError.payloadMissing
        }
        return value.1
    }

    func remove(
        _ reference: MCPResultReference,
        scopeFingerprint: String
    ) async throws {
        guard let value = values[reference],
              value.0 == scopeFingerprint else {
            throw MCPRegistryFixtureError.payloadMissing
        }
        values.removeValue(forKey: reference)
    }
}

private actor MCPRegistryExpiryRecorder {
    private var invocations = 0

    func record() {
        invocations += 1
    }

    func count() -> Int {
        invocations
    }
}

private actor MCPRegistryNotificationRecorder:
    MCPCatalogNotificationSink
{
    struct ResourceUpdate: Equatable {
        let server: MCPServerReference
        let generation: MCPConnectionGeneration
        let uri: String
    }

    private var resourceUpdates: [ResourceUpdate] = []

    func catalogListChanged(
        server _: MCPServerReference,
        generation _: MCPConnectionGeneration,
        kind _: MCPCatalogChangeKind
    ) async {}

    func subscribedResourceUpdated(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        uri: String
    ) async {
        resourceUpdates.append(.init(
            server: server,
            generation: generation,
            uri: uri))
    }

    func updates() -> [ResourceUpdate] {
        resourceUpdates
    }
}

private struct MCPRegistryFixture {
    let definition: MCPServerDefinition
    let prepared: MCPPreparedAgentDispatch
    let identity: MCPConnectionReuseIdentity
    let generation: MCPConnectionGeneration

    static func make(
        expiresAt: Date? = nil,
        legacyAuthority: Bool = false
    ) throws -> MCPRegistryFixture {
        let configuration = try MCPServerConfiguration(
            serverID: MCPServerID(
                rawValue: "mcpserver_registry"),
            displayName: "Registry Fixture",
            protocolProfile: .standardExtended,
            approvalPolicy: MCPApprovalPolicy(
                serverDefault: .auto),
            timeouts: MCPServerTimeouts(),
            filters: MCPServerFilters(),
            transport: .streamableHTTP(
                try MCPHTTPServerConfiguration(
                    endpoint:
                        "https://example.com/mcp")),
            environmentReference:
                MCPEnvironmentReference(
                    rawValue: "env_registry"),
            provenance: MCPConfigurationProvenance(
                sourceKind: .intatisUser,
                sourceLabel: "registry-fixture"))
        let definition =
            try MCPServerDefinition.isolatedTest(
                configuration: configuration)
        let sessionID =
            SessionID(rawValue: "session_registry")
        let agentID =
            AgentID(rawValue: "agent_registry")
        let taskID =
            TaskID(rawValue: "task_registry")
        let capabilityLeaseID =
            CapabilityLeaseID(
                rawValue: "capability_registry")
        let policyRevision =
            MCPPolicyRevision(
                rawValue: "policy_registry")
        let revocationGeneration =
            MCPRevocationGeneration(
                rawValue: "revocation_registry")
        let attachment = MCPServerAttachment(
            attachmentID: MCPAttachmentID(
                rawValue: "attachment_registry"),
            server: definition.reference,
            policy: MCPAttachmentPolicy(
                revision: policyRevision,
                approvalMode: .auto,
                filter: MCPCatalogFilter(
                    revision: policyRevision)),
            source: .user)
        let workspacePolicy =
            MCPConnectionIdentityBuilder
                .workspaceLeasePolicyFingerprint(nil)
        let sandboxPolicy =
            MCPConnectionIdentityBuilder
                .sandboxPolicyFingerprint(
                    hostProfile: .macDeveloperID,
                    transport: .streamableHTTP,
                    sandboxProfileRevision:
                        policyRevision,
                    networkPolicyRevision:
                        policyRevision,
                    workspaceLeasePolicyFingerprint:
                        workspacePolicy)
        let built =
            try MCPConnectionIdentityBuilder.build(
                definition: definition,
                inputs:
                    MCPConnectionAuthorityInputs(
                        sessionID: sessionID,
                        agentID: agentID,
                        attachment: attachment,
                        capabilityLeaseID:
                            capabilityLeaseID,
                        capabilityTaskID: taskID,
                        workspaceLeasePolicyFingerprint:
                            workspacePolicy,
                        rootsPolicyRevision:
                            policyRevision,
                        networkPolicyRevision:
                            policyRevision,
                        sandboxProfileRevision:
                            policyRevision,
                        sandboxPolicyFingerprint:
                            sandboxPolicy,
                        revocationGeneration:
                            revocationGeneration,
                        hostProfile:
                            .macDeveloperID,
                        runtimeIdentityFingerprint:
                            String(
                                repeating: "f",
                                count: 64)))

        let requirement:
            MCPInvocationServerRequirement
        if legacyAuthority {
            let legacyAuthority =
                try Self.legacy(
                    built.identity.authority)
            let legacyIdentity =
                MCPConnectionReuseIdentity(
                    server: built.identity.server,
                    transport:
                        built.identity.transport,
                    transportConfigurationFingerprint:
                        built.identity
                            .transportConfigurationFingerprint,
                    authority: legacyAuthority,
                    oauthAccountReference:
                        built.identity
                            .oauthAccountReference,
                    environmentReference:
                        built.identity
                            .environmentReference,
                    launchArtifactFingerprint:
                        built.identity
                            .launchArtifactFingerprint,
                    runtimeIdentityFingerprint:
                        built.identity
                            .runtimeIdentityFingerprint)
            requirement =
                MCPInvocationServerRequirement(
                    identity: legacyIdentity,
                    agentCatalogViewRevision:
                        built
                            .agentCatalogViewRevision,
                    revocationGeneration:
                        built.revocationGeneration,
                    serverDefinitionRequired:
                        built.serverDefinitionRequired,
                    attachmentRequired:
                        built.attachmentRequired,
                    callerFingerprint:
                        built.callerFingerprint)
        } else {
            requirement = built
        }

        let grant = MCPGrant(
            grantID:
                MCPGrantID(
                    rawValue: "grant_registry"),
            attachmentID:
                attachment.attachmentID,
            server: definition.reference,
            agentID: agentID,
            capabilityLeaseID:
                capabilityLeaseID,
            taskID: taskID,
            capabilities:
                [.resources, .subscriptions],
            filter: MCPCatalogFilter(
                revision: policyRevision),
            approvalModeCeiling: .auto,
            authorityFingerprint:
                requirement.identity
                    .authority.fingerprint,
            grantFingerprint:
                String(repeating: "e", count: 64),
            revocationGeneration:
                revocationGeneration,
            expiresAt: expiresAt)
        let capabilityLease = CapabilityLease(
            id: capabilityLeaseID,
            taskID: taskID,
            tools: [],
            mcpGrants: [grant])
        let plan = MCPInvocationPlan(
            invocationID:
                MCPInvocationID(
                    rawValue: "invocation_registry"),
            sessionID: sessionID,
            agentID: agentID,
            activationReason: .send,
            servers: [requirement])
        return MCPRegistryFixture(
            definition: definition,
            prepared: MCPPreparedAgentDispatch(
                plan: plan,
                capabilityLease:
                    capabilityLease,
                policies: []),
            identity: requirement.identity,
            generation:
                MCPConnectionGeneration(
                    rawValue: "generation_registry"))
    }

    private static func legacy(
        _ authority: MCPConnectionAuthority
    ) throws -> MCPConnectionAuthority {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    authority))
                as? [String: Any])
        object["schemaVersion"] = 1
        object.removeValue(
            forKey: "capabilityTaskID")
        object.removeValue(
            forKey:
                "workspaceLeasePolicyFingerprint")
        object.removeValue(
            forKey: "sandboxPolicyFingerprint")
        return try JSONDecoder().decode(
            MCPConnectionAuthority.self,
            from: JSONSerialization.data(
                withJSONObject: object))
    }
}

final class MCPShippingConnectionServicesRegistryTests:
    XCTestCase
{
    func testRegisterAndProviderRequireCurrentExecutionAuthority()
        async throws
    {
        let registry = Self.makeRegistry()
        let current = try MCPRegistryFixture.make()
        try await registry.register(
            prepared: current.prepared,
            workspaceLease: nil)
        let services = try registry.provider()(
            current.definition,
            current.identity,
            current.generation)
        XCTAssertNotNil(
            services.catalogNotificationSink)
        XCTAssertTrue(
            services.callbackCapabilities.isEmpty)
        XCTAssertNil(
            services.inboundServicesFactory,
            "A tools/resources-only authority must not install a callback factory for an empty advertised callback surface.")
        let notificationSink = try XCTUnwrap(
            services.inboundNotificationSink)
        await notificationSink
            .receiveMCPInboundNotification(
                .log(MCPInboundLogRecord(
                    authority:
                        MCPCallbackAuthorityContext(
                            server:
                                current.identity.server,
                            connectionGeneration:
                                current.generation,
                            authorityFingerprint:
                                current.identity
                                    .authority
                                    .fingerprint,
                            profile:
                                .standardExtended),
                    level: .warning,
                    logger: "registry",
                    dataSummary: "\"bounded\"")))
        let inboundDiagnostics =
            await registry
                .inboundNotificationStore
                .inboundDiagnosticsSnapshot()
        XCTAssertEqual(
            inboundDiagnostics.map(\.code),
            ["mcp_server_log_warning"])

        let legacy =
            try MCPRegistryFixture.make(
                legacyAuthority: true)
        do {
            try await registry.register(
                prepared: legacy.prepared,
                workspaceLease: nil)
            XCTFail(
                "Legacy MCP authority must remain audit-only")
        } catch {
            XCTAssertFalse(
                legacy.identity.authority
                    .hasCurrentExecutionAuthority)
        }

        await registry.shutdownAndDrain()
    }

    func testShutdownAndDrainIsIdempotentAndClosesAdmission()
        async throws
    {
        let registry = Self.makeRegistry()
        let fixture = try MCPRegistryFixture.make()
        try await registry.register(
            prepared: fixture.prepared,
            workspaceLease: nil)
        let capturedProvider = registry.provider()
        _ = try capturedProvider(
            fixture.definition,
            fixture.identity,
            fixture.generation)

        async let first: Void =
            registry.shutdownAndDrain()
        async let second: Void =
            registry.shutdownAndDrain()
        _ = await (first, second)

        do {
            try await registry.register(
                prepared: fixture.prepared,
                workspaceLease: nil)
            XCTFail(
                "Registration after shutdown must fail")
        } catch {}

        XCTAssertThrowsError(
            try capturedProvider(
                fixture.definition,
                fixture.identity,
                fixture.generation))

        await registry.shutdownAndDrain()
    }

    func testShutdownDrainsAnExpiryRaceBeforeReturning()
        async throws
    {
        let registry = Self.makeRegistry()
        let expiry = MCPRegistryExpiryRecorder()
        let fixture = try MCPRegistryFixture.make(
            expiresAt: Date().addingTimeInterval(
                0.05))
        try await registry.register(
            prepared: fixture.prepared,
            workspaceLease: nil,
            expiryHandler: { _, _ in
                await expiry.record()
            })

        try await Task.sleep(
            for: .milliseconds(40))
        await registry.shutdownAndDrain()
        let countAtShutdown =
            await expiry.count()
        try await Task.sleep(
            for: .milliseconds(50))
        let countAfterDelay =
            await expiry.count()
        XCTAssertEqual(
            countAfterDelay,
            countAtShutdown,
            "No expiry callback may escape shutdownAndDrain")
    }

    func testGenerationRouterDropsOldAndPostShutdownNotifications()
        async throws
    {
        let registry = Self.makeRegistry()
        let fixture = try MCPRegistryFixture.make()
        try await registry.register(
            prepared: fixture.prepared,
            workspaceLease: nil)
        let services = try registry.provider()(
            fixture.definition,
            fixture.identity,
            fixture.generation)
        let router = try XCTUnwrap(
            services.catalogNotificationSink)
        let recorder =
            MCPRegistryNotificationRecorder()
        await registry
            .installSubscriptionNotificationSink(
                recorder)

        let oldGeneration =
            MCPConnectionGeneration(
                rawValue: "generation_registry_old")
        await router.subscribedResourceUpdated(
            server: fixture.identity.server,
            generation: oldGeneration,
            uri: "file:///old")
        await router.subscribedResourceUpdated(
            server: fixture.identity.server,
            generation: fixture.generation,
            uri: "file:///current")
        let currentUpdates =
            await recorder.updates()
        XCTAssertEqual(
            currentUpdates,
            [
                .init(
                    server: fixture.identity.server,
                    generation:
                        fixture.generation,
                    uri: "file:///current"),
            ])

        await registry.shutdownAndDrain()
        await router.subscribedResourceUpdated(
            server: fixture.identity.server,
            generation: fixture.generation,
            uri: "file:///after-shutdown")
        let postShutdownUpdates =
            await recorder.updates()
        XCTAssertEqual(
            postShutdownUpdates.count,
            1)
    }

    private static func makeRegistry()
        -> MCPShippingConnectionServicesRegistry
    {
        MCPShippingConnectionServicesRegistry(
            events: MCPRegistryEventSink(),
            payloadStore:
                MCPRegistryPayloadStore())
    }
}
