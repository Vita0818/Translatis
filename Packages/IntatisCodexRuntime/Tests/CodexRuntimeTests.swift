import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisConversation
import IntatisCowork
import IntatisMCP
@testable import IntatisCodexRuntime

private struct FixedSecretResolver: SecretResolver {
    let value: String

    func secret(for ref: KeychainRef) async throws -> String {
        value
    }
}

private struct FailingSecretResolver: SecretResolver {
    func secret(for ref: KeychainRef) async throws -> String {
        throw IntatisError.config("secret resolver was called")
    }
}

final class CodexRuntimeToolsetIdentityTests: XCTestCase {
    func testStructuredInputCapabilityQualifiesPersistedToolsetIdentity() {
        XCTAssertEqual(
            CodexAppServerSession.runtimeToolsetIdentity(
                dynamicToolsetID: "business-v1",
                requestUserInputEnabled: false),
            "business-v1")

        let first = CodexAppServerSession.runtimeToolsetIdentity(
            dynamicToolsetID: "business-v1",
            requestUserInputEnabled: true)
        let second = CodexAppServerSession.runtimeToolsetIdentity(
            dynamicToolsetID: "business-v1",
            requestUserInputEnabled: true)
        let differentBase = CodexAppServerSession.runtimeToolsetIdentity(
            dynamicToolsetID: "business-v2",
            requestUserInputEnabled: true)

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, "business-v1")
        XCTAssertNotEqual(first, differentBase)
        XCTAssertTrue(first?.hasPrefix("intatis.codex-session.") == true)
    }
}

private struct FailingImageGenerationToolService:
    ImageGenerationToolService
{
    func generateImage(
        prompt: String,
        size: String,
        count: Int,
        outputPath: String,
        workspaceRoot: URL
    ) async throws -> ToolObservation {
        throw IntatisError.config("test image generation is unavailable")
    }

    func editImage(
        image: Data,
        filename: String,
        mime: String,
        prompt: String,
        outputPath: String,
        workspaceRoot: URL
    ) async throws -> ToolObservation {
        throw IntatisError.config("test image editing is unavailable")
    }
}

private actor RecordingImageGenerationToolService:
    ImageGenerationToolService
{
    struct GenerateCall: Equatable {
        let prompt: String
        let size: String
        let count: Int
        let outputPath: String
        let workspaceRoot: URL
    }

    struct EditCall: Equatable {
        let image: Data
        let filename: String
        let mime: String
        let prompt: String
        let outputPath: String
        let workspaceRoot: URL
    }

    private var generateCalls: [GenerateCall] = []
    private var editCalls: [EditCall] = []

    func generateImage(
        prompt: String,
        size: String,
        count: Int,
        outputPath: String,
        workspaceRoot: URL
    ) async throws -> ToolObservation {
        let call = GenerateCall(
            prompt: prompt,
            size: size,
            count: count,
            outputPath: outputPath,
            workspaceRoot: workspaceRoot)
        generateCalls.append(call)
        let output = try PathConfinement.resolve(
            outputPath,
            within: workspaceRoot)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: output,
            options: .atomic)
        return ToolObservation(
            text: "generated image: \(outputPath)",
            changedFiles: [outputPath])
    }

    func editImage(
        image: Data,
        filename: String,
        mime: String,
        prompt: String,
        outputPath: String,
        workspaceRoot: URL
    ) async throws -> ToolObservation {
        let call = EditCall(
            image: image,
            filename: filename,
            mime: mime,
            prompt: prompt,
            outputPath: outputPath,
            workspaceRoot: workspaceRoot)
        editCalls.append(call)
        let output = try PathConfinement.resolve(
            outputPath,
            within: workspaceRoot)
        try image.write(to: output, options: .atomic)
        return ToolObservation(
            text: "edited image: \(outputPath)",
            changedFiles: [outputPath])
    }

    func recordedGenerateCalls() -> [GenerateCall] { generateCalls }
    func recordedEditCalls() -> [EditCall] { editCalls }
}

private actor RecordingHostedWebSearchToolService:
    HostedWebSearchToolService
{
    private let result: String
    private var queries: [String] = []

    init(result: String) {
        self.result = result
    }

    func search(query: String) async throws -> ToolObservation {
        queries.append(query)
        return ToolObservation(text: result)
    }

    func recordedQueries() -> [String] { queries }
}

private actor DynamicToolCallCapture {
    private var calls: [CodexRuntimeDynamicToolCall] = []

    func append(_ call: CodexRuntimeDynamicToolCall) {
        calls.append(call)
    }

    func snapshot() -> [CodexRuntimeDynamicToolCall] {
        calls
    }
}

private actor UserInputRequestCapture {
    private var requests: [CodexRuntimeUserInputRequest] = []

    func answer(
        _ request: CodexRuntimeUserInputRequest
    ) -> CodexRuntimeUserInputResponse {
        requests.append(request)
        return CodexRuntimeUserInputResponse(answers: [
            "probe_choice": ["Continue (Recommended)"],
        ])
    }

    func snapshot() -> [CodexRuntimeUserInputRequest] {
        requests
    }
}

private actor BlockingUserInputRequestCapture {
    private var requests: [CodexRuntimeUserInputRequest] = []
    private var cancellationCount = 0

    func wait(
        _ request: CodexRuntimeUserInputRequest
    ) async throws -> CodexRuntimeUserInputResponse {
        requests.append(request)
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return CodexRuntimeUserInputResponse(answers: [
                "probe_choice": ["Continue (Recommended)"],
            ])
        } catch {
            cancellationCount += 1
            throw error
        }
    }

    func snapshot() -> [CodexRuntimeUserInputRequest] {
        requests
    }

    func cancellations() -> Int { cancellationCount }
}

private actor PermissionAgentCapture {
    private var agents: [AgentID] = []

    func append(_ agent: AgentID) {
        agents.append(agent)
    }

    func snapshot() -> [AgentID] {
        agents
    }
}

private actor PermissionRequestCapture {
    private var requests: [PermissionRequestPayload] = []

    func append(_ request: PermissionRequestPayload) {
        requests.append(request)
    }

    func snapshot() -> [PermissionRequestPayload] {
        requests
    }
}

private actor CodexSessionNamingCapture: SessionNamingService {
    struct Call: Equatable {
        let name: String
        let operationID: String
    }

    private var recordedCalls: [Call] = []

    func renameCurrentSession(
        to name: String,
        operationID: String
    ) async throws -> SessionRenameResult {
        recordedCalls.append(Call(
            name: name,
            operationID: operationID))
        return SessionRenameResult(
            previousName: nil,
            name: name,
            currentName: name,
            revision: 1,
            changed: true)
    }

    func calls() -> [Call] {
        recordedCalls
    }
}

private actor RuntimeBoundaryEventCapture {
    private var events: [CodexRuntimeEvent] = []

    func append(_ event: CodexRuntimeEvent) {
        events.append(event)
    }

    func snapshot() -> [CodexRuntimeEvent] {
        events
    }
}

private actor DynamicToolCloseCapture {
    private var closeCount = 0

    func close() -> Bool {
        closeCount += 1
        return true
    }

    func count() -> Int { closeCount }
}

private struct TestSearchKnowledgeTool: Tool {
    static let descriptor = ToolDescriptor(
        name: "search_knowledge",
        description: "Search the exact test Knowledge mount.",
        sideEffect: .readOnly,
        parameters: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
        ]))

    func execute(
        _ args: ToolArgs,
        in context: ToolContext
    ) async throws -> ToolObservation {
        ToolObservation(text: "knowledge result")
    }
}

private struct NativeMCPFixture {
    let catalog: MCPServerCatalog
    let attachment: MCPServerAttachment
    let grant: MCPGrant
    let consent: MCPConsent
}

private func nativeMCPFixture(
    capabilities: Set<MCPGrantedCapability>,
    expiresAt: Date? = nil
) throws -> NativeMCPFixture {
    let serverID = MCPServerID(rawValue: "server_native")
    let secret = try MCPSecretReference(
        storageClass: .hostOwned,
        identifier: "mcp:native-test")
    let environmentReference = MCPEnvironmentReference(
        rawValue: "mcpenv_native_test")
    let configuration = try MCPServerConfiguration(
        serverID: serverID,
        displayName: "Native Test",
        protocolProfile: .codexCompat,
        approvalPolicy: MCPApprovalPolicy(
            serverDefault: .auto,
            toolOverrides: ["read": .approve]),
        timeouts: MCPServerTimeouts(
            startupMilliseconds: 1_500,
            callMilliseconds: 2_250,
            shutdownMilliseconds: 500),
        filters: MCPServerFilters(
            tools: MCPNameFilter(
                allowList: ["read", "write"],
                denyList: ["write"])),
        transport: .streamableHTTP(
            try MCPHTTPServerConfiguration(
                endpoint: "https://mcp.example.test/v1",
                headers: [
                    "X-Native-Secret": .secret(secret),
                ],
                bearerTokenReference: secret)),
        environmentReference: environmentReference,
        provenance: try MCPConfigurationProvenance(
            sourceKind: .intatisUser,
            sourceLabel: "native-test"))
    let definition = try MCPServerDefinition.isolatedTest(
        configuration: configuration)
    let catalog = try MCPServerCatalog.isolatedTest(
        definition: definition)
    let policyRevision = MCPPolicyRevision(
        rawValue: "mcppolicy_native_test")
    let attachment = MCPServerAttachment(
        attachmentID: MCPAttachmentID(
            rawValue: "mcpattachment_native_test"),
        server: definition.reference,
        policy: MCPAttachmentPolicy(
            revision: policyRevision,
            approvalMode: .writes,
            filter: MCPCatalogFilter(
                revision: policyRevision)),
        source: .user)
    let authority = String(repeating: "a", count: 64)
    let grant = MCPGrant(
        grantID: MCPGrantID(
            rawValue: "mcpgrant_native_test"),
        attachmentID: attachment.attachmentID,
        server: attachment.server,
        agentID: AgentID(rawValue: "Coder"),
        capabilityLeaseID: CapabilityLeaseID(
            rawValue: "clease_native_test"),
        capabilities: Array(capabilities),
        filter: MCPCatalogFilter(
            revision: MCPPolicyRevision(
                rawValue: "mcppolicy_native_grant")),
        approvalModeCeiling: .prompt,
        authorityFingerprint: authority,
        grantFingerprint: String(repeating: "b", count: 64),
        revocationGeneration: MCPRevocationGeneration(
            rawValue: "mcprevocation_native_test"),
        expiresAt: expiresAt)
    let consent = MCPConsent(
        consentID: MCPConsentID(
            rawValue: "mcpconsent_native_test"),
        kind: .connect,
        server: attachment.server,
        attachmentID: attachment.attachmentID,
        authorityFingerprint: authority,
        environmentReference: environmentReference,
        policyRevision: policyRevision)
    return NativeMCPFixture(
        catalog: catalog,
        attachment: attachment,
        grant: grant,
        consent: consent)
}

private actor CountingWorkTaskManager: WorkTaskManager {
    private var updateInvocations = 0

    func createWorkTask(_ request: WorkTaskCreateRequest) async throws
        -> WorkTaskDetail
    {
        throw IntatisError.config("not used")
    }

    func updateWorkTask(_ request: WorkTaskUpdateRequest) async throws
        -> WorkTaskDetail
    {
        updateInvocations += 1
        throw IntatisError.config("executor must not run")
    }

    func getWorkTask(_ taskID: WorkTaskID) async throws -> WorkTaskDetail {
        throw IntatisError.notFound("not used")
    }

    func listWorkTasks(_ request: WorkTaskListRequest) async throws
        -> [WorkTaskDetail]
    {
        []
    }

    func updateInvocationCount() -> Int {
        updateInvocations
    }
}

