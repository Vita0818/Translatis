import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
import IntatisSkills
@testable import IntatisAgentKernel

private final class SkillActivationProvider:
    ToolCallingProvider,
    @unchecked Sendable
{
    private let skillID: String
    private let lock = NSLock()
    private var captured: [AgentRequest] = []

    init(skillID: String) {
        self.skillID = skillID
    }

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stream(
        _ request: AgentRequest
    ) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        captured.append(request)
        let ordinal = captured.count
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if ordinal == 1 {
                let data = try! JSONSerialization.data(
                    withJSONObject: ["skill_id": self.skillID],
                    options: [.sortedKeys])
                continuation.yield(.toolCalls([
                    ToolCall(
                        id: "activate-1",
                        name: "activate_skill",
                        arguments: String(
                            decoding: data,
                            as: UTF8.self)),
                ]))
                continuation.yield(
                    .done(finishReason: "tool_calls"))
            } else {
                continuation.yield(.textDelta("used skill"))
                continuation.yield(.done(finishReason: "stop"))
            }
            continuation.finish()
        }
    }
}

private actor SkillToolSnapshotProbe {
    private var count = 0

    func resolve(
        _ snapshot: AgentRequestToolSnapshot
    ) -> AgentRequestToolSnapshot {
        count += 1
        return snapshot
    }

    func resolutionCount() -> Int {
        count
    }
}

private final class SkillContextCaptureProvider:
    ToolCallingProvider,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var captured: [AgentRequest] = []

    var requests: [AgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func stream(
        _ request: AgentRequest
    ) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        captured.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("used explicit skill"))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

