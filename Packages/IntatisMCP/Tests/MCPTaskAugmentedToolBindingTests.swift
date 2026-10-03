import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisMCP

final class MCPTaskAugmentedToolBindingTests: XCTestCase {
    func testRequiredTaskUsesExactTaskPathAndCarriesTTLAndCallID()
        async throws {
        let fixture = try await makeTaskBindingFixture(
            profile: .standardExtended,
            serverSupportsToolCallTasks: true)

        let result = try await fixture.route.callToolResolved(
            remoteName: "long_running",
            arguments: ["query": .string("swift")],
            toolTaskSupport: .required,
            preference: .automatic,
            ttlMilliseconds: 42_000,
            originatingToolCallID: "tool-call-required",
            timeoutMilliseconds: 500)

        XCTAssertEqual(result.content, [.text("task-result")])
        let calls = await fixture.client.recordedCalls()
        XCTAssertEqual(calls.ordinary, 0)
        XCTAssertEqual(calls.task, 1)
        XCTAssertEqual(calls.ttlMilliseconds, 42_000)
        XCTAssertEqual(calls.originatingToolCallID, "tool-call-required")
    }

    func testOptionalTaskAutomaticUsesOrdinaryPath()
        async throws {
        let fixture = try await makeTaskBindingFixture(
            profile: .standardExtended,
            serverSupportsToolCallTasks: true)

        let result = try await fixture.route.callToolResolved(
            remoteName: "long_running",
            arguments: ["query": .string("swift")],
            toolTaskSupport: .optional,
            preference: .automatic,
            ttlMilliseconds: nil,
            originatingToolCallID: "tool-call-ordinary",
            timeoutMilliseconds: 500)

        XCTAssertEqual(result.content, [.text("ordinary-result")])
        let calls = await fixture.client.recordedCalls()
        XCTAssertEqual(calls.ordinary, 1)
        XCTAssertEqual(calls.task, 0)
    }

    func testOptionalTaskPreferenceUsesTaskPath()
        async throws {
        let fixture = try await makeTaskBindingFixture(
            profile: .standardExtended,
            serverSupportsToolCallTasks: true)

        _ = try await fixture.route.callToolResolved(
            remoteName: "long_running",
            arguments: ["query": .string("swift")],
            toolTaskSupport: .optional,
            preference: .preferTask,
            ttlMilliseconds: nil,
            originatingToolCallID: "tool-call-preferred",
            timeoutMilliseconds: 500)

        let calls = await fixture.client.recordedCalls()
        XCTAssertEqual(calls.ordinary, 0)
        XCTAssertEqual(calls.task, 1)
    }

    func testRequiredPreferenceFailsBeforeCallWhenToolForbidsTasks()
        async throws {
        let fixture = try await makeTaskBindingFixture(
            profile: .standardExtended,
            serverSupportsToolCallTasks: true)

        do {
            _ = try await fixture.route.callToolResolved(
                remoteName: "long_running",
                arguments: ["query": .string("swift")],
                toolTaskSupport: .forbidden,
                preference: .requireTask,
                ttlMilliseconds: nil,
                originatingToolCallID: "tool-call-forbidden",
                timeoutMilliseconds: 500)
            XCTFail("forbidden task augmentation must fail")
        } catch let error as MCPTaskAugmentationError {
            XCTAssertEqual(error, .toolForbidsTasks)
        }

        let calls = await fixture.client.recordedCalls()
        XCTAssertEqual(calls.ordinary, 0)
        XCTAssertEqual(calls.task, 0)
    }

    func testRequiredToolFailsBeforeCallWithoutNegotiatedServerCapability()
        async throws {
        let fixture = try await makeTaskBindingFixture(
            profile: .standardExtended,
            serverSupportsToolCallTasks: false)

        do {
            _ = try await fixture.route.callToolResolved(
                remoteName: "long_running",
                arguments: ["query": .string("swift")],
                toolTaskSupport: .required,
                preference: .automatic,
                ttlMilliseconds: nil,
                originatingToolCallID: "tool-call-missing-capability",
                timeoutMilliseconds: 500)
            XCTFail("missing server capability must fail")
        } catch let error as MCPTaskAugmentationError {
            XCTAssertEqual(error, .serverCapabilityMissing)
        }

        let calls = await fixture.client.recordedCalls()
        XCTAssertEqual(calls.ordinary, 0)
        XCTAssertEqual(calls.task, 0)
    }

    func testCodexCompatibleProfileCannotExecuteRequiredTaskTool()
        async throws {
        let fixture = try await makeTaskBindingFixture(
            profile: .codexCompat,
            serverSupportsToolCallTasks: true)

        do {
            _ = try await fixture.route.callToolResolved(
                remoteName: "long_running",
                arguments: ["query": .string("swift")],
                toolTaskSupport: .required,
                preference: .automatic,
                ttlMilliseconds: nil,
                originatingToolCallID: "tool-call-codex-profile",
                timeoutMilliseconds: 500)
            XCTFail("Codex-compatible profile must not expose MCP tasks")
        } catch let error as MCPTaskAugmentationError {
            XCTAssertEqual(error, .unsupportedProfile)
        }

        let calls = await fixture.client.recordedCalls()
        XCTAssertEqual(calls.ordinary, 0)
        XCTAssertEqual(calls.task, 0)
    }
}

