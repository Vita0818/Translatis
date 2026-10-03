#if canImport(SwiftUI)
import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation
@testable import IntatisSharedUI

private struct ChatAutoTitleTestSecretResolver: SecretResolver {
    func secret(for ref: KeychainRef) async throws -> String { "test-key" }
}

private final class ChatAutoTitleTerminationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var wasTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func markTerminated() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private enum ChatAutoTitleHTTPScript: @unchecked Sendable {
    case chunks([Data])
    case never(ChatAutoTitleTerminationProbe)
}

private final class ChatAutoTitleSequentialHTTP: HTTPByteStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private let scripts: [ChatAutoTitleHTTPScript]
    private var nextScriptIndex = 0
    private var requests: [URLRequest] = []

    init(scripts: [ChatAutoTitleHTTPScript]) {
        self.scripts = scripts
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    var recordedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        let script: ChatAutoTitleHTTPScript = {
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
            guard nextScriptIndex < scripts.count else {
                return .chunks([])
            }
            let value = scripts[nextScriptIndex]
            nextScriptIndex += 1
            return value
        }()

        return AsyncThrowingStream { continuation in
            switch script {
            case .chunks(let chunks):
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            case .never(let probe):
                let producer = Task {
                    do {
                        try await Task.sleep(for: .seconds(60))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    probe.markTerminated()
                    producer.cancel()
                }
            }
        }
    }
}

private actor ChatAutoTitleCommitRecorder {
    private var values: [ChatSessionAutoTitleCommit] = []

    func append(_ commit: ChatSessionAutoTitleCommit) {
        values.append(commit)
    }

    func snapshot() -> [ChatSessionAutoTitleCommit] {
        values
    }
}

@MainActor
final class ChatAutoTitleViewModelTests: XCTestCase {
    func testSuccessfulChatTurnTriggersHiddenTitleWithoutPollutingConversationState()
        async throws
    {
        let mainSSE = Self.completedSSE("这是主对话回答")
        let titleSSE = Self.completedSSE("iOS 输入框布局修复")
        let http = ChatAutoTitleSequentialHTTP(scripts: [
            .chunks([Data(mainSSE.utf8)]),
            .chunks([Data(titleSSE.utf8)]),
        ])
        let fixture = try makeFixture("success", http: http)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.viewModel.start()
        fixture.viewModel.input = "为什么 iOS 输入框没有对齐"
        fixture.viewModel.send()

        try await waitUntil {
            !fixture.viewModel.isStreaming && http.requestCount == 2
        }
        try await waitUntilAsync {
            !(await fixture.recorder.snapshot()).isEmpty
        }

        XCTAssertFalse(fixture.viewModel.isBusy)
        XCTAssertNil(fixture.viewModel.errorText)
        XCTAssertEqual(fixture.viewModel.messages.count, 2)
        XCTAssertEqual(fixture.viewModel.messages.map(\.role), [.user, .assistant])

        let replay = try await fixture.log.replayChecked()
        var userMessages = 0
        var assistantCompletions = 0
        var settingsUpdates = 0
        for envelope in replay {
            switch envelope.event {
            case .userMessage:
                userMessages += 1
            case .messageCompleted(let payload) where payload.role == .assistant:
                assistantCompletions += 1
            case .sessionSettingsUpdated:
                settingsUpdates += 1
            default:
                break
            }
        }
        XCTAssertEqual(userMessages, 1)
        XCTAssertEqual(assistantCompletions, 1)
        XCTAssertEqual(settingsUpdates, 1)

        let commits = await fixture.recorder.snapshot()
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.sessionID, fixture.sessionID)
        XCTAssertEqual(commits.first?.kind, .chat)
        XCTAssertEqual(commits.first?.displayName, "iOS 输入框布局修复")

