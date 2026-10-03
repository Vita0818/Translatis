import Foundation
import XCTest
import IntatisAgentKernel
import IntatisArtifacts
import IntatisConversation
import IntatisCore
import IntatisCowork
import IntatisPermission
import IntatisProtocol
import IntatisProviders
import IntatisTools
@testable import TranslatisCLI

private final class CLIMultimodalCapturingProvider:
    ToolCallingProvider, @unchecked Sendable
{
    let toolCallingCapabilities = ToolCallingProviderCapabilities(
        supportsUserImageInput: true,
        supportsFunctionOutputImageInput: true)

    private let lock = NSLock()
    private let output: String
    private var requestStorage: [AgentRequest] = []

    init(output: String) {
        self.output = output
    }

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
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(output))
            continuation.yield(.done(finishReason: "stop"))
            continuation.finish()
        }
    }
}

final class CLIAttachmentTests: XCTestCase {
    func testImageLoaderRetainsBytesAndPreservesChatDataURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-attachment-tests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bytes = Data([0xff, 0xd8, 0xff, 0xd9])
        let file = directory.appendingPathComponent("sample.jpg")
        try bytes.write(to: file)

        guard case .image(let image) =
                AttachmentLoader.load(file.path) else {
            return XCTFail("expected an image attachment")
        }
        XCTAssertEqual(image.name, "sample.jpg")
        XCTAssertEqual(image.data, bytes)
        XCTAssertEqual(image.mime, "image/jpeg")
        XCTAssertEqual(
            image.providerAttachment.url,
            "data:image/jpeg;base64,\(bytes.base64EncodedString())")
    }

    func testTextLoaderBehaviorIsUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-attachment-tests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)

        guard case .text(let name, let content) =
                AttachmentLoader.load(file.path) else {
            return XCTFail("expected a text attachment")
        }
        XCTAssertEqual(name, "notes.txt")
        XCTAssertEqual(content, "hello")
    }

    func testCodeHostReplaysDurableImageOnNextTurnInSameSession()
        async throws
    {
        // `sessionLog()` and the sibling artifacts directory are the exact
        // storage ownership used by one CLI Code REPL process.
        let log = try sessionLog()
        let sessionDirectory = log.sessionDirectoryURL
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let workspace = sessionDirectory.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        let store = try ArtifactStore(
            root: sessionDirectory.appendingPathComponent(
                "artifacts",
                isDirectory: true))
        let imageData = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))
        let artifact = try await store.addAttachment(
            name: "pixel.png",
            data: imageData,
            mime: "image/png")
        let expectedImage = ImageAttachment.base64(
            mime: "image/png",
            base64: imageData.base64EncodedString())
        let resolver = AgentImageResolution.resolver(store: store)
        let runtime = AgentRuntime.code(
            registry: ToolRegistry([]),
            allowsShell: false)
        let agent = Agent(
            name: AgentID(rawValue: "cli"),
            workspaceRoot: workspace,
            model: ModelID(rawValue: "cli-code-vision"),
            profile: .reviewed)
        let workspaceLease = WorkspaceLease(
            rootPath: workspace.path,
            access: .readWrite)

        let firstProvider = CLIMultimodalCapturingProvider(output: "first")
        let firstSubmission = SubmissionID(rawValue: "cli-code-image-first")
        _ = try await runtime.makeLoop(
            log: log,
            provider: firstProvider,
            responder: FixedResponder(.allow),
            agent: agent,
            context: ContextBuilder(
                runtimeEnvironment: .code,
                conversationHistoryPolicy: .conversation),
            imageResolver: resolver,
            workspaceLease: workspaceLease)
            .send(
                "inspect the pixel",
                userMessage: UserMessagePayload(
                    text: "inspect the pixel",
                    attachments: [artifact.id],
                    submissionID: firstSubmission,
                    turnID: TurnID(rawValue: "cli-code-turn-first")))

        XCTAssertTrue(try XCTUnwrap(firstProvider.requests.first)
            .messages.contains { message in
                message.role == .user
                    && message.content == "inspect the pixel"
                    && message.images == [expectedImage]
            })

        let secondProvider = CLIMultimodalCapturingProvider(output: "second")
        _ = try await runtime.makeLoop(
            log: log,
            provider: secondProvider,
            responder: FixedResponder(.allow),
            agent: agent,
            context: ContextBuilder(
                runtimeEnvironment: .code,
                conversationHistoryPolicy: .conversation),
            imageResolver: resolver,
            workspaceLease: workspaceLease)
            .send(
                "use the prior image",
                userMessage: UserMessagePayload(
                    text: "use the prior image",
                    submissionID: SubmissionID(
                        rawValue: "cli-code-image-second"),
                    turnID: TurnID(rawValue: "cli-code-turn-second")))

        let replayRequest = try XCTUnwrap(secondProvider.requests.first)
        XCTAssertTrue(replayRequest.messages.contains { message in
            message.role == .user
                && message.content == "inspect the pixel"
                && message.images == [expectedImage]
        })
        let codeEvents = try await log.replayChecked()
        let codeImageItems: [ModelHistoryItemPayload] = codeEvents.compactMap {
            envelope in
            guard case .modelHistoryItem(let payload) = envelope.event,
                  payload.submissionID == firstSubmission,
                  payload.messageClassification == .realUser else {
                return nil
            }
            return payload
        }
        let durableItem = try XCTUnwrap(codeImageItems.first)
        XCTAssertEqual(
            durableItem.schemaVersion,
            ModelHistoryItemPayload.mediaSchemaVersion)
        XCTAssertEqual(
            durableItem.imageReferences?.map { $0.artifactID },
            [artifact.id])
        XCTAssertFalse(
            try String(
                contentsOf: sessionDirectory.appendingPathComponent(
                    "events.jsonl"),
                encoding: .utf8)
                .contains("data:image"))
    }

    func testCoworkExactMainReplaysDurableImageAfterSessionRebuild()
        async throws
    {
        // Reopen both durable owners with new instances to model a CLI Cowork
        // process restart, then use the shipping writer-lease runtime factory.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "translatis-cli-cowork-media-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent(
            "workspace",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true)
        let eventURL = root
            .appendingPathComponent("session", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let sessionID = SessionID(rawValue: "cli-cowork-durable-image")
        let firstLog = try EventLog(session: sessionID, fileURL: eventURL)
        let artifactRoot = firstLog.sessionDirectoryURL
            .appendingPathComponent("artifacts", isDirectory: true)
        let firstStore = try ArtifactStore(root: artifactRoot)
        let imageData = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))
        let artifact = try await firstStore.addAttachment(
            name: "pixel.png",
            data: imageData,
            mime: "image/png")
        let expectedImage = ImageAttachment.base64(
            mime: "image/png",
            base64: imageData.base64EncodedString())
        let binding = Self.coworkBinding
        let firstProvider = CLIMultimodalCapturingProvider(
            output: "first cowork answer")
        var firstRuntime: Orchestrator? = try Self.makeCoworkRuntime(
            log: firstLog,
            store: firstStore,
            binding: binding,
            provider: firstProvider)
        let bootstrap = await firstRuntime?.bootstrapFreshSession(
            main: Agent(
                name: Orchestrator.mainAgentID,
                workspaceRoot: workspace,
                model: binding.modelID,
                agentInferenceBinding: binding,
                profile: .reviewed,
                coordinationDepth: Agent.defaultCoordinationDepth),
            settings: CoworkSessionSettings(
                sessionID: sessionID,
                defaultModelID: binding.modelID.rawValue,
                defaultInferenceProfileBinding: binding,
                workspaces: [CoworkSessionWorkspace(
                    path: workspace.path,
                    agentName: Orchestrator.mainAgentID.rawValue,
                    isPrimary: true)]),
            permissionReviewerModel: binding.modelID,
            permissionReviewerInferenceBinding: binding)
        XCTAssertEqual(bootstrap, .attached(Orchestrator.mainAgentID))

        let firstSubmission = SubmissionID(
            rawValue: "cli-cowork-image-first")
        let firstResult = await firstRuntime?.send(
            "inspect the durable pixel",
            to: Orchestrator.mainAgentID,
            userMessage: UserMessagePayload(
                text: "inspect the durable pixel",
                attachments: [artifact.id],
                to: Orchestrator.mainAgentID,
                submissionID: firstSubmission,
                mainAgentInferenceBinding: binding,
                turnID: TurnID(rawValue: "cli-cowork-turn-first")))
        XCTAssertEqual(firstResult, .sent)
        XCTAssertTrue(try XCTUnwrap(firstProvider.requests.first)
            .messages.contains { message in
                message.role == .user
                    && message.content == "inspect the durable pixel"
                    && message.images == [expectedImage]
            })

        await firstRuntime?.cancelAll(reason: "simulate CLI process exit")
        firstRuntime = nil

        let restoredLog = try EventLog(session: sessionID, fileURL: eventURL)
        let restoredStore = try ArtifactStore(root: artifactRoot)
        let restoredProvider = CLIMultimodalCapturingProvider(
            output: "restored cowork answer")
        var restoredRuntime: Orchestrator? = try Self.makeCoworkRuntime(
            log: restoredLog,
            store: restoredStore,
            binding: binding,
            provider: restoredProvider)
        await restoredRuntime?.restore(
            from: CoworkProjection.build(from: await restoredLog.replay()))
        let restoredMain = await restoredRuntime?.agentList().first(where: {
            $0.name == Orchestrator.mainAgentID
        })
        XCTAssertEqual(restoredMain?.agentInferenceBinding, binding)
        let started = await restoredRuntime?
            .startNewTasksKeepingRestoredTasksPaused()
        XCTAssertEqual(started, true)

        let secondResult = await restoredRuntime?.send(
            "use the image after restart",
            to: Orchestrator.mainAgentID,
            userMessage: UserMessagePayload(
                text: "use the image after restart",
                to: Orchestrator.mainAgentID,
                submissionID: SubmissionID(
                    rawValue: "cli-cowork-image-second"),
                mainAgentInferenceBinding: binding,
                turnID: TurnID(rawValue: "cli-cowork-turn-second")))
        XCTAssertEqual(secondResult, .sent)
        let restartRequest = try XCTUnwrap(restoredProvider.requests.first)
        XCTAssertTrue(restartRequest.messages.contains { message in
            message.role == .user
                && message.content == "inspect the durable pixel"
                && message.images == [expectedImage]
        })

        let restoredEvents = try await restoredLog.replayChecked()
        let restoredImageItems: [ModelHistoryItemPayload] =
            restoredEvents.compactMap { envelope in
                guard case .modelHistoryItem(let payload) = envelope.event,
                      payload.submissionID == firstSubmission,
                      payload.messageClassification == .realUser else {
                    return nil
                }
                return payload
            }
        let durableItem = try XCTUnwrap(restoredImageItems.first)
        XCTAssertEqual(
            durableItem.imageReferences?.map { $0.artifactID },
            [artifact.id])
        await restoredRuntime?.cancelAll(reason: "test complete")
        restoredRuntime = nil
    }

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    private static let coworkBinding = AgentInferenceBinding(
        inferenceProfileRef: InferenceProfileRef(
            inferenceProfileID: InferenceProfileID(
                rawValue: "cli-cowork-vision"),
            inferenceProfileRevision: InferenceProfileRevision(
                rawValue: "revision-1")),
        inferenceConnectionID: InferenceConnectionID(
            rawValue: "cli-cowork-connection"),
        inferenceConnectionRevision: InferenceConnectionRevision(
            rawValue: "revision-1"),
        modelID: ModelID(rawValue: "cli-cowork-vision-model"),
        safeRouteLabel: "test route",
        trustDomain: "test",
        egressClassification: "none",
        immutableDefinitionFingerprint: "cli-cowork-vision-revision-1")

    private static func makeCoworkRuntime(
        log: EventLog,
        store: ArtifactStore,
        binding: AgentInferenceBinding,
        provider: any ToolCallingProvider
    ) throws -> Orchestrator {
        try Orchestrator.runtime(
            log: log,
            allowsShell: false,
            responder: FixedResponder(.allow),
            availableInferenceProfiles: [binding],
            requiresInferenceBindings: true,
            imageResolver: AgentImageResolution.resolver(store: store),
            resolvedInferenceFor: { agent in
                guard agent.agentInferenceBinding == binding,
                      agent.model == binding.modelID else {
                    throw InferenceCatalogError.unresolvedProfile
                }
                return ResolvedInferenceProfile(
                    binding: binding,
                    model: binding.modelID,
                    provider: provider)
            })
    }
}