final class SkillDurableActivationTests: XCTestCase {
    func testActivationUsesRegistryPermissionAndDurableExecutionPath() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-skill-durable-\(UUID().uuidString)",
                isDirectory: true)
        let skillDirectory = workspace
            .appendingPathComponent(
                ".agents/skills/durable",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: skillDirectory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try """
        ---
        name: durable
        description: Prove the ordinary durable tool path.
        ---
        DURABLE_SKILL_BODY
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8)

        let snapshot = try await SkillCatalogService.shared.snapshot(
            configuration: SkillDiscoveryConfiguration(
                workspaceRoot: workspace,
                access: .workspaceOnly))
        let skill = try XCTUnwrap(snapshot.skills.first)
        let registry = snapshot.augmenting(ToolRegistry([]))
        let provider = SkillActivationProvider(skillID: skill.id)
        let log = try EventLog(
            session: SessionID(rawValue: "skill_durable"),
            fileURL: workspace.appendingPathComponent("events.jsonl"))
        let workspaceLease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readOnly)
        let loop = AgentRuntime.code(
            registry: registry,
            allowsShell: false,
            maxIterations: 3)
            .makeLoop(
                log: log,
                provider: provider,
                responder: FixedResponder(.allow),
                agent: Agent(
                    name: AgentID(rawValue: "skill-agent"),
                    workspaceRoot: workspace,
                    model: ModelID(rawValue: "m"),
                    profile: .reviewed),
                context: ContextBuilder(
                    skillSnapshot: snapshot),
                workspaceLease: workspaceLease)

        let answer = try await loop.send(
            "Choose the relevant Skill.")

        XCTAssertEqual(answer, "used skill")
        XCTAssertTrue(
            registry.registryVersion.contains(
                "+skills.\(snapshot.digest.prefix(24))"))
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertTrue(provider.requests[1].messages.contains {
            $0.role == .tool
                && $0.toolCallId == "activate-1"
                && $0.content?.contains("DURABLE_SKILL_BODY") == true
        })

        let events = await log.replay()
        XCTAssertTrue(events.contains {
            if case .toolCall(let payload) = $0.event {
                return payload.name == "activate_skill"
            }
            return false
        })
        let permission = try XCTUnwrap(events.compactMap {
            envelope -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) =
                    envelope.event,
                  payload.tool == "activate_skill"
            else { return nil }
            return payload
        }.first)
        XCTAssertEqual(permission.decision, .allow)
        XCTAssertEqual(
            permission.authorization?.registryVersion,
            registry.registryVersion)
        XCTAssertTrue(events.contains {
            if case .toolExecutionPrepared(let payload) = $0.event {
                return payload.tool == "activate_skill"
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .toolResult(let payload) = $0.event {
                return payload.toolCallId == "activate-1"
                    && payload.observation.contains(
                        "DURABLE_SKILL_BODY")
            }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .toolExecutionSettled(let payload) = $0.event {
                return payload.tool == "activate_skill"
                    && payload.outcome == .succeeded
            }
            return false
        })
    }

    func testTaskScopedWorkerUsesExactFirstRequestMCPProofForExplicitSkill()
        async throws
    {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-skill-worker-mcp-\(UUID().uuidString)",
                isDirectory: true)
        let skillDirectory = workspace
            .appendingPathComponent(
                ".agents/skills/dependent",
                isDirectory: true)
        let metadataDirectory = skillDirectory
            .appendingPathComponent(
                "agents",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(
                at: workspace)
        }
        try """
        ---
        name: dependent
        description: Requires one exact MCP connection.
        ---
        TASK_SCOPED_DEPENDENT_BODY
        """.write(
            to: skillDirectory
                .appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8)
        try """
        dependencies:
          tools:
            - type: mcp
              value: dependent-server
              transport: streamable_http
              url: https://dependent.example.test/mcp
        """.write(
            to: metadataDirectory
                .appendingPathComponent("openai.yaml"),
            atomically: true,
            encoding: .utf8)

        let skillSnapshot =
            try await SkillCatalogService.shared
                .snapshot(
                    configuration:
                        SkillDiscoveryConfiguration(
                            workspaceRoot: workspace,
                            access: .workspaceOnly))
        let registry = skillSnapshot.augmenting(
            ToolRegistry([]))
        let availability =
            try MCPToolAvailabilitySnapshot.frozen(
                snapshotID: "worker-mcp-view",
                serverIdentifiers: [
                    "dependent-server",
                ],
                toolIdentifiers: [],
                dependencyIdentities: [
                    MCPServerDependencyIdentity(
                        serverID:
                            "dependent-server",
                        transportLocatorFingerprint:
                            try MCPDependencyLocatorFingerprint
                                .streamableHTTP(
                                    "https://dependent.example.test/mcp")),
                ])
        let requestSnapshot =
            AgentRequestToolSnapshot(
                snapshotID: "worker-request-tools",
                registry: registry,
                mcpAvailability: availability)
        let snapshotProbe =
            SkillToolSnapshotProbe()
        let provider =
            SkillContextCaptureProvider()
        let log = try EventLog(
            session:
                SessionID(
                    rawValue:
                        "skill_worker_mcp"),
            fileURL: workspace
                .appendingPathComponent(
                    "events.jsonl"))
        let workerID =
            AgentID(rawValue: "worker")
        let task = TaskContract(
            id: TaskID(
                rawValue:
                    "task_skill_worker_mcp"),
            kind: .agentInvocation,
            issuer: AgentID(rawValue: "main"),
            assignee: workerID,
            objective:
                "Use the dependent Skill.",
            roleHint: "worker",
            expectedDeliverable:
                "A response based on the Skill.")
        let loop = AgentLoop(
            log: log,
            provider: provider,
            registry: registry,
            engine: PermissionEngine(),
            responder: FixedResponder(.allow),
            agent: Agent(
                name: workerID,
                workspaceRoot: workspace,
                model: ModelID(rawValue: "m"),
                profile: .reviewed),
            context: ContextBuilder(
                taskContract: task,
                contextBundle: ContextBundle(
                    globalBrief:
                        task.objective,
                    safetyPolicy: "test",
                    taskContract: task),
                skillSnapshot:
                    skillSnapshot,
                runtimeEnvironment: .cowork,
                conversationHistoryPolicy:
                    .taskScoped),
            allowsShell: false,
            maxIterations: 2,
            toolSnapshotProvider: { _, _ in
                await snapshotProbe.resolve(
                    requestSnapshot)
            })

        let answer = try await loop.send(
            "Use $dependent for this task.")

        XCTAssertEqual(
            answer,
            "used explicit skill")
        let resolutionCount =
            await snapshotProbe
                .resolutionCount()
        XCTAssertEqual(
            resolutionCount,
            1)
        let request = try XCTUnwrap(
            provider.requests.first)
        XCTAssertTrue(
            request.messages.contains {
                $0.role == .user
                    && $0.content?.contains(
                        "TASK_SCOPED_DEPENDENT_BODY")
                        == true
            })
        XCTAssertFalse(
            request.messages
                .compactMap(\.content)
                .joined(separator: "\n")
                .contains(
                    "dependent.example.test"))
    }
}