        let requests = http.recordedRequests
        XCTAssertEqual(requests.count, 2)
        let titleBody = try XCTUnwrap(requests.last?.httpBody)
        let titleJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: titleBody) as? [String: Any])
        XCTAssertEqual(titleJSON["model"] as? String, "chat-auto-title-test")
        XCTAssertNil(titleJSON["tools"])
        XCTAssertNil(titleJSON["tool_choice"])
        let messages = try XCTUnwrap(titleJSON["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")

        await fixture.viewModel.shutdown(reason: "test")
    }

    func testFailedChatTurnDoesNotDispatchAutomaticTitleRequest() async throws {
        let incompleteMainSSE = """
        data: {"choices":[{"delta":{"content":"partial"}}]}

        """
        let http = ChatAutoTitleSequentialHTTP(scripts: [
            .chunks([Data(incompleteMainSSE.utf8)]),
        ])
        let fixture = try makeFixture("failed", http: http)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.viewModel.start()
        fixture.viewModel.input = "这个回合会失败"
        fixture.viewModel.send()

        try await waitUntil { !fixture.viewModel.isStreaming }
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(http.requestCount, 1)
        let commits = await fixture.recorder.snapshot()
        XCTAssertTrue(commits.isEmpty)
        let settings = try SessionProjectionStore.canonicalSessionSettings(
            from: await fixture.log.replay(),
            session: fixture.sessionID)
        XCTAssertNil(settings?.displayName)

        await fixture.viewModel.shutdown(reason: "test")
    }

    func testViewModelShutdownCancelsAndWaitsForHiddenTitleConsumer() async throws {
        let probe = ChatAutoTitleTerminationProbe()
        let http = ChatAutoTitleSequentialHTTP(scripts: [
            .chunks([Data(Self.completedSSE("主回答").utf8)]),
            .never(probe),
        ])
        let fixture = try makeFixture("shutdown", http: http)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.viewModel.input = "启动一个会等待的标题请求"
        fixture.viewModel.send()
        try await waitUntil { http.requestCount == 2 }

        XCTAssertFalse(fixture.viewModel.isStreaming)
        XCTAssertFalse(fixture.viewModel.isBusy)
        async let firstShutdown: Void = fixture.viewModel.shutdown(reason: "test")
        async let secondShutdown: Void = fixture.viewModel.shutdown(reason: "test")
        _ = await (firstShutdown, secondShutdown)

        XCTAssertTrue(probe.wasTerminated)
        let commits = await fixture.recorder.snapshot()
        XCTAssertTrue(commits.isEmpty)
        let settings = try SessionProjectionStore.canonicalSessionSettings(
            from: await fixture.log.replay(),
            session: fixture.sessionID)
        XCTAssertNil(settings?.displayName)
    }

    private func makeFixture(
        _ name: String,
        http: ChatAutoTitleSequentialHTTP
    ) throws -> (
        root: URL,
        sessionID: SessionID,
        log: EventLog,
        recorder: ChatAutoTitleCommitRecorder,
        viewModel: ChatViewModel
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-chat-auto-title-vm-\(name)-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let sessionID = SessionID(rawValue: "chat_auto_title_vm_\(name)")
        let log = try EventLog(
            session: sessionID,
            fileURL: root.appendingPathComponent("events.jsonl"))
        let endpoint = ProviderEndpoint(
            id: "chat-auto-title-endpoint",
            baseURL: URL(string: "https://example.test/v1")!,
            apiKeyRef: KeychainRef(service: "test", account: "test"),
            wire: .openai)
        let model = ModelID(rawValue: "chat-auto-title-test")
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [endpoint],
                models: ResolvedModels(chat: ModelRef(
                    endpoint: endpoint.id,
                    model: model))),
            resolver: ChatAutoTitleTestSecretResolver(),
            http: http)
        let recorder = ChatAutoTitleCommitRecorder()
        let coordinator = ChatSessionAutoTitleCoordinator()
        let autoTitleSession = coordinator.bind(
            sessionID: sessionID,
            log: log,
            onCommit: { commit in
                await recorder.append(commit)
            })
        let viewModel = ChatViewModel(
            log: log,
            registry: registry,
            autoTitleSession: autoTitleSession)
        return (root, sessionID, log, recorder, viewModel)
    }

    private static func completedSSE(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        data: {"choices":[{"delta":{"content":"\(escaped)"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
    }

    private func waitUntil(
        attempts: Int = 2_000,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for ChatViewModel state")
    }

    private func waitUntilAsync(
        attempts: Int = 2_000,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for async Chat metadata state")
    }
}
#endif
