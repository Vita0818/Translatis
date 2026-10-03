import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

private actor SnapshotExecutionProbe {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private actor SnapshotCapabilityProbe {
    private var values:
        [ToolCallingProviderCapabilities] = []

    func record(
        _ value: ToolCallingProviderCapabilities
    ) {
        values.append(value)
    }

    func snapshot()
        -> [ToolCallingProviderCapabilities] {
        values
    }
}

private actor SnapshotBudgetIdentityProbe {
    private var first:
        AgentExternalToolOutputBudget?
    private var count = 0
    private var allSame = true

    func record(
        _ value:
            AgentExternalToolOutputBudget
    ) {
        if let first {
            allSame = allSame
                && first === value
        } else {
            first = value
        }
        count += 1
    }

    func snapshot()
        -> (count: Int, allSame: Bool) {
        (count, allSame)
    }
}

private struct SnapshotEchoArguments: Decodable {
    let value: String
}

private enum SnapshotSequenceError: Error {
    case exhausted
}

private enum SnapshotRequiredServerError: Error {
    case unavailable
}

private struct SnapshotEchoTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "static_descriptor_must_not_be_used",
        description: "Static metadata sentinel.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
        ])
    )

    let label: String
    let probe: SnapshotExecutionProbe

    func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        let decoded = try args.decode(SnapshotEchoArguments.self)
        let value = "\(label):\(decoded.value)"
        await probe.record(value)
        return ToolObservation(text: value)
    }
}

private actor SnapshotSequence {
    private let snapshots: [AgentRequestToolSnapshot]
    private var index = 0

    init(_ snapshots: [AgentRequestToolSnapshot]) {
        self.snapshots = snapshots
    }

    func next() throws -> AgentRequestToolSnapshot {
        guard index < snapshots.count else {
            throw SnapshotSequenceError.exhausted
        }
        defer { index += 1 }
        return snapshots[index]
    }
}

private final class SnapshotScriptedProvider:
    ToolCallingProvider, @unchecked Sendable
{
    let toolCallingCapabilities:
        ToolCallingProviderCapabilities =
            .responsesToolSearch
    private let lock = NSLock()
    private var requestStorage: [AgentRequest] = []

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    func stream(
        _ request: AgentRequest
    ) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        requestStorage.append(request)
        let ordinal = requestStorage.count
        lock.unlock()

        return AsyncThrowingStream { continuation in
            if ordinal == 1 {
                continuation.yield(.toolCalls([
                    ToolCall(
                        id: "snapshot-call",
                        name: "mcp__srv__echo",
                        arguments: #"{"value":"payload"}"#
                    ),
                ]))
                continuation.yield(.done(finishReason: "tool_calls"))
            } else {
                continuation.yield(.textDelta("complete"))
                continuation.yield(.done(finishReason: "stop"))
            }
            continuation.finish()
        }
    }
}

final class AgentRequestToolSnapshotTests: XCTestCase {
    func testToolExposureStaysDirectWithinBudgetWithoutSearchCapability()
        throws {
        XCTAssertEqual(
            try MCPAgentRequestToolSnapshotBuilder
                .exposureMode(
                    toolCount: 4,
                    schemaBytes: 4_096,
                    providerCapabilities:
                        .chatCompletionsOnly,
                    exposureBudget:
                        MCPToolExposureBudget(
                            maximumDirectTools: 4,
                            maximumDirectSchemaBytes:
                                4_096)),
            .direct)
    }

    func testToolExposureUsesSearchOnlyWhenOverBudgetAndSupported()
        throws {
        XCTAssertEqual(
            try MCPAgentRequestToolSnapshotBuilder
                .exposureMode(
                    toolCount: 5,
                    schemaBytes: 4_096,
                    providerCapabilities:
                        .responsesToolSearch,
                    exposureBudget:
                        MCPToolExposureBudget(
                            maximumDirectTools: 4,
                            maximumDirectSchemaBytes:
                                4_096)),
            .deferredSearch)
    }

    func testToolExposureFailsClosedWhenOverBudgetAndUnsupported() {
        XCTAssertThrowsError(
            try MCPAgentRequestToolSnapshotBuilder
                .exposureMode(
                    toolCount: 5,
                    schemaBytes: 4_096,
                    providerCapabilities:
                        .chatCompletionsOnly,
                    exposureBudget:
                        MCPToolExposureBudget(
                            maximumDirectTools: 4,
                            maximumDirectSchemaBytes:
                                4_096))
        ) { error in
            XCTAssertEqual(
                error as? MCPToolExposureError,
                .toolSearchUnsupported(
                    toolCount: 5,
                    schemaBytes: 4_096))
        }
    }