private actor DynamicLeaseGate {
    private var enteredCalls: [CodexRuntimeDynamicToolCall] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var validityAfterRelease: [Bool?] = []

    func suspend(_ call: CodexRuntimeDynamicToolCall) async {
        enteredCalls.append(call)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        validityAfterRelease.append(call.executionLease?.isValid)
    }

    func entryCount() -> Int {
        enteredCalls.count
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func validitySnapshot() -> [Bool?] {
        validityAfterRelease
    }
}

private actor EmptyWorkTaskManager: WorkTaskManager {
    func createWorkTask(_ request: WorkTaskCreateRequest) async throws
        -> WorkTaskDetail
    {
        throw IntatisError.config("not used")
    }

    func updateWorkTask(_ request: WorkTaskUpdateRequest) async throws
        -> WorkTaskDetail
    {
        throw IntatisError.config("not used")
    }

    func getWorkTask(_ taskID: WorkTaskID) async throws -> WorkTaskDetail {
        throw IntatisError.notFound("not used")
    }

    func listWorkTasks(_ request: WorkTaskListRequest) async throws
        -> [WorkTaskDetail]
    {
        []
    }
}

private actor EmptyGoalManager: GoalManager {
    func currentGoal() async throws -> Goal? { nil }

    func editGoal(_ request: GoalEditRequest) async throws -> Goal {
        throw IntatisError.config("not used")
    }

    func transitionGoal(
        _ goalID: GoalID,
        expectedRevision: Int,
        to status: GoalStatus
    ) async throws -> Goal {
        throw IntatisError.config("not used")
    }

    func clearGoal(_ goalID: GoalID, expectedRevision: Int) async throws {
        throw IntatisError.config("not used")
    }
}

final class CodexRuntimeTests: XCTestCase {
    func testHostUserCodexHomeSkillRootIsBoundedAndSecretSafe()
        throws
    {
        let home = URL(fileURLWithPath: "/tmp/intatis-skill-home")
        let configuration = try CodexRuntimeSkillConfiguration
            .hostUserCodexHome(
                processEnvironment: [
                    "CODEX_HOME": "/tmp/intatis-user-codex",
                ],
                homeDirectory: home)

        XCTAssertEqual(
            configuration.extraRoots.map(\.path),
            ["/tmp/intatis-user-codex/skills"])
        XCTAssertFalse(configuration.description.contains("/tmp"))
        XCTAssertThrowsError(try CodexRuntimeSkillConfiguration
            .hostUserCodexHome(
                processEnvironment: ["CODEX_HOME": "relative/codex"],
                homeDirectory: home))
    }

    func testAppServerSetsOfficialSkillExtraRootsBeforeThreadStart()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let skillRoot = temporary.appendingPathComponent(
            "host-skills",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: skillRoot,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            case "$line" in
              *skills/extraRoots/set*"\(skillRoot.path)"*)
                echo '{"id":2,"result":{}}'
                ;;
              *) exit 41 ;;
            esac
          elif [ "$count" = "3" ]; then
            case "$line" in
              *thread/start*)
                echo '{"id":3,"result":{"thread":{"id":"thread-skills"}}}'
                ;;
              *) exit 42 ;;
            esac
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "native-skills-test"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                skillConfiguration: try CodexRuntimeSkillConfiguration(
                    extraRoots: [skillRoot])))

        let identity = try await session.start()
        await session.shutdown()

        XCTAssertEqual(identity.threadID, "thread-skills")
    }

    func testNativeMCPProjectionWritesOfficialConfigWithoutPersistingSecret()
        async throws
    {
        let fixture = try nativeMCPFixture(
            capabilities:
                CodexRuntimeMCPProjector
                    .requiredNativeSurfaceCapabilities)
        let secret = "native-mcp-secret-value"
        let projected = try await CodexRuntimeMCPProjector.project(
            catalog: fixture.catalog,
            attachments: [fixture.attachment],
            grants: [fixture.grant],
            consents: [fixture.consent],
            resolveSecret: { _ in Data(secret.utf8) })

        XCTAssertEqual(projected.serverNames, ["server_native"])
        XCTAssertFalse(projected.isEmpty)
        XCTAssertFalse(projected.description.contains(secret))
        XCTAssertEqual(Set(projected.processEnvironment.values), [secret])
        XCTAssertTrue(projected.processEnvironment.keys.allSatisfy {
            $0.hasPrefix("INTATIS_MCP_")
        })
        let toml = try projected.renderedTOML()
            .joined(separator: "\n")
        XCTAssertTrue(toml.contains("[mcp_servers.\"server_native\"]"))
        XCTAssertTrue(toml.contains(
            "url = \"https://mcp.example.test/v1\""))
        XCTAssertTrue(toml.contains(
            "default_tools_approval_mode = \"prompt\""))
        XCTAssertTrue(toml.contains("enabled_tools = [\"read\"]"))
        XCTAssertTrue(toml.contains("disabled_tools = [\"write\"]"))
        XCTAssertTrue(toml.contains("bearer_token_env_var"))
        XCTAssertFalse(toml.contains(secret))

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: temporary)
        try storage.prepare()
        try storage.writeAgentRegistry(
            [],
            profileURLs: [:],
            mcpConfiguration: projected)
        let persisted = try XCTUnwrap(
            DurableOwnerOnlyFile.read(from: storage.configURL))
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self)
            .contains(secret))
    }

    func testNativeMCPProjectionRejectsPartialCapabilityGrant()
        async throws
    {
        let fixture = try nativeMCPFixture(
            capabilities: [.tools])
        do {
            _ = try await CodexRuntimeMCPProjector.project(
                catalog: fixture.catalog,
                attachments: [fixture.attachment],
                grants: [fixture.grant],
                consents: [fixture.consent],
                resolveSecret: { _ in Data("unused".utf8) })
            XCTFail("A partial legacy grant must not widen in native Codex MCP")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(
                "partial capability grant"))
        }
    }

    func testNativeMCPProjectionRejectsExpiringGrant()
        async throws
    {
        let fixture = try nativeMCPFixture(
            capabilities:
                CodexRuntimeMCPProjector
                    .requiredNativeSurfaceCapabilities,
            expiresAt: Date().addingTimeInterval(3_600))
        do {
            _ = try await CodexRuntimeMCPProjector.project(
                catalog: fixture.catalog,
                attachments: [fixture.attachment],
                grants: [fixture.grant],
                consents: [fixture.consent],
                resolveSecret: { _ in Data("unused".utf8) })
            XCTFail("A static native MCP config cannot retain an expiring grant")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(
                "Expiring MCP grants"))
        }
    }

    func testCoworkNativeMCPKeepsRootEnabledAndDisablesEveryChildRole()
        async throws
    {
        let fixture = try nativeMCPFixture(
            capabilities:
                CodexRuntimeMCPProjector
                    .requiredNativeSurfaceCapabilities)
        let projected = try await CodexRuntimeMCPProjector.project(
            catalog: fixture.catalog,
            attachments: [fixture.attachment],
            grants: [fixture.grant],
            consents: [fixture.consent],
            resolveSecret: { _ in Data("cowork-native-secret".utf8) })
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(
            rootURL: temporary.appendingPathComponent(
                "runtime",
                isDirectory: true))
        try storage.prepare()
        let profile = CodexRuntimeChildProfile(
            roleName: "research",
            description: "Research without inherited MCP authority.",
            workspaceURL: workspace,
            route: ResponsesRuntimeRoute(
                endpointID: "child",
                model: ModelID(rawValue: "child-model"),
                baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                bearerToken: "child-token"),
            sandbox: .readOnly)
        let profileURLs = try storage.writeChildProfiles(
            [profile],
            providerIDs: ["research": "intatis_agent_research"],
            mcpConfiguration: projected)
        try storage.writeAgentRegistry(
            [profile],
            profileURLs: profileURLs,
            mcpConfiguration: projected)

        let rootConfig = String(decoding: try XCTUnwrap(
            DurableOwnerOnlyFile.read(from: storage.configURL)),
            as: UTF8.self)
        XCTAssertTrue(rootConfig.contains(
            "[mcp_servers.\"server_native\"]"))
        XCTAssertTrue(rootConfig.contains(
            "url = \"https://mcp.example.test/v1\""))
        XCTAssertTrue(rootConfig.contains("[agents.default]"))
        XCTAssertFalse(rootConfig.contains("cowork-native-secret"))

        for role in ["research", "default"] {
            let url = try XCTUnwrap(profileURLs[role])
            let config = String(decoding: try XCTUnwrap(
                DurableOwnerOnlyFile.read(from: url)),
                as: UTF8.self)
            XCTAssertTrue(config.contains(
                "[mcp_servers.\"server_native\"]"))
            XCTAssertTrue(config.contains("enabled = false"))
            XCTAssertTrue(config.contains("mcp.example.test"))
            XCTAssertFalse(config.contains("cowork-native-secret"))
        }

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "cowork-native-mcp"),
                mode: .cowork,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "session-runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                mcpConfiguration: projected,
                childProfiles: [profile]))
        let lifecycle = await session.threadLifecycleParameters()
        guard case .object(let config)? = lifecycle["config"],
              case .object(let agents)? = config["agents"] else {
            return XCTFail("Cowork lifecycle must include native agent roles")
        }
        XCTAssertNotNil(agents["default"])
        XCTAssertNotNil(agents["research"])
    }

    func testBusinessToolHostAddsKnowledgeAndDrainsItsLease()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let log = try EventLog(
            session: SessionID(rawValue: "knowledge-dynamic-host"),
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        let closeCapture = DynamicToolCloseCapture()
        let augmenter = HostToolRegistryAugmenter(
            additionalCapabilities: [
                .buildKnowledge,
                .searchKnowledge,
            ]) { input in
                XCTAssertFalse(input.capabilityLease.tools.contains(
                    .buildKnowledge))
                XCTAssertTrue(input.capabilityLease.tools.contains(
                    .searchKnowledge))
                let registry = input.baseRegistry.adding(
                    registrations: [ToolRegistration(
                        tool: TestSearchKnowledgeTool(),
                        grantingCapabilities: [.searchKnowledge])],
                    registryVersion: "test.knowledge.v1")
                return HostToolRegistryAugmentationLease(
                    registry: registry,
                    close: { await closeCapture.close() })
            }
        let host = try CodexBusinessToolHost(
            sessionID: SessionID(rawValue: "knowledge-dynamic-host"),
            agentID: AgentID(rawValue: "main"),
            workspaceURL: workspace,
            workspaceLease: WorkspaceLease(
                id: WorkspaceLeaseID(
                    rawValue: "wlease_knowledge_dynamic_host"),
                workspaceID: WorkspaceID(
                    rawValue: "workspace_knowledge_dynamic_host"),
                rootPath: workspace.path,
                access: .readOnly),
            registryAugmenter: augmenter,
            imageGenerator: FailingImageGenerationToolService(),
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                XCTFail("search_knowledge is deterministic read-only")
                return PermissionApprovalResolution(
                    decision: .deny,
                    risk: request.risk,
                    source: .user)
            })
        let tools = try await host.dynamicTools()
        XCTAssertTrue(tools.specs.contains {
            $0.name == "search_knowledge"
        })

        let rootResult = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "root",
                turnID: "turn",
                callID: "knowledge-root",
                tool: "search_knowledge",
                arguments: .object([:])))
        XCTAssertTrue(rootResult.success)
        let childResult = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "child",
                turnID: "turn",
                callID: "knowledge-child",
                tool: "search_knowledge",
                arguments: .object([:]),
                agentID: AgentID(rawValue: "codex:child"),
                workspaceURL: workspace,
                workspaceAccess: .readOnly,
                permissionProfile: .readOnly,
                knowledgeCapabilities: [.searchKnowledge]))
        XCTAssertTrue(childResult.success)
        let ungrantedChildResult = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "child-ungranted",
                turnID: "turn",
                callID: "knowledge-child-ungranted",
                tool: "search_knowledge",
                arguments: .object([:]),
                agentID: AgentID(rawValue: "codex:child-ungranted"),
                workspaceURL: workspace,
                workspaceAccess: .readOnly,
                permissionProfile: .readOnly))
        XCTAssertFalse(ungrantedChildResult.success)
        let closeCountBeforeShutdown = await closeCapture.count()
        XCTAssertEqual(closeCountBeforeShutdown, 0)
        let firstShutdown = await tools.shutdown()
        let closeCountAfterFirstShutdown = await closeCapture.count()
        XCTAssertTrue(firstShutdown)
        XCTAssertEqual(closeCountAfterFirstShutdown, 2)
        let secondShutdown = await tools.shutdown()
        let closeCountAfterSecondShutdown = await closeCapture.count()
        XCTAssertTrue(secondShutdown)
        XCTAssertEqual(closeCountAfterSecondShutdown, 2)
    }

    func testBusinessToolHostRejectsKnowledgeRegistrationOutsideScopedAugmenter()
        throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let log = try EventLog(
            session: SessionID(rawValue: "knowledge-direct-registration"),
            fileURL: temporary.appendingPathComponent("events.jsonl"))

        XCTAssertThrowsError(try CodexBusinessToolHost(
            sessionID: SessionID(rawValue: "knowledge-direct-registration"),
            agentID: AgentID(rawValue: "main"),
            workspaceURL: workspace,
            additionalRegistrations: [ToolRegistration(
                tool: TestSearchKnowledgeTool(),
                grantingCapabilities: [.searchKnowledge])],
            imageGenerator: FailingImageGenerationToolService(),
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                PermissionApprovalResolution(
                    decision: .deny,
                    risk: request.risk,
                    source: .user)
            })) { error in
                XCTAssertTrue(error.localizedDescription.contains(
                    "scoped registry augmenter"))
            }
    }

    func testResponsesRouteUsesExplicitResponsesBaseAndRedactsCredential()
        async throws
    {
        let endpoint = ProviderEndpoint(
            id: "example",
            baseURL: URL(string: "https://unused.invalid/v1")!,
            responsesEndpoint: URL(
                string: "https://api.example.test/v2/responses?api-version=7")!,
            apiKeyRef: .environment("EXAMPLE_API_KEY"),
            wire: .openai,
            modelRequestOptions: [
                "example-model": [
                    "reasoningEffort": .string("high"),
                ],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: endpoint.id,
                        model: ModelID(rawValue: "example-model")))),
            resolver: FixedSecretResolver(value: "Bearer test-secret"))

        let route = try await registry.responsesRuntimeRoute()

        XCTAssertEqual(route.endpointID, "example")
        XCTAssertEqual(route.model.rawValue, "example-model")
        XCTAssertEqual(
            route.baseURL.absoluteString,
            "https://api.example.test/v2/")
        XCTAssertEqual(route.queryParameters, ["api-version": "7"])
        XCTAssertEqual(route.bearerToken, "test-secret")
        XCTAssertEqual(route.reasoningEffort, "high")
        XCTAssertEqual(route.requestAdapter, .legacyOpenAIWire)
        XCTAssertFalse(String(describing: route).contains("test-secret"))
    }

    func testOpenRouterProviderObjectPassesThroughWithoutFieldEnumeration()
        async throws
    {
        let providerOptions: [String: JSONValue] = [
            "require_parameters": .bool(true),
            "allow_fallbacks": .bool(false),
            "order": .array([
                .string("openai"),
                .string("azure"),
            ]),
            "future_routing": .object([
                "mode": .string("provider-owned"),
            ]),
        ]
        let endpoint = ProviderEndpoint(
            id: "openrouter",
            baseURL: URL(string: "https://openrouter.example.test/api/v1")!,
            apiKeyRef: .environment("OPENROUTER_API_KEY"),
            wire: .openai,
            requestAdapter: .openRouter,
            modelRequestOptions: [
                "stealth/ox-alpha": [
                    "reasoningEffort": .string("max"),
                    "provider": .object(providerOptions),
                ],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(chat: ModelRef(
                    endpoint: endpoint.id,
                    model: ModelID(rawValue: "stealth/ox-alpha")))),
            resolver: FixedSecretResolver(value: "test-secret"))

        let route = try await registry.responsesRuntimeRoute()

        XCTAssertEqual(route.reasoningEffort, "max")
        XCTAssertEqual(route.providerOptions, providerOptions)
        XCTAssertEqual(route.requestAdapter, .openRouter)

        let connectionID = InferenceConnectionID(rawValue: "openrouter")
        let catalog = try InferenceCatalogReconciler.reconcile(draft:
            InferenceCatalogDraft(
                connections: [InferenceConnectionDraft(
                    inferenceConnectionID: connectionID,
                    wire: .openai,
                    requestAdapter: .openRouter,
                    baseURL: endpoint.baseURL,
                    credentialRef: endpoint.apiKeyRef)],
                profiles: [InferenceProfileDraft(
                    inferenceProfileID: InferenceProfileID(
                        rawValue: "stealth-ox-alpha"),
                    inferenceConnectionID: connectionID,
                    modelID: ModelID(rawValue: "stealth/ox-alpha"),
                    modelBaseRequestOptions:
                        endpoint.requestOptions(for: ModelID(
                            rawValue: "stealth/ox-alpha")))]))
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let profileRef = try XCTUnwrap(catalog.currentProfileRefs.first)
        let binding = try snapshot.resolve(profileRef).binding
        let exactRegistry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(chat: ModelRef(
                    endpoint: endpoint.id,
                    model: ModelID(rawValue: "stealth/ox-alpha")))),
            resolver: FixedSecretResolver(value: "test-secret"),
            inferenceCatalogSnapshot: snapshot)

        let exactRoute = try await exactRegistry.responsesRuntimeRoute(
            for: binding)

        XCTAssertEqual(exactRoute.reasoningEffort, "max")
        XCTAssertEqual(exactRoute.providerOptions, providerOptions)
        XCTAssertEqual(exactRoute.requestAdapter, .openRouter)
    }

    func testUnsupportedModelOptionsFailBeforeCredentialResolution()
        async throws
    {
        let endpoint = ProviderEndpoint(
            id: "example",
            baseURL: URL(string: "https://api.example.test/v1")!,
            apiKeyRef: .environment("EXAMPLE_API_KEY"),
            wire: .openai,
            modelRequestOptions: [
                "example-model": [
                    "temperature": .number(0.2),
                ],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(chat: ModelRef(
                    endpoint: endpoint.id,
                    model: ModelID(rawValue: "example-model")))),
            resolver: FailingSecretResolver())

        do {
            _ = try await registry.responsesRuntimeRoute()
            XCTFail("Unsupported options must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(
                "cannot project"))
            XCTAssertFalse(error.localizedDescription.contains(
                "secret resolver"))
        }
    }

    func testProviderPassthroughRejectsSecretMaterialBeforeCredentialResolution()
        async throws
    {
        let endpoint = ProviderEndpoint(
            id: "openrouter",
            baseURL: URL(string: "https://openrouter.example.test/api/v1")!,
            apiKeyRef: .environment("OPENROUTER_API_KEY"),
            wire: .openai,
            requestAdapter: .openRouter,
            modelRequestOptions: [
                "model": [
                    "provider": .object([
                        "authorization": .string(
                            "Bearer must-not-leak"),
                    ]),
                ],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(chat: ModelRef(
                    endpoint: endpoint.id,
                    model: ModelID(rawValue: "model")))),
            resolver: FailingSecretResolver())

        do {
            _ = try await registry.responsesRuntimeRoute()
            XCTFail("Secret-bearing provider options must fail closed")
        } catch {
            XCTAssertEqual(
                error as? InferenceCatalogError,
                .secretLikeRequestOptions)
            XCTAssertFalse(error.localizedDescription.contains(
                "must-not-leak"))
            XCTAssertFalse(error.localizedDescription.contains(
                "secret resolver"))
        }
    }

    func testResponsesRouteRejectsNonstandardCustomPath() async throws {
        let endpoint = ProviderEndpoint(
            id: "example",
            baseURL: URL(string: "https://api.example.test/v1")!,
            responsesEndpoint: URL(
                string: "https://api.example.test/custom-generation")!,
            apiKeyRef: .environment("EXAMPLE_API_KEY"),
            wire: .openai)
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: endpoint.id,
                        model: ModelID(rawValue: "example-model")))),
            resolver: FixedSecretResolver(value: "secret"))

        do {
            _ = try await registry.responsesRuntimeRoute()
            XCTFail("Expected an exact Responses URL validation failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("/responses"))
        }
    }

    func testThreadConfigurationKeepsProviderTokenOutOfToolEnvironment()
        async throws
    {
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "config-test"),
                mode: .cowork,
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                runtimeRootURL: URL(fileURLWithPath: "/tmp/runtime"),
                route: ResponsesRuntimeRoute(
                    endpointID: "example",
                    model: ModelID(rawValue: "example-model"),
                    baseURL: URL(string: "https://api.example.test/v1")!,
                    bearerToken: "must-not-enter-json",
                    providerOptions: [
                        "require_parameters": .bool(true),
                        "allow_fallbacks": .bool(false),
                        "order": .array([.string("openai")]),
                        "future_routing": .object([
                            "mode": .string("provider-owned"),
                        ]),
                    ],
                    requestAdapter: .openRouter)))

        let params = await session.threadLifecycleParameters()
        let data = try JSONEncoder().encode(JSONValue.object(params))
        let encoded = try XCTUnwrap(
            String(data: data, encoding: .utf8))

        XCTAssertTrue(encoded.contains("shell_environment_policy"))
        XCTAssertTrue(encoded.contains("\"shell_snapshot\":false"))
        XCTAssertTrue(encoded.contains(
            "\"default_mode_request_user_input\":false"))
        XCTAssertTrue(encoded.contains("\"inherit\":\"core\""))
        XCTAssertTrue(encoded.contains(
            "\"ignore_default_excludes\":false"))
        XCTAssertTrue(encoded.contains("INTATIS_*"))
        XCTAssertTrue(encoded.contains("CODEX_HOME"))
        XCTAssertTrue(encoded.contains("intatis_responses_provider"))
        XCTAssertTrue(encoded.contains("\"web_search\":\"disabled\""))
        XCTAssertFalse(encoded.contains("\"agents\":{\"enabled\":false}"))
        XCTAssertTrue(encoded.contains("\"multi_agent_v2\""))
        XCTAssertTrue(encoded.contains("\"enabled\":true"))
        XCTAssertTrue(encoded.contains(
            "\"hide_spawn_agent_metadata\":false"))
        XCTAssertTrue(encoded.contains(
            "\"expose_spawn_agent_model_overrides\":false"))
        XCTAssertTrue(encoded.contains("\"flat_tools\":true"))
        XCTAssertFalse(encoded.contains("tool_namespace"))
        XCTAssertTrue(encoded.contains("use Codex collaboration tools"))
        XCTAssertTrue(encoded.contains("require_parameters"))
        XCTAssertTrue(encoded.contains("allow_fallbacks"))
        XCTAssertTrue(encoded.contains("future_routing"))
        XCTAssertFalse(encoded.contains("x-intatis-openrouter"))
        XCTAssertFalse(encoded.contains("\"http_headers\""))
        XCTAssertFalse(encoded.contains("must-not-enter-json"))
    }

    func testChildProfilesMaterializeOfficialRoleProvidersWithoutSecrets()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootWorkspace = temporary.appendingPathComponent(
            "root-workspace",
            isDirectory: true)
        let childWorkspace = temporary.appendingPathComponent(
            "research-workspace",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootWorkspace,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: childWorkspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{}}'
          elif [ "$count" = "2" ]; then
            case "$line" in *'"multi_agent_v2"'*) ;; *) exit 51 ;; esac
            case "$line" in *'"flat_tools":true'*) ;; *) exit 55 ;; esac
            case "$line" in *'"intatis_agent_workspaces"'*) ;; *) exit 56 ;; esac
            case "$line" in *'"research"'*) ;; *) exit 52 ;; esac
            case "$line" in *'"intatis_agent_research"'*) ;; *) exit 53 ;; esac
            case "$line" in *'root-secret'*|*'child-secret'*) exit 54 ;; *) ;; esac
            echo '{"id":2,"result":{"thread":{"id":"thread-profile","turns":[],"status":{"type":"idle"}}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "child-profile"),
                mode: .cowork,
                workspaceURL: rootWorkspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "root",
                    model: ModelID(rawValue: "root-model"),
                    baseURL: URL(string: "https://root.example/v1")!,
                    bearerToken: "root-secret",
                    requestAdapter: .openRouter),
                approvalReviewer: .user,
                executableOverride: executable,
                childProfiles: [CodexRuntimeChildProfile(
                    roleName: "research",
                    description: "Research the assigned source material.",
                    workspaceURL: childWorkspace,
                    route: ResponsesRuntimeRoute(
                        endpointID: "research",
                        model: ModelID(rawValue: "research-model"),
                        baseURL: URL(string: "https://research.example/v1")!,
                        bearerToken: "child-secret",
                        reasoningEffort: "high"),
                    sandbox: .workspaceWrite)]))
        _ = try await session.start()
        await session.shutdown()

        let storage = CodexRuntimeStorage(rootURL: runtimeRoot)
        let roleURL = storage.childProfilesURL.appendingPathComponent(
            "intatis-research.toml")
        let roleData = try XCTUnwrap(
            DurableOwnerOnlyFile.read(from: roleURL))
        let role = try XCTUnwrap(
            String(data: roleData, encoding: .utf8))
        XCTAssertTrue(role.contains("name = \"research\""))
        XCTAssertTrue(role.contains("model = \"research-model\""))
        XCTAssertTrue(role.contains(
            "model_provider = \"intatis_agent_research\""))
        XCTAssertTrue(role.contains("model_reasoning_effort = \"high\""))
        XCTAssertTrue(role.contains("sandbox_mode = \"workspace-write\""))
        let encodedWorkspace = try XCTUnwrap(String(
            data: JSONEncoder.intatisCodex.encode(
                childWorkspace.resolvingSymlinksInPath()
                    .standardizedFileURL.path),
            encoding: .utf8))
        XCTAssertTrue(role.contains(encodedWorkspace))
        XCTAssertFalse(role.contains("root-secret"))
        XCTAssertFalse(role.contains("child-secret"))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: roleURL.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)

        let catalogData = try XCTUnwrap(
            DurableOwnerOnlyFile.read(from: storage.modelCatalogURL))
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData)
                as? [String: Any])
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        XCTAssertEqual(
            models.compactMap { $0["slug"] as? String },
            ["root-model", "research-model"])
        try assertBytesAreAbsent(Data("root-secret".utf8), below: runtimeRoot)
        try assertBytesAreAbsent(Data("child-secret".utf8), below: runtimeRoot)
    }

    func testThreadStartRegistersFlatDynamicToolsOnlyWhenRequested()
        async throws
    {
        let dynamicTools = CodexRuntimeDynamicTools(
            toolsetID: "business-v1",
            specs: [CodexRuntimeDynamicToolSpec(
                name: "business_echo",
                description: "Echo one value.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "value": .object([
                            "type": .string("string"),
                        ]),
                    ]),
                    "required": .array([.string("value")]),
                    "additionalProperties": .bool(false),
                ]))],
            handler: { _ in .text("ok") })
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "dynamic-config-test"),
                mode: .code,
                workspaceURL: URL(fileURLWithPath: "/tmp/workspace"),
                runtimeRootURL: URL(fileURLWithPath: "/tmp/runtime"),
                route: ResponsesRuntimeRoute(
                    endpointID: "example",
                    model: ModelID(rawValue: "example-model"),
                    baseURL: URL(string: "https://api.example.test/v1")!,
                    bearerToken: "secret"),
                dynamicTools: dynamicTools))

        let start = await session.threadLifecycleParameters(
            includeDynamicTools: true)
        let resume = await session.threadLifecycleParameters(
            includeDynamicTools: false)
        let encoded = String(decoding: try JSONEncoder().encode(
            JSONValue.object(start)), as: UTF8.self)

        if case .array(let registered)? = start["dynamicTools"] {
            XCTAssertEqual(registered.count, 1)
        } else {
            XCTFail("thread/start must contain dynamicTools")
        }
        XCTAssertNil(resume["dynamicTools"])
        XCTAssertTrue(encoded.contains("business_echo"))
        XCTAssertTrue(encoded.contains("\"type\":\"function\""))
        XCTAssertTrue(encoded.contains(
            "authoritative business-tool path"))
        XCTAssertFalse(encoded.contains("namespace"))
    }

    func testBusinessToolHostExportsDocumentBrowserAndImageRegistryWithoutFallbacks()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sessionID = SessionID(rawValue: "business-host-test")
        let log = try EventLog(
            session: sessionID,
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        let host = try CodexBusinessToolHost(
            sessionID: sessionID,
            agentID: AgentID(rawValue: "Coder"),
            workspaceURL: workspace,
            imageGenerator: FailingImageGenerationToolService(),
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                if request.tool == "web_fetch" {
                    return PermissionApprovalResolution(
                        decision: .deny,
                        action: .decline,
                        reason: "test denial",
                        risk: request.risk,
                        source: .user,
                        failureSource: .userDenied)
                }
                return PermissionApprovalResolution(
                    decision: .allow,
                    action: .approve,
                    risk: request.risk,
                    source: .user)
            })

        let names = try await host.registeredToolNames()
        let dynamicTools = try await host.dynamicTools()

        XCTAssertNoThrow(try dynamicTools.validate())
        XCTAssertEqual(names.count, 73)
        XCTAssertTrue(names.contains("read_docx"))
        XCTAssertTrue(names.contains("continue_xlsx_read"))
        XCTAssertTrue(names.contains("docx_create_document"))
        XCTAssertTrue(names.contains("pptx_add_slide"))
        XCTAssertTrue(names.contains("xlsx_set_cell_value"))
        XCTAssertTrue(names.contains("html_export_pdf"))
        XCTAssertTrue(names.contains("browser_navigate"))
        XCTAssertTrue(names.contains("browser_screenshot"))
        XCTAssertTrue(names.contains("web_fetch"))
        XCTAssertFalse(names.contains("read_file"))
        XCTAssertFalse(names.contains("exec_command"))
        XCTAssertTrue(names.contains("generate_image"))
        XCTAssertTrue(names.contains("edit_image"))
        XCTAssertFalse(names.contains("hosted_web_search"))
        XCTAssertFalse(names.contains("spawn_agent"))
        XCTAssertEqual(dynamicTools.specs.map(\.name), names)

        let invalid = await dynamicTools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "thread",
                turnID: "turn",
                callID: "call",
                tool: "read_docx",
                arguments: .object([:])))
        XCTAssertFalse(invalid.success)
        XCTAssertFalse(invalid.shouldInterruptTurn)

        let deniedNetwork = await dynamicTools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "thread",
                turnID: "turn",
                callID: "fetch",
                tool: "web_fetch",
                arguments: .object([
                    "url": .string("https://example.invalid/"),
                ])))
        XCTAssertFalse(deniedNetwork.success)

        let localRead = await dynamicTools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "thread",
                turnID: "turn",
                callID: "profiles",
                tool: "browser_profiles",
                arguments: .object([:])))
        XCTAssertTrue(localRead.success)
        let childAgentID = AgentID(rawValue: "codex:thread-child")
        let childRead = await dynamicTools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "thread-child",
                turnID: "turn-child",
                callID: "child-profiles",
                tool: "browser_profiles",
                arguments: .object([:]),
                agentID: childAgentID))
        XCTAssertTrue(childRead.success)
        let events = await log.replay().map(\.event)
        XCTAssertTrue(events.contains { event in
            guard case .permissionRequest(let payload) = event else {
                return false
            }
            return payload.tool == "web_fetch"
                && payload.effectiveApprovalMode == .manual
        })
        XCTAssertTrue(events.contains { event in
            guard case .permissionResolved(let payload) = event else {
                return false
            }
            return payload.tool == "browser_profiles"
                && payload.decision == .allow
        })
        XCTAssertTrue(events.contains { event in
            guard case .toolExecutionPrepared(let payload) = event else {
                return false
            }
            return payload.tool == "browser_profiles"
                && payload.toolCallID
                    == "codex:thread:turn:profiles"
        })
        XCTAssertTrue(events.contains { event in
            guard case .toolExecutionPrepared(let payload) = event else {
                return false
            }
            return payload.tool == "browser_profiles"
                && payload.toolCallID
                    == "codex:thread-child:turn-child:child-profiles"
                && payload.agent == childAgentID
                && payload.authorization?.agent == childAgentID
        })
        XCTAssertTrue(events.contains { event in
            guard case .toolExecutionSettled(let payload) = event else {
                return false
            }
            return payload.tool == "browser_profiles"
                && payload.outcome == .succeeded
                && payload.effectDisposition == .committed
        })
    }

    func testBusinessToolHostExecutesExactImageToolsForRootAndWritableChild()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let inputImage = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ])
        try inputImage.write(
            to: workspace.appendingPathComponent("input.png"))
        let sessionID = SessionID(rawValue: "codex-image-tools")
        let log = try EventLog(
            session: sessionID,
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        let imageGenerator = RecordingImageGenerationToolService()
        let permissionCapture = PermissionRequestCapture()
        let readOnlyProfile = CodexRuntimeChildProfile(
            roleName: "reader",
            description: "Read-only child.",
            workspaceURL: workspace,
            route: ResponsesRuntimeRoute(
                endpointID: "reader",
                model: ModelID(rawValue: "reader-model"),
                baseURL: URL(string: "https://reader.example/v1")!,
                bearerToken: "reader-token"),
            sandbox: .readOnly,
            permissionProfile: .readOnly)
        let host = try CodexBusinessToolHost(
            sessionID: sessionID,
            agentID: AgentID(rawValue: "main"),
            workspaceURL: workspace,
            childProfiles: [readOnlyProfile],
            imageGenerator: imageGenerator,
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                await permissionCapture.append(request)
                return PermissionApprovalResolution(
                    decision: .allow,
                    action: .approve,
                    reason: "test image tool approval",
                    risk: request.risk,
                    source: .user)
            })
        let tools = try await host.dynamicTools()

        XCTAssertEqual(tools.specs.count, 73)
        XCTAssertTrue(tools.contains(tool: "generate_image"))
        XCTAssertTrue(tools.contains(tool: "edit_image"))

        let secretBearingGenerate = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "root-thread",
                turnID: "root-turn",
                callID: "secret-generate",
                tool: "generate_image",
                arguments: .object([
                    "prompt": .string(
                        "Render sk-1234567890abcdef in the image"),
                    "outputPath": .string("secret.png"),
                ])))
        XCTAssertFalse(secretBearingGenerate.success)
        let secretPermissionRequests = await permissionCapture.snapshot()
        let secretGenerateCalls = await imageGenerator.recordedGenerateCalls()
        XCTAssertTrue(secretPermissionRequests.isEmpty)
        XCTAssertTrue(secretGenerateCalls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("secret.png").path))
        let secretAudit = String(
            data: try JSONEncoder().encode(await log.replay()),
            encoding: .utf8) ?? ""
        XCTAssertFalse(secretAudit.contains("sk-1234567890abcdef"))

        let rootGenerate = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "root-thread",
                turnID: "root-turn",
                callID: "root-generate",
                tool: "generate_image",
                arguments: .object([
                    "prompt": .string("A blue square"),
                    "outputPath": .string("generated.png"),
                    "size": .string("1024x1024"),
                    "count": .number(1),
                ])))
        XCTAssertTrue(rootGenerate.success)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("generated.png").path))

        let rootEdit = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "root-thread",
                turnID: "root-turn",
                callID: "root-edit",
                tool: "edit_image",
                arguments: .object([
                    "imagePath": .string("input.png"),
                    "prompt": .string("Make it green"),
                    "outputPath": .string("edited.png"),
                ])))
        XCTAssertTrue(rootEdit.success)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("edited.png").path))

        let writableChild = AgentID(rawValue: "codex:writable-child")
        let childGenerate = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "writable-child",
                turnID: "child-turn",
                callID: "child-generate",
                tool: "generate_image",
                arguments: .object([
                    "prompt": .string("A red circle"),
                    "outputPath": .string("child.png"),
                ]),
                agentID: writableChild,
                workspaceURL: workspace,
                workspaceAccess: .readWrite,
                permissionProfile: .reviewed))
        XCTAssertTrue(childGenerate.success)

        let requestCountBeforeReadOnly = await permissionCapture
            .snapshot().count
        let readOnlyResult = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "reader-child",
                turnID: "reader-turn",
                callID: "reader-generate",
                tool: "generate_image",
                arguments: .object([
                    "prompt": .string("Must not execute"),
                    "outputPath": .string("denied.png"),
                ]),
                agentID: AgentID(rawValue: "codex:reader-child"),
                workspaceURL: workspace,
                workspaceAccess: .readOnly,
                permissionProfile: .readOnly))
        XCTAssertFalse(readOnlyResult.success)
        let requestCountAfterReadOnly = await permissionCapture
            .snapshot().count
        XCTAssertEqual(
            requestCountAfterReadOnly,
            requestCountBeforeReadOnly)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("denied.png").path))

        let generateCalls = await imageGenerator.recordedGenerateCalls()
        let editCalls = await imageGenerator.recordedEditCalls()
        XCTAssertEqual(generateCalls.count, 2)
        XCTAssertEqual(generateCalls.first?.prompt, "A blue square")
        XCTAssertEqual(generateCalls.first?.size, "1024x1024")
        XCTAssertEqual(generateCalls.first?.count, 1)
        XCTAssertEqual(editCalls.count, 1)
        XCTAssertEqual(editCalls.first?.filename, "input.png")
        XCTAssertEqual(editCalls.first?.mime, "image/png")
        XCTAssertEqual(editCalls.first?.prompt, "Make it green")

        let prepared = (await log.replay()).compactMap { envelope
            -> ToolExecutionPreparedPayload? in
            guard case .toolExecutionPrepared(let payload) = envelope.event,
                  ["generate_image", "edit_image"].contains(payload.tool) else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(prepared.count, 3)
        XCTAssertTrue(prepared.contains {
            $0.tool == "generate_image"
                && $0.agent == AgentID(rawValue: "main")
                && $0.authorization?.requiredCapabilities == [.generateImage]
        })
        XCTAssertTrue(prepared.contains {
            $0.tool == "edit_image"
                && $0.authorization?.requiredCapabilities == [.editImage]
        })
        XCTAssertTrue(prepared.contains {
            $0.tool == "generate_image"
                && $0.agent == writableChild
                && $0.authorization?.requiredCapabilities == [.generateImage]
        })
        let shutdownSucceeded = await tools.shutdown()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testRootBusinessCapabilityLeaseUsesExactImageAndHostedSearchCapabilities()
    {
        let writable = CodexBusinessToolHost.rootBusinessCapabilityLease(
            id: CapabilityLeaseID(rawValue: "clease_image_writable"),
            workspaceAccess: .readWrite,
            includesSessionNaming: true,
            includesWorkTaskManagement: true)
        XCTAssertTrue(
            ToolCapability.exactImageMutationCapabilities.isSubset(
                of: writable.tools))
        XCTAssertFalse(writable.tools.contains(.generateMedia))
        XCTAssertFalse(writable.tools.contains(.hostedWebSearch))

        let searchable = CodexBusinessToolHost
            .rootBusinessCapabilityLease(
                id: CapabilityLeaseID(
                    rawValue: "clease_hosted_search_writable"),
                workspaceAccess: .readWrite,
                includesSessionNaming: true,
                includesWorkTaskManagement: true,
                includesHostedWebSearch: true)
        XCTAssertTrue(searchable.tools.contains(.hostedWebSearch))

        let readOnly = CodexBusinessToolHost.rootBusinessCapabilityLease(
            id: CapabilityLeaseID(rawValue: "clease_image_read_only"),
            workspaceAccess: .readOnly,
            includesSessionNaming: true,
            includesWorkTaskManagement: true,
            includesHostedWebSearch: true)
        XCTAssertTrue(readOnly.tools.isDisjoint(
            with: ToolCapability.exactImageMutationCapabilities))
        XCTAssertFalse(readOnly.tools.contains(.generateMedia))
        XCTAssertFalse(readOnly.tools.contains(.hostedWebSearch))
    }

    func testBusinessToolHostBindsHostedSearchToExactRootAndChildServices()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sessionID = SessionID(rawValue: "codex-hosted-search")
        let log = try EventLog(
            session: sessionID,
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        let rootService = RecordingHostedWebSearchToolService(
            result: "root search result")
        let childService = RecordingHostedWebSearchToolService(
            result: "child search result")
        let readOnlyService = RecordingHostedWebSearchToolService(
            result: "must not execute")
        let permissionCapture = PermissionRequestCapture()
        let route = ResponsesRuntimeRoute(
            endpointID: "test",
            model: ModelID(rawValue: "test-model"),
            baseURL: URL(string: "https://search.example/v1")!,
            bearerToken: "test-token",
            requestAdapter: .openRouter)
        let childProfiles = [
            CodexRuntimeChildProfile(
                roleName: "searcher",
                description: "Writable search child.",
                workspaceURL: workspace,
                route: route,
                sandbox: .workspaceWrite,
                permissionProfile: .reviewed,
                hostedWebSearchEnabled: true),
            CodexRuntimeChildProfile(
                roleName: "reader",
                description: "Read-only search child.",
                workspaceURL: workspace,
                route: route,
                sandbox: .readOnly,
                permissionProfile: .readOnly,
                hostedWebSearchEnabled: true),
        ]
        let host = try CodexBusinessToolHost(
            sessionID: sessionID,
            agentID: AgentID(rawValue: "main"),
            workspaceURL: workspace,
            childProfiles: childProfiles,
            imageGenerator: FailingImageGenerationToolService(),
            hostedWebSearchServices: [
                .root: rootService,
                .childRole("searcher"): childService,
                .childRole("reader"): readOnlyService,
            ],
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                await permissionCapture.append(request)
                return PermissionApprovalResolution(
                    decision: .allow,
                    action: .approve,
                    reason: "test hosted-search approval",
                    risk: request.risk,
                    source: .user)
            })
        let tools = try await host.dynamicTools()

        XCTAssertEqual(tools.specs.count, 74)
        XCTAssertTrue(tools.contains(tool: "hosted_web_search"))

        let rootResult = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "root-thread",
                turnID: "root-turn",
                callID: "root-search",
                tool: "hosted_web_search",
                arguments: .object([
                    "query": .string("  root query  "),
                ]),
                hostedWebSearchScope: .root))
        XCTAssertTrue(rootResult.success)
        XCTAssertEqual(
            rootResult.contentItems,
            [.inputText("root search result")])

        let childAgent = AgentID(rawValue: "codex:search-child")
        let childResult = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "search-child",
                turnID: "child-turn",
                callID: "child-search",
                tool: "hosted_web_search",
                arguments: .object([
                    "query": .string("child query"),
                ]),
                agentID: childAgent,
                workspaceURL: workspace,
                workspaceAccess: .readWrite,
                permissionProfile: .reviewed,
                hostedWebSearchScope: .childRole("searcher")))
        XCTAssertTrue(childResult.success)
        XCTAssertEqual(
            childResult.contentItems,
            [.inputText("child search result")])

        let requestCountBeforeDenied = await permissionCapture
            .snapshot().count
        let unsupportedChild = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "unsupported-child",
                turnID: "child-turn",
                callID: "unsupported-search",
                tool: "hosted_web_search",
                arguments: .object([
                    "query": .string("must not route"),
                ]),
                agentID: AgentID(rawValue: "codex:unsupported-child"),
                workspaceURL: workspace,
                workspaceAccess: .readWrite,
                permissionProfile: .reviewed))
        XCTAssertFalse(unsupportedChild.success)

        let readOnlyChild = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "reader-child",
                turnID: "reader-turn",
                callID: "reader-search",
                tool: "hosted_web_search",
                arguments: .object([
                    "query": .string("must not execute"),
                ]),
                agentID: AgentID(rawValue: "codex:reader-child"),
                workspaceURL: workspace,
                workspaceAccess: .readOnly,
                permissionProfile: .readOnly,
                hostedWebSearchScope: .childRole("reader")))
        XCTAssertFalse(readOnlyChild.success)

        let secretResult = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "root-thread",
                turnID: "root-turn",
                callID: "secret-search",
                tool: "hosted_web_search",
                arguments: .object([
                    "query": .string("find sk-1234567890abcdef"),
                ]),
                hostedWebSearchScope: .root))
        XCTAssertFalse(secretResult.success)

        let requestCountAfterDenied = await permissionCapture
            .snapshot().count
        let rootQueries = await rootService.recordedQueries()
        let childQueries = await childService.recordedQueries()
        let readOnlyQueries = await readOnlyService.recordedQueries()
        XCTAssertEqual(requestCountBeforeDenied, 2)
        XCTAssertEqual(requestCountAfterDenied, requestCountBeforeDenied)
        XCTAssertEqual(rootQueries, ["root query"])
        XCTAssertEqual(childQueries, ["child query"])
        XCTAssertTrue(readOnlyQueries.isEmpty)

        let prepared = (await log.replay()).compactMap { envelope
            -> ToolExecutionPreparedPayload? in
            guard case .toolExecutionPrepared(let payload) = envelope.event,
                  payload.tool == "hosted_web_search" else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(prepared.count, 2)
        XCTAssertTrue(prepared.contains {
            $0.agent == AgentID(rawValue: "main")
                && $0.authorization?.requiredCapabilities
                    == [.hostedWebSearch]
        })
        XCTAssertTrue(prepared.contains {
            $0.agent == childAgent
                && $0.authorization?.requiredCapabilities
                    == [.hostedWebSearch]
        })
        let audit = String(
            data: try JSONEncoder().encode(await log.replay()),
            encoding: .utf8) ?? ""
        XCTAssertFalse(audit.contains("sk-1234567890abcdef"))
        let shutdownSucceeded = await tools.shutdown()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testBusinessToolHostNeverUsesChildHostedSearchAsRootFallback()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let log = try EventLog(
            session: SessionID(rawValue: "codex-child-search-only"),
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        let childService = RecordingHostedWebSearchToolService(
            result: "child-only result")
        let permissionCapture = PermissionRequestCapture()
        let host = try CodexBusinessToolHost(
            sessionID: SessionID(rawValue: "codex-child-search-only"),
            agentID: AgentID(rawValue: "main"),
            workspaceURL: workspace,
            childProfiles: [CodexRuntimeChildProfile(
                roleName: "searcher",
                description: "Hosted-search child.",
                workspaceURL: workspace,
                route: ResponsesRuntimeRoute(
                    endpointID: "child",
                    model: ModelID(rawValue: "child-model"),
                    baseURL: URL(string: "https://child.example/v1")!,
                    bearerToken: "child-token",
                    requestAdapter: .openRouter),
                sandbox: .workspaceWrite,
                hostedWebSearchEnabled: true)],
            imageGenerator: FailingImageGenerationToolService(),
            hostedWebSearchServices: [
                .childRole("searcher"): childService,
            ],
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                await permissionCapture.append(request)
                return PermissionApprovalResolution(
                    decision: .allow,
                    action: .approve,
                    risk: request.risk,
                    source: .user)
            })
        let tools = try await host.dynamicTools()
        XCTAssertTrue(tools.contains(tool: "hosted_web_search"))

        let rootResult = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "root",
                turnID: "turn",
                callID: "root-must-not-fallback",
                tool: "hosted_web_search",
                arguments: .object([
                    "query": .string("root query"),
                ]),
                hostedWebSearchScope: .childRole("searcher")))
        XCTAssertFalse(rootResult.success)
        let rootPermissionRequests = await permissionCapture.snapshot()
        let rootQueries = await childService.recordedQueries()
        XCTAssertTrue(rootPermissionRequests.isEmpty)
        XCTAssertTrue(rootQueries.isEmpty)

        let childResult = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "child",
                turnID: "turn",
                callID: "child-search",
                tool: "hosted_web_search",
                arguments: .object([
                    "query": .string("child query"),
                ]),
                agentID: AgentID(rawValue: "codex:child"),
                workspaceURL: workspace,
                workspaceAccess: .readWrite,
                permissionProfile: .reviewed,
                hostedWebSearchScope: .childRole("searcher")))
        XCTAssertTrue(childResult.success)
        let childQueries = await childService.recordedQueries()
        XCTAssertEqual(childQueries, ["child query"])
        let shutdownSucceeded = await tools.shutdown()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testBusinessToolHostRejectsHostedSearchRoleWithoutExactService()
        throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let log = try EventLog(
            session: SessionID(rawValue: "codex-search-service-missing"),
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        XCTAssertThrowsError(try CodexBusinessToolHost(
            sessionID: SessionID(
                rawValue: "codex-search-service-missing"),
            agentID: AgentID(rawValue: "main"),
            workspaceURL: workspace,
            childProfiles: [CodexRuntimeChildProfile(
                roleName: "searcher",
                description: "Search child.",
                workspaceURL: workspace,
                route: ResponsesRuntimeRoute(
                    endpointID: "child",
                    model: ModelID(rawValue: "child-model"),
                    baseURL: URL(string: "https://child.example/v1")!,
                    bearerToken: "child-token",
                    requestAdapter: .openRouter),
                sandbox: .workspaceWrite,
                hostedWebSearchEnabled: true)],
            imageGenerator: FailingImageGenerationToolService(),
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                PermissionApprovalResolution(
                    decision: .deny,
                    risk: request.risk,
                    source: .user)
            })) { error in
                XCTAssertTrue(error.localizedDescription.contains(
                    "exactly match"))
            }
    }

    func testBusinessToolHostExposesRenameToRootAndRejectsChildBeforeAudit()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sessionID = SessionID(rawValue: "codex-session-rename")
        let logURL = temporary.appendingPathComponent("events.jsonl")
        let log = try EventLog(session: sessionID, fileURL: logURL)
        let naming = CodexSessionNamingCapture()
        let host = try CodexBusinessToolHost(
            sessionID: sessionID,
            agentID: AgentID(rawValue: "main"),
            workspaceURL: workspace,
            imageGenerator: FailingImageGenerationToolService(),
            sessionNaming: naming,
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                XCTFail("current-session rename must be deterministically allowed")
                return PermissionApprovalResolution(
                    decision: .deny,
                    risk: request.risk,
                    source: .user)
            })
        let tools = try await host.dynamicTools()
        let names = try await host.registeredToolNames()

        XCTAssertEqual(names.count, 74)
        XCTAssertTrue(names.contains("rename_session"))
        XCTAssertTrue(tools.specs.contains { $0.name == "rename_session" })

        let title = "Reconnect session naming"
        let rootResult = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "root-thread",
                turnID: "root-turn",
                callID: "rename-root",
                tool: "rename_session",
                arguments: .object([
                    "name": .string(title),
                ])))
        XCTAssertTrue(rootResult.success)

        let eventsAfterRoot = await log.replay().map(\.event)
        let prepared = try XCTUnwrap(eventsAfterRoot.compactMap { event
            -> ToolExecutionPreparedPayload? in
            guard case .toolExecutionPrepared(let payload) = event,
                  payload.tool == "rename_session" else {
                return nil
            }
            return payload
        }.first)
        XCTAssertEqual(prepared.authorization?.requiredCapabilities, [
            .renameSession,
        ])
        let rootNamingCalls = await naming.calls()
        XCTAssertEqual(
            rootNamingCalls,
            [.init(name: title, operationID: prepared.executionID)])
        XCTAssertFalse(eventsAfterRoot.contains {
            if case .permissionRequest = $0 { return true }
            return false
        })
        let durableBytes = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(durableBytes.contains(title))
        XCTAssertFalse(durableBytes.contains(
            ToolRegistry.authorizationDigest(#"{"name":"Reconnect session naming"}"#)))

        let eventCountBeforeChild = eventsAfterRoot.count
        let childResult = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "child-thread",
                turnID: "child-turn",
                callID: "rename-child",
                tool: "rename_session",
                arguments: .object([
                    "name": .string("Child must not rename"),
                ]),
                agentID: AgentID(rawValue: "codex:child-thread")))
        XCTAssertFalse(childResult.success)
        XCTAssertTrue(childResult.contentItems.contains {
            if case .inputText(let text) = $0 {
                return text.contains("only the exact current root agent")
            }
            return false
        })
        let eventCountAfterChild = await log.replay().count
        let namingCallsAfterChild = await naming.calls()
        XCTAssertEqual(eventCountAfterChild, eventCountBeforeChild)
        XCTAssertEqual(namingCallsAfterChild.count, 1)
    }

    func testBusinessToolHostRejectsSecretSessionNameBeforeAuthorizationOrPrepare()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sessionID = SessionID(rawValue: "codex-secret-session-rename")
        let logURL = temporary.appendingPathComponent("events.jsonl")
        let log = try EventLog(session: sessionID, fileURL: logURL)
        let naming = CodexSessionNamingCapture()
        let host = try CodexBusinessToolHost(
            sessionID: sessionID,
            agentID: AgentID(rawValue: "main"),
            workspaceURL: workspace,
            imageGenerator: FailingImageGenerationToolService(),
            sessionNaming: naming,
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                XCTFail("secret rename must fail before permission presentation")
                return PermissionApprovalResolution(
                    decision: .deny,
                    risk: request.risk,
                    source: .user)
            })
        let tools = try await host.dynamicTools()
        let secretTitle = "token=ghp_abcdef1234567890"

        let result = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "root-thread",
                turnID: "root-turn",
                callID: "rename-secret",
                tool: "rename_session",
                arguments: .object([
                    "name": .string(secretTitle),
                ])))

        XCTAssertFalse(result.success)
        let namingCalls = await naming.calls()
        XCTAssertEqual(namingCalls, [])
        let events = await log.replay().map(\.event)
        XCTAssertFalse(events.contains {
            if case .permissionRequest = $0 { return true }
            return false
        })
        XCTAssertFalse(events.contains {
            if case .toolExecutionPrepared = $0 { return true }
            return false
        })
        let denial = try XCTUnwrap(events.compactMap { event
            -> PermissionResolvedPayload? in
            guard case .permissionResolved(let payload) = event,
                  payload.tool == "rename_session" else {
                return nil
            }
            return payload
        }.first)
        XCTAssertEqual(denial.decision, .deny)
        XCTAssertNil(denial.authorization)
        XCTAssertFalse(
            try String(contentsOf: logURL, encoding: .utf8)
                .contains(secretTitle))
    }

    func testDeveloperInstructionsRequireOneRootFirstTaskRenameOnlyWhenAvailable() {
        let disabled = CodexRuntimeMode.cowork.developerInstructions(
            nativeCollaborationEnabled: true,
            businessToolsEnabled: true,
            sessionRenameEnabled: false)
        XCTAssertFalse(disabled.contains("rename_session"))

        let code = CodexRuntimeMode.code.developerInstructions(
            nativeCollaborationEnabled: false,
            businessToolsEnabled: true,
            sessionRenameEnabled: true)
        XCTAssertTrue(code.contains("first user task"))
        XCTAssertTrue(code.contains("after completing the work and its verification"))
        XCTAssertTrue(code.contains("call `rename_session` exactly once"))
        XCTAssertTrue(code.contains("date, time, SessionID"))
        XCTAssertTrue(code.contains("only when the user explicitly asks"))

        let cowork = CodexRuntimeMode.cowork.developerInstructions(
            nativeCollaborationEnabled: true,
            businessToolsEnabled: true,
            sessionRenameEnabled: true)
        XCTAssertTrue(cowork.contains("only to the exact root @main"))
        XCTAssertTrue(cowork.contains("Descendants must never call `rename_session`"))
        XCTAssertTrue(cowork.contains("last non-run-control tool call"))
        XCTAssertTrue(cowork.contains("after it succeeds"))
    }

    func testDynamicToolsRetainTheirBusinessToolHost() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let sessionID = SessionID(rawValue: "business-host-lifetime")
        let log = try EventLog(
            session: sessionID,
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        let dynamicTools: CodexRuntimeDynamicTools = try await {
            let host = try CodexBusinessToolHost(
                sessionID: sessionID,
                agentID: AgentID(rawValue: "main"),
                workspaceURL: workspace,
                imageGenerator: FailingImageGenerationToolService(),
                allowsShell: true,
                log: log,
                permissionResolver: { request in
                    PermissionApprovalResolution(
                        decision: .allow,
                        action: .approve,
                        risk: request.risk,
                        source: .user)
                })
            return try await host.dynamicTools()
        }()

        let result = await dynamicTools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "thread",
                turnID: "turn",
                callID: "profiles",
                tool: "browser_profiles",
                arguments: .object([:])))

        XCTAssertTrue(result.success)
        XCTAssertFalse(result.contentItems.isEmpty)
    }

    func testCoworkBusinessHostAddsWorkTaskCardsWithoutAgentCore()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sessionID = SessionID(rawValue: "cowork-product-tools")
        let log = try EventLog(
            session: sessionID,
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        let main = AgentID(rawValue: "main")
        let controller = CodexWorkTaskController(
            log: log,
            rootAgentID: main)
        let host = try CodexBusinessToolHost(
            sessionID: sessionID,
            agentID: main,
            workspaceURL: workspace,
            additionalRegistrations:
                CodexWorkTaskToolRegistry.registrations,
            workTaskManagerResolver: { agentID in
                await controller.manager(
                    for: agentID)
            },
            imageGenerator: FailingImageGenerationToolService(),
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                PermissionApprovalResolution(
                    decision: .allow,
                    action: .approve,
                    risk: request.risk,
                    source: .user)
            })
        let names = try await host.registeredToolNames()
        XCTAssertEqual(names.count, 78)
        for name in [
            "task_create", "task_update", "task_get", "task_list",
            "task_link_agent",
        ] {
            XCTAssertTrue(names.contains(name), "missing \(name)")
        }
        XCTAssertFalse(names.contains("get_goal"))
        XCTAssertFalse(names.contains("update_goal"))
        let tools = try await host.dynamicTools()
        let listed = await tools.execute(CodexRuntimeDynamicToolCall(
            threadID: "root",
            turnID: "turn-list",
            callID: "list",
            tool: "task_list",
            arguments: .object([:])))
        XCTAssertTrue(listed.success)
        XCTAssertTrue(listed.contentItems.contains {
            if case .inputText(let text) = $0 {
                return text.contains("\"tasks\":[]")
            }
            return false
        })
        let beforeChildCreate = await log.replay().count
        let childCreate = await tools.execute(
            CodexRuntimeDynamicToolCall(
                threadID: "thread-child",
                turnID: "turn-child-create",
                callID: "child-create",
                tool: "task_create",
                arguments: .object([
                    "title": .string("unauthorized"),
                    "description": .string("must fail before review"),
                ]),
                agentID: AgentID(rawValue: "codex:thread-child")))
        XCTAssertFalse(childCreate.success)
        let afterChildCreate = await log.replay().count
        XCTAssertEqual(afterChildCreate, beforeChildCreate)
    }

    func testRememberedBusinessToolApprovalIsScopedToCallingAgent()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sessionID = SessionID(rawValue: "remembered-agent-scope")
        let log = try EventLog(
            session: sessionID,
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        let capture = PermissionAgentCapture()
        let host = try CodexBusinessToolHost(
            sessionID: sessionID,
            agentID: AgentID(rawValue: "main"),
            workspaceURL: workspace,
            imageGenerator: FailingImageGenerationToolService(),
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                await capture.append(
                    request.agent ?? AgentID(rawValue: "missing-agent"))
                return PermissionApprovalResolution(
                    decision: .allow,
                    action: .approveAndRemember,
                    reason: "remember for this agent",
                    risk: request.risk,
                    source: .user)
            })
        let dynamicTools = try await host.dynamicTools()
        let arguments: JSONValue = .object([
            "profile": .string("missing-profile"),
            "confirmProfile": .string("missing-profile"),
        ])
        let child = AgentID(rawValue: "codex:thread-child")

        _ = await dynamicTools.execute(CodexRuntimeDynamicToolCall(
            threadID: "thread-child",
            turnID: "turn-child",
            callID: "delete-child",
            tool: "browser_profile_delete",
            arguments: arguments,
            agentID: child))
        _ = await dynamicTools.execute(CodexRuntimeDynamicToolCall(
            threadID: "thread-root",
            turnID: "turn-root",
            callID: "delete-root",
            tool: "browser_profile_delete",
            arguments: arguments))

        let agents = await capture.snapshot()
        XCTAssertEqual(
            agents,
            [child, AgentID(rawValue: "main")])
    }

    func testBusinessToolAuthorizationUsesVerifiedChildWorkspaceLease()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootWorkspace = temporary.appendingPathComponent(
            "root",
            isDirectory: true)
        let childWorkspace = temporary.appendingPathComponent(
            "child",
            isDirectory: true)
        let foreignWorkspace = temporary.appendingPathComponent(
            "foreign",
            isDirectory: true)
        for workspace in [rootWorkspace, childWorkspace, foreignWorkspace] {
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sessionID = SessionID(rawValue: "child-workspace-scope")
        let log = try EventLog(
            session: sessionID,
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        let capture = PermissionRequestCapture()
        let profile = CodexRuntimeChildProfile(
            roleName: "research",
            description: "Research one scope.",
            workspaceURL: childWorkspace,
            route: ResponsesRuntimeRoute(
                endpointID: "child",
                model: ModelID(rawValue: "child-model"),
                baseURL: URL(string: "https://child.example/v1")!,
                bearerToken: "child-token"),
            sandbox: .workspaceWrite)
        let host = try CodexBusinessToolHost(
            sessionID: sessionID,
            agentID: AgentID(rawValue: "main"),
            workspaceURL: rootWorkspace,
            childProfiles: [profile],
            imageGenerator: FailingImageGenerationToolService(),
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                await capture.append(request)
                return PermissionApprovalResolution(
                    decision: .deny,
                    action: .decline,
                    reason: "capture only",
                    risk: request.risk,
                    source: .user,
                    failureSource: .userDenied)
            })
        let tools = try await host.dynamicTools()
        let arguments: JSONValue = .object([
            "profile": .string("missing-profile"),
            "confirmProfile": .string("missing-profile"),
        ])
        let childAgent = AgentID(rawValue: "codex:child-thread")
        _ = await tools.execute(CodexRuntimeDynamicToolCall(
            threadID: "child-thread",
            turnID: "child-turn",
            callID: "child-call",
            tool: "browser_profile_delete",
            arguments: arguments,
            agentID: childAgent,
            workspaceURL: childWorkspace,
            workspaceAccess: .readWrite,
            permissionProfile: .reviewed))
        let requests = await capture.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.agent, childAgent)
        XCTAssertEqual(
            requests.first?.context?.workspaceLease?.rootPath,
            childWorkspace.resolvingSymlinksInPath()
                .standardizedFileURL.path)

        let rejected = await tools.execute(CodexRuntimeDynamicToolCall(
            threadID: "foreign-thread",
            turnID: "foreign-turn",
            callID: "foreign-call",
            tool: "browser_profile_delete",
            arguments: arguments,
            agentID: AgentID(rawValue: "codex:foreign-thread"),
            workspaceURL: foreignWorkspace,
            workspaceAccess: .readWrite,
            permissionProfile: .reviewed))
        XCTAssertFalse(rejected.success)
        XCTAssertTrue(rejected.contentItems.contains {
            if case .inputText(let text) = $0 {
                return text.contains(
                    "no unique matching user-approved workspace lease")
            }
            return false
        })
        let finalRequests = await capture.snapshot()
        XCTAssertEqual(finalRequests.count, 1)
    }

    func testInvalidDynamicExecutionLeaseSettlesWithoutEnteringExecutor()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let canonicalWorkspace = workspace.resolvingSymlinksInPath()
            .standardizedFileURL
        let sessionID = SessionID(rawValue: "invalid-dynamic-lease")
        let log = try EventLog(
            session: sessionID,
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        let executionLease = CodexRuntimeDynamicToolExecutionLease()
        let manager = CountingWorkTaskManager()
        let childProfile = CodexRuntimeChildProfile(
            roleName: "worker",
            description: "Update one assigned card.",
            workspaceURL: canonicalWorkspace,
            route: ResponsesRuntimeRoute(
                endpointID: "worker",
                model: ModelID(rawValue: "worker-model"),
                baseURL: URL(string: "https://worker.example/v1")!,
                bearerToken: "worker-token"),
            sandbox: .workspaceWrite,
            permissionProfile: .reviewed)
        let host = try CodexBusinessToolHost(
            sessionID: sessionID,
            agentID: AgentID(rawValue: "main"),
            workspaceURL: canonicalWorkspace,
            childProfiles: [childProfile],
            additionalRegistrations:
                CodexWorkTaskToolRegistry.registrations,
            workTaskManagerResolver: { _ in manager },
            imageGenerator: FailingImageGenerationToolService(),
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                executionLease.invalidate()
                return PermissionApprovalResolution(
                    decision: .allow,
                    action: .approve,
                    reason: "approved before the binding changed",
                    risk: request.risk,
                    source: .user)
            })
        let tools = try await host.dynamicTools()

        let result = await tools.execute(CodexRuntimeDynamicToolCall(
            threadID: "thread-child",
            turnID: "turn-child",
            callID: "update-card",
            tool: "task_update",
            arguments: .object([
                "task_id": .string("wt_test"),
                "expected_revision": .number(0),
                "progress_note": .string("must not execute"),
            ]),
            agentID: AgentID(rawValue: "codex:thread-child"),
            workspaceURL: canonicalWorkspace,
            workspaceAccess: .readWrite,
            permissionProfile: .reviewed,
            executionLease: executionLease))

        XCTAssertFalse(result.success)
        let executorInvocations = await manager.updateInvocationCount()
        XCTAssertEqual(executorInvocations, 0)
        let events = await log.replay().map(\.event)
        let prepared = events.compactMap { event
            -> ToolExecutionPreparedPayload? in
            guard case .toolExecutionPrepared(let payload) = event,
                  payload.toolCallID
                    == "codex:thread-child:turn-child:update-card" else {
                return nil
            }
            return payload
        }
        let settled = events.compactMap { event
            -> ToolExecutionSettledPayload? in
            guard case .toolExecutionSettled(let payload) = event,
                  payload.toolCallID
                    == "codex:thread-child:turn-child:update-card" else {
                return nil
            }
            return payload
        }
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.first?.executionID, prepared.first?.executionID)
        XCTAssertEqual(settled.first?.outcome, .denied)
        XCTAssertEqual(settled.first?.effectDisposition, .notStarted)
    }

    func testNestedRolelessDescendantInheritsParentReadOnlyProfile()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let canonicalWorkspace = workspace.resolvingSymlinksInPath()
            .standardizedFileURL
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        while IFS= read -r line; do
          request_id=$(printf '%s\n' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
          case "$line" in
            *'"method":"initialize"'*)
              echo '{"id":1,"result":{"userAgent":"fake"}}'
              ;;
            *'"method":"thread/start"'*)
              echo '{"id":2,"result":{"thread":{"id":"thread-root","turns":[],"status":{"type":"idle"}}}}'
              ;;
            *'"method":"turn/start"'*)
              echo '{"id":3,"result":{"turn":{"id":"turn-root","items":[],"status":"inProgress"}}}'
              echo '{"method":"turn/started","params":{"threadId":"thread-root","turn":{"id":"turn-root","items":[],"status":"inProgress"}}}'
              echo '{"method":"thread/started","params":{"thread":{"id":"thread-parent","sessionId":"thread-root","parentThreadId":"thread-root","agentRole":"readonly","cwd":"\(canonicalWorkspace.path)","modelProvider":"intatis","turns":[],"status":{"type":"active"}}}}'
              echo '{"method":"thread/started","params":{"thread":{"id":"thread-grandchild","sessionId":"thread-root","parentThreadId":"thread-parent","cwd":"\(canonicalWorkspace.path)","modelProvider":"intatis","turns":[],"status":{"type":"active"}}}}'
              echo '{"method":"item/tool/call","id":91,"params":{"threadId":"thread-grandchild","turnId":"turn-grandchild","callId":"call-grandchild","namespace":null,"tool":"business_echo","arguments":{"value":"nested"}}}'
              ;;
            *'"id":91'*)
              echo '{"method":"turn/completed","params":{"threadId":"thread-root","turn":{"id":"turn-root","items":[],"status":"completed"}}}'
              ;;
            *)
              exit 81
              ;;
          esac
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let capture = DynamicToolCallCapture()
        let dynamicTools = CodexRuntimeDynamicTools(
            toolsetID: "nested-policy",
            specs: [
                CodexRuntimeDynamicToolSpec(
                    name: "business_echo",
                    description: "Echo one value.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "value": .object([
                                "type": .string("string"),
                            ]),
                        ]),
                        "required": .array([.string("value")]),
                        "additionalProperties": .bool(false),
                    ])),
                CodexRuntimeDynamicToolSpec(
                    name: HostedWebSearchTool.descriptor.name,
                    description:
                        HostedWebSearchTool.descriptor.description,
                    inputSchema:
                        HostedWebSearchTool.descriptor.parameters),
            ],
            handler: { call in
                await capture.append(call)
                return .text("handled")
            })
        let childProfile = CodexRuntimeChildProfile(
            roleName: "readonly",
            description: "Read only.",
            workspaceURL: canonicalWorkspace,
            route: ResponsesRuntimeRoute(
                endpointID: "child",
                model: ModelID(rawValue: "child-model"),
                baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                bearerToken: "child-token"),
            sandbox: .readOnly,
            permissionProfile: .readOnly,
            hostedWebSearchEnabled: true)
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "nested-policy"),
                mode: .cowork,
                workspaceURL: canonicalWorkspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "root",
                    model: ModelID(rawValue: "root-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "root-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                dynamicTools: dynamicTools,
                childProfiles: [childProfile],
                rootPermissionProfile: .autopilot))

        _ = try await session.start()
        let result = try await session.runTurn(text: "delegate")
        let calls = await capture.snapshot()
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.threadID, "thread-grandchild")
        XCTAssertEqual(
            calls.first?.workspaceURL?.standardizedFileURL.path,
            canonicalWorkspace.path)
        XCTAssertEqual(calls.first?.workspaceAccess, .readOnly)
        XCTAssertEqual(calls.first?.permissionProfile, .readOnly)
        XCTAssertEqual(
            calls.first?.hostedWebSearchScope,
            .childRole("readonly"))
    }

    func testRuntimeRecordRoundTripsOwnerOnly() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: temporary)

        try storage.prepare()
        try storage.writeModelCatalog(
            modelID: "selected-model",
            baseInstructions: "test instructions",
            reasoningEffort: "max",
            multiAgentEnabled: false)
        try storage.writeRecord(
            threadID: "thread-test",
            mode: .cowork,
            workspacePath: "/tmp/workspace",
            dynamicToolsetID: "toolset-test")

        XCTAssertEqual(
            try storage.readRecord(),
            CodexRuntimeStorage.Record(
                schemaVersion: 2,
                runtimeVersion: CodexRuntimeExecutable.pinnedVersion,
                derivationID: CodexRuntimeExecutable.pinnedDerivationID,
                threadID: "thread-test",
                mode: .cowork,
                workspacePath: "/tmp/workspace",
                dynamicToolsetID: "toolset-test",
                materialized: true))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: storage.recordURL.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600)
        let catalogData = try XCTUnwrap(
            DurableOwnerOnlyFile.read(from: storage.modelCatalogURL))
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData)
                as? [String: Any])
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["slug"] as? String, "selected-model")
        XCTAssertEqual(
            models.first?["auto_review_model_override"] as? String,
            "selected-model")
        XCTAssertEqual(
            models.first?["supports_reasoning_summary_parameter"] as? Bool,
            false)
        XCTAssertEqual(
            models.first?["default_reasoning_summary"] as? String,
            "none")
        XCTAssertEqual(
            models.first?["multi_agent_version"] as? String,
            "disabled")
        XCTAssertEqual(
            models.first?["include_skills_usage_instructions"] as? Bool,
            true)
        let reasoningLevels = try XCTUnwrap(
            models.first?["supported_reasoning_levels"]
                as? [[String: Any]])
        XCTAssertEqual(reasoningLevels.count, 1)
        XCTAssertEqual(reasoningLevels.first?["effort"] as? String, "max")
        XCTAssertFalse(String(data: catalogData, encoding: .utf8)?
            .contains("test-secret") == true)
    }

    func testCoworkModelCatalogUsesMultiAgentV2WithoutLegacyFallback()
        throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: temporary)

        try storage.prepare()
        try storage.writeModelCatalog(
            modelID: "selected-model",
            baseInstructions: "test instructions",
            reasoningEffort: "high",
            multiAgentEnabled: true)

        let catalogData = try XCTUnwrap(
            DurableOwnerOnlyFile.read(from: storage.modelCatalogURL))
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData)
                as? [String: Any])
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])

        XCTAssertEqual(
            models.first?["multi_agent_version"] as? String,
            "v2")
        XCTAssertNotEqual(
            models.first?["multi_agent_version"] as? String,
            "v1")
    }

    func testRuntimeRecordRejectsEveryPriorRuntimeVersion() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: temporary)
        try storage.prepare()

        let priorRecord = CodexRuntimeStorage.Record(
            schemaVersion: 2,
            runtimeVersion: "0.145.0-intatis.2",
            threadID: "thread-prior",
            mode: .cowork,
            workspacePath: "/tmp/workspace",
            materialized: true)
        try DurableOwnerOnlyFile.writeAtomically(
            try JSONEncoder().encode(priorRecord),
            to: storage.recordURL,
            temporaryPrefix: ".codex-runtime-test-")
        XCTAssertThrowsError(try storage.readRecord()) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .unsafeRuntimeStorage)
        }

        let staleSameVersionRecord = CodexRuntimeStorage.Record(
            schemaVersion: 2,
            runtimeVersion: CodexRuntimeExecutable.pinnedVersion,
            derivationID: "0003-sha256:stale",
            threadID: "thread-stale-same-version",
            mode: .cowork,
            workspacePath: "/tmp/workspace",
            materialized: true)
        try DurableOwnerOnlyFile.writeAtomically(
            try JSONEncoder().encode(staleSameVersionRecord),
            to: storage.recordURL,
            temporaryPrefix: ".codex-runtime-test-")
        XCTAssertThrowsError(try storage.readRecord()) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .unsafeRuntimeStorage)
        }

        let unrelatedRecord = CodexRuntimeStorage.Record(
            schemaVersion: 2,
            runtimeVersion: "0.145.0-intatis.1",
            threadID: "thread-unrelated",
            mode: .cowork,
            workspacePath: "/tmp/workspace",
            materialized: true)
        try DurableOwnerOnlyFile.writeAtomically(
            try JSONEncoder().encode(unrelatedRecord),
            to: storage.recordURL,
            temporaryPrefix: ".codex-runtime-test-")
        XCTAssertThrowsError(try storage.readRecord()) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .unsafeRuntimeStorage)
        }
    }

    func testUnsafeExistingRuntimeDirectoryIsRejectedWithoutChmodRepair()
        throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)])
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: temporary.path)

        XCTAssertThrowsError(
            try CodexRuntimeStorage(rootURL: temporary).prepare()
        ) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .unsafeRuntimeStorage)
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: temporary.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o755)
    }

    func testRuntimeProcessLeaseIsSingleWriterAndRecoverable() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: temporary)
        try storage.prepare()

        let first = try CodexRuntimeProcessLease(
            url: storage.processLockURL)
        XCTAssertThrowsError(
            try CodexRuntimeProcessLease(url: storage.processLockURL)
        ) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .runtimeAlreadyActive)
        }
        first.release()
        let replacement = try CodexRuntimeProcessLease(
            url: storage.processLockURL)
        replacement.release()
    }

    func testPersistedShellSnapshotDirectoryFailsClosedWithoutDeletion()
        throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: temporary)
        try storage.prepare()
        let snapshots = storage.homeURL.appendingPathComponent(
            "shell_snapshots",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: snapshots,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])

        XCTAssertThrowsError(
            try storage.rejectPersistedShellSnapshots()
        ) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .shellSnapshotStoragePresent)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: snapshots.path))
    }

    func testModelCatalogRejectsControlCharacters() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: temporary)
        try storage.prepare()

        XCTAssertThrowsError(try storage.writeModelCatalog(
            modelID: "unsafe\nmodel",
            baseInstructions: "test")) { error in
                XCTAssertEqual(
                    error as? CodexRuntimeError,
                    .malformedProtocol(
                        "the selected Responses model id is invalid"))
            }
    }

    func testVersionVerifierRequiresPinnedRuntime() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        try Data("#!/bin/sh\necho 'codex-cli 9.9.9'\n".utf8)
            .write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        XCTAssertThrowsError(
            try CodexRuntimeExecutable.verifiedVersion(at: executable)
        ) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .incompatibleRuntime(
                    expected: "0.145.0-intatis.4",
                    actual: "9.9.9"))
        }
    }

    func testVersionVerifierRejectsSameVersionWithWrongDerivation() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:stale'
          exit 0
        fi
        exit 2
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        XCTAssertThrowsError(
            try CodexRuntimeExecutable.verifiedVersion(at: executable)
        ) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .incompatibleRuntimeDerivation(
                    expected: CodexRuntimeExecutable.pinnedDerivationID,
                    actual: "0003-sha256:stale"))
        }
    }

    func testVersionVerifierTimeoutForceStopsTermIgnoringExecutable()
        throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        try Data("#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n".utf8)
            .write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let started = Date()
        XCTAssertThrowsError(try CodexRuntimeExecutable.verifiedVersion(
            at: executable,
            expectedVersion: "0.145.0-intatis.4",
            timeoutSeconds: 0.1)) { error in
                XCTAssertEqual(
                    error as? CodexRuntimeError,
                    .requestTimedOut("codex --version"))
            }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testExplicitExecutableOverrideDoesNotFallThroughToInstalledRuntime()
        throws
    {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(
            try CodexRuntimeExecutable.locate(
                override: missing,
                environment: ProcessInfo.processInfo.environment)
        ) { error in
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .executableUnavailable)
        }
    }

    func testApprovalRequestIDRejectsUnsafeNumericValues() {
        XCTAssertNil(CodexRuntimeRequestID(
            wireValue: .number(Double.greatestFiniteMagnitude)))
        XCTAssertNil(CodexRuntimeRequestID(
            wireValue: .number(1.5)))
        XCTAssertEqual(
            CodexRuntimeRequestID(wireValue: .number(42))?.description,
            "42")
    }

    func testInstalledPinnedAppServerStartsIsolatedThread() async throws {
        let executable: URL
        do {
            executable = try CodexRuntimeExecutable.locate()
            _ = try CodexRuntimeExecutable.verifiedVersion(at: executable)
        } catch {
            throw XCTSkip(
                "Pinned Codex Runtime is not installed for the integration handshake")
        }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "code-test"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "offline-test",
                    model: ModelID(rawValue: "offline-test-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "offline-placeholder"),
                approvalReviewer: .automatic,
                executableOverride: executable,
                dynamicTools: CodexRuntimeDynamicTools(
                    toolsetID: "offline-dynamic-v1",
                    specs: [CodexRuntimeDynamicToolSpec(
                        name: "business_echo",
                        description: "Echo one value.",
                        inputSchema: .object([
                            "type": .string("object"),
                            "properties": .object([
                                "value": .object([
                                    "type": .string("string"),
                                ]),
                            ]),
                            "required": .array([.string("value")]),
                            "additionalProperties": .bool(false),
                        ]))],
                    handler: { _ in .text("offline") })))

        let identity = try await session.start()
        XCTAssertFalse(identity.threadID.isEmpty)
        XCTAssertEqual(identity.runtimeVersion, "0.145.0-intatis.4")
        XCTAssertEqual(identity.mode, .code)
        XCTAssertNil(try DurableOwnerOnlyFile.read(
            from: runtimeRoot.appendingPathComponent("runtime.json")))
        await session.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            runtimeRoot
                .appendingPathComponent("codex-home", isDirectory: true)
                .appendingPathComponent("shell_snapshots", isDirectory: true)
                .path))
        try assertBytesAreAbsent(
            Data("offline-placeholder".utf8),
            below: runtimeRoot)
    }

    func testInstalledPinnedAppServerRequestUserInputRoundTripsOnTheExistingMode()
        async throws
    {
        let executable: URL
        do {
            executable = try CodexRuntimeExecutable.locate()
            _ = try CodexRuntimeExecutable.verifiedVersion(at: executable)
        } catch {
            throw XCTSkip(
                "Pinned Codex Runtime is not installed for the structured-question probe")
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let server = try LocalResponsesServer { _, request in
            let input = request["input"] as? [[String: Any]] ?? []
            let hasAnswer = input.contains {
                $0["type"] as? String == "function_call_output"
                    && $0["call_id"] as? String
                        == "request-user-input-call"
            }
            if hasAnswer {
                return responsesMessageSSE(
                    responseID: "resp-input-final",
                    messageID: "msg-input-final",
                    model: "request-input-model",
                    text: "INPUT_OK")
            }
            let arguments = #"{"questions":[{"id":"probe_choice","header":"Probe","question":"Choose a probe answer.","options":[{"label":"Continue (Recommended)","description":"Resume the same turn."},{"label":"Stop","description":"Do not continue the probe."}]}]}"#
            let encodedArguments = String(
                data: try! JSONEncoder().encode(arguments),
                encoding: .utf8)!
            let item = """
            {"id":"fc-request-input","type":"function_call","status":"completed","name":"request_user_input","call_id":"request-user-input-call","arguments":\(encodedArguments)}
            """
            return responsesSSE([
                "{\"type\":\"response.created\",\"response\":{\"id\":\"resp-input-call\",\"status\":\"in_progress\",\"model\":\"request-input-model\",\"output\":[]}}",
                "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":\(item)}",
                "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp-input-call\",\"status\":\"completed\",\"model\":\"request-input-model\",\"output\":[\(item)],\"usage\":{\"input_tokens\":10,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2,\"output_tokens_details\":{\"reasoning_tokens\":0},\"total_tokens\":12}}}",
            ])
        }
        defer { server.stop() }
        let capture = UserInputRequestCapture()
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "installed-request-input"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "loopback-request-input",
                    model: ModelID(rawValue: "request-input-model"),
                    baseURL: try server.baseURL,
                    bearerToken: "offline-placeholder"),
                approvalReviewer: .user,
                executableOverride: executable,
                requestUserInputHandler: { request in
                    await capture.answer(request)
                }))

        _ = try await session.start()
        let result = try await session.runTurn(text: "Ask the probe question.")
        let capturedRequests = server.requests()
        let presented = await capture.snapshot()
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(presented.count, 1)
        XCTAssertEqual(capturedRequests.count, 2)
        let firstTools = capturedRequests.first?["tools"]
            as? [[String: Any]] ?? []
        XCTAssertTrue(firstTools.contains {
            $0["type"] as? String == "function"
                && $0["name"] as? String == "request_user_input"
                && ($0["description"] as? String)?
                    .contains("Default or Plan mode") == true
        })
        let secondInput = capturedRequests.last?["input"]
            as? [[String: Any]] ?? []
        let output = try XCTUnwrap(secondInput.first(where: {
            $0["type"] as? String == "function_call_output"
                && $0["call_id"] as? String
                    == "request-user-input-call"
        })?["output"] as? String)
        XCTAssertTrue(output.contains("probe_choice"))
        XCTAssertTrue(output.contains("Continue (Recommended)"))
        try assertBytesAreAbsent(
            Data("offline-placeholder".utf8),
            below: runtimeRoot)
    }

    func testInstalledPinnedCoworkAcceptsDirectV2AndCustomRoleConfig()
        async throws
    {
        let executable: URL
        do {
            executable = try CodexRuntimeExecutable.locate()
            _ = try CodexRuntimeExecutable.verifiedVersion(at: executable)
        } catch {
            throw XCTSkip(
                "Pinned Codex Runtime is not installed for the Cowork config handshake")
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootWorkspace = temporary.appendingPathComponent(
            "root",
            isDirectory: true)
        let childWorkspace = temporary.appendingPathComponent(
            "child",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootWorkspace,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: childWorkspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "cowork-config-test"),
                mode: .cowork,
                workspaceURL: rootWorkspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "offline-openrouter",
                    model: ModelID(rawValue: "root-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "root-offline-token",
                    providerOptions: [
                        "require_parameters": .bool(true),
                        "allow_fallbacks": .bool(false),
                    ],
                    requestAdapter: .openRouter),
                approvalReviewer: .automatic,
                executableOverride: executable,
                childProfiles: [CodexRuntimeChildProfile(
                    roleName: "research",
                    description: "Research one assigned scope.",
                    workspaceURL: childWorkspace,
                    route: ResponsesRuntimeRoute(
                        endpointID: "offline-child",
                        model: ModelID(rawValue: "child-model"),
                        baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                        bearerToken: "child-offline-token",
                        reasoningEffort: "medium"),
                    sandbox: .workspaceWrite)]))
        let identity = try await session.start()
        XCTAssertEqual(identity.mode, .cowork)
        XCTAssertFalse(identity.threadID.isEmpty)
        await session.shutdown()
        try assertBytesAreAbsent(
            Data("root-offline-token".utf8),
            below: runtimeRoot)
        try assertBytesAreAbsent(
            Data("child-offline-token".utf8),
            below: runtimeRoot)
    }

    func testAppServerTurnStreamsOfficialLifecycle() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-fake","turns":[],"createdAt":0,"updatedAt":0,"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-fake","items":[],"status":"inProgress"}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-fake","turn":{"id":"turn-fake","items":[],"status":"inProgress"}}}'
            echo '{"method":"error","params":{"error":{"message":"Reconnecting... 2/5","additionalDetails":"Upstream at https://private.example/v1 timed out"},"willRetry":true,"threadId":"thread-fake","turnId":"turn-fake"}}'
            echo '{"method":"warning","params":{"threadId":"thread-fake","message":"The upstream stream is being resumed."}}'
            echo '{"method":"skills/changed","params":{}}'
            echo '{"method":"item/mcpToolCall/progress","params":{"threadId":"thread-fake","turnId":"turn-fake","itemId":"mcp-fake","message":"Loading MCP result"}}'
            echo '{"method":"item/started","params":{"threadId":"thread-fake","turnId":"turn-fake","startedAtMs":1,"item":{"id":"message-commentary","type":"agentMessage","text":"","phase":"commentary","memoryCitation":null}}}'
            echo '{"method":"item/agentMessage/delta","params":{"threadId":"thread-fake","turnId":"turn-fake","itemId":"message-commentary","delta":"checking"}}'
            echo '{"method":"item/completed","params":{"threadId":"thread-fake","turnId":"turn-fake","completedAtMs":2,"item":{"id":"message-commentary","type":"agentMessage","text":"checking","phase":"commentary","memoryCitation":null}}}'
            echo '{"method":"item/started","params":{"threadId":"thread-fake","turnId":"turn-fake","startedAtMs":3,"item":{"id":"reasoning-fake","type":"reasoning","summary":[],"content":[]}}}'
            echo '{"method":"item/reasoning/textDelta","params":{"threadId":"thread-fake","turnId":"turn-fake","itemId":"reasoning-fake","delta":"considering","contentIndex":0}}'
            echo '{"method":"item/completed","params":{"threadId":"thread-fake","turnId":"turn-fake","completedAtMs":4,"item":{"id":"reasoning-fake","type":"reasoning","summary":[],"content":["considering"]}}}'
            echo '{"method":"item/started","params":{"threadId":"thread-fake","turnId":"turn-fake","startedAtMs":5,"item":{"id":"message-fake","type":"agentMessage","text":"","phase":"final_answer","memoryCitation":null}}}'
            echo '{"method":"item/agentMessage/delta","params":{"threadId":"thread-fake","turnId":"turn-fake","itemId":"message-fake","delta":"hello "}}'
            echo '{"method":"item/agentMessage/delta","params":{"threadId":"thread-fake","turnId":"turn-fake","itemId":"message-fake","delta":"world"}}'
            echo '{"method":"item/completed","params":{"threadId":"thread-fake","turnId":"turn-fake","completedAtMs":6,"item":{"id":"message-fake","type":"agentMessage","text":"hello world","phase":"final_answer","memoryCitation":null}}}'
            echo '{"method":"thread/tokenUsage/updated","params":{"threadId":"thread-fake","turnId":"turn-fake","tokenUsage":{"total":{"totalTokens":740,"inputTokens":650,"cachedInputTokens":400,"cacheWriteInputTokens":30,"outputTokens":90,"reasoningOutputTokens":20},"last":{"totalTokens":180,"inputTokens":150,"cachedInputTokens":100,"cacheWriteInputTokens":10,"outputTokens":30,"reasoningOutputTokens":10},"modelContextWindow":258400}}}'
            echo '{"method":"turn/completed","params":{"threadId":"thread-fake","turn":{"id":"turn-fake","items":[],"status":"completed","durationMs":1234}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "code-fake"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))
        let stream = await session.events()
        let eventTask = Task { () -> [CodexRuntimeEvent] in
            var received: [CodexRuntimeEvent] = []
            for await event in stream {
                received.append(event)
                if case .turnCompleted = event { break }
            }
            return received
        }

        _ = try await session.start()
        let result = try await session.runTurn(text: "test")
        let received = await eventTask.value
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.turnID, "turn-fake")
        let recordData = try XCTUnwrap(DurableOwnerOnlyFile.read(
            from: temporary
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("runtime.json")))
        XCTAssertEqual(
            try JSONDecoder().decode(
                CodexRuntimeStorage.Record.self,
                from: recordData).schemaVersion,
            2)
        XCTAssertTrue(received.contains(.assistantDelta(
            itemID: "message-commentary",
            text: "checking",
            phase: .commentary)))
        XCTAssertTrue(received.contains(.assistantCompleted(
            itemID: "message-commentary",
            text: "checking",
            phase: .commentary)))
        XCTAssertTrue(received.contains(.assistantDelta(
            itemID: "message-fake",
            text: "hello ",
            phase: .finalAnswer)))
        XCTAssertTrue(received.contains(.assistantCompleted(
            itemID: "message-fake",
            text: "hello world",
            phase: .finalAnswer)))
        XCTAssertTrue(received.contains(.appServerEvent(.init(
            eventID: "codex-app-server:error:turn-fake",
            method: "error",
            threadID: "thread-fake",
            turnID: "turn-fake",
            message: "Reconnecting... 2/5",
            details: "Upstream at [REDACTED_URL] timed out",
            willRetry: true))))
        XCTAssertTrue(received.contains(.appServerEvent(.init(
            eventID: "codex-app-server:warning:turn-fake",
            method: "warning",
            threadID: "thread-fake",
            turnID: "turn-fake",
            message: "The upstream stream is being resumed."))))
        XCTAssertTrue(received.contains(.appServerEvent(.init(
            eventID: "codex-app-server:skills/changed:session",
            method: "skills/changed"))))
        XCTAssertTrue(received.contains(.appServerEvent(.init(
            eventID: "codex-app-server:item/mcpToolCall/progress:mcp-fake",
            method: "item/mcpToolCall/progress",
            threadID: "thread-fake",
            turnID: "turn-fake",
            itemID: "mcp-fake",
            message: "Loading MCP result"))))
        XCTAssertFalse(received.contains { event in
            guard case .runtimeError(let code, _, _) = event else {
                return false
            }
            return code == "codex_runtime"
        })
        XCTAssertTrue(received.contains(.appServerEvent(.init(
            eventID:
                "codex-app-server:item/reasoning/textDelta:reasoning-fake",
            method: "item/reasoning/textDelta",
            threadID: "thread-fake",
            turnID: "turn-fake",
            itemID: "reasoning-fake",
            textDelta: "considering"))))
        XCTAssertTrue(received.contains(.appServerEvent(.init(
            eventID:
                "codex-app-server:thread/tokenUsage/updated:turn-fake",
            method: "thread/tokenUsage/updated",
            threadID: "thread-fake",
            turnID: "turn-fake"))))
        XCTAssertTrue(received.contains(.responsesUsage(
            CodexRuntimeResponsesUsage(
                turnID: "turn-fake",
                responseMessageItemID: "message-fake",
                inputTokens: 150,
                cachedInputTokens: 100,
                cacheWriteInputTokens: 10,
                outputTokens: 30,
                reasoningOutputTokens: 10,
                totalTokens: 180,
                durationMs: 1_234))))
        XCTAssertTrue(received.contains(.turnCompleted(result)))
    }

    func testTerminalAppServerErrorStopsRetryingAndFailsTheTurn() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-failed","turns":[],"createdAt":0,"updatedAt":0,"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-failed","items":[],"status":"inProgress"}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-failed","turn":{"id":"turn-failed","items":[],"status":"inProgress"}}}'
            echo '{"method":"error","params":{"error":{"message":"Upstream idle timeout exceeded","additionalDetails":"stream disconnected before completion"},"willRetry":false,"threadId":"thread-failed","turnId":"turn-failed"}}'
            echo '{"method":"turn/completed","params":{"threadId":"thread-failed","turn":{"id":"turn-failed","items":[],"status":"failed","error":{"message":"Upstream idle timeout exceeded"},"durationMs":42}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "code-failed"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))
        let stream = await session.events()
        let eventTask = Task { () -> [CodexRuntimeEvent] in
            var received: [CodexRuntimeEvent] = []
            for await event in stream {
                received.append(event)
                if case .turnCompleted = event { break }
            }
            return received
        }

        _ = try await session.start()
        do {
            _ = try await session.runTurn(text: "test")
            XCTFail("terminal App Server failure unexpectedly succeeded")
        } catch let error as CodexRuntimeError {
            guard case .turnFailed(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(message, "Upstream idle timeout exceeded")
        }
        let received = await eventTask.value
        await session.shutdown()

        XCTAssertTrue(received.contains(.appServerEvent(.init(
            eventID: "codex-app-server:error:turn-failed",
            method: "error",
            threadID: "thread-failed",
            turnID: "turn-failed",
            message: "Upstream idle timeout exceeded",
            details: "stream disconnected before completion",
            willRetry: false))))
        XCTAssertTrue(received.contains(.runtimeError(
            code: "codex_runtime",
            message: "Upstream idle timeout exceeded",
            fatal: false)))
        XCTAssertTrue(received.contains(.turnCompleted(
            CodexRuntimeTurnResult(
                turnID: "turn-failed",
                status: "failed",
                errorMessage: "Upstream idle timeout exceeded"))))
    }

    func testCurrentTimeServerRequestReturnsWholeUnixSeconds() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let responseCapture = temporary.appendingPathComponent(
            "current-time-response.json")
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-clock","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-clock","items":[],"status":"inProgress"}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-clock","turn":{"id":"turn-clock","items":[],"status":"inProgress"}}}'
            echo '{"method":"currentTime/read","id":88,"params":{"threadId":"thread-clock"}}'
          elif [ "$count" = "4" ]; then
            printf '%s\n' "$line" > '\(responseCapture.path)'
            echo '{"method":"turn/completed","params":{"threadId":"thread-clock","turn":{"id":"turn-clock","items":[],"status":"completed"}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "clock-test"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))
        _ = try await session.start()
        let earliest = floor(Date().timeIntervalSince1970)
        let result = try await session.runTurn(text: "what time is it")
        let latest = floor(Date().timeIntervalSince1970)
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        let response = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data(contentsOf: responseCapture))
        XCTAssertEqual(response["id"], .number(88))
        guard case .object(let resultObject)? = response["result"],
              case .number(let currentTimeAt)? = resultObject[
                "currentTimeAt"] else {
            return XCTFail("currentTime/read response is malformed")
        }
        XCTAssertEqual(currentTimeAt, floor(currentTimeAt))
        XCTAssertGreaterThanOrEqual(currentTimeAt, earliest)
        XCTAssertLessThanOrEqual(currentTimeAt, latest)
    }

    func testImplicitModelRerouteFailsClosedWithoutStrandingTurnWaiter()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-reroute","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-reroute","items":[],"status":"inProgress"}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-reroute","turn":{"id":"turn-reroute","items":[],"status":"inProgress"}}}'
            echo '{"method":"model/rerouted","params":{"threadId":"thread-reroute","turnId":"turn-reroute","fromModel":"selected-model","toModel":"other-model","reason":"capacity"}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "reroute-test"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "selected-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))
        let stream = await session.events()
        let eventTask = Task { () -> [CodexRuntimeEvent] in
            var events: [CodexRuntimeEvent] = []
            for await event in stream {
                events.append(event)
                if case .runtimeError(_, _, let fatal) = event, fatal {
                    return events
                }
            }
            return events
        }

        _ = try await session.start()
        do {
            _ = try await session.runTurn(text: "do not reroute")
            XCTFail("implicit model reroute unexpectedly succeeded")
        } catch let error as CodexRuntimeError {
            guard case .malformedProtocol(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("does not accept implicit model rerouting"))
        }
        let events = await eventTask.value
        await session.shutdown()

        XCTAssertTrue(events.contains(.appServerEvent(.init(
            eventID: "codex-app-server:model/rerouted:turn-reroute",
            method: "model/rerouted",
            threadID: "thread-reroute",
            turnID: "turn-reroute",
            fromModel: "selected-model",
            toModel: "other-model",
            reason: "capacity"))))
        XCTAssertTrue(events.contains { event in
            guard case .runtimeError(let code, let message, let fatal) = event
            else { return false }
            return code == "codex_protocol"
                && fatal
                && message.contains("implicit model rerouting")
        })
    }

    func testPinnedExperimentalAppServerMethodInventoryIsFullyAudited()
        throws
    {
        let executable: URL
        do {
            executable = try CodexRuntimeExecutable.locate()
            _ = try CodexRuntimeExecutable.verifiedVersion(at: executable)
        } catch {
            throw XCTSkip(
                "The exact pinned Codex Runtime is not installed: \(error)")
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let process = Process()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = [
            "app-server",
            "generate-json-schema",
            "--experimental",
            "--out",
            temporary.path,
        ]
        process.standardOutput = Pipe()
        process.standardError = standardError
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            XCTFail("pinned App Server schema generation timed out")
            return
        }
        process.waitUntilExit()
        let diagnostic = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "schema generation failed: \(diagnostic)")

        let requestMethods = try appServerProtocolMethods(
            at: temporary.appendingPathComponent("ServerRequest.json"))
        let supportedRequests: Set<String> = [
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval",
            "item/tool/call",
            "item/tool/requestUserInput",
            "currentTime/read",
        ]
        let intentionallyUnsupportedRequests: Set<String> = [
            "mcpServer/elicitation/request",
            "account/chatgptAuthTokens/refresh",
            "attestation/generate",
            "applyPatchApproval",
            "execCommandApproval",
        ]
        XCTAssertEqual(
            requestMethods,
            supportedRequests.union(intentionallyUnsupportedRequests),
            "A pinned server request was added, removed, or left unaudited")

        let notificationMethods = try appServerProtocolMethods(
            at: temporary.appendingPathComponent("ServerNotification.json"))
        XCTAssertEqual(notificationMethods, [
            "error",
            "thread/started",
            "thread/status/changed",
            "thread/archived",
            "thread/deleted",
            "thread/unarchived",
            "thread/closed",
            "skills/changed",
            "thread/name/updated",
            "thread/goal/updated",
            "thread/goal/cleared",
            "thread/environment/connected",
            "thread/environment/disconnected",
            "thread/settings/updated",
            "thread/tokenUsage/updated",
            "turn/started",
            "hook/started",
            "turn/completed",
            "hook/completed",
            "turn/diff/updated",
            "turn/plan/updated",
            "item/started",
            "item/autoApprovalReview/started",
            "item/autoApprovalReview/completed",
            "item/completed",
            "item/agentMessage/delta",
            "item/plan/delta",
            "command/exec/outputDelta",
            "process/outputDelta",
            "process/exited",
            "item/commandExecution/outputDelta",
            "item/commandExecution/terminalInteraction",
            "item/fileChange/outputDelta",
            "item/fileChange/patchUpdated",
            "serverRequest/resolved",
            "item/mcpToolCall/progress",
            "mcpServer/oauthLogin/completed",
            "mcpServer/startupStatus/updated",
            "account/updated",
            "account/rateLimits/updated",
            "app/list/updated",
            "remoteControl/status/changed",
            "externalAgentConfig/import/progress",
            "externalAgentConfig/import/completed",
            "fs/changed",
            "item/reasoning/summaryTextDelta",
            "item/reasoning/summaryPartAdded",
            "item/reasoning/textDelta",
            "thread/compacted",
            "model/rerouted",
            "model/verification",
            "turn/moderationMetadata",
            "model/safetyBuffering/updated",
            "warning",
            "guardianWarning",
            "deprecationNotice",
            "configWarning",
            "fuzzyFileSearch/sessionUpdated",
            "fuzzyFileSearch/sessionCompleted",
            "thread/realtime/started",
            "thread/realtime/itemAdded",
            "thread/realtime/transcript/delta",
            "thread/realtime/transcript/done",
            "thread/realtime/outputAudio/delta",
            "thread/realtime/sdp",
            "thread/realtime/error",
            "thread/realtime/closed",
            "windows/worldWritableWarning",
            "windowsSandbox/setupCompleted",
            "account/login/completed",
        ], "The pinned notification inventory changed without an audit")
    }

    func testAppServerDynamicToolCallExecutesClientHandlerAndReturnsContent()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            case "$line" in
              *'"experimentalApi":true'*) ;;
              *) exit 11 ;;
            esac
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            case "$line" in
              *'"dynamicTools"'*'"business_echo"'*'"type":"function"'*) ;;
              *) exit 12 ;;
            esac
            echo '{"id":2,"result":{"thread":{"id":"thread-dynamic","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-dynamic","items":[],"status":"inProgress"}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-dynamic","turn":{"id":"turn-dynamic","items":[],"status":"inProgress"}}}'
            echo '{"method":"item/started","params":{"threadId":"thread-dynamic","turnId":"turn-dynamic","item":{"id":"call-dynamic","type":"dynamicToolCall","tool":"business_echo","arguments":{"value":"hello"},"status":"inProgress"}}}'
            echo '{"method":"item/tool/call","id":99,"params":{"threadId":"thread-dynamic","turnId":"turn-dynamic","callId":"call-dynamic","namespace":null,"tool":"business_echo","arguments":{"value":"hello"}}}'
          elif [ "$count" = "4" ]; then
            case "$line" in
              *'"id":99'*'handled hello'*'"success":true'*) ;;
              *) exit 13 ;;
            esac
            echo '{"method":"item/completed","params":{"threadId":"thread-dynamic","turnId":"turn-dynamic","item":{"id":"call-dynamic","type":"dynamicToolCall","tool":"business_echo","arguments":{"value":"hello"},"status":"completed","contentItems":[{"type":"inputText","text":"handled hello"}],"success":true}}}'
            echo '{"method":"turn/completed","params":{"threadId":"thread-dynamic","turn":{"id":"turn-dynamic","items":[],"status":"completed"}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let rootScopeCapture = DynamicToolCallCapture()
        let dynamicTools = CodexRuntimeDynamicTools(
            toolsetID: "business-v1",
            specs: [
                CodexRuntimeDynamicToolSpec(
                    name: "business_echo",
                    description: "Echo one value.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "value": .object([
                                "type": .string("string"),
                            ]),
                        ]),
                        "required": .array([.string("value")]),
                        "additionalProperties": .bool(false),
                    ])),
                CodexRuntimeDynamicToolSpec(
                    name: HostedWebSearchTool.descriptor.name,
                    description:
                        HostedWebSearchTool.descriptor.description,
                    inputSchema:
                        HostedWebSearchTool.descriptor.parameters),
            ],
            handler: { call in
                await rootScopeCapture.append(call)
                guard case .object(let arguments) = call.arguments,
                      case .string(let value)? = arguments["value"] else {
                    return .text("invalid", success: false)
                }
                return .text("handled \(value)")
            })
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "dynamic-call-test"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                dynamicTools: dynamicTools,
                rootHostedWebSearchEnabled: true))

        _ = try await session.start()
        let result = try await session.runTurn(text: "echo")
        let rootCalls = await rootScopeCapture.snapshot()
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(rootCalls.first?.hostedWebSearchScope, .root)
        XCTAssertEqual(result.turnID, "turn-dynamic")
        XCTAssertEqual(
            try CodexRuntimeStorage(rootURL: runtimeRoot)
                .readRecord()?.dynamicToolsetID,
            "business-v1")
    }

    func testAppServerHostedSearchCallReachesExactBusinessHostService()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            case "$line" in
              *'"experimentalApi":true'*) ;;
              *) exit 21 ;;
            esac
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            case "$line" in
              *'"dynamicTools"'*'"hosted_web_search"'*'"type":"function"'*) ;;
              *) exit 22 ;;
            esac
            echo '{"id":2,"result":{"thread":{"id":"thread-search","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-search","items":[],"status":"inProgress"}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-search","turn":{"id":"turn-search","items":[],"status":"inProgress"}}}'
            echo '{"method":"item/started","params":{"threadId":"thread-search","turnId":"turn-search","item":{"id":"call-search","type":"dynamicToolCall","tool":"hosted_web_search","arguments":{"query":"app server query"},"status":"inProgress"}}}'
            echo '{"method":"item/tool/call","id":99,"params":{"threadId":"thread-search","turnId":"turn-search","callId":"call-search","namespace":null,"tool":"hosted_web_search","arguments":{"query":"app server query"}}}'
          elif [ "$count" = "4" ]; then
            case "$line" in *'"id":99'*) ;; *) exit 23 ;; esac
            case "$line" in *'root app-server search result'*) ;; *) exit 24 ;; esac
            case "$line" in *'"success":true'*) ;; *) exit 25 ;; esac
            echo '{"method":"item/completed","params":{"threadId":"thread-search","turnId":"turn-search","item":{"id":"call-search","type":"dynamicToolCall","tool":"hosted_web_search","arguments":{"query":"app server query"},"status":"completed","contentItems":[{"type":"inputText","text":"root app-server search result"}],"success":true}}}'
            echo '{"method":"turn/completed","params":{"threadId":"thread-search","turn":{"id":"turn-search","items":[],"status":"completed"}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let sessionID = SessionID(rawValue: "app-server-hosted-search")
        let log = try EventLog(
            session: sessionID,
            fileURL: temporary.appendingPathComponent("events.jsonl"))
        let service = RecordingHostedWebSearchToolService(
            result: "root app-server search result")
        let host = try CodexBusinessToolHost(
            sessionID: sessionID,
            agentID: AgentID(rawValue: "main"),
            workspaceURL: workspace,
            imageGenerator: FailingImageGenerationToolService(),
            hostedWebSearchServices: [.root: service],
            allowsShell: true,
            log: log,
            permissionResolver: { request in
                PermissionApprovalResolution(
                    decision: .allow,
                    action: .approve,
                    reason: "test hosted-search approval",
                    risk: request.risk,
                    source: .user)
            })
        let dynamicTools = try await host.dynamicTools()
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: sessionID,
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                dynamicTools: dynamicTools,
                rootHostedWebSearchEnabled: true))

        _ = try await session.start()
        let result = try await session.runTurn(text: "search")
        await session.shutdown()
        let recordedQueries = await service.recordedQueries()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(recordedQueries, ["app server query"])
        let events = await log.replay().map(\.event)
        XCTAssertTrue(events.contains { event in
            guard case .toolExecutionPrepared(let prepared) = event else {
                return false
            }
            return prepared.tool == "hosted_web_search"
                && prepared.authorization?.requiredCapabilities
                    == [.hostedWebSearch]
        })
        XCTAssertTrue(events.contains { event in
            guard case .toolExecutionSettled(let settled) = event else {
                return false
            }
            return settled.prepared.tool == "hosted_web_search"
                && settled.outcome == .succeeded
        })
    }

    func testAppServerRequestUserInputUsesSingleModeHostCallbackAndResumesTurn()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            case "$line" in *'"default_mode_request_user_input":true'*) ;; *) exit 31 ;; esac
            case "$line" in *'"collaborationMode"'*) exit 32 ;; *) ;; esac
            echo '{"id":2,"result":{"thread":{"id":"thread-input","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            case "$line" in *'"collaborationMode"'*) exit 33 ;; *) ;; esac
            echo '{"id":3,"result":{"turn":{"id":"turn-input","items":[],"status":"inProgress"}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-input","turn":{"id":"turn-input","items":[],"status":"inProgress"}}}'
            echo '{"method":"item/tool/requestUserInput","id":99,"params":{"threadId":"thread-input","turnId":"turn-input","itemId":"request-input-call","questions":[{"id":"probe_choice","header":"Probe","question":"Choose a probe answer.","options":[{"label":"Continue (Recommended)","description":"Resume the same turn."},{"label":"Stop","description":"Do not continue the probe."}],"isOther":true,"isSecret":false}],"autoResolutionMs":null}}'
          elif [ "$count" = "4" ]; then
            case "$line" in *'"id":99'*) ;; *) exit 34 ;; esac
            case "$line" in *'"probe_choice"'*'Continue (Recommended)'*) ;; *) exit 35 ;; esac
            echo '{"method":"serverRequest/resolved","params":{"threadId":"thread-input","requestId":99}}'
            echo '{"method":"turn/completed","params":{"threadId":"thread-input","turn":{"id":"turn-input","items":[],"status":"completed"}}}'
          else
            exit 36
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let capture = UserInputRequestCapture()
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "request-user-input-root"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                requestUserInputHandler: { request in
                    await capture.answer(request)
                }))

        _ = try await session.start()
        let result = try await session.runTurn(text: "ask")
        let requests = await capture.snapshot()
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.threadID, "thread-input")
        XCTAssertEqual(request.turnID, "turn-input")
        XCTAssertEqual(request.itemID, "request-input-call")
        XCTAssertNil(request.agentID)
        XCTAssertNil(request.autoResolutionMilliseconds)
        XCTAssertEqual(request.questions.count, 1)
        XCTAssertEqual(request.questions.first?.id, "probe_choice")
        XCTAssertEqual(request.questions.first?.header, "Probe")
        XCTAssertEqual(request.questions.first?.allowsOther, true)
        XCTAssertEqual(
            request.questions.first?.options.map(\.label),
            ["Continue (Recommended)", "Stop"])
    }

    func testAppServerAutoResolvedUserInputCancelsTheHostCallback()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-auto-input","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-auto-input","items":[],"status":"inProgress"}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-auto-input","turn":{"id":"turn-auto-input","items":[],"status":"inProgress"}}}'
            echo '{"method":"item/tool/requestUserInput","id":101,"params":{"threadId":"thread-auto-input","turnId":"turn-auto-input","itemId":"request-auto-call","questions":[{"id":"probe_choice","header":"Probe","question":"Choose a probe answer.","options":[{"label":"Continue (Recommended)","description":"Resume the same turn."},{"label":"Stop","description":"Do not continue the probe."}],"isOther":true,"isSecret":false}],"autoResolutionMs":60000}}'
            echo '{"method":"serverRequest/resolved","params":{"threadId":"thread-auto-input","requestId":101}}'
            echo '{"method":"turn/completed","params":{"threadId":"thread-auto-input","turn":{"id":"turn-auto-input","items":[],"status":"completed"}}}'
          else
            exit 41
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let capture = BlockingUserInputRequestCapture()
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "request-user-input-auto"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                requestUserInputHandler: { request in
                    try await capture.wait(request)
                }))

        _ = try await session.start()
        let result = try await session.runTurn(text: "ask")
        for _ in 0..<100 {
            if await capture.cancellations() > 0 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let requests = await capture.snapshot()
        let cancellations = await capture.cancellations()
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests.first?.autoResolutionMilliseconds,
            60_000)
        XCTAssertEqual(cancellations, 1)
    }

    func testVerifiedCoworkChildUserInputKeepsExactAgentIdentity()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let canonicalWorkspace = workspace.resolvingSymlinksInPath()
            .standardizedFileURL
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-root-input","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-root-input","items":[],"status":"inProgress"}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-root-input","turn":{"id":"turn-root-input","items":[],"status":"inProgress"}}}'
            echo '{"method":"item/tool/requestUserInput","id":102,"params":{"threadId":"thread-input-child","turnId":"turn-child-input","itemId":"request-child-call","questions":[{"id":"probe_choice","header":"Probe","question":"Choose a probe answer.","options":[{"label":"Continue (Recommended)","description":"Resume the same turn."},{"label":"Stop","description":"Do not continue the probe."}],"isOther":true,"isSecret":false}],"autoResolutionMs":null}}'
          elif [ "$count" = "4" ]; then
            case "$line" in *'"method":"thread/read"'*'"threadId":"thread-input-child"'*|*'"threadId":"thread-input-child"'*'"method":"thread/read"'*) ;; *) exit 51 ;; esac
            echo '{"id":4,"result":{"thread":{"id":"thread-input-child","sessionId":"thread-root-input","parentThreadId":"thread-root-input","agentNickname":"research","agentRole":"research","cwd":"\(canonicalWorkspace.path)","modelProvider":"intatis","preview":"ask","createdAt":1,"canAcceptDirectInput":true,"turns":[],"status":{"type":"active","activeFlags":[]}}}}'
          elif [ "$count" = "5" ]; then
            case "$line" in *'"id":102'*) ;; *) exit 51 ;; esac
            echo '{"method":"serverRequest/resolved","params":{"threadId":"thread-input-child","requestId":102}}'
            echo '{"method":"turn/completed","params":{"threadId":"thread-root-input","turn":{"id":"turn-root-input","items":[],"status":"completed"}}}'
          else
            exit 52
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let capture = UserInputRequestCapture()
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "request-user-input-child"),
                mode: .cowork,
                workspaceURL: canonicalWorkspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                requestUserInputHandler: { request in
                    await capture.answer(request)
                }))

        _ = try await session.start()
        let result = try await session.runTurn(text: "delegate")
        let requests = await capture.snapshot()
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.threadID, "thread-input-child")
        XCTAssertEqual(requests.first?.turnID, "turn-child-input")
        XCTAssertEqual(
            requests.first?.agentID,
            AgentID(rawValue: "codex:thread-input-child"))
    }

    func testSecretUserInputQuestionFailsBeforeHostPresentation()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-secret-input","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-secret-input","items":[],"status":"inProgress"}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-secret-input","turn":{"id":"turn-secret-input","items":[],"status":"inProgress"}}}'
            echo '{"method":"item/tool/requestUserInput","id":103,"params":{"threadId":"thread-secret-input","turnId":"turn-secret-input","itemId":"request-secret-call","questions":[{"id":"probe_choice","header":"Secret","question":"Enter a secret.","options":[{"label":"Continue (Recommended)","description":"Resume the same turn."},{"label":"Stop","description":"Do not continue the probe."}],"isOther":true,"isSecret":true}],"autoResolutionMs":null}}'
          elif [ "$count" = "4" ]; then
            case "$line" in *'"id":103'*) ;; *) exit 61 ;; esac
            case "$line" in *'"error"'*) ;; *) exit 63 ;; esac
            echo '{"method":"turn/completed","params":{"threadId":"thread-secret-input","turn":{"id":"turn-secret-input","items":[],"status":"completed"}}}'
          else
            exit 62
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let capture = UserInputRequestCapture()
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "request-user-input-secret"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                requestUserInputHandler: { request in
                    await capture.answer(request)
                }))
        let stream = await session.events()
        let eventTask = Task { () -> [CodexRuntimeEvent] in
            var events: [CodexRuntimeEvent] = []
            for await event in stream {
                events.append(event)
                if case .turnCompleted = event { break }
            }
            return events
        }

        _ = try await session.start()
        let result = try await session.runTurn(text: "ask")
        let presented = await capture.snapshot()
        let events = await eventTask.value
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(presented.isEmpty)
        XCTAssertTrue(events.contains { event in
            guard case .runtimeError(let code, let message, false) = event
            else { return false }
            return code == "invalid_request_user_input"
                && !message.contains("Enter a secret")
        })
    }

    func testFirstUnknownChildApprovalAndNotificationSurviveAncestryCheck()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let canonicalWorkspace = workspace.resolvingSymlinksInPath()
            .standardizedFileURL
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        while IFS= read -r line; do
          request_id=$(printf '%s\n' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
          case "$line" in
            *'"method":"initialize"'*)
              echo '{"id":1,"result":{"userAgent":"fake"}}'
              ;;
            *'"method":"thread/start"'*)
              echo '{"id":2,"result":{"thread":{"id":"thread-root","turns":[],"status":{"type":"idle"}}}}'
              ;;
            *'"method":"turn/start"'*)
              echo '{"id":3,"result":{"turn":{"id":"turn-root","items":[],"status":"inProgress"}}}'
              echo '{"method":"turn/started","params":{"threadId":"thread-root","turn":{"id":"turn-root","items":[],"status":"inProgress"}}}'
              echo '{"method":"turn/started","params":{"threadId":"thread-new-child","turn":{"id":"turn-new-child","items":[],"status":"inProgress"}}}'
              echo '{"method":"item/commandExecution/requestApproval","id":77,"params":{"threadId":"thread-new-child","turnId":"turn-new-child","itemId":"command-new-child","reason":"verify the child first","command":"true"}}'
              ;;
            *'"method":"thread/read"'*'"threadId":"thread-new-child"'*|*'"threadId":"thread-new-child"'*'"method":"thread/read"'*)
              read_count=$((read_count + 1))
              if [ "$read_count" = "1" ]; then
                echo '{"id":4,"result":{"thread":{"id":"thread-new-child","sessionId":"thread-root","parentThreadId":"thread-root","cwd":"\(canonicalWorkspace.path)","modelProvider":"intatis","turns":[],"status":{"type":"active"}}}}'
              else
                echo '{"id":5,"result":{"thread":{"id":"thread-new-child","sessionId":"thread-root","parentThreadId":"thread-root","cwd":"\(canonicalWorkspace.path)","modelProvider":"intatis","turns":[],"status":{"type":"active"}}}}'
              fi
              ;;
            *'"id":77'*)
              echo '{"method":"serverRequest/resolved","params":{"threadId":"thread-new-child","requestId":77}}'
              echo '{"method":"turn/completed","params":{"threadId":"thread-root","turn":{"id":"turn-root","items":[],"status":"completed"}}}'
              ;;
            *)
              exit 82
              ;;
          esac
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "unknown-child-events"),
                mode: .cowork,
                workspaceURL: canonicalWorkspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))
        let capture = RuntimeBoundaryEventCapture()
        let stream = await session.events()
        let consumer = Task {
            for await event in stream {
                await capture.append(event)
                if case .turnCompleted = event { return }
            }
        }

        _ = try await session.start()
        let turnTask = Task {
            try await session.runTurn(text: "delegate")
        }
        var approval: CodexRuntimeApprovalRequest?
        var sawChildTurn = false
        for _ in 0..<300 {
            let events = await capture.snapshot()
            approval = events.compactMap { event in
                guard case .approvalRequested(let request) = event else {
                    return nil
                }
                return request
            }.first
            sawChildTurn = events.contains(.child(.turnStarted(
                threadID: "thread-new-child",
                turnID: "turn-new-child")))
            if approval != nil, sawChildTurn { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let approval, sawChildTurn else {
            let runtimeErrors = (await capture.snapshot()).compactMap {
                event -> String? in
                guard case .runtimeError(let code, let message, _) = event else {
                    return nil
                }
                return "\(code):\(message)"
            }
            consumer.cancel()
            turnTask.cancel()
            await session.shutdown()
            XCTFail(
                "official ancestry verification did not surface both first-child events (approval=\(approval != nil), childTurn=\(sawChildTurn), errors=\(runtimeErrors))")
            return
        }
        try await session.resolveApproval(
            requestID: approval.requestID,
            decision: .decline)
        let result = try await turnTask.value
        await consumer.value
        let events = await capture.snapshot()
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(approval.threadID, "thread-new-child")
        XCTAssertEqual(approval.itemID, "command-new-child")
        XCTAssertTrue(sawChildTurn)
        XCTAssertFalse(events.contains { event in
            guard case .runtimeError(let code, _, _) = event else {
                return false
            }
            return code == "unverified_approval_thread"
                || code == "unverified_child_notification_thread"
        })
    }

    func testNativeSubagentEventsAndThreadReadRemainThreadScoped()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            case "$line" in *'"experimentalApi":true'*) ;; *) exit 31 ;; esac
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-root","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-root","items":[],"status":"inProgress"}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-root","turn":{"id":"turn-root","items":[],"status":"inProgress"}}}'
            echo '{"method":"thread/started","params":{"thread":{"id":"thread-child","sessionId":"thread-root","parentThreadId":"thread-root","agentNickname":"research","agentRole":"explorer","cwd":"/workspace","modelProvider":"intatis","preview":"inspect","createdAt":1,"canAcceptDirectInput":true,"turns":[],"status":{"type":"active","activeFlags":[]}}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-child","turn":{"id":"turn-child","items":[],"status":"inProgress"}}}'
            echo '{"method":"item/completed","params":{"threadId":"thread-child","turnId":"turn-child","item":{"id":"child-user","type":"userMessage","content":[{"type":"text","text":"inspect files"}]}}}'
            echo '{"method":"item/started","params":{"threadId":"thread-child","turnId":"turn-child","item":{"id":"child-answer","type":"agentMessage","text":"","phase":"final_answer"}}}'
            echo '{"method":"item/agentMessage/delta","params":{"threadId":"thread-child","turnId":"turn-child","itemId":"child-answer","delta":"found "}}'
            echo '{"method":"item/completed","params":{"threadId":"thread-child","turnId":"turn-child","item":{"id":"child-answer","type":"agentMessage","text":"found it","phase":"final_answer"}}}'
            echo '{"method":"thread/tokenUsage/updated","params":{"threadId":"thread-child","turnId":"turn-child","tokenUsage":{"last":{"totalTokens":30,"inputTokens":20,"cachedInputTokens":5,"cacheWriteInputTokens":1,"outputTokens":10,"reasoningOutputTokens":2}}}}'
            echo '{"method":"turn/completed","params":{"threadId":"thread-child","turn":{"id":"turn-child","items":[],"status":"completed","durationMs":42}}}'
            echo '{"method":"thread/status/changed","params":{"threadId":"thread-child","status":{"type":"idle"}}}'
            echo '{"method":"turn/completed","params":{"threadId":"thread-root","turn":{"id":"turn-root","items":[],"status":"completed"}}}'
          elif [ "$count" = "4" ]; then
            case "$line" in
              *'"method":"thread/list"'*'"archived":false'*)
                echo '{"id":4,"result":{"data":[{"id":"thread-child","sessionId":"thread-root","parentThreadId":"thread-root","agentNickname":"research","agentRole":"explorer","cwd":"/workspace","modelProvider":"intatis","preview":"inspect","createdAt":1,"canAcceptDirectInput":true,"turns":[],"status":{"type":"idle"}}],"nextCursor":null}}' ;;
              *'"method":"thread/read"'*'"threadId":"thread-child"'*'"includeTurns":true'*|*'"method":"thread/read"'*'"includeTurns":true'*'"threadId":"thread-child"'*)
                echo '{"id":4,"result":{"thread":{"id":"thread-child","turns":[{"id":"turn-child","status":"completed","items":[{"id":"child-user","type":"userMessage","content":[{"type":"text","text":"inspect files"}]},{"id":"child-tool","type":"dynamicToolCall","tool":"read_docx","arguments":{},"status":"completed"},{"id":"child-answer","type":"agentMessage","text":"found it","phase":"final_answer"}] }]}}}' ;;
              *) exit 39 ;;
            esac
          elif [ "$count" = "5" ]; then
            case "$line" in *'"method":"thread/list"'*'"archived":true'*) ;; *) exit 36 ;; esac
            echo '{"id":5,"result":{"data":[],"nextCursor":null}}'
          elif [ "$count" = "6" ]; then
            case "$line" in *'"method":"thread/resume"'*'"threadId":"thread-child"'*) ;; *) exit 37 ;; esac
            echo '{"id":6,"result":{"thread":{"id":"thread-child","sessionId":"thread-root","parentThreadId":"thread-root","agentNickname":"research","agentRole":"explorer","cwd":"/workspace","modelProvider":"intatis","canAcceptDirectInput":true,"turns":[],"status":{"type":"idle"}},"cwd":"/workspace","model":"child-model","modelProvider":"intatis","reasoningEffort":"medium","serviceTier":null,"runtimeWorkspaceRoots":["/workspace"]}}'
          elif [ "$count" = "7" ]; then
            case "$line" in *'"method":"thread/read"'*'"threadId":"thread-child"'*'"includeTurns":true'*|*'"method":"thread/read"'*'"includeTurns":true'*'"threadId":"thread-child"'*) ;; *) exit 38 ;; esac
            echo '{"id":7,"result":{"thread":{"id":"thread-child","turns":[{"id":"turn-child","status":"completed","items":[{"id":"child-user","type":"userMessage","content":[{"type":"text","text":"inspect files"}]},{"id":"child-tool","type":"dynamicToolCall","tool":"read_docx","arguments":{},"status":"completed"},{"id":"child-answer","type":"agentMessage","text":"found it","phase":"final_answer"}] }]}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "child-events"),
                mode: .cowork,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))
        let stream = await session.events()
        let eventTask = Task { () -> [CodexRuntimeEvent] in
            var received: [CodexRuntimeEvent] = []
            for await event in stream {
                received.append(event)
                if case .turnCompleted = event { break }
            }
            return received
        }

        _ = try await session.start()
        let root = try await session.runTurn(text: "delegate")
        let received = await eventTask.value
        let history = try await session.threadHistory(
            threadID: "thread-child")
        let descendants = await session.descendantThreadDescriptors()
        await session.shutdown()

        XCTAssertTrue(root.succeeded)
        XCTAssertEqual(descendants.map(\.threadID), ["thread-child"])
        XCTAssertEqual(descendants.first?.displayName, "research")
        XCTAssertEqual(descendants.first?.agentRole, "explorer")
        XCTAssertEqual(descendants.first?.status, "idle")
        XCTAssertTrue(received.contains(.child(.assistantDelta(
            threadID: "thread-child",
            turnID: "turn-child",
            itemID: "child-answer",
            text: "found ",
            phase: .finalAnswer))))
        XCTAssertTrue(received.contains(.child(.assistantCompleted(
            threadID: "thread-child",
            turnID: "turn-child",
            itemID: "child-answer",
            text: "found it",
            phase: .finalAnswer))))
        XCTAssertTrue(received.contains(.child(.responsesUsage(
            threadID: "thread-child",
            usage: CodexRuntimeResponsesUsage(
                turnID: "turn-child",
                responseMessageItemID: "child-answer",
                inputTokens: 20,
                cachedInputTokens: 5,
                cacheWriteInputTokens: 1,
                outputTokens: 10,
                reasoningOutputTokens: 2,
                totalTokens: 30,
                durationMs: 42)))))
        XCTAssertEqual(history.threadID, "thread-child")
        XCTAssertEqual(history.items.count, 3)
        XCTAssertEqual(history.items[0], .user(
            id: "child-user",
            turnID: "turn-child",
            text: "inspect files"))
        XCTAssertEqual(history.items[2], .assistant(
            id: "child-answer",
            turnID: "turn-child",
            text: "found it",
            phase: .finalAnswer,
            complete: true))
    }

    func testResumeRestoresVerifiedDescendantTreeFromOfficialThreadList()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: runtimeRoot)
        try storage.prepare()
        try storage.writeRecord(
            threadID: "thread-root",
            mode: .cowork,
            workspacePath: workspace.resolvingSymlinksInPath()
                .standardizedFileURL.path,
            dynamicToolsetID: nil)

        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            echo '{"method":"thread/tokenUsage/updated","params":{"threadId":"thread-child","turnId":"turn-prior","tokenUsage":{"last":{"totalTokens":30,"inputTokens":20,"cachedInputTokens":5,"cacheWriteInputTokens":1,"outputTokens":10,"reasoningOutputTokens":2}}}}'
            echo '{"id":2,"result":{"thread":{"id":"thread-root","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"data":[{"id":"thread-grandchild","sessionId":"thread-grandchild","parentThreadId":"thread-child","agentNickname":"writer","cwd":"/workspace","modelProvider":"intatis","preview":"write","createdAt":2,"turns":[],"status":{"type":"idle"}},{"id":"thread-child","sessionId":"thread-child","parentThreadId":"thread-root","agentNickname":"research","cwd":"/workspace","modelProvider":"intatis","preview":"research","createdAt":1,"turns":[],"status":{"type":"idle"}}],"nextCursor":null}}'
          elif [ "$count" = "4" ]; then
            echo '{"id":4,"result":{"data":[],"nextCursor":null}}'
          elif [ "$count" = "5" ]; then
            case "$line" in
              *'"method":"thread/resume"'*'"threadId":"thread-child"'*) ;;
              *) exit 41 ;;
            esac
            case "$line" in *'"model_providers"'*'"intatis"'*) ;; *) exit 43 ;; esac
            echo '{"id":5,"result":{"thread":{"id":"thread-child","sessionId":"thread-child","parentThreadId":"thread-root","agentNickname":"research","cwd":"/workspace/research","modelProvider":"intatis","preview":"research","createdAt":1,"canAcceptDirectInput":true,"turns":[],"status":{"type":"idle"}},"cwd":"/workspace/research","model":"research-model","modelProvider":"intatis","reasoningEffort":"high","serviceTier":"priority","runtimeWorkspaceRoots":["/workspace/research"],"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"workspace-write"}}'
          elif [ "$count" = "6" ]; then
            case "$line" in
              *'"method":"thread/resume"'*'"threadId":"thread-grandchild"'*) ;;
              *) exit 42 ;;
            esac
            case "$line" in *'"model_providers"'*'"intatis"'*) ;; *) exit 44 ;; esac
            echo '{"id":6,"result":{"thread":{"id":"thread-grandchild","sessionId":"thread-grandchild","parentThreadId":"thread-child","agentNickname":"writer","cwd":"/workspace/writer","modelProvider":"intatis","preview":"write","createdAt":2,"canAcceptDirectInput":true,"turns":[],"status":{"type":"idle"}},"cwd":"/workspace/writer","model":"writer-model","modelProvider":"intatis","reasoningEffort":"medium","serviceTier":null,"runtimeWorkspaceRoots":["/workspace/writer"],"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"workspace-write"}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "resume-descendants"),
                mode: .cowork,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                allowsThreadCreation: false))
        _ = try await session.start()
        let descendants = await session.descendantThreadDescriptors()
        await session.shutdown()

        XCTAssertEqual(
            descendants.map(\.threadID),
            ["thread-child", "thread-grandchild"])
        XCTAssertEqual(
            descendants.map(\.parentThreadID),
            ["thread-root", "thread-child"])
        XCTAssertEqual(
            descendants.map(\.displayName),
            ["research", "writer"])
        XCTAssertEqual(
            descendants.map(\.requestedModel),
            ["research-model", "writer-model"])
        XCTAssertEqual(
            descendants.map(\.reasoningEffort),
            ["high", "medium"])
        XCTAssertEqual(
            descendants.map(\.runtimeWorkspaceRoots),
            [["/workspace/research"], ["/workspace/writer"]])
        XCTAssertTrue(descendants.allSatisfy { !$0.isArchived })
    }

    func testVerifiedChildUsesNativeControlPlaneMessageAndArchive()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-root","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"thread":{"id":"thread-root","turns":[]}}}'
            echo '{"method":"thread/started","params":{"thread":{"id":"thread-active","sessionId":"thread-root","parentThreadId":"thread-root","agentNickname":"active","cwd":"/workspace","modelProvider":"intatis","createdAt":1,"canAcceptDirectInput":false,"turns":[],"status":{"type":"active"}}}}'
            echo '{"method":"thread/started","params":{"thread":{"id":"thread-idle","sessionId":"thread-root","parentThreadId":"thread-root","agentNickname":"idle","cwd":"/workspace","modelProvider":"intatis","createdAt":2,"canAcceptDirectInput":false,"turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "4" ]; then
            case "$line" in *'"method":"thread/subagent/message"'*) ;; *) exit 31 ;; esac
            case "$line" in *'"threadId":"thread-root"'*) ;; *) exit 36 ;; esac
            case "$line" in *'"targetThreadId":"thread-active"'*) ;; *) exit 37 ;; esac
            case "$line" in *'"message":"more context"'*) ;; *) exit 38 ;; esac
            case "$line" in *'"triggerTurn":true'*) ;; *) exit 39 ;; esac
            echo '{"id":4,"result":{"submissionId":"submission-active"}}'
          elif [ "$count" = "5" ]; then
            case "$line" in *'"method":"thread/subagent/message"'*) ;; *) exit 32 ;; esac
            case "$line" in *'"targetThreadId":"thread-idle"'*) ;; *) exit 32 ;; esac
            case "$line" in *'"message":"begin work"'*) ;; *) exit 32 ;; esac
            echo '{"id":5,"result":{"submissionId":"submission-idle"}}'
          elif [ "$count" = "6" ]; then
            case "$line" in *'"method":"thread'*'archive"'*) ;; *) exit 34 ;; esac
            case "$line" in *'"threadId":"thread-idle"'*) ;; *) exit 34 ;; esac
            echo '{"id":6,"result":{}}'
          elif [ "$count" = "7" ]; then
            case "$line" in *'"method":"thread'*'read"'*) ;; *) exit 35 ;; esac
            case "$line" in *'"threadId":"thread-idle"'*) ;; *) exit 35 ;; esac
            case "$line" in *'"includeTurns":true'*) ;; *) exit 35 ;; esac
            echo '{"id":7,"result":{"thread":{"id":"thread-idle","turns":[{"id":"turn-idle","items":[{"id":"user-idle","type":"userMessage","content":[{"type":"text","text":"begin work"}]}],"status":"completed"}]}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "child-direct-input"),
                mode: .cowork,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))
        let events = await session.events()
        let childrenTask = Task {
            var threads: [CodexRuntimeThreadDescriptor] = []
            for await event in events {
                if case .child(.threadUpdated(let thread)) = event {
                    threads.append(thread)
                    if threads.count == 2 { return threads }
                }
            }
            return threads
        }
        _ = try await session.start()
        _ = try await session.threadHistory(threadID: "thread-root")
        let discovered = await childrenTask.value
        XCTAssertEqual(discovered.map(\.displayName), ["active", "idle"])

        let activeSubmission = try await session.sendMessage(
            toDescendantThreadID: "thread-active",
            text: "more context")
        XCTAssertEqual(activeSubmission, "submission-active")
        let idleSubmission = try await session.sendMessage(
            toDescendantThreadID: "thread-idle",
            text: "begin work")
        XCTAssertEqual(idleSubmission, "submission-idle")
        try await session.archiveDescendantThread(
            threadID: "thread-idle")

        let archived = await session.descendantThreadDescriptors()
            .first { $0.threadID == "thread-idle" }
        XCTAssertEqual(archived?.isArchived, true)
        XCTAssertEqual(archived?.canAcceptDirectInput, false)
        let history = try await session.threadHistory(
            threadID: "thread-idle")
        XCTAssertEqual(history.items, [
            .user(
                id: "user-idle",
                turnID: "turn-idle",
                text: "begin work"),
        ])

        do {
            _ = try await session.sendMessage(
                toDescendantThreadID: "thread-foreign",
                text: "reject me")
            XCTFail("A foreign thread must never receive a control-plane message")
        } catch let error as CodexRuntimeError {
            guard case .malformedProtocol = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        await session.shutdown()
    }

    func testOfficialThreadGoalReadUpdateAndClearRemainAuthoritative()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-goal","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"goal":{"threadId":"thread-goal","objective":"Ship the feature","status":"active","tokenBudget":5000,"tokensUsed":120,"timeUsedSeconds":30,"createdAt":10,"updatedAt":11}}}'
          elif [ "$count" = "4" ]; then
            case "$line" in *'"status":"paused"'*) ;; *) exit 61 ;; esac
            echo '{"id":4,"result":{"goal":{"threadId":"thread-goal","objective":"Ship the feature","status":"paused","tokenBudget":5000,"tokensUsed":125,"timeUsedSeconds":35,"createdAt":10,"updatedAt":12}}}'
            echo '{"method":"thread/goal/updated","params":{"threadId":"thread-goal","turnId":null,"goal":{"threadId":"thread-goal","objective":"Ship the feature","status":"paused","tokenBudget":5000,"tokensUsed":125,"timeUsedSeconds":35,"createdAt":10,"updatedAt":12}}}'
          elif [ "$count" = "5" ]; then
            echo '{"id":5,"result":{"cleared":true}}'
            echo '{"method":"thread/goal/cleared","params":{"threadId":"thread-goal","turnId":null}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "goal-protocol"),
                mode: .cowork,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))
        let events = await session.events()
        let goalEvents = Task {
            var values: [CodexRuntimeGoalSnapshot?] = []
            for await event in events {
                if case .goalUpdated(let goal) = event {
                    values.append(goal)
                    if values.count == 2 { return values }
                }
            }
            return values
        }
        _ = try await session.start()
        let current = try await session.currentGoal()
        XCTAssertEqual(current?.objective, "Ship the feature")
        XCTAssertEqual(current?.tokensUsed, 120)
        try await session.setGoalStatus("paused")
        try await session.clearGoal()
        let emitted = await goalEvents.value
        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(emitted[0]?.status, "paused")
        XCTAssertNil(emitted[1])
        await session.shutdown()
    }

    func testPersistedActiveGoalIsPausedBeforeColdThreadResume()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let storage = CodexRuntimeStorage(rootURL: runtimeRoot)
        try storage.prepare()
        let canonicalWorkspace = workspace
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        try storage.writeRecord(
            threadID: "thread-cold-goal",
            mode: .code,
            workspacePath: canonicalWorkspace)

        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            case "$line" in *'"method":"initialize"'*) ;; *) exit 81 ;; esac
            echo '{"id":1,"result":{}}'
          elif [ "$count" = "2" ]; then
            case "$line" in *'"method":"thread/goal/get"'*) ;; *) exit 82 ;; esac
            echo '{"id":2,"result":{"goal":{"threadId":"thread-cold-goal","objective":"Finish safely","status":"active","tokenBudget":null,"tokensUsed":12,"timeUsedSeconds":4,"createdAt":1,"updatedAt":2}}}'
          elif [ "$count" = "3" ]; then
            case "$line" in *'"method":"thread/goal/set"'*'"status":"paused"'*) ;; *) exit 83 ;; esac
            echo '{"id":3,"result":{"goal":{"threadId":"thread-cold-goal","objective":"Finish safely","status":"paused","tokenBudget":null,"tokensUsed":12,"timeUsedSeconds":4,"createdAt":1,"updatedAt":3}}}'
          elif [ "$count" = "4" ]; then
            case "$line" in *'"method":"thread/resume"'*) ;; *) exit 84 ;; esac
            echo '{"id":4,"result":{"thread":{"id":"thread-cold-goal","turns":[],"status":{"type":"idle"}}}}'
          else
            exit 85
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "cold-goal-pause"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                allowsThreadCreation: false,
                pauseActiveGoalBeforeResume: true))

        let identity = try await session.start()
        XCTAssertEqual(identity.threadID, "thread-cold-goal")
        await session.shutdown()
    }

    func testOfficialGoalEditPreservesStatusClearsBudgetAndWritesJoin()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-goal-edit","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            case "$line" in *'"method":"thread/goal/set"'*) ;; *) exit 71 ;; esac
            case "$line" in *'"objective":"Edited objective"'*) ;; *) exit 72 ;; esac
            case "$line" in *'"tokenBudget":null'*) ;; *) exit 73 ;; esac
            case "$line" in *'"status"'*) exit 74 ;; esac
            echo '{"id":3,"result":{"goal":{"threadId":"thread-goal-edit","objective":"Edited objective","status":"paused","tokenBudget":null,"tokensUsed":12,"timeUsedSeconds":4,"createdAt":1,"updatedAt":2}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "goal-edit"),
                mode: .cowork,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))
        _ = try await session.start()
        try await session.updateGoal(
            objective: "Edited objective",
            tokenBudget: .clear)
        let record = try CodexRuntimeStorage(rootURL: runtimeRoot)
            .readRecord()
        XCTAssertEqual(record?.threadID, "thread-goal-edit")
        XCTAssertTrue(record?.materialized == true)
        await session.shutdown()
    }

    func testResumeRestoresArchivedDescendantWithoutLoadingIt()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = CodexRuntimeStorage(rootURL: runtimeRoot)
        try storage.prepare()
        try storage.writeRecord(
            threadID: "thread-root",
            mode: .cowork,
            workspacePath: workspace.resolvingSymlinksInPath()
                .standardizedFileURL.path,
            dynamicToolsetID: nil)

        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-root","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            case "$line" in *'"archived":false'*) ;; *) exit 41 ;; esac
            echo '{"id":3,"result":{"data":[],"nextCursor":null}}'
          elif [ "$count" = "4" ]; then
            case "$line" in *'"archived":true'*) ;; *) exit 42 ;; esac
            echo '{"id":4,"result":{"data":[{"id":"thread-archived","sessionId":"thread-root","parentThreadId":"thread-root","agentNickname":"finished","cwd":"/workspace","modelProvider":"intatis","createdAt":1,"turns":[],"status":{"type":"notLoaded"}}],"nextCursor":null}}'
          else
            exit 43
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "archived-descendant"),
                mode: .cowork,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                allowsThreadCreation: false))
        _ = try await session.start()
        let descendants = await session.descendantThreadDescriptors()
        XCTAssertEqual(descendants.count, 1)
        XCTAssertEqual(descendants.first?.displayName, "finished")
        XCTAssertEqual(descendants.first?.isArchived, true)
        await session.shutdown()
    }

    func testVerifiedCodexSubagentCanInvokeInheritedDynamicTool()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            case "$line" in
              *'"dynamicTools"'*'"business_echo"'*) ;;
              *) exit 21 ;;
            esac
            echo '{"id":2,"result":{"thread":{"id":"thread-root","turns":[],"status":{"type":"idle"}}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-root","items":[],"status":"inProgress"}}}'
            echo '{"method":"turn/started","params":{"threadId":"thread-root","turn":{"id":"turn-root","items":[],"status":"inProgress"}}}'
            echo '{"method":"item/tool/call","id":98,"params":{"threadId":"thread-unrelated","turnId":"turn-unrelated","callId":"call-unrelated","namespace":null,"tool":"business_echo","arguments":{"value":"must reject"}}}'
          elif [ "$count" = "4" ]; then
            case "$line" in
              *'"method":"thread/read"'*'"threadId":"thread-unrelated"'*) ;;
              *) exit 22 ;;
            esac
            echo '{"id":4,"result":{"thread":{"id":"thread-unrelated","sessionId":"foreign-root","parentThreadId":"foreign-root","cwd":"/foreign","modelProvider":"foreign","turns":[],"status":{"type":"active"}}}}'
          elif [ "$count" = "5" ]; then
            case "$line" in
              *'"method":"thread/read"'*'"threadId":"foreign-root"'*) ;;
              *) exit 23 ;;
            esac
            echo '{"id":5,"error":{"code":-32600,"message":"foreign parent not found"}}'
          elif [ "$count" = "6" ]; then
            case "$line" in
              *'"id":98'*'"success":false'*) ;;
              *) exit 24 ;;
            esac
            echo '{"method":"item/tool/call","id":99,"params":{"threadId":"thread-child","turnId":"turn-child","callId":"call-child","namespace":null,"tool":"business_echo","arguments":{"value":"from child"}}}'
          elif [ "$count" = "7" ]; then
            case "$line" in
              *'"method":"thread/read"'*'"threadId":"thread-child"'*) ;;
              *) exit 25 ;;
            esac
            echo '{"id":6,"result":{"thread":{"id":"thread-child","sessionId":"thread-child","parentThreadId":"thread-root","cwd":"\(workspace.resolvingSymlinksInPath().standardizedFileURL.path)","modelProvider":"intatis","canAcceptDirectInput":true,"turns":[],"status":{"type":"active"}}}}'
          elif [ "$count" = "8" ]; then
            case "$line" in
              *'"id":99'*'handled from child'*'"success":true'*) ;;
              *) exit 26 ;;
            esac
            echo '{"method":"turn/completed","params":{"threadId":"thread-root","turn":{"id":"turn-root","items":[],"status":"completed"}}}'
          else
            exit 29
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let capture = DynamicToolCallCapture()
        let dynamicTools = CodexRuntimeDynamicTools(
            toolsetID: "business-v2",
            specs: [CodexRuntimeDynamicToolSpec(
                name: "business_echo",
                description: "Echo one value.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "value": .object([
                            "type": .string("string"),
                        ]),
                    ]),
                    "required": .array([.string("value")]),
                    "additionalProperties": .bool(false),
                ]))],
            handler: { call in
                await capture.append(call)
                guard case .object(let arguments) = call.arguments,
                      case .string(let value)? = arguments["value"] else {
                    return .text("invalid", success: false)
                }
                return .text("handled \(value)")
            })
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "subagent-dynamic-call"),
                mode: .cowork,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                dynamicTools: dynamicTools))

        _ = try await session.start()
        let result = try await session.runTurn(text: "delegate and echo")
        let calls = await capture.snapshot()
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.threadID, "thread-child")
        XCTAssertEqual(calls.first?.turnID, "turn-child")
        XCTAssertEqual(calls.first?.callID, "call-child")
        XCTAssertEqual(
            calls.first?.agentID,
            AgentID(rawValue: "codex:thread-child"))
        XCTAssertEqual(
            calls.first?.workspaceURL?.standardizedFileURL.path,
            workspace.resolvingSymlinksInPath()
                .standardizedFileURL.path)
    }

    func testMetadataChangeAndArchiveInvalidatePendingDynamicToolLease()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let canonicalWorkspace = workspace.resolvingSymlinksInPath()
            .standardizedFileURL
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        turn_count=0
        while IFS= read -r line; do
          request_id=$(printf '%s\n' "$line" | sed -E 's/.*"id":([0-9]+).*/\\1/')
          case "$line" in
            *'"method":"initialize"'*)
              echo '{"id":1,"result":{"userAgent":"fake"}}'
              ;;
            *'"method":"thread/start"'*)
              echo '{"id":2,"result":{"thread":{"id":"thread-root","turns":[],"status":{"type":"idle"}}}}'
              ;;
            *'"method":"turn/start"'*)
              turn_count=$((turn_count + 1))
              if [ "$turn_count" = "1" ]; then
                echo '{"id":3,"result":{"turn":{"id":"turn-root-1","items":[],"status":"inProgress"}}}'
                echo '{"method":"turn/started","params":{"threadId":"thread-root","turn":{"id":"turn-root-1","items":[],"status":"inProgress"}}}'
                echo '{"method":"thread/started","params":{"thread":{"id":"thread-child","sessionId":"thread-root","parentThreadId":"thread-root","agentRole":"alpha","cwd":"\(canonicalWorkspace.path)","modelProvider":"intatis_agent_alpha","turns":[],"status":{"type":"active"}}}}'
                echo '{"method":"item/tool/call","id":91,"params":{"threadId":"thread-child","turnId":"turn-child-1","callId":"call-1","namespace":null,"tool":"business_echo","arguments":{"value":"pending-1"}}}'
              else
                echo '{"id":5,"result":{"turn":{"id":"turn-root-2","items":[],"status":"inProgress"}}}'
                echo '{"method":"turn/started","params":{"threadId":"thread-root","turn":{"id":"turn-root-2","items":[],"status":"inProgress"}}}'
                echo '{"method":"item/tool/call","id":92,"params":{"threadId":"thread-child","turnId":"turn-child-2","callId":"call-2","namespace":null,"tool":"business_echo","arguments":{"value":"pending-2"}}}'
              fi
              ;;
            *'"method":"thread/resume"'*)
              echo '{"id":4,"result":{"thread":{"id":"thread-child","sessionId":"thread-root","parentThreadId":"thread-root","agentRole":"beta","cwd":"\(canonicalWorkspace.path)","modelProvider":"intatis_agent_beta","turns":[],"status":{"type":"active"}},"cwd":"\(canonicalWorkspace.path)","model":"beta-model","modelProvider":"intatis_agent_beta","reasoningEffort":"medium","serviceTier":null,"runtimeWorkspaceRoots":["\(canonicalWorkspace.path)"]}}'
              ;;
            *'"method":"thread/archive"'*)
              echo '{"id":6,"result":{}}'
              ;;
            *'"id":91'*)
              echo '{"method":"turn/completed","params":{"threadId":"thread-root","turn":{"id":"turn-root-1","items":[],"status":"completed"}}}'
              ;;
            *'"id":92'*)
              echo '{"method":"turn/completed","params":{"threadId":"thread-root","turn":{"id":"turn-root-2","items":[],"status":"completed"}}}'
              ;;
            *)
              exit 83
              ;;
          esac
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        func profile(_ role: String) -> CodexRuntimeChildProfile {
            CodexRuntimeChildProfile(
                roleName: role,
                description: "Use the \(role) preset.",
                workspaceURL: canonicalWorkspace,
                route: ResponsesRuntimeRoute(
                    endpointID: role,
                    model: ModelID(rawValue: "\(role)-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "\(role)-token",
                    reasoningEffort: "medium"),
                sandbox: .workspaceWrite,
                permissionProfile: .reviewed)
        }
        let gate = DynamicLeaseGate()
        let dynamicTools = CodexRuntimeDynamicTools(
            toolsetID: "lease-invalidation",
            specs: [CodexRuntimeDynamicToolSpec(
                name: "business_echo",
                description: "Wait for a host lifecycle change.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "value": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("value")]),
                    "additionalProperties": .bool(false),
                ]))],
            handler: { call in
                await gate.suspend(call)
                return .text("released")
            })
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "lease-lifecycle"),
                mode: .cowork,
                workspaceURL: canonicalWorkspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "root",
                    model: ModelID(rawValue: "root-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "root-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                dynamicTools: dynamicTools,
                childProfiles: [profile("alpha"), profile("beta")]))
        _ = try await session.start()

        let firstTurn = Task {
            try await session.runTurn(text: "first")
        }
        var firstEntered = false
        for _ in 0..<300 {
            if await gate.entryCount() == 1 {
                firstEntered = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard firstEntered else {
            await gate.releaseAll()
            firstTurn.cancel()
            await session.shutdown()
            XCTFail("first dynamic call did not enter its explicit test gate")
            return
        }
        let rebound = try await session.reapplyConfiguredChildProfile(
            threadID: "thread-child")
        XCTAssertEqual(rebound.agentRole, "beta")
        await gate.releaseNext()
        let firstResult = try await firstTurn.value
        XCTAssertTrue(firstResult.succeeded)

        let secondTurn = Task {
            try await session.runTurn(text: "second")
        }
        var secondEntered = false
        for _ in 0..<300 {
            if await gate.entryCount() == 2 {
                secondEntered = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard secondEntered else {
            await gate.releaseAll()
            secondTurn.cancel()
            await session.shutdown()
            XCTFail("second dynamic call did not enter its explicit test gate")
            return
        }
        try await session.archiveDescendantThread(
            threadID: "thread-child")
        await gate.releaseNext()
        let secondResult = try await secondTurn.value
        XCTAssertTrue(secondResult.succeeded)
        let validity = await gate.validitySnapshot()
        await session.shutdown()

        XCTAssertEqual(validity, [false, false])
    }

    func testDynamicToolThreadDoesNotResumeRecordWithoutExactToolset()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let storage = CodexRuntimeStorage(rootURL: runtimeRoot)
        try storage.prepare()
        let priorRecord = CodexRuntimeStorage.Record(
            schemaVersion: 2,
            runtimeVersion: CodexRuntimeExecutable.pinnedVersion,
            threadID: "thread-prior",
            mode: .cowork,
            workspacePath: workspace.resolvingSymlinksInPath()
                .standardizedFileURL.path,
            dynamicToolsetID: nil,
            materialized: true)
        try DurableOwnerOnlyFile.writeAtomically(
            try JSONEncoder().encode(priorRecord),
            to: storage.recordURL,
            temporaryPrefix: ".codex-runtime-test-")

        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{"userAgent":"fake"}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-prior","turns":[],"createdAt":0,"updatedAt":0,"status":{"type":"idle"}}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)

        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "resume-upgrade-test"),
                mode: .cowork,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                allowsThreadCreation: false,
                dynamicTools: CodexRuntimeDynamicTools(
                    toolsetID: "new-toolset",
                    specs: [CodexRuntimeDynamicToolSpec(
                        name: "business_echo",
                        description: "Echo one value.",
                        inputSchema: .object([
                            "type": .string("object"),
                            "properties": .object([
                                "value": .object([
                                    "type": .string("string"),
                                ]),
                            ]),
                            "required": .array([.string("value")]),
                            "additionalProperties": .bool(false),
                        ]))],
                    handler: { _ in .text("unused") })))

        do {
            _ = try await session.start()
            XCTFail("A thread cannot acquire a new dynamic-tool surface on resume")
        } catch {
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .threadMigrationRequired)
        }
        await session.shutdown()
    }

    func testShutdownWaitsForProcessExitBeforeReleasingSessionLease()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let retirementMarker = URL(
            fileURLWithPath: executable.path + ".retired")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        trap '' TERM
        trap 'sleep 0.35; : > "$0.retired"' EXIT
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-drain"}}}'
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)
        let runtimeRoot = temporary.appendingPathComponent(
            "runtime",
            isDirectory: true)
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "shutdown-drain-test"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: runtimeRoot,
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))

        _ = try await session.start()
        let started = Date()
        await session.shutdown()

        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(started),
            0.25)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: retirementMarker.path))
        let storage = CodexRuntimeStorage(rootURL: runtimeRoot)
        let replacement = try CodexRuntimeProcessLease(
            url: storage.processLockURL)
        replacement.release()
    }

    func testLegacySessionWithoutThreadMappingFailsInsteadOfStartingEmptyThread()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        if IFS= read -r line; then
          echo '{"id":1,"result":{"userAgent":"fake"}}'
        fi
        while IFS= read -r line; do :; done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "legacy-test"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable,
                allowsThreadCreation: false))

        do {
            _ = try await session.start()
            XCTFail("Legacy history must not acquire an empty Codex thread")
        } catch {
            XCTAssertEqual(
                error as? CodexRuntimeError,
                .threadMigrationRequired)
        }
        await session.shutdown()
    }

    func testEverySupportedServerInitiatedApprovalRoundTripsDecision()
        async throws
    {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = temporary.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo 'codex-cli 0.145.0-intatis.4'
          exit 0
        fi
        if [ "$1" = "--intatis-derivation-id" ]; then
          echo '0003-sha256:9cd57fc61366cb7410f6e551aa48ec762094e9a4edbfcbf0ae4670b7ba1f2285'
          exit 0
        fi
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          if [ "$count" = "1" ]; then
            echo '{"id":1,"result":{}}'
          elif [ "$count" = "2" ]; then
            echo '{"id":2,"result":{"thread":{"id":"thread-approval"}}}'
          elif [ "$count" = "3" ]; then
            echo '{"id":3,"result":{"turn":{"id":"turn-approval","items":[],"status":"inProgress"}}}'
            echo '{"method":"item/commandExecution/requestApproval","id":99,"params":{"threadId":"thread-approval","turnId":"turn-approval","itemId":"command-approval","reason":"run the requested check","startedAtMs":1,"command":"true","cwd":"/tmp","commandActions":[]}}'
          elif [ "$count" = "4" ]; then
            case "$line" in
              *'"decision":"accept"'*)
                echo '{"method":"item/fileChange/requestApproval","id":100,"params":{"threadId":"thread-approval","turnId":"turn-approval","itemId":"file-approval","reason":"write the requested file","startedAtMs":2,"grantRoot":null}}'
                ;;
              *) exit 2 ;;
            esac
          elif [ "$count" = "5" ]; then
            case "$line" in
              *'"decision":"accept"'*)
                echo '{"method":"item/permissions/requestApproval","id":101,"params":{"threadId":"thread-approval","turnId":"turn-approval","itemId":"permissions-approval","reason":"use the requested capability","startedAtMs":3,"cwd":"/tmp","permissions":{"network":null,"fileSystem":null,"macos":null}}}'
                ;;
              *) exit 3 ;;
            esac
          elif [ "$count" = "6" ]; then
            case "$line" in
              *'"permissions"'*'"scope":"turn"'*)
                echo '{"method":"serverRequest/resolved","params":{"threadId":"thread-approval","requestId":101}}'
                echo '{"method":"turn/completed","params":{"threadId":"thread-approval","turn":{"id":"turn-approval","items":[],"status":"completed"}}}'
                ;;
              *) exit 4 ;;
            esac
          fi
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path)
        let session = CodexAppServerSession(configuration:
            CodexRuntimeConfiguration(
                sessionID: SessionID(rawValue: "approval-test"),
                mode: .code,
                workspaceURL: workspace,
                runtimeRootURL: temporary.appendingPathComponent(
                    "runtime",
                    isDirectory: true),
                route: ResponsesRuntimeRoute(
                    endpointID: "fake",
                    model: ModelID(rawValue: "fake-model"),
                    baseURL: URL(string: "http://127.0.0.1:9/v1")!,
                    bearerToken: "fake-token"),
                approvalReviewer: .user,
                executableOverride: executable))
        let stream = await session.events()
        let approvalTask = Task { () throws
            -> [CodexRuntimeApprovalRequest] in
            var approvals: [CodexRuntimeApprovalRequest] = []
            for await event in stream {
                if case .approvalRequested(let request) = event {
                    try await session.resolveApproval(
                        requestID: request.requestID,
                        decision: .accept)
                    approvals.append(request)
                    if approvals.count == 3 {
                        return approvals
                    }
                }
            }
            throw CodexRuntimeError.requestNotPending
        }

        _ = try await session.start()
        let result = try await session.runTurn(text: "check")
        let approvals = try await approvalTask.value
        await session.shutdown()

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(approvals.map(\.kind), [
            .command,
            .fileChange,
            .permissions,
        ])
        XCTAssertEqual(approvals.map(\.itemID), [
            "command-approval",
            "file-approval",
            "permissions-approval",
        ])
    }

    private func appServerProtocolMethods(at url: URL) throws -> Set<String> {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let variants = root["oneOf"] as? [[String: Any]] else {
            throw CodexRuntimeError.malformedProtocol(
                "generated App Server schema has no oneOf method inventory")
        }
        let methods = variants.flatMap { variant -> [String] in
            guard let properties = variant["properties"]
                    as? [String: Any],
                  let method = properties["method"] as? [String: Any],
                  let values = method["enum"] as? [String] else {
                return []
            }
            return values
        }
        guard methods.count == variants.count else {
            throw CodexRuntimeError.malformedProtocol(
                "generated App Server schema contains a methodless variant")
        }
        return Set(methods)
    }

    private func assertBytesAreAbsent(
        _ needle: Data,
        below root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []) else { return }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            XCTAssertNil(
                data.range(of: needle),
                "Sensitive bytes persisted in \(url.lastPathComponent)",
                file: file,
                line: line)
        }
    }
}