private actor MCPTaskBindingClient: MCPConnectionClient {
    struct Calls: Equatable, Sendable {
        let ordinary: Int
        let task: Int
        let ttlMilliseconds: Int?
        let originatingToolCallID: String?
    }

    private let catalog: MCPCompleteCatalogSnapshot
    private let capabilities: MCPNegotiatedCapabilitySet
    private var open = false
    private var ordinaryCalls = 0
    private var taskCalls = 0
    private var lastTTL: Int?
    private var lastOriginatingToolCallID: String?

    init(
        catalog: MCPCompleteCatalogSnapshot,
        capabilities: MCPNegotiatedCapabilitySet
    ) {
        self.catalog = catalog
        self.capabilities = capabilities
    }

    func startup(
        profile: MCPProtocolProfile,
        maximumProtocolVersion _: MCPProtocolVersion
    ) async throws -> MCPConnectionStartupResult {
        open = true
        return MCPConnectionStartupResult(
            negotiatedProtocolVersion: .init(
                profile.defaultMaximumVersion),
            negotiatedCapabilities: capabilities,
            catalog: catalog)
    }

    func isOpen() async -> Bool {
        open
    }

    func callTool(
        name _: String,
        arguments _: [String: JSONValue]
    ) async throws -> MCPRawToolCallResult {
        ordinaryCalls += 1
        return MCPRawToolCallResult(content: [.text("ordinary-result")])
    }

    func callToolTaskAugmentedAndAwait(
        name _: String,
        arguments _: [String: JSONValue],
        ttlMilliseconds: Int?,
        originatingToolCallID: String?,
        timeoutMilliseconds _: Int
    ) async throws -> MCPRawToolCallResult {
        taskCalls += 1
        lastTTL = ttlMilliseconds
        lastOriginatingToolCallID = originatingToolCallID
        return MCPRawToolCallResult(content: [.text("task-result")])
    }

    func shutdownAndDrain(reason _: String) async {
        open = false
    }

    func recordedCalls() -> Calls {
        Calls(
            ordinary: ordinaryCalls,
            task: taskCalls,
            ttlMilliseconds: lastTTL,
            originatingToolCallID: lastOriginatingToolCallID)
    }
}

private struct MCPTaskBindingFixture {
    let route: MCPPreparedConnectionRoute
    let client: MCPTaskBindingClient
}

private func makeTaskBindingFixture(
    profile: MCPProtocolProfile,
    serverSupportsToolCallTasks: Bool
) async throws -> MCPTaskBindingFixture {
    let suffix = profile.rawValue
        + (serverSupportsToolCallTasks ? "-tasks" : "-ordinary")
    let server = MCPServerReference(
        serverID: MCPServerID(rawValue: "task-server-\(suffix)"),
        serverRevision: MCPServerRevision(rawValue: "revision-1"))
    let authority = MCPConnectionAuthority(
        server: server,
        transport: .streamableHTTP,
        protocolProfile: profile,
        sessionID: SessionID(rawValue: "task-session-\(suffix)"),
        agentID: AgentID(rawValue: "task-agent-\(suffix)"),
        attachmentID: MCPAttachmentID(
            rawValue: "task-attachment-\(suffix)"),
        capabilityLeaseID: CapabilityLeaseID(
            rawValue: "task-capability-\(suffix)"),
        capabilityTaskID: nil,
        workspaceLeasePolicyFingerprint:
            String(repeating: "a", count: 64),
        attachmentPolicyRevision: MCPPolicyRevision(
            rawValue: "attachment-policy-1"),
        environmentReference: MCPEnvironmentReference(
            rawValue: "environment-1"),
        rootsPolicyRevision: MCPPolicyRevision(
            rawValue: "roots-policy-1"),
        networkPolicyRevision: MCPPolicyRevision(
            rawValue: "network-policy-1"),
        sandboxProfileRevision: MCPPolicyRevision(
            rawValue: "sandbox-policy-1"),
        sandboxPolicyFingerprint:
            String(repeating: "b", count: 64),
        hostPlatform: "test",
        fingerprint: "task-authority-\(suffix)")
    let identity = MCPConnectionReuseIdentity(
        server: server,
        transport: .streamableHTTP,
        transportConfigurationFingerprint: "transport-\(suffix)",
        authority: authority,
        oauthAccountReference: nil,
        environmentReference: authority.environmentReference,
        launchArtifactFingerprint: nil,
        runtimeIdentityFingerprint: "runtime-\(suffix)")
    let tool = try MCPRawToolRecord(
        remoteName: "long_running",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ]))
    let catalog = try MCPCompleteCatalogSnapshot(
        revision: MCPRawCatalogRevision(rawValue: "raw-\(suffix)"),
        catalogFingerprint: "catalog-\(suffix)",
        items: [
            MCPPublishedCatalogItem(
                kind: .tool,
                remoteName: tool.remoteName,
                identityFingerprint: tool.identityFingerprint,
                schemaHash: tool.inputSchemaHash),
        ],
        tools: [tool])
    let client = MCPTaskBindingClient(
        catalog: catalog,
        capabilities: MCPNegotiatedCapabilitySet(
            capabilities: [.tools, .tasks],
            remoteTaskList: serverSupportsToolCallTasks,
            remoteTaskCancel: serverSupportsToolCallTasks,
            remoteTaskToolCall: serverSupportsToolCallTasks))
    let connection = MCPManagedConnection(
        reuseIdentity: identity,
        generation: MCPConnectionGeneration(
            rawValue: "generation-\(suffix)"),
        revocationGeneration: MCPRevocationGeneration(
            rawValue: "revocation-1"),
        client: client)
    _ = try await connection.startup()
    let snapshot = try await connection.makeSnapshot(
        bindingID: MCPBindingID(rawValue: "binding-\(suffix)"),
        agentCatalogViewRevision: MCPAgentCatalogViewRevision(
            rawValue: "view-\(suffix)"))
    return MCPTaskBindingFixture(route: snapshot.route, client: client)
}