    func testProviderResponseExecutesOnlyRegistrationShownToThatDispatch() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-agent-request-snapshot-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let log = try EventLog(
            session: SessionID(rawValue: "agent-request-snapshot"),
            fileURL: workspace.appendingPathComponent("events.jsonl")
        )
        let probe = SnapshotExecutionProbe()
        let toolName = "mcp__srv__echo"
        let versionOneDescriptor = ToolDescriptor(
            name: toolName,
            description: "catalog-v1",
            sideEffect: .readOnly,
            parameters: Self.schema(required: "value")
        )
        let versionTwoDescriptor = ToolDescriptor(
            name: toolName,
            description: "catalog-v2",
            sideEffect: .readOnly,
            parameters: Self.schema(required: "newValue")
        )
        let versionOne = ToolRegistry(
            registrations: [
                ToolRegistration(
                    descriptor: versionOneDescriptor,
                    tool: SnapshotEchoTool(label: "v1", probe: probe),
                    canonicalPermission: "mcp.tool.call"
                ),
            ],
            registryVersion: "mcp-view-v1"
        )
        let versionTwo = ToolRegistry(
            registrations: [
                ToolRegistration(
                    descriptor: versionTwoDescriptor,
                    tool: SnapshotEchoTool(label: "v2", probe: probe),
                    canonicalPermission: "mcp.tool.call"
                ),
            ],
            registryVersion: "mcp-view-v2"
        )
        let snapshots = SnapshotSequence([
            AgentRequestToolSnapshot(
                snapshotID: "binding-v1",
                registry: versionOne
            ),
            AgentRequestToolSnapshot(
                snapshotID: "binding-v2",
                registry: versionTwo
            ),
        ])
        let capabilityProbe =
            SnapshotCapabilityProbe()
        let budgetProbe =
            SnapshotBudgetIdentityProbe()
        let provider = SnapshotScriptedProvider()
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: ToolRegistry([]),
            engine: PermissionEngine(),
            responder: FixedResponder(.allow),
            agent: Agent(
                name: AgentID(rawValue: "snapshot-agent"),
                workspaceRoot: workspace,
                model: ModelID(rawValue: "snapshot-model"),
                profile: .reviewed
            ),
            allowsShell: false,
            maxIterations: 3,
            toolSnapshotProvider: {
                providerCapabilities,
                outputBudget in
                await capabilityProbe.record(
                    providerCapabilities)
                await budgetProbe.record(
                    outputBudget)
                return try await snapshots.next()
            }
        )

        let response = try await loop.send("run the shown tool")
        let executedValues = await probe.snapshot()
        XCTAssertEqual(response, "complete")
        XCTAssertEqual(executedValues, ["v1:payload"])
        let observedCapabilities =
            await capabilityProbe.snapshot()
        XCTAssertEqual(
            observedCapabilities,
            [
                .responsesToolSearch,
                .responsesToolSearch,
            ])
        let budgetIdentity =
            await budgetProbe.snapshot()
        XCTAssertEqual(
            budgetIdentity.count,
            2)
        XCTAssertTrue(
            budgetIdentity.allSame)

        let requests = provider.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].tools.map(\.description), ["catalog-v1"])
        XCTAssertEqual(requests[1].tools.map(\.description), ["catalog-v2"])
        XCTAssertTrue(
            requests[1].messages.contains {
                $0.role == .tool && $0.content == "v1:payload"
            }
        )

        let events = await log.replay()
        let authorizations = events.compactMap {
            envelope -> ResolvedToolAuthorization? in
            guard case .permissionResolved(let payload) = envelope.event
            else { return nil }
            return payload.authorization
        }
        XCTAssertEqual(authorizations.count, 1)
        XCTAssertEqual(authorizations[0].registryVersion, "mcp-view-v1")
        XCTAssertEqual(authorizations[0].canonicalPermission, "mcp.tool.call")
    }

    func testSnapshotFailurePreventsProviderDispatch() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-agent-request-snapshot-failure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let log = try EventLog(
            session: SessionID(
                rawValue: "agent-request-snapshot-failure"),
            fileURL: workspace.appendingPathComponent("events.jsonl")
        )
        let provider = SnapshotScriptedProvider()
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: ToolRegistry([]),
            engine: PermissionEngine(),
            responder: FixedResponder(.allow),
            agent: Agent(
                name: AgentID(rawValue: "snapshot-agent"),
                workspaceRoot: workspace,
                model: ModelID(rawValue: "snapshot-model"),
                profile: .reviewed
            ),
            allowsShell: false,
            maxIterations: 3,
            toolSnapshotProvider: { _, _ in
                throw SnapshotRequiredServerError.unavailable
            }
        )

        do {
            _ = try await loop.send("must not reach the provider")
            XCTFail("Expected MCP snapshot failure")
        } catch {
            XCTAssertTrue(error is SnapshotRequiredServerError)
        }
        XCTAssertEqual(provider.requests.count, 0)
    }

    func testDurableMCPGrantRequiresExactLeaseTaskAndNonControlPlaneAgent()
        throws {
        let agent = AgentID(rawValue: "main")
        let lease = CapabilityLeaseID(rawValue: "clease_exact")
        let task = TaskID(rawValue: "task_exact")
        let server = MCPServerReference(
            serverID: MCPServerID(rawValue: "mcp_exact"),
            serverRevision: MCPServerRevision(
                rawValue: "mcprev_exact"))
        let attachment = MCPAttachmentID(
            rawValue: "mcpattach_exact")
        let grant = MCPGrant(
            grantID: MCPGrantID(rawValue: "mcpgrant_exact"),
            attachmentID: attachment,
            server: server,
            agentID: agent,
            capabilityLeaseID: lease,
            taskID: task,
            capabilities: [.tools],
            filter: MCPCatalogFilter(
                revision: MCPPolicyRevision(
                    rawValue: "mcppolicy_exact")),
            approvalModeCeiling: .prompt,
            authorityFingerprint:
                String(repeating: "a", count: 64),
            grantFingerprint:
                String(repeating: "b", count: 64),
            revocationGeneration:
                MCPRevocationGeneration(
                    rawValue: "mcprevocation_exact"))
        let state = MCPDurableSessionState(
            grants: [grant.grantID: grant])

        XCTAssertEqual(
            state.grants(
                agentID: agent,
                capabilityLeaseID: lease,
                taskID: task),
            [grant])
        XCTAssertTrue(state.grants(
            agentID: agent,
            capabilityLeaseID:
                CapabilityLeaseID(rawValue: "clease_other"),
            taskID: task).isEmpty)
        XCTAssertTrue(state.grants(
            agentID: agent,
            capabilityLeaseID: lease,
            taskID: nil).isEmpty)

        let encoded = try JSONEncoder().encode(grant)
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "capabilityLeaseID")
        legacy.removeValue(forKey: "taskID")
        let legacyGrant = try JSONDecoder().decode(
            MCPGrant.self,
            from: try JSONSerialization.data(
                withJSONObject: legacy))
        let legacyState = MCPDurableSessionState(
            grants: [
                legacyGrant.grantID:
                    legacyGrant,
            ])
        XCTAssertTrue(legacyState.grants(
            agentID: agent,
            capabilityLeaseID: lease,
            taskID: task).isEmpty)

        for reserved in [
            MCPReservedControlPlaneIdentity
                .permissionReviewer,
            MCPReservedControlPlaneIdentity.goalVerifier,
        ] {
            let forged = MCPGrant(
                grantID: MCPGrantID(
                    rawValue:
                        "mcpgrant_\(reserved.rawValue)"),
                attachmentID: attachment,
                server: server,
                agentID: reserved,
                capabilityLeaseID: lease,
                taskID: task,
                capabilities: [.tools],
                filter: grant.filter,
                approvalModeCeiling: .auto,
                authorityFingerprint:
                    grant.authorityFingerprint,
                grantFingerprint:
                    grant.grantFingerprint,
                revocationGeneration:
                    grant.revocationGeneration)
            let forgedState = MCPDurableSessionState(
                grants: [forged.grantID: forged])
            XCTAssertTrue(forgedState.grants(
                agentID: reserved,
                capabilityLeaseID: lease,
                taskID: task).isEmpty)
        }
    }

    private static func schema(required: String) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                required: .object([
                    "type": .string("string"),
                ]),
            ]),
            "required": .array([.string(required)]),
            "additionalProperties": .bool(false),
        ])
    }
}
